-- Что показывает «Мой компьютер».
--
-- Диски — это записи `fs.*` реестра, и заводить их не надо: почти каждый
-- установленный модуль привозит свою файловую систему, и на стенде их
-- десятки. Окно их ПОКАЗЫВАЕТ. Отсюда оба правила разом: диск, объявленный
-- установленным модулем, появляется сам, без правки в оболочке; а диска,
-- которого нет в реестре, здесь не будет — нарисованный `C:` был бы
-- предметом, которого не существует, и первым вопросом было бы, почему он не
-- открывается.
--
-- Корень показывает только диски. Для открытых напрямую папок стола и
-- служебных путей остаются отдельные модели источников; оболочка их читает
-- по другим поводам:
--
--   Программы      — каталог реестра, тот же, что наполняет меню «Пуск»
--   Рабочий стол   — своя раскладка, ярлыки и папки стола
--   Открытые окна  — то, что сейчас на экране, у композитора основы
--
-- Чего здесь намеренно НЕТ: прогонов, работ бриджа, битов контент-машины.
-- Читать чужие таблицы напрямую значило бы завести зависимость от схем
-- модулей, от которых оболочка не зависит, — и сломаться на их первой
-- миграции, молча и не у себя. Модуль, желающий показать своё, объявляет окно
-- записью с `meta.type: tui_desktop.window`, и оно появляется в «Программах»
-- само. Это тот же принцип, на котором стоит весь модуль: объявляет реестр.
--
-- Разбиение на чистую сборку и чтение источников — то же, что в каталоге:
-- правило, проверяемое только через живую базу, проверяется один раз, а потом
-- никогда.

local catalog = require("catalog")
local associations = require("associations")

local model = {}

model.ROOT = ""

-- Filesystem kinds supported by the installed runtime. Discovery and object
-- construction share this list, so non-filesystem registry entries stay out.
model.DRIVE_KINDS = {"fs.directory", "fs.embed"}
local drive_kinds = {}
for _, kind in ipairs(model.DRIVE_KINDS) do drive_kinds[kind] = true end

model.DEFAULT_ICON = "▢"
model.BROKEN_ICON = "▨"
model.DRIVE_ICON = "▦"
model.DIR_ICON = "▤"
model.FILE_ICON = "▫"

-- Путь — строка, и её грамматика вся здесь, потому что читают её трое: окно
-- (чтобы знать, что рисовать), источники (чтобы знать, что читать) и кнопка
-- «Вверх» (чтобы знать, куда возвращаться). Разойдись они — «Вверх» уводила
-- бы не туда, куда ведёт двойной щелчок.
--
--   ""                    корень «Моего компьютера»
--   "programs"            каталог программ
--   "desktop"             рабочий стол, верхний уровень
--   "desktop/<id>"        папка стола
--   "windows"             открытые окна
--   "drive/<запись>"      корень файловой системы из реестра
--   "drive/<запись>/<путь>"  каталог внутри неё
--
-- Идентификатор записи реестра — всегда `namespace:name`, и косой черты в нём
-- быть не может; на этом и стоит разбор пути внутри диска.
function model.parse(path: any)
    local text = type(path) == "string" and path or ""

    if text == model.ROOT then return {view = "root"} end
    if text == "programs" then return {view = "programs"} end
    if text == "desktop" then return {view = "desktop"} end
    if text == "windows" then return {view = "windows"} end

    local folder = string.match(text, "^desktop/(.+)$")
    if folder then return {view = "desktop_folder", id = folder} end

    local drive, rest = string.match(text, "^drive/([^/]+)(.*)$")
    if drive then
        local inside = string.match(tostring(rest), "^/(.+)$")
        return {view = "drive", id = drive, sub = inside}
    end

    -- Неизвестный путь — это не корень. Молчаливый откат к корню превратил бы
    -- опечатку в успешный переход, и человек решил бы, что папка пуста.
    return {view = "unknown"}
end

