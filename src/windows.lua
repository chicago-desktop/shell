-- Оболочка в стиле Windows 95: композитор основы, вызванный со своей темой.
--
-- Своей механики окон здесь нет ни строки. Хостинг окон, PTY, командный канал
-- и мастерская остаются в butschster/tui-desktop; отсюда приходят вид (тема),
-- каталог с папками меню и раскладка рабочего стола.
--
-- Копия композитора вместо вызова разошлась бы с оригиналом на первой правке,
-- и обнаружилось бы это через неделю на живом стенде.

local logger = require("logger")
local environment = require("environment")
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
local logon_screen = require("logon_screen")
local logon_provider = require("logon_provider")

local SERVICE_NAME = "butschster.windows.shell"

-- Шрифт пиксельной темы. Приезжает БАЙТАМИ через `fs`, а не путём внутри
-- `gfx`: чтение файла управляется правами процесса, и модуль, открывающий
-- пути сам, был бы дорогой мимо них. Побочно это значит, что шрифт может
-- приехать откуда угодно — из встроенной файловой системы модуля, из базы.
--
-- Полужирный — ОТДЕЛЬНЫЙ файл, а не опция: в Windows 95 заголовок набран им,
-- и синтезировать его размазыванием пикселей значит перестать быть похожим.
-- Окружение читает `butschster.windows.config:environment` — там же обе
-- ловушки, из-за которых «переменной нет» бывает враньём: `env.get` не видит
-- окружения процесса, а `get_all` молчит об отказе по правам.

