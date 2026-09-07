-- Оболочка в стиле Windows 95: композитор основы, вызванный со своей темой.
--
-- Своей механики окон здесь нет ни строки. Хостинг окон, PTY, командный канал
-- и мастерская остаются в butschster/tui-desktop; отсюда приходят вид (тема),
-- каталог с папками меню и раскладка рабочего стола.
--
-- Копия композитора вместо вызова разошлась бы с оригиналом на первой правке,
-- и обнаружилось бы это через неделю на живом стенде.

local logger = require("logger")
local env = require("env")
local fs = require("fs")
local gfx = require("gfx")
local library = require("library")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local catalog = require("catalog")
local defaults = require("defaults")
local seed = require("seed")
local view = require("view")
local repo = require("repo")

local SERVICE_NAME = "butschster.windows.shell"

-- Шрифт пиксельной темы. Приезжает БАЙТАМИ через `fs`, а не путём внутри
-- `gfx`: чтение файла управляется правами процесса, и модуль, открывающий
-- пути сам, был бы дорогой мимо них. Побочно это значит, что шрифт может
-- приехать откуда угодно — из встроенной файловой системы модуля, из базы.
--
-- Полужирный — ОТДЕЛЬНЫЙ файл, а не опция: в Windows 95 заголовок набран им,
-- и синтезировать его размазыванием пикселей значит перестать быть похожим.
-- ЛОВУШКА, СТОИВШАЯ ЧУЖОЙ СЕССИИ И ОДНОГО ПУСТОГО ЗАПУСКА ЗДЕСЬ.
--
-- `env.get` видит ТОЛЬКО файловое хранилище. На переменную, которая есть в
-- окружении процесса, он отвечает «environment variable not found» — то есть
-- `BUTSCHSTER_WINDOWS_PIXELS=1 wippy run …` не работает и работать не будет.
-- Окружение процесса отдаёт `env.get_all`.
--
-- Хуже самого промаха его вид: отказ выглядит как «человек не просил
-- пикселей», а не как «мы не сумели прочитать». Поэтому читаем оба источника
-- и РАЗЛИЧАЕМ их в причине.
local function environment(): any
    local all = env.get_all()
    return type(all) == "table" and all or {}
end

-- read(name) -> значение, откуда взято
--
-- Возвращает второе значение нарочно: «переменная не задана» и «переменная
-- задана, но не тем способом» — разные факты, и второй человек не угадает.
local function read(name): (any, string)
    local from_env: any = environment()[name]
    if type(from_env) == "string" and from_env ~= "" then
        return from_env, "окружение процесса"
    end
    local stored = env.get(name)
    if type(stored) == "string" and stored ~= "" then
        return stored, "файловое хранилище"
    end
    return nil, "не задана"
end

local FONTS = read("BUTSCHSTER_WINDOWS_FONTS") or "app:system_fonts"
local FONT_FACE = "LiberationSans-Regular.ttf"
local FONT_BOLD = "LiberationSans-Bold.ttf"
local FONT_SIZE = 13

-- Пиксельный режим включается ЯВНО, а не по наличию графики (FR-005 §6):
-- терминал, умеющий sixel, — не повод перерисовывать интерфейс иначе, чем
-- человек просил.
--
-- Отвечает вторым значением, ОТКУДА взято, чтобы «не просил» и «просил, но не
-- прочиталось» не выглядели одинаково.
local function wants_pixels(): (boolean, string)
    local asked, source = read("BUTSCHSTER_WINDOWS_PIXELS")
    if asked == "1" or asked == "true" or asked == "yes" then return true, source end
    if asked ~= nil then return false, "задана как «" .. tostring(asked) .. "»" end
    return false, source
end

-- Шрифты для пиксельной темы. Отказ здесь — НЕ повод погасить оболочку:
-- она поднимается в ячейках и говорит причину. Пустой экран вместо стола
-- читается как сломанный стенд, а не как ненайденный файл.
local function load_fonts(log)
    local store, err = fs.get(FONTS)
    if err or not store then
        return nil, "шрифты не открылись (" .. FONTS .. "): " .. tostring(err)
    end

    local face_data, ferr = store:readfile(FONT_FACE)
    if ferr or not face_data then
        return nil, FONT_FACE .. " не прочитан: " .. tostring(ferr)
    end
    local bold_data, berr = store:readfile(FONT_BOLD)
    if berr or not bold_data then
        return nil, FONT_BOLD .. " не прочитан: " .. tostring(berr)
    end

    return {face = gfx.font(face_data, {size = FONT_SIZE}),
            bold = gfx.font(bold_data, {size = FONT_SIZE})}, nil