-- parent(path) -> путь на уровень выше | nil, если выше некуда
--
-- Тем же разбором, что и `parse`: кнопка «Вверх», считающая путь своей
-- формулой, разъедется с двойным щелчком, и разойдутся они молча.
-- address(path) -> строка адреса, как её показала бы Windows: `Мой компьютер`,
-- `Мой компьютер\Программы`, `app:app_fs\src\app`. Диск называется своей
-- записью реестра — другого имени у него нет, а придуманная буква обещала
-- бы то, чего не существует.
function model.address(path: any): string
    local where: any = model.parse(path)
    if where.view == "root" then return "My Computer" end
    if where.view == "programs" then return "My Computer\\Programs" end
    if where.view == "desktop" then return "My Computer\\Desktop" end
    if where.view == "desktop_folder" then return "My Computer\\Desktop\\" .. tostring(where.id) end
    if where.view == "windows" then return "My Computer\\Open Windows" end
    if where.view == "drive" then
        local text = tostring(where.id)
        if where.sub then text = text .. "\\" .. tostring(where.sub):gsub("/", "\\") end
        return text
    end
    return tostring(path or "")
end

-- ancestors(path) -> список {title, path} от корня до текущей папки.
--
-- Это содержимое выпадающего списка адресной строки: каждая строка — куда
-- можно перейти одним щелчком. Последняя — сама папка.
function model.ancestors(path: any): any
    local chain: any = {}
    local at: any = path
    local guard = 0
    while at ~= nil and guard < 64 do
        guard = guard + 1
        table.insert(chain, 1, {title = model.address(at), path = at})
        if at == model.ROOT then break end
        at = model.parent(at)
        if at == nil then break end
    end
    if #chain == 0 or chain[1].path ~= model.ROOT then
        table.insert(chain, 1, {title = "My Computer", path = model.ROOT})
    end
    return chain
end

function model.parent(path: any)
    local where = model.parse(path)

    if where.view == "root" then return nil end
    if where.view == "desktop_folder" then return "desktop" end

    if where.view == "drive" then
        if not where.sub then return model.ROOT end
        local up = string.match(tostring(where.sub), "^(.+)/[^/]+$")
        if up then return "drive/" .. tostring(where.id) .. "/" .. up end
        return "drive/" .. tostring(where.id)
    end

    return model.ROOT
end

-- Объект: что видно (title, icon, detail) и что происходит по двойному щелчку
-- (open). Двойной, а не одиночный: программа, стартующая с одного клика, —
-- ловушка, и в настоящей Windows её тоже нет.
--
-- `open` описывает НАМЕРЕНИЕ, а не выполняет его: окно не порождает процессов
-- и не открывает соседей само, оно просит об этом композитор. Разбор намерения
-- живёт в одном месте, и окно не решает по дороге, что значит «открыть».
local function object(fields: any)
    return {
        id = fields.id,
        kind = fields.kind,
        title = fields.title,
        icon = fields.icon,
        image = fields.image, entry = fields.entry, broken = fields.broken,
        detail = fields.detail,
        open = fields.open,
    }
end

