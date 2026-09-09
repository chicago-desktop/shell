-- Откуда «Мой компьютер» берёт объекты.
--
-- Отделено от сборки объектов нарочно: сборка — чистое правило и проверяется
-- без живой базы, а здесь только чтение. Правило, проверяемое только через
-- базу, проверяется один раз, а потом никогда.
--
-- Читается ровно четыре вещи, и все они либо свои, либо общие:
--
--   диски          записи `fs.*` реестра, и содержимое — модулем `fs`
--   программы      каталог реестра, тот же, что наполняет меню «Пуск»
--   рабочий стол   своя таблица раскладки
--   папка стола    она же, строки с этим родителем
--
-- Чужих таблиц здесь нет и не будет. Прочитать таблицу соседнего модуля
-- значит завести зависимость от его схемы — и сломаться на ЕГО миграции,
-- молча, не у себя и через неделю.
--
-- Открытых окон здесь НЕТ, и это не пропуск. Список окон живёт у композитора,
-- и спросить его можно только сообщением с ответом в собственный inbox. Внутри
-- окна так делать нельзя: ждущий цикл забирает из inbox и ЧУЖИЕ сообщения
-- тоже, а выбросить сообщение, адресованное окну, — значит потерять команду
-- композитора без следа. Поэтому список окон приносит сам процесс окна: его
-- цикл владеет inbox и разбирает ответ наравне с остальным, а `model.windows`
-- превращает принесённое в объекты.

local fs = require("fs")
local registry = require("registry")

local catalog = require("catalog")
local model = require("model")
local repo = require("repo")

local sources = {}

-- Виды записей, которые оболочка считает диском. Их два, и оба настоящие:
-- `fs.directory` — каталог на диске, `fs.embed` — файлы, вмороженные в модуль
-- при сборке. Третьего вида не изобретаем: диск, которого нет в реестре,
-- рисовать нельзя.
sources.DRIVE_KINDS = model.DRIVE_KINDS

-- Потолок на одно чтение каталога. Каталог с десятью тысячами файлов собрал бы
-- десять тысяч объектов ради трёх строк, которые влезут в окно. Обрезка НЕ
-- молчаливая: срезанный список говорит об этом сам, иначе «показано всё» и
-- «показано начало» выглядят одинаково.
sources.FILE_LIMIT = 500