end

local function main()
    local log = logger:named("windows.shell")

    -- Каталог читается в момент открытия меню, а не при старте: окно,
    -- собранное мастерской при запущенной оболочке, попадает в меню без
    -- перезапуска.
    --
    -- Отказ реестра возвращается ВТОРЫМ значением, а список остаётся пустым.
    -- Тема обязана показать причину текстом: «ничего нет» и «не смогли
    -- прочитать» — разные утверждения, и человек, увидевший первое вместо
    -- второго, пойдёт искать ошибку в своём приложении, где её нет.
    local function menu_catalog()
        local found, err = catalog.list()
        if err or not found then return {}, err or "каталог не прочитан" end

        -- Опечатка в `window_type` не мешает показать программу, но должна
        -- быть названа: неназванная, она живёт вечно, а окно всё это время
        -- рисуется не тем, чем его объявляли.
        for _, warning in ipairs(found.warnings or {}) do
            log:warn("неизвестный тип окна", {
                entry = tostring((warning :: any).entry),
                window_type = tostring((warning :: any).window_type),
            })
        end

        local items = {}
        -- В меню — только то, что просило в меню. Программа с `in_menu:
        -- false` остаётся в каталоге и открывается ярлыком: признак про
        -- меню, а не про запуск.
        for _, program in ipairs(catalog.listed(found.programs)) do
            items[#items + 1] = {
                entry = program.entry,
                title = program.title,
                -- Композитор основы открывает окно по `w`/`h`; тема читает
                -- те же размеры под своими именами. Два имени одного числа
                -- лучше, чем перевод на границе, который однажды забудут.
                w = program.width,
                h = program.height,
                width = program.width,
                height = program.height,
                icon = program.icon,
                group = program.group,
                order = program.order,
                args = program.args,
                -- Тип едет композитору, чтобы тема выбрала состав кнопок
                -- заголовка по нему. Не поедь он — диалог откроется с тремя
                -- кнопками, из которых две ничего не делают.
                window_type = program.window_type,
            }
        end
        return items, nil
    end

    -- Что появляется на столе само. Мебель первого запуска заводится раньше
    -- программ: композитор кладёт значки в том порядке, в каком их отдаёт
    -- раскладка, и «Мой компьютер» должен занять начало колонки, а не встать
    -- под тем, что подвернулось.
    --
    -- Места здесь не выбирают: строка пишется без координат, и композитор
    -- кладёт значок сам, зная ширину экрана в момент кадра. Оболочка на старте
    -- её ещё не знает, и выбранное ею место могло бы оказаться за краем — а
    -- значок за краем не обрезается, он исчезает целиком.
    --
    -- Отказ здесь не прячет стол и не отменяет кадра: раскладка уже есть, и
    -- незаведённый значок — повод сказать в лог, а не показать пустоту.
    local function furnish(found: any)
        local programs = type(found) == "table" and found.programs or {}

        local _, ferr = seed.furnish(defaults.resolve(programs))
        if ferr then log:warn("мебель стола не заведена", {error = tostring(ferr)}) end

        local _, serr = seed.ensure(programs)
        if serr then log:warn("ярлыки не вынесены на стол", {error = tostring(serr)}) end
    end

    -- Раскладка стола. Отдаётся функцией, а не таблицей: композитор
    -- перечитывает её по команде `desktop.refresh`, и значок, переставленный
    -- ручкой снаружи, встаёт на место без перезапуска оболочки.
    --
    -- Каталог подмешивается здесь же: значок открывает окно по размерам из
    -- реестра, а не по копии, снятой при создании ярлыка.
    local function desktop_items()
        -- Каталог читается ДО раскладки: мебель заводится по нему, и читать
        -- раскладку раньше значило бы отдать кадр без только что заведённых
        -- значков — они появились бы лишь на следующем обновлении.
        local found = catalog.list()
        furnish(found)

        local items, err = repo.list()
        if err then return {}, "раскладка не прочитана: " .. tostring(err) end

        -- Отказ каталога сюда НЕ попадает. `failure` означает «раскладка не
        -- прочитана», и тема на него не рисует значков вовсе — сказать так
        -- из-за нечитаемого каталога значит убрать со стола ярлыки, которых
        -- человек не терял. Без каталога значки рисуются, просто без признака
        -- битости: обвинить исправную программу хуже, чем промолчать.
        return view.join(items or {}, found), nil
    end

    -- Перетаскивание значка мышью ведёт композитор, а записывает место
    -- оболочка — тем же путём, что и ручка PATCH, то есть одним репозиторием.
    -- Второй способ записать место разошёлся бы с первым на первой правке.
    --
    -- Кадр эта функция не роняет ни при каком исходе: неудавшаяся запись
    -- возвращается причиной, значок остаётся там, где был, и человек видит
    -- стол, а не аварию.
    local function move_desktop_item(id, x, y)
        if type(id) ~= "string" or id == "" then
            return false, "значок не назван"
        end
        local item, err = repo.update(id, {x = x, y = y})
        if err then return false, "запись места: " .. tostring(err) end
        -- `false` от репозитория — это «такой строки нет», а не отказ базы.
        -- Молчание здесь превратило бы опечатку в успешное перемещение.
        if item == false then return false, "значка нет: " .. id end
        return true, nil
    end

    -- Пиксельный режим собирается ЗДЕСЬ, а не в механике, и не по прихоти:
    -- запись механики не объявляет `gfx`, поэтому спросить терминал о размере
    -- ячейки она не может. Решение принимает она, вопрос задаём мы.
    --
    -- Каждый отказ по дороге оставляет оболочку в ячейках и НАЗЫВАЕТ причину.
    -- Пиксельный режим, не включившийся молча, выглядит как «почему-то
    -- по-старому», и человек идёт искать поломку там, где её нет.
    local theme: any = chrome
    local cell_size: any = nil

    local asked, source = wants_pixels()
    log:info("пиксельный режим", {asked = asked, source = source})

    if asked then
        local protocol, why = gfx.supported()
        local width, height = gfx.cell_size()

        if not protocol then
            log:warn("пиксельный режим не включён: терминал не умеет графику",
                {reason = tostring(why)})
        elseif not width or not height then
            -- Догадка «8×16» права достаточно часто, чтобы выглядеть верной, и
            -- картинка не того размера читается как ошибка рисования, а не как
            -- незаданный вопрос. Поэтому отказ, а не умолчание.
            log:warn("пиксельный режим не включён: терминал не сказал размер ячейки",
                {reason = tostring(height)})
        else
            local fonts, ferr = load_fonts(log)
            if not fonts then
                log:warn("пиксельный режим не включён: нет шрифта", {error = tostring(ferr)})
            else
                chrome_pixels.use_fonts(fonts.face, fonts.bold)
                theme = chrome_pixels
                cell_size = gfx.cell_size
                log:info("пиксельный режим включён",
                    {protocol = protocol, cell = width .. "x" .. height})
            end
        end
    end

    -- Голым `return library.run(...)` это писать нельзя: в go-lua v1.5.18
    -- хвостовой вызов yield-функции из базового фрейма корутины не
    -- выполняется вовсе — молча, за 0 мс.
    local ok, err = library.run({
        chrome = theme,
        pixels = cell_size ~= nil,
        -- Функцией, а не значением: размер ячейки меняется, когда человек
        -- меняет шрифт терминала, и снятое однажды число разъедется с экраном.
        cell_size = cell_size,
        service_name = SERVICE_NAME,
        hint = "Пуск — программы · alt+n — окно с bash · ctrl+q — выход",
        -- Необязательные швы к основе. Не поддержи их композитор — меню
        -- откатывается к его собственному плоскому каталогу, а стол остаётся
        -- без значков; оболочка при этом поднимается и работает.
        catalog = menu_catalog,
        desktop_items = desktop_items,
        move_desktop_item = move_desktop_item,
        -- Окна, собранные мастерской основы, возвращаются в реестр на старте.
        -- Оболочка часто поднимается одна, и без восстановления её меню
        -- показало бы каталог без них, не объяснив, куда они делись. Отказ
        -- восстановления уезжает в restore_report и виден в GET /windows/status.
        restore = true,
    })
    return ok, err
end

return {main = main}