-- Диски: записи `fs.directory` и `fs.embed` реестра как они есть.
--
-- Своей таблицы дисков нет и быть не может — она означала бы, что модуль,
-- привёзший файловую систему, не появится здесь, пока кто-то не впишет его
-- руками. Поэтому список ровно такой, каким его отдал реестр.
--
-- Подпись — имя записи, а не полный идентификатор: `wippy.facade:public_files`
-- в двенадцать ячеек подписи не помещается и обрезается ровно там, где
-- начинается различие.
--
-- Но имя не всегда различает: `ui_static_fs` привозят сразу несколько
-- модулей, и два одинаковых значка рядом — это не подпись, а загадка. Тогда
-- к имени добавляется пространство имён, и добавляется ПРОБЕЛОМ, а не
-- двоеточием: подпись переносится по пробелам, и `keeper ui_static_fs`
-- ложится двумя строками, где хотя бы первая читается целиком, а
-- `keeper:ui_static_fs` обрезается в `keeper:ui_st` — то есть ровно там, где
-- начинается различие, ради которого его и удлинили.
--
-- Удлиняются ОБА совпавших имени, а не второе: подпись, зависящая от порядка
-- чтения реестра, меняется сама по себе.
--
-- Полный идентификатор при этом не теряется: он в `detail`, а `detail`
-- выделенного объекта окно показывает в статусной строке.
function model.drives(records: any)
    local seen: any = {}
    local drives: any = {}

    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record: any = entry
        if type(record.id) == "string" and record.id ~= "" and drive_kinds[record.kind] then
            local space, name = string.match(record.id, "^([^:]*):(.+)$")
            if not name then space, name = "", record.id end
            seen[name] = (seen[name] or 0) + 1
            drives[#drives + 1] = {
                id = record.id, name = name, space = space, kind = record.kind,
            }
        end
    end

    -- Порядок задан здесь и не наследуется от реестра: список, порядок
    -- которого решает чужая выдача, переставляет значки сам по себе, и
    -- человек, привыкший к месту, каждый раз ищет заново.
    table.sort(drives, function(left, right) return left.id < right.id end)

    local out = {}
    for _, drive in ipairs(drives) do
        local ambiguous = (seen[drive.name] or 0) > 1 and drive.space ~= ""
        out[#out + 1] = object({
            id = drive.id,
            kind = "drive",
            title = ambiguous and (drive.space .. " " .. drive.name) or drive.name,
            icon = model.DRIVE_ICON,
            -- Вид записи — это ответ на «почему он не открывается»: `fs.embed`
            -- вморожен в модуль и доступен только на чтение, `fs.directory` —
            -- настоящий каталог на диске.
            detail = drive.id .. " · " .. tostring(drive.kind or "fs"),
            open = {action = "folder", path = "drive/" .. drive.id},
        })
    end
    return out
end

-- Содержимое каталога внутри диска. `entries` — то, что отдал `readdir`:
-- имя и вид, и больше ничего. Размера здесь нет намеренно — за ним пришлось
-- бы делать `stat` на каждую строку, то есть сотню обращений к диску ради
-- колонки, которой в значках всё равно нет.
--
-- Файл открывает программа из реестра типов (`associations.open`). У файла,
-- которого нечем открыть, намерения нет: оно было бы обещанием, которое
-- некому исполнить. Причина лежит в `detail`, и на двойной щелчок окно
-- говорит её тем же способом, что и про любой другой отказ.
function model.files(entries: any, path: any, drive: any, sub: any, programs: any)
    local rows = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local record: any = entry
        if type(record.name) == "string" and record.name ~= "" then
            rows[#rows + 1] = {name = record.name, dir = record.type == "directory"}
        end
    end

    -- Папки раньше файлов, дальше по имени — как в проводнике. Порядок,
    -- взятый у файловой системы, у каждой свой.
    table.sort(rows, function(left, right)
        if left.dir ~= right.dir then return left.dir end
        return left.name < right.name
    end)

    local base = type(path) == "string" and path or ""
    -- Путь ВНУТРИ диска — то, что получит программа; `path` — это адрес
    -- папки в проводнике, у него другая форма.
    local inside = (type(sub) == "string" and sub ~= "") and ("/" .. sub) or ""
    local out = {}
    for _, row in ipairs(rows) do
        if row.dir then
            out[#out + 1] = object({
                id = row.name,
                kind = "directory",
                title = row.name,
                icon = model.DIR_ICON,
                detail = "folder",
                open = {action = "folder", path = base .. "/" .. row.name},
            })
        else
            -- Файл открывает программа из реестра типов, и она же даёт ему
            -- значок. Файл, который нечем открыть, говорит об этом в
            -- подробностях и не открывается — вместо тишины на двойной щелчок.
            local file_path = inside .. "/" .. row.name
            local open, why = associations.open(programs, drive, file_path)
            out[#out + 1] = object({
                id = row.name,
                kind = "file",
                title = row.name,
                icon = model.FILE_ICON,
                image = associations.image_for(programs, row.name),
                detail = open and "file" or tostring(why),
                open = open,
            })
        end
    end
    return out
end

-- My Computer contains filesystem entries only; other shell objects are
-- reached through their own menu or desktop folder.
function model.root(records: any)
    return model.drives(records)
end