-- drives() -> (записи, nil) | (nil, причина)
--
-- Отказ реестра и «дисков нет» — разные исходы, как и везде здесь. Пустой
-- список на отказе сказал бы «файловых систем на стенде не объявлено», то есть
-- утверждение, которого мы не делали.
function sources.drives()
    local out = {}
    for _, kind in ipairs(sources.DRIVE_KINDS) do
        local found, err = registry.find({[".kind"] = kind})
        if err then return nil, "registry not read: " .. tostring(err) end
        if type(found) ~= "table" then
            return nil, "registry not read: the answer is not a list"
        end
        for _, record in ipairs(found) do out[#out + 1] = record end
    end
    return out, nil
end

-- Содержимое каталога внутри диска.
--
-- Читается модулем `fs` под правами самого окна: у окна нет доступа к
-- файловой системе машины, есть доступ к записи реестра, названной диском.
-- Диск, объявленный, но недоступный, отвечает ПРИЧИНОЙ, а не пустотой:
-- пустой каталог и закрытая дверь — разные вещи, и второе человек обязан
-- увидеть словами.
local function read_drive(id: any, sub: any)
    local handle, err = fs.get(tostring(id))
    if err or not handle then
        return nil, "drive not opened: " .. tostring(err or "no such entry")
    end

    local path = "/"
    if type(sub) == "string" and sub ~= "" then path = "/" .. sub end

    local iterator, state = handle:readdir(path)
    if type(iterator) ~= "function" then
        return nil, "catalog not read: " .. tostring(state)
    end

    local entries, cut = {}, false
    for entry in iterator, state do
        if #entries >= sources.FILE_LIMIT then
            cut = true
            break
        end
        entries[#entries + 1] = entry
    end

    return entries, nil, cut
end

-- list(path, context) -> (вид, nil) | (nil, причина)
--
-- Вид: { objects = список, title = заголовок, notice = замечание | nil }.
--
-- Отказ и пустая папка различаются ПЕРВЫМ значением: пустая папка — вид с
-- пустым списком, нечитаемый источник — nil и причина. Одинаковые, они
-- отправляют человека искать пропажу там, где ничего не пропадало.
--
-- `notice` — третье состояние между ними: прочитали, но не всё. Замечание не
-- прячет объекты и не выдаёт себя за отказ.
--
function sources.list(path, context: any)
    local where = model.parse(path)

    if where.view == "root" then
        local records, err = sources.drives()
        if err or not records then return nil, err or "drives not read" end
        return {objects = model.root(records), title = "My Computer"}, nil
    end

    if where.view == "programs" then
        local found, err = catalog.list()
        if err or not found then return nil, err or "catalog not read" end
        -- Та же папка, что и меню «Пуск», только в другом виде: здесь человек
        -- ВЫБИРАЕТ программу, а не ищет её по ссылке. Программа, попросившая
        -- не показывать себя в меню, спрятана и тут — иначе признак не значит
        -- ничего, кроме «в одном из двух списков меня нет».
        return {objects = model.programs(catalog.listed(found.programs)),
                title = "Programs"}, nil
    end

    if where.view == "desktop" then
        local items, err = repo.list()
        if err then return nil, "layout not read: " .. tostring(err) end
        -- Каталог нужен, чтобы отличить битый ярлык от исправного. Его отказ
        -- НЕ прячет стол: объекты отдаются, просто все без признака битости —
        -- обвинить исправную программу хуже, чем промолчать.
        local found = catalog.list()
        -- Верхний уровень — только то, что лежит НА столе. Содержимое папок
        -- отдаётся тем же чтением, и показать его здесь значило бы показать
        -- каждый вложенный значок дважды: в папке и рядом с ней.
        local top = {}
        for _, item in ipairs(items or {}) do
            if not (item :: any).parent_id then top[#top + 1] = item end
        end
        return {
            objects = model.desktop(top, found and found.programs or nil),
            title = "Desktop",
        }, nil
    end

    if where.view == "desktop_folder" then
        local items, err = repo.list()
        if err then return nil, "layout not read: " .. tostring(err) end

        local folder: any = nil
        local inside = {}
        for _, entry in ipairs(items or {}) do
            local item: any = entry
            if item.id == where.id then folder = item end
            if item.parent_id == where.id then inside[#inside + 1] = item end
        end

        -- Папки нет — это отказ, а не пустая папка: молчание превратило бы
        -- опечатку в пути в успешно открытую пустоту.
        if not folder then return nil, "no such folder: " .. tostring(where.id) end
        if folder.kind ~= "folder" then
            return nil, "not a folder: " .. tostring(where.id)
        end

        local found = catalog.list()
        return {
            objects = model.desktop(inside, found and found.programs or nil),
            title = tostring(folder.title or "Folder"),
        }, nil
    end

    if where.view == "drive" then
        local entries, err, cut = read_drive(where.id, where.sub)
        if err or not entries then return nil, err or "drive not read" end

        local title = tostring(where.id)
        if where.sub then title = title .. "/" .. tostring(where.sub) end

        -- Каталог нужен файлам: программа для расширения и её значок берутся
        -- из реестра типов. Отказ каталога не прячет файлы — они остаются
        -- «нечем открыть», как и положено без программ.
        local found = catalog.list()

        return {
            objects = model.files(entries, path, where.id, where.sub, found and found.programs or nil),
            title = title,
            notice = cut and ("showing the first " .. tostring(sources.FILE_LIMIT)) or nil,
        }, nil
    end

    return nil, "unknown folder: " .. tostring(path)
end

return sources