local function whole_cell(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Через `read_or`, а не `read(...) or …`: умолчание подставляется, но отказ
-- по правам называется в логе, а не выдаётся за «человек не переназначал».
local FONTS = environment.read_or("BUTSCHSTER_WINDOWS_FONTS", "app:system_fonts")
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
    local asked, source = environment.read("BUTSCHSTER_WINDOWS_PIXELS")
    if asked == "1" or asked == "true" or asked == "yes" then return true, source end
    if asked ~= nil then return false, "set to \"" .. tostring(asked) .. "\"" end
    return false, source
end

-- Шрифты для пиксельной темы. Отказ здесь — НЕ повод погасить оболочку:
-- она поднимается в ячейках и говорит причину. Пустой экран вместо стола
-- читается как сломанный стенд, а не как ненайденный файл.
-- Крупный шрифт — для экрана прощания: в Windows 95 «Теперь питание
-- компьютера можно отключить» набрано крупно, в две строки, на весь экран.
-- Размер считается от высоты ячейки, а не константой: на терминале с другой
-- ячейкой надпись в 34 пикселя была бы или мелкой, или шире экрана.
local function display_size(cell_h: any): integer
    local size = (whole_cell(cell_h) * 17) // 10
    if size < 20 then size = 20 end
    if size > 64 then size = 64 end
    return math.tointeger(size) or 34
end

local function load_fonts(log, cell_h: any)
    local store, err = fs.get(FONTS)
    if err or not store then
        return nil, "fonts not opened (" .. FONTS .. "): " .. tostring(err)
    end

    local face_data, ferr = store:readfile(FONT_FACE)
    if ferr or not face_data then
        return nil, FONT_FACE .. " not read: " .. tostring(ferr)
    end
    local bold_data, berr = store:readfile(FONT_BOLD)
    if berr or not bold_data then
        return nil, FONT_BOLD .. " not read: " .. tostring(berr)
    end

    -- Thresholding small TrueType glyphs erases thin strokes. Set smoothing
    -- once on each face so the shell and every client share readable text.
    return {face = gfx.font(face_data, {size = FONT_SIZE, smooth = true}),
            bold = gfx.font(bold_data, {size = FONT_SIZE, smooth = true}),
            display = gfx.font(bold_data, {size = display_size(cell_h), smooth = true})}, nil
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
        if err or not found then return {}, err or "catalog not read" end

        -- Опечатка в `window_type` не мешает показать программу, но должна
        -- быть названа: неназванная, она живёт вечно, а окно всё это время
        -- рисуется не тем, чем его объявляли.
        for _, warning in ipairs(found.warnings or {}) do
            log:warn("unknown window type", {
                entry = tostring((warning :: any).entry),
                window_type = tostring((warning :: any).window_type),
            })
        end

        return catalog.menu_items(found.programs), nil
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
        if ferr then log:warn("desktop furniture not created", {error = tostring(ferr)}) end

        local _, serr = seed.ensure(programs)
        if serr then log:warn("shortcuts not placed on the desktop", {error = tostring(serr)}) end
    end

    -- Раскладка стола. Отдаётся функцией, а не таблицей: композитор
    -- перечитывает её по команде `desktop.refresh`, и значок, переставленный
    -- ручкой снаружи, встаёт на место без перезапуска оболочки.
    --
    -- Каталог подмешивается здесь же: значок открывает окно по размерам из
    -- реестра, а не по копии, снятой при создании ярлыка.
    -- Цвет стола — настройка из «Свойств экрана». Читается при старте и на
    -- каждом `desktop.refresh`: окно свойств пишет в базу и толкает
    -- композитор, и тот перечитывает стол этим же путём. Отказ базы стол не
    -- роняет: остаётся прежний цвет, причина в лог.
    local function apply_desktop_color()
        local hex, err = repo.setting("desktop_color")
        if err then
            log:warn("desktop color not read", {error = tostring(err)})
            return
        end
        if type(hex) == "string" and hex ~= "" and not chrome.use_desktop(hex) then
            log:warn("desktop color in the database is invalid", {value = hex})
        end
    end

    local function desktop_items()
        apply_desktop_color()
        -- Каталог читается ДО раскладки: мебель заводится по нему, и читать
        -- раскладку раньше значило бы отдать кадр без только что заведённых
        -- значков — они появились бы лишь на следующем обновлении.
        local found = catalog.list()
        furnish(found)

        local items, err = repo.list()
        if err then return {}, "layout not read: " .. tostring(err) end

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
            return false, "icon not named"
        end
        local item, err = repo.update(id, {x = x, y = y})
        if err then return false, "writing the position: " .. tostring(err) end
        -- `false` от репозитория — это «такой строки нет», а не отказ базы.
        -- Молчание здесь превратило бы опечатку в успешное перемещение.
        if item == false then return false, "no such icon: " .. id end
        return true, nil
    end

    -- Пиксельный режим собирается ЗДЕСЬ, а не в механике, и не по прихоти:
    -- запись механики не объявляет `gfx`, поэтому спросить терминал о размере
    -- ячейки она не может. Решение принимает она, вопрос задаём мы.
    --
    -- Каждый отказ по дороге оставляет оболочку в ячейках и НАЗЫВАЕТ причину.
    -- Пиксельный режим, не включившийся молча, выглядит как «почему-то
    -- по-старому», и человек идёт искать поломку там, где её нет.
    --
    -- НАЗЫВАТЬ ЕЁ ТОЛЬКО В ЛОГ — ЗНАЧИТ НЕ НАЗЫВАТЬ НИКОМУ. Лог этого хоста
    -- заглушён нарочно (`hide_logs: true`): строка лога разъезжает кадр
    -- насовсем, потому что диффер поверхности считает себя единственным
    -- писателем в терминал. Значит единственный читатель причины — экран.
    -- Здесь это стоило круга: оболочка поднималась в ячейках, и снаружи это
    -- было неотличимо от «пиксели включились, но выглядят по-старому».
    local theme: any = chrome
    local cell_size: any = nil
    -- Короткая заметка об исходе — уезжает в подсказку пустого стола, то
    -- есть в первое, что человек видит после запуска.
    local pixel_note = "pixels off"

    local asked, source = wants_pixels()
    log:info("pixel mode", {asked = asked, source = source})

    if not asked then
        -- «Не просили» и «просили, но не прочиталось» — разные утверждения, и
        -- второе человек может исправить. Поэтому источник едет на экран
        -- вместе с исходом: отказ по правам выглядит как незаданная
        -- переменная ровно до тех пор, пока его так не назвать.
        pixel_note = "pixels off: BUTSCHSTER_WINDOWS_PIXELS " .. tostring(source)
    end

    if asked then
        local protocol, why = gfx.supported()
        local width, height = gfx.cell_size()

        if not protocol then
            pixel_note = "pixels off: the terminal has no graphics (" .. tostring(why) .. ")"
            log:warn("pixel mode not enabled: the terminal has no graphics",
                {reason = tostring(why)})
        elseif not width or not height then
            -- Догадка «8×16» права достаточно часто, чтобы выглядеть верной, и
            -- картинка не того размера читается как ошибка рисования, а не как
            -- незаданный вопрос. Поэтому отказ, а не умолчание.
            pixel_note = "pixels off: the terminal did not report a cell size"
            log:warn("pixel mode not enabled: the terminal did not report a cell size",
                {reason = tostring(height)})
        else
            local fonts, ferr = load_fonts(log, height)
            if not fonts then
                pixel_note = "pixels off: no font (" .. tostring(ferr) .. ")"
                log:warn("pixel mode not enabled: no font", {error = tostring(ferr)})
            else
                chrome_pixels.use_fonts(fonts.face, fonts.bold, fonts.display)
                chrome_pixels.use_cell_size(width, height)
                theme = chrome_pixels
                cell_size = function()
                    local w, h = gfx.cell_size()
                    if type(w) == "number" and type(h) == "number" then
                        chrome_pixels.use_cell_size(w, h)
                    end
                    return w, h
                end
                pixel_note = "pixels: " .. tostring(protocol) .. " " .. width .. "x" .. height
                log:info("pixel mode enabled",
                    {protocol = protocol, cell = width .. "x" .. height})
            end
        end
    end

    -- Голым `return library.run(...)` это писать нельзя: в go-lua v1.5.18
    -- хвостовой вызов yield-функции из базового фрейма корутины не
    -- выполняется вовсе — молча, за 0 мс.
    local clock_entry, clock_error = catalog.taskbar_clock()
    theme.clock_entry = clock_entry
    if clock_error then log:warn("taskbar clock not configured", {error = clock_error}) end

    -- Вход в систему — если приложение назвало функцию входа и хранилище
    -- токенов. Без них оболочка поднимается без входа, под своим актором:
    -- так было всегда, и стенд без модуля пользователей остаётся рабочим.
    -- Отказ по правам — не «не настроено»: он называется в логе.
    local logon: any = nil
    local logon_config, logon_error = logon_provider.configured()
    if logon_error then
        log:warn("logon not enabled", {reason = tostring(logon_error)})
    elseif logon_config then
        logon = function(screen)
            local identity, why = logon_screen.run(screen, function(login, password)
                return logon_provider.authenticate(logon_config, login, password)
            end)
            -- Имя вошедшего — в «Пуск», обеим темам сразу: раскладку меню
            -- они считают одной функцией и читают одну таблицу.
            if type(identity) == "table" then
                local context: any = type(identity.context) == "table" and identity.context or {}
                chrome.use_user({id = context.user_id, name = context.user_name})
            end
            return identity, why
        end
        log:info("logon enabled", {func = logon_config.func, store = logon_config.store})
    end

    local ok, err = library.run({
        chrome = theme,
        pixels = cell_size ~= nil,
        -- Функцией, а не значением: размер ячейки меняется, когда человек
        -- меняет шрифт терминала, и снятое однажды число разъедется с экраном.
        cell_size = cell_size,
        service_name = SERVICE_NAME,
        hint = "Start — programs · alt+n — bash window · ctrl+q — quit · " .. pixel_note,
        -- Необязательные швы к основе. Не поддержи их композитор — меню
        -- откатывается к его собственному плоскому каталогу, а стол остаётся
        -- без значков; оболочка при этом поднимается и работает.
        catalog = menu_catalog,
        desktop_items = desktop_items,
        move_desktop_item = move_desktop_item,
        -- «Свойства» по правой кнопке на пустом столе — «Свойства: Экран».
        desktop_properties = "butschster.windows.display:window",
        -- Окна, собранные мастерской основы, возвращаются в реестр на старте.
        -- Оболочка часто поднимается одна, и без восстановления её меню
        -- показало бы каталог без них, не объяснив, куда они делись. Отказ
        -- восстановления уезжает в restore_report и виден в GET /windows/status.
        restore = true,
        logon = logon,
    })
    return ok, err
end

return {main = main}