-- Программы каталога. Плоско, без папок меню: в окне проводника папки меню
-- были бы вторым деревом рядом с деревом «Мой компьютер», и человек не понял
-- бы, в каком из них он находится.
function model.programs(programs: any)
    local out = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        out[#out + 1] = object({
            id = program.entry,
            kind = "program",
            title = program.title,
            icon = program.icon or model.DEFAULT_ICON,
            image = program.image, entry = program.entry,
            detail = program.entry,
            open = {
                action = "open_window",
                entry = program.entry,
                title = program.title,
                w = program.width,
                h = program.height,
                args = program.args,
            },
        })
    end
    return out
end

-- Ярлыки и папки стола. Битый ярлык виден и здесь, и по той же причине:
-- пропавшая строка читается как «я его случайно удалил», битая — как
-- «программы больше нет».
function model.desktop(items: any, programs: any)
    local out = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if item.kind == "folder" then
            out[#out + 1] = object({
                id = item.id,
                kind = "folder",
                title = item.title,
                icon = "▤",
                detail = "desktop folder",
                -- Папка стола открывается своим окном, а не этим: у неё своё
                -- содержимое и своя раскладка.
                open = {action = "folder", path = "desktop/" .. tostring(item.id)},
            })
        else
            local program = catalog.find(programs, item.entry)
            out[#out + 1] = object({
                id = item.id,
                kind = "shortcut",
                title = item.title,
                icon = program and (program.icon or model.DEFAULT_ICON) or model.BROKEN_ICON,
                image = program and program.image, entry = item.entry,
                broken = programs ~= nil and program == nil or nil,
                detail = program and item.entry or ("no program: " .. tostring(item.entry)),
                open = program and {
                    action = "open_window",
                    entry = item.entry,
                    title = item.title,
                    w = program.width,
                    h = program.height,
                    args = program.args,
                } or nil,
            })
        end
    end
    return out
end

-- Открытые окна. Двойной щелчок поднимает окно, а не открывает второе такое
-- же: список показывает то, что уже на экране, и «открыть» здесь значит
-- «показать».
function model.windows(windows: any)
    local out = {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
        out[#out + 1] = object({
            id = window.id,
            kind = "window",
            title = window.title or window.id,
            icon = "◫",
            detail = window.minimized and "minimized" or "on screen",
            open = {action = "raise", id = window.id},
        })
    end
    return out
end

-- ─── ответы композитора ──────────────────────────────────────────────────
--
-- Канал ответов у окна один, и приезжает в него не только ответ на
-- `desktop.list`. Команды без ожидания — `desktop.open`, `desktop.focus`,
-- `desktop.state` — композитор отказывает тем же каналом, с пометкой
-- `unsolicited` (основа, `refuse`). Окно, читавшее всё подряд как список,
-- принимало отказ открыть программу за «список окон не прочитан»: причина
-- ложилась в папку, на которую никто не смотрел, а на экране не было ничего.

local NO_REASON = "the compositor refused without a reason"

-- Как отказ называется в строке состояния. Одна таблица и для отказа,
-- пришедшего сразу (композитор не найден), и для пришедшего потом каналом:
-- две формулировки одного отказа читались бы как два разных.
local REFUSED: any = {["desktop.open"] = "did not open", ["desktop.focus"] = "did not start"}

function model.refusal(command: any, reason: any): string
    local prefix = REFUSED[tostring(command)]
        or (type(command) == "string" and command .. " refused" or "refused")
    return prefix .. ": " .. tostring(reason or NO_REASON)
end

-- take_reply(state, body) -> "list" | "notice" | nil
--
-- "list" — пришёл список окон или отказ его дать, папку надо перечитать;
-- "notice" — отказ другой команде: он лёг в строку состояния, список не
-- тронут; nil — ответ не на вопрос этого окна, класть его некуда.
function model.take_reply(state: any, body: any): any
    if type(body) ~= "table" then return nil end
    if body.unsolicited or (body.ok == false and body.command ~= "desktop.list") then
        state.notice = model.refusal(body.command, body.error)
        return "notice"
    end
    if body.command ~= "desktop.list" then return nil end
    if body.ok == false then
        state.windows_error = tostring(body.error or NO_REASON)
        state.windows = nil
    else
        state.windows = type(body.windows) == "table" and body.windows or {}
        state.windows_error = nil
    end
    return "list"
end

return model
