-- Второй уровень пиксельного пробника: настоящий PNG.
--
-- Подставка на чистом Lua ловит раскладку, перекрытия и попадания за
-- миллисекунды, но глифов у неё нет и метрик шрифта тоже. Что грань вышла в
-- ОДИН пиксель, что кириллица прорисовалась, что цвет тот самый — видно
-- только на снимке, и смотрит на него человек или агент Read'ом.
--
-- Рисует ТОТ ЖЕ `butschster.windows.shell:pixels`, что поедет на стенд. Своя
-- копия отрисовки ради снимка проверяла бы копию.
--
--   cd test && wippy run --host wippy.terminal:host paint-png
--
-- Файлы ложатся в `test/shots/`. Каталог не в поставке модуля: снимки — это
-- проверка, а не часть оболочки.

local fs = require("fs")
local gfx = require("gfx")

local pixels = require("pixels")
local images = require("images")
local catalog = require("catalog")
local desktop_view = require("desktop_view")
local model = require("model")
local rasters = require("rasters")
local chrome_pixels = require("chrome_pixels")
local ui = require("ui")
local run_window = require("run_window")
local render = require("render")
local render_pixels = require("render_pixels")
local datetime_window = require("datetime_window")
local calc_window = require("calc_window")
local taskman_window = require("taskman_window")
local sdk_render = require("sdk_render")
local reg_model = require("reg_model")
local regedit = require("regedit_window")

-- Размер ячейки. У этой команды терминала НЕТ — она пишет файлы, а не рисует
-- на экране, — поэтому `gfx.cell_size()` здесь честно молчит, и это измерено,
-- а не предположено.
--
-- Отсюда правило: число называют снаружи, аргументом, и отчёт пишет, ОТКУДА
-- оно взялось. Догадка «8×16» права достаточно часто, чтобы выглядеть верной,
-- и картинка не того размера читается как ошибка рисования, а не как
-- незаданный вопрос.
--
--   wippy run --host wippy.terminal:host paint-png 10x20
local FALLBACK = {w = 10, h = 20}

-- Отчёт кладётся ФАЙЛОМ рядом со снимками, а не печатается.
--
-- `print` из процесса под терминальным хостом наружу не доходит — измерено:
-- снимки записались, а ни одной строки не появилось. Отчёт, рассказанный
-- только в лог, не рассказан никому: числа про метрики шрифта и про
-- переживающие кадр растры — это половина проверки, и её надо ЧИТАТЬ.
local REPORT = "report.txt"

-- Бирюзовый стола. В живом кадре его кладут ячейки, здесь — только ради
-- снимка: чтобы человек видел то же, что увидит на экране.
local color_desktop = "#008080"

local SHOTS = "app:shots"
local FONTS = "app:system_fonts"
local FACE = "LiberationSans-Regular.ttf"
-- Полужирный — отдельный ФАЙЛ, а не опция: в Windows 95 заголовок набран им,
-- и синтезировать его размазыванием пикселей значит перестать быть похожим.
local BOLD = "LiberationSans-Bold.ttf"

local function cell_size(spec)
    local w, h = gfx.cell_size()
    if w and h then return {w = w, h = h}, "терминал ответил" end

    local given_w, given_h = string.match(tostring(spec or ""), "^(%d+)[xX×](%d+)$")
    if given_w then
        return {w = math.tointeger(tonumber(given_w)) or FALLBACK.w,
                h = math.tointeger(tonumber(given_h)) or FALLBACK.h}, "названо аргументом"
    end

    return FALLBACK, "ЗАПАСНОЕ ЗНАЧЕНИЕ — терминал молчит, аргумента нет"
end

local function load_font(file, size)
    local store, err = fs.get(FONTS)
    if err or not store then return nil, "шрифты не открылись: " .. tostring(err) end
    local data, rerr = store:readfile(file)
    if rerr or not data then return nil, "шрифт не прочитан: " .. tostring(rerr) end
    local face = gfx.font(data, {size = size})
    return face, nil
end

-- ─── сцены ───────────────────────────────────────────────────────────────
--
-- Те же, что у подставки: снимок и карта обязаны показывать одно и то же,
-- иначе один из двух уровней проверяет не то, что второй.

local function scene_window(raster, cell, font, bold)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    pixels.title(raster, 4, 4, w - 6, cell.h - 2,
        {text = "Мой компьютер", font = font, bold = bold, focused = true}, cell)

    -- Кнопки заголовка ставятся В ЯЧЕЙКАХ, по две на кнопку: поставленные по
    -- пикселям с шагом 18, они выглядели бы так же, а зоны попадания
    -- пересекались бы — пробник это и поймал.
    local marks = {"minimize", "maximize", "close"}
    for index, id in ipairs(marks) do
        local hit = pixels.button_at(raster, 24 + (index - 1) * 2, 1, 2, 1,
            {id = id, label = "", font = font, inset = 2}, cell)
        local area = pixels.box(hit.from, hit.row, 2, 1, cell)
        -- Знак кладётся по центру НАРИСОВАННОГО прямоугольника, а не ячейки:
        -- у кнопки есть отступ, и знак, посчитанный от ячейки, съехал бы.
        local side = 10
        pixels.MARKS[id](raster,
            area.x + (area.w - side) // 2, area.y + (area.h - side) // 2, side)
    end

    pixels.field(raster, 4, cell.h + 4, w - 6, h - cell.h - 7)
end

local function scene_buttons(raster, cell, font, bold)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)

    -- Одна ширина на обе: разноширокие «ОК» и «Отмена» — первое, что выдаёт
    -- подделку. Считается по самой широкой ИЗМЕРЕННОЙ подписи и округляется
    -- вверх до целых ячеек, не меньше семидесяти пяти пикселей — как в
    -- Windows 95.
    local labels = {"ОК", "Отмена"}
    local span = pixels.button_span(font, labels, cell, 75)
    for index, label in ipairs(labels) do
        pixels.button_at(raster, 2 + (index - 1) * (span + 1), 2, span, 1,
            {id = label, label = label, font = font, inset = 2,
             pressed = index == 2}, cell)
    end
end

local function scene_titles(raster, cell, font, bold)
    local w = raster:size()
    pixels.panel(raster, 1, 1, w, cell.h * 2)
    pixels.title(raster, 2, 2, w - 2, cell.h - 2,
        {text = "В фокусе", font = font, bold = bold, focused = true}, cell)
    pixels.title(raster, 2, cell.h + 2, w - 2, cell.h - 2,
        {text = "Не в фокусе", font = font, bold = bold}, cell)
end

local SCENES = {
    {name = "window", cols = 30, rows = 8, paint = scene_window},
    {name = "buttons", cols = 23, rows = 3, paint = scene_buttons},
    {name = "titles", cols = 20, rows = 2, paint = scene_titles},
}

-- Та же мера, что у подставки, но на НАСТОЯЩЕМ gfx.
--
-- Подставка своя, и хранилище, проверенное только против неё, доказано против
-- собственной выдумки. Здесь растры настоящие, и `version` двигает рантайм, а
-- не Lua.
--
-- Сравнивается ТОЖДЕСТВО растра, а не только его версия. Выяснилось мутацией:
-- хранилище, пересоздающее растр каждый кадр, отдаёт свежий буфер, рисующий
-- код повторяет те же вызовы — и версия приходит та же самая. Числа
-- совпадают, а на экран летит всё заново.
local lines = {}
local function say(text)
    lines[#lines + 1] = tostring(text)
    print(text)
end

local function check_frames(cell, font)
    local store = rasters.store()

    local function paint(state: any)
        store.begin()
        local title, dirty = store.take("win:title", 30, 1, cell,
            state.title .. "|" .. tostring(state.focused))
        if dirty then
            pixels.panel(title, 1, 1, 30 * cell.w, cell.h)
            pixels.title(title, 2, 2, 30 * cell.w - 4, cell.h - 4,
                {text = state.title, font = font, focused = state.focused}, cell)
        end
        store.place("win:title", 1, 1)

        local bar, bar_dirty = store.take("taskbar", 30, 1, cell, state.clock)
        if bar_dirty then
            pixels.panel(bar, 1, 1, 30 * cell.w, cell.h)
            pixels.label(bar, 24 * cell.w, 1, 5 * cell.w, cell.h, state.clock, font)
        end
        store.place("taskbar", 1, 8)

        return store.frame(cell)
    end

    local function snapshot(placements)
        local out: any = {}
        for _, item in ipairs(placements) do
            out[item.id] = {raster = item.raster, version = item.raster:version()}
        end
        return out
    end

    local function moved(before: any, after: any)
        local names = {}
        for id, now in pairs(after) do
            local was: any = before[id]
            if not was then names[#names+1] = id .. " (появился)"
            elseif was.raster ~= now.raster then names[#names+1] = id .. " (ПЕРЕСОЗДАН)"
            elseif was.version ~= now.version then names[#names+1] = id end
        end
        table.sort(names)
        return names
    end

    local state: any = {title = "Мой компьютер", focused = true, clock = "21:47"}
    local first = snapshot(paint(state))
    local second = snapshot(paint(state))
    local still = moved(first, second)
    say(string.format("кадр без изменений: сдвинулось %d из %d размещений%s",
        #still, 2, #still == 0 and "" or "  ◄ ОШИБКА: " .. table.concat(still, ", ")))

    state.clock = "21:48"
    local ticked = moved(second, snapshot(paint(state)))
    say(string.format("сменились часы: перерисовано %s%s",
        table.concat(ticked, ", "),
        (#ticked == 1 and ticked[1] == "taskbar") and "" or "  ◄ ОШИБКА: ожидалась только taskbar"))

    return #still == 0 and #ticked == 1 and ticked[1] == "taskbar"
end

local function main(spec)
    local store_shots, serr = fs.get(SHOTS)
    if not store_shots then
        print("ОТКАЗ: каталог снимков не открылся: " .. tostring(serr))
        return false, serr
    end

    local cell, source = cell_size(spec)
    say("ячейка " .. cell.w .. "×" .. cell.h .. " px (" .. source .. ")")

    local font, ferr = load_font(FACE, 13)
    if not font then
        say("ОТКАЗ: " .. tostring(ferr))
        return false, ferr
    end
    local bold, berr = load_font(BOLD, 13)
    if not bold then
        say("ОТКАЗ: полужирный не загрузился: " .. tostring(berr))
        return false, berr
    end

    -- Метрики шрифта печатаются рядом со снимком: подставка их не знает и
    -- считает приближением, а расхождение между уровнями иначе обнаружится
    -- тем, что надпись не влезла в кнопку на стенде.
    local sample = "Мой компьютер"
    local tw, th = font:measure(sample)
    say(string.format("шрифт %d px, высота строки %d, ascent %d; «%s» = %d×%d px",
        font:size(), font:height(), font:ascent(), sample, tw, th))


    -- «Мой компьютер» ПИКСЕЛЬНЫМ бэкендом. Раскладку считает тот же
    -- `render.layout`, что и путь в ячейках, — на то и разделение: разъедься
    -- они, щелчок попадал бы на соседа в одном из двух режимов.
    local function explorer_shots(store)
        local view: any = {
            title = "Мой компьютер",
            selected = 2,
            offset = 0,
            objects = {
                {id = "app:app_fs", kind = "drive", title = "app_fs",
                 detail = "app:app_fs · fs.directory"},
                {id = "wippy.facade:public_files", kind = "drive", title = "public_files",
                 detail = "wippy.facade:public_files · fs.directory"},
                {id = "keeper:ui_static_fs", kind = "drive", title = "keeper ui_static_fs",
                 detail = "keeper:ui_static_fs · fs.embed"},
                {id = "programs", kind = "folder", title = "Программы",
                 detail = "12 объектов"},
                {id = "desktop", kind = "folder", title = "Рабочий стол",
                 detail = "3 объекта"},
                {id = "windows", kind = "folder", title = "Открытые окна",
                 detail = "2 объекта"},
            },
        }

        local plan = render.layout(view, 46, 14)
        local placements = render_pixels.paint(store, plan, cell,
            {face = font, bold = bold}, "explorer")

        say(string.format("проводник: размещений %d, попаданий по значкам %d",
            #placements, #plan.cells))

        for _, item in ipairs(placements) do
            local bytes = item.raster:encode("png")
            local file = "explorer-" .. string.gsub(item.id, "[^%w]", "-") .. ".png"
            if bytes then
                store_shots:writefile(file, bytes)
                say(string.format("  %-22s ячейка %2d,%-2d  %2d×%-2d ячеек  → %s",
                    item.id, item.x, item.y, item.cols, item.rows, file))
            end
        end

        -- Тот же кадр ещё раз: ни одно размещение не имеет права уехать
        -- заново. Это и есть мера FR-005 §4, применённая к настоящему виду, а
        -- не к учебной сцене.
        local before: any = {}
        for _, item in ipairs(placements) do
            before[item.id] = {raster = item.raster, version = item.raster:version()}
        end
        local again = render_pixels.paint(store, plan, cell,
            {face = font, bold = bold}, "explorer")
        local moved = {}
        for _, item in ipairs(again) do
            local was: any = before[item.id]
            if not was then moved[#moved+1] = item.id .. " (появился)"
            elseif was.raster ~= item.raster then moved[#moved+1] = item.id .. " (ПЕРЕСОЗДАН)"
            elseif was.version ~= item.raster:version() then moved[#moved+1] = item.id end
        end
        say("проводник, тот же кадр ещё раз: сдвинулось " .. #moved
            .. (#moved == 0 and "" or " — " .. table.concat(moved, ", ")))
        return #moved == 0
    end

    -- ─── весь экран одним снимком ────────────────────────────────────────
    --
    -- Композитор кладёт размещения по отдельности, но человек смотрит на
    -- ЭКРАН. Куски, разложенные по восьми файлам, не показывают ни того, что
    -- рамка сошлась, ни того, что значок не наехал на окно.
    --
    -- `blit` собирает их в один растр по тем же координатам, по которым их
    -- положит поверхность, — то есть снимок врёт ровно настолько, насколько
    -- врут координаты, и ни на сколько больше.
    local function screen_shot(file, notice)
        chrome_pixels.use_fonts(font, bold)

        local cols, rows = 100, 28
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local layout = chrome_pixels.layout(cols, rows)
        local state: any = {
            width = cols, height = rows, top = 1, bottom = rows - layout.bottom,
            windows = {
                {id = "w1", title = "Командная строка", x = 20, y = 4, w = 52, h = 14,
                 window_type = "app"},
                {id = "w2", title = "Свойства системы", x = 44, y = 12, w = 44, h = 10,
                 window_type = "dialog"},
            },
            focused_id = "w2",
            items = {
                {id = "s1", kind = "shortcut", entry = "butschster.windows.explorer:window",
                 title = "Мой компьютер", x = 2, y = 1},
                {id = "f1", kind = "folder", title = "Программы", x = 2, y = 5},
                {id = "s2", kind = "shortcut", entry = "app:bin", image = "recycle_bin", title = "Корзина", x = 2, y = 9},
                {id = "s3", kind = "shortcut", entry = "app:gone", title = "Старая программа",
                 x = 2, y = 13, broken = true},
            },
            selected = "f1",
            clock = "21:47",
            status = "Свойства системы · 40x7 · окон: 2",
            menu = {open = {"Программы"}, cursor = 2, items = {
                {entry = "app:calc", title = "Калькулятор", icon = "▣",
                 group = {"Программы"}},
                {entry = "app:notepad", title = "Блокнот", group = {"Программы"}},
                {entry = "app:paint", title = "Графический редактор", group = {"Программы"}},
                {entry = "app:ping", title = "Пинг", group = {"Программы", "Связь"}},
                {entry = "app:bash", title = "Сеанс MS-DOS"},
                {entry = "app:docs", image = "documents", title = "Документы"},
                {entry = "app:settings", image = "settings", title = "Настройка"},
                {entry = "app:shutdown", image = "shutdown", title = "Завершение работы"},
            }},
        }

        if notice then
            state.menu = {items = {}}
            if notice == "failure" then state.menu.failure = "реестр временно недоступен" end
        end
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local screen = gfx.raster(cols * cell.w, rows * cell.h)
        -- Стол заливкой: в живом кадре это стили ЯЧЕЕК, а не картинка
        -- (FR-005 §3а). Здесь он закрашен, чтобы снимок показывал то же, что
        -- увидит человек, — но в кадр такой растр не попадает никогда.
        screen:fill(color_desktop)
        for _, window in ipairs(state.windows) do
            screen:rect((window.x - 1) * cell.w + 1, (window.y - 1) * cell.h + 1,
                window.w * cell.w, window.h * cell.h,
                window.window_type == "dialog" and "#c0c0c0" or "#ffffff")
        end

        for _, item in ipairs(painted.placements) do
            screen:blit(item.raster, (item.x - 1) * cell.w + 1, (item.y - 1) * cell.h + 1)
        end

        local bytes = screen:encode("png")
        if bytes then
            store_shots:writefile(file, bytes)
            say(string.format("экран: размещений %d, значков %d, кнопок панели %d, пунктов меню %d → %s",
                #painted.placements, #painted.hits.desktop, #painted.hits.bars,
                #painted.hits.menu, file))
        end
    end

    -- Same catalog adapter and desktop join as the live shell. This scene uses
    -- the host's actual window identities, including runtime workshop windows.
    local function menu_icons_shot()
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local records = {
            {id = "butschster.windows.explorer:window", meta = {title = "Мой компьютер", image = "my_computer", order = 10}},
            {id = "app.desktop:window_calc", meta = {title = "Калькулятор", image = "calculator", group = "Стандартные"}},
            {id = "butschster.tui_desktop.apps:commander", meta = {title = "Обозреватель стенда"}},
            {id = "butschster.tui_desktop.apps:dataflows", meta = {title = "Прогоны"}},
            {id = "butschster.tui_desktop.apps:bridge_runs", meta = {title = "Прогоны работы"}},
            {id = "butschster.tui_desktop.apps:bridge_jobs", meta = {title = "Работы бриджа"}},
            {id = "butschster.tui_desktop.apps:dataflow_detail", meta = {title = "Узлы прогона"}},
            {id = "butschster.tui_desktop.apps:clock", meta = {title = "Часы"}},
        }
        local built = catalog.build(records)
        assert(catalog.assign_images(built.programs, {{data = {images = {
            ["butschster.tui_desktop.apps:commander"] = "network_neighborhood",
            ["butschster.tui_desktop.apps:dataflows"] = "run",
            ["butschster.tui_desktop.apps:bridge_runs"] = "documents_stack",
            ["butschster.tui_desktop.apps:bridge_jobs"] = "system",
            ["butschster.tui_desktop.apps:dataflow_detail"] = "program_settings",
            ["butschster.tui_desktop.apps:clock"] = "clock",
        }}}}))
        local items = desktop_view.join({
            {id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window", title = "Мой компьютер", x = 2, y = 1},
            {id = "programs", kind = "folder", title = "Программы", x = 2, y = 6},
        }, built)
        local state = {width = 100, height = 36, top = 1, bottom = 36 - chrome_pixels.layout(100, 36).bottom,
            items = items, windows = {}, clock = "12:00",
            menu = {items = catalog.menu_items(built.programs), open = {"Стандартные"}, cursor = 1}}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("menu-icons.png", assert(canvas:encode("png")))
        say("каталог → меню и стол: menu-icons.png")
    end

    -- Same native window path that the compositor now uses for Explorer.
    local function explorer_native_shot()
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local records = {}
        for _, name in ipairs({"app.desktop:system_fonts", "app:app_fs", "app:codex_store", "app:data_dir",
            "app:system_fonts", "app:tmp", "app:uploads", "app:uploads_store", "butschster.blog:ui_fs",
            "butschster.bridge:ui_fs", "butschster.windows:assets", "kickside:ui_fs"}) do
            records[#records + 1] = {id = name, kind = "fs.directory"}
        end
        local objects = model.drives(records)
        for index = #objects + 1, 65 do objects[index] = {id = "fs" .. index, kind = "drive", title = "Файловая система " .. index} end
        local state: any = {width = 110, height = 34, top = 1,
            bottom = 34 - chrome_pixels.layout(110, 34).bottom,
            items = {{id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window",
                title = "Мой компьютер", x = 10, y = 2},
                {id = "programs", kind = "folder", title = "Программы", x = 20, y = 10}},
            windows = {{id = "explorer", entry = "butschster.windows.explorer:window", image = "my_computer",
                title = "Мой компьютер", window_type = "app", content = "pixels",
                render = "butschster.windows.explorer:render_pixels", x = 34, y = 8, w = 64, h = 20,
                content_state = {title = "Мой компьютер", objects = objects, selected = 0, offset = 0}}},
            focused_id = "explorer", clock = "12:00"}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("explorer-native.png", assert(canvas:encode("png")))
        say("пиксельное окно проводника: explorer-native.png")
    end

    -- Fixture metadata mirrors the declarations; the dialog uses its live renderer.
    local function run_shot()
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local found = catalog.build({
            {id = "butschster.windows.explorer:window", meta = {title = "Мой компьютер", image = "my_computer", order = 10}},
            {id = "butschster.windows.calc:window", meta = {title = "Калькулятор", image = "calculator", group = "Стандартные", order = 20}},
            {id = "butschster.tui_desktop.desktop:window_pty", meta = {title = "Bash", image = "program", group = "Стандартные"}},
            {id = "butschster.windows.run:window", meta = {title = "Выполнить…", image = "run", order = 900}},
        })
        local items = found.programs
        local state: any = {width = 100, height = 32, top = 1,
            bottom = 32 - chrome_pixels.layout(100, 32).bottom,
            items = {{id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window",
                title = "Мой компьютер", x = 8, y = 2}},
            windows = {{id = "run", entry = "butschster.windows.run:window", image = "run",
                title = "Выполнить…", window_type = "dialog", content = "pixels", resizable = false,
                render = "butschster.windows.sdk:render", x = 30, y = 7, w = 54, h = 12,
                content_state = {sdk = 1, revision = 1, interaction = ui.interaction(),
                    ui = run_window.definition.view({text = "claude --resume", pending = false}, {width = 52, height = 10})}}},
            focused_id = "run", clock = "12:00",
            menu = {items = catalog.menu_items(items), open = {"Стандартные"}, cursor = 1}}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("run-bash.png", assert(canvas:encode("png")))
    end
    run_shot()

    -- Sample data goes through the same Task Manager renderer as live windows.
    do
        local MB = 1024 * 1024
        local state: any = {tab = 3, selected = 0, offset = 0, heap_history = {}, goroutine_history = {},
            snapshot = {taken = 1788858300, goroutines = 428, cpu_count = 8, max_procs = 8,
                pid = "24680", hostname = "wippy-workstation", node_id = "local", node_role = "standalone",
                memory = {alloc = 286 * MB, heap_in_use = 312 * MB, heap_sys = 384 * MB, heap_released = 46 * MB, num_gc = 128},
                processes = {}, hosts = {{id = "app:processes", processes = 64}, {id = "wippy:processes", processes = 12}}, members = {{id = "local"}}},
            windows = {{id = "w1", title = "Мой компьютер", ready = true, image = "my_computer"},
                {id = "w2", title = "Блокнот — заметки.txt", ready = true, image = "text_document"},
                {id = "w3", title = "Bash", ready = true, image = "program"},
                {id = "w4", title = "Диспетчер задач", ready = true, image = "system"}}}
        for index = 1, 150 do
            state.goroutine_history[index] = math.floor(360 + math.sin(index / 8) * 24 + math.sin(index / 3) * 14 + index / 3)
            state.heap_history[index] = (230 + (index % 45) * 1.8) * MB
        end
        for index = 1, 76 do
            state.snapshot.processes[index] = {pid = "local:process-" .. string.format("%04d", index),
                source = index == 1 and "butschster.windows:shell" or "app.workers:worker_" .. string.format("%02d", index),
                state = index % 4 == 0 and "running" or "waiting", steps = index * 147, started = 1788850100}
        end
        local names = {"applications", "processes", "performance", "node"}
        for tab = 1, 4 do
            state.tab, state.selected_id = tab, tab == 1 and "w2" or (tab == 2 and "local:process-0002" or nil)
            local client = {width = 76, height = 24}
            local scene = {width = 110, height = 36, top = 1, bottom = 34, items = {}, clock = "12:00",
                focused_id = "taskman", windows = {{id = "taskman", entry = "butschster.windows.taskman:window",
                    title = "Диспетчер задач", image = "system", window_type = "app", content = "pixels",
                    render = "butschster.windows.sdk:render", state_revision = tab, x = 17, y = 4, w = 78, h = 27,
                    content_state = {sdk = 1, revision = tab, interaction = ui.interaction(),
                        ui = taskman_window.definition.view(state, client)}}}}
            local rendered = chrome_pixels.paint(scene, cell.w, cell.h)
            local canvas = gfx.raster(scene.width * cell.w, scene.height * cell.h)
            canvas:fill(color_desktop)
            for _, placement in ipairs(rendered.placements) do
                canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
            end
            store_shots:writefile("taskman-" .. names[tab] .. ".png", assert(canvas:encode("png")))
        end
    end

    -- Real shell chrome with a sample of the cell text layer represented in PNG.
    do
        local mono = assert(load_font("LiberationMono-Regular.ttf", 14))
        local window = {id = "bash", entry = "butschster.tui_desktop.desktop:window_pty",
            title = "Bash", image = "program", window_type = "app", x = 16, y = 6, w = 72, h = 20}
        local state = {width = 100, height = 32, top = 1, bottom = 30, items = {},
            windows = {window}, focused_id = "bash", clock = "12:00"}
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        local defaults = chrome_pixels.content_colors(window)
        canvas:rect((window.x - 1) * cell.w + 1, (window.y - 1) * cell.h + 1,
            window.w * cell.w, window.h * cell.h, defaults.background)
        local rows = {"user@wippy:~$ printf 'Hello, Wippy!\\n'", "Hello, Wippy!", "",
            "user@wippy:~$ ls", "Desktop  Documents  Programs", "", "user@wippy:~$ "}
        for index, row in ipairs(rows) do
            canvas:text(window.x * cell.w + 1, (window.y + index - 1) * cell.h + 1,
                row, {font = mono, color = index == 5 and "#55ffff" or defaults.foreground})
        end
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("bash-black.png", assert(canvas:encode("png")))
    end

    -- Проверка поворота отдельно от темы: если надпись не видна на экране,
    -- надо знать, поворот ли это не работает или место посчитано мимо.
    do
        local label = "WIPPY 2026"
        local tw = bold:measure(label)
        local th = bold:height()
        local temp = gfx.raster(tw, th + 2)
        temp:fill("#000080")
        temp:text(1, 1, label, {font = bold, color = "#ffffff"})

        local canvas = gfx.raster(60, tw + 20)
        canvas:fill("#c0c0c0")
        canvas:blit(temp, 4, 8, {rotate = 270})
        canvas:blit(temp, 34, 8, {rotate = 90})
        local bytes = canvas:encode("png")
        if bytes then
            store_shots:writefile("banner.png", bytes)
            say(string.format("поворот: строка %d×%d px, слева 270°, справа 90° → banner.png",
                tw, th))
        end
    end

    local steady = check_frames(cell, font)
    if not steady then
        say("ОТКАЗ: растры не переживают кадр — экран будет правильным, а летать будет всё")
    end

    explorer_native_shot()
    menu_icons_shot()
    screen_shot("desktop.png", nil)
    screen_shot("menu-empty.png", "empty")
    screen_shot("menu-failure.png", "failure")

    -- Native 32px and 16px assets side by side, rendered through the real gfx.
    local atlas = gfx.raster(960, ((#images.NAMES + 4) // 5) * 80)
    atlas:fill("#c0c0c0")
    for index, name in ipairs(images.NAMES) do
        local x = ((index - 1) % 5) * 192 + 12
        local y = ((index - 1) // 5) * 80 + 8
        for _, size in ipairs({32, 16}) do
            local picture, why = images.get(name, size)
            if not picture then error(tostring(why)) end
            atlas:blit(picture, size == 32 and x or x + 52, size == 32 and y or y + 8)
        end
        atlas:text(x, y + 44, name, {font = font, color = "#000000"})
    end
    store_shots:writefile("stock-icons.png", assert(atlas:encode("png")))

    local explorer_ok = explorer_shots(rasters.store())
    if not explorer_ok then
        say("ОТКАЗ: проводник пересоздаёт растры — экран останется СТАРЫМ, не медленным")
    end

    -- Окна-виды целиком: куски собираются в один растр по тем же координатам,
    -- по которым их положит поверхность. Смотреть глазами: календарь,
    -- стрелки, цвета подписей калькулятора — этого не покажет ни один тест.
    local function view_shot(name, lib: any, window: any, cols: any, rows: any)
        local store = rasters.store()
        local inner = {x = 1, y = 1, cols = cols, rows = rows}
        store.begin()
        local placed, why = lib.placement(window, inner, cell, {face = font, bold = bold}, store)
        if not placed then
            say("ОТКАЗ: " .. name .. " не нарисовался: " .. tostring(why))
            return
        end
        -- Отрисовщик вправе отдать одно размещение, а не список (так делает SDK).
        if placed.raster then placed = {placed} end
        local cw = math.tointeger(cell.w) or 10
        local ch = math.tointeger(cell.h) or 20
        local whole_view = gfx.raster((math.tointeger(cols) or 1) * cw, (math.tointeger(rows) or 1) * ch)
        whole_view:fill("#c0c0c0")
        for _, item in ipairs(placed) do
            local at: any = item
            whole_view:blit(at.raster :: gfx.Raster, ((math.tointeger(at.x) or 1) - 1) * cw + 1,
                ((math.tointeger(at.y) or 1) - 1) * ch + 1)
        end
        local bytes = whole_view:encode("png")
        if bytes then
            store_shots:writefile(name .. ".png", bytes)
            say(string.format("%s: размещений %d → %s.png", name, #placed, name))
        end
    end
    view_shot("datetime", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
        interaction = ui.interaction(), ui = datetime_window.definition.view({tab = 1, clock = {
            year = 2026, month = 9, day = 8, hour = 21, minute = 47, second = 23,
            first_weekday = 1, days = 30, zone = "UTC+04:00"}}, {width = 42, height = 17})}}, 42, 17)
    -- Экран прощания: крупный шрифт считается от высоты ячейки, как в оболочке.
    do
        local big_size = math.max(20, math.min(64, (cell.h * 17) // 10))
        local big, big_err = load_font(BOLD, big_size)
        if not big then
            say("ОТКАЗ: крупный шрифт не загрузился: " .. tostring(big_err))
        else
            chrome_pixels.use_fonts(font, bold, big)
            chrome_pixels.use_cell_size(cell.w, cell.h)
            local raster, col, row = chrome_pixels.farewell_raster(cell, 100, 28)
            if raster then
                local screen = gfx.raster(100 * cell.w, 28 * cell.h)
                screen:fill("#000000")
                local at_x = ((math.tointeger(col) or 1) - 1) * (math.tointeger(cell.w) or 10) + 1
                local at_y = ((math.tointeger(row) or 1) - 1) * (math.tointeger(cell.h) or 20) + 1
                screen:blit(raster :: gfx.Raster, at_x, at_y)
                local png: any = screen:encode("png")
                store_shots:writefile("farewell.png", png :: string)
                say(string.format("прощание: шрифт %d px, растр в ячейке %d,%d → farewell.png", big_size, col, row))
            else
                say("ОТКАЗ: экран прощания не нарисовался")
            end
        end
    end
    do
        -- Просмотрщик реестра: дерево с раскрытыми ветками и запись с полями.
        local sample = {
            {id = "app:db", kind = "db.sql.sqlite", meta = {comment = "База стенда"}, data = {file = ".wippy/app.db"}},
            {id = "app:api", kind = "http.router", meta = {}, data = {prefix = "/api/v1"}},
            {id = "app.desktop:window_calc", kind = "process.lua", meta = {type = "tui_desktop.window", title = "Калькулятор"}, data = {}},
            {id = "butschster.windows.shell:chrome", kind = "library.lua", meta = {comment = "Тема в ячейках"}, data = {source = "file://chrome.lua", modules = {"tty"}}},
            {id = "butschster.windows.shell:pixels", kind = "library.lua", meta = {comment = "Пиксельные примитивы"}, data = {source = "file://pixels.lua"}},
            {id = "butschster.windows.shell:palette", kind = "library.lua", meta = {}, data = {}},
            {id = "butschster.windows:shell", kind = "process.lua", meta = {title = "Оболочка Windows 95"}, data = {method = "main", modules = {"gfx", "tty"}}},
            {id = "butschster.windows:terminal", kind = "terminal.host", meta = {}, data = {hide_logs = true}},
            {id = "wippy.security:process", kind = "security.group", meta = {}, data = {}},
        }
        local session = regedit.session(sample)
        for _, key in ipairs({"", "butschster", "butschster.windows", "butschster.windows.shell"}) do
            session.expanded[key] = true
        end
        session.rows = reg_model.flatten(session.root, session.expanded)
        session.selected = "butschster.windows.shell:chrome"
        view_shot("regedit", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
            interaction = ui.interaction(), ui = regedit.definition.view(session, {width = 78, height = 22})}}, 78, 22)
    end
    do
        local calc_state = calc_window.definition.init(nil, {})
        calc_state.calc.entry, calc_state.calc.memory, calc_state.calc.pressed = "1234.5", 1, "5"
        view_shot("calc", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
            interaction = ui.interaction(),
            ui = calc_window.definition.view(calc_state, {width = 27, height = 14})}}, 27, 14)
    end

    for _, scene in ipairs(SCENES) do
        local raster = gfx.raster(scene.cols * cell.w, scene.rows * cell.h)
        scene.paint(raster, cell, font, bold)

        local bytes, eerr = raster:encode("png")
        if not bytes then
            say("ОТКАЗ: " .. scene.name .. " не закодировался: " .. tostring(eerr))
            return false, eerr
        end

        local path = scene.name .. ".png"
        local ok, werr = store_shots:writefile(path, bytes)
        if not ok then
            say("ОТКАЗ: " .. path .. " не записался: " .. tostring(werr))
            return false, werr
        end
        say(string.format("%-10s %4d×%-4d px  версия %d  %d байт  → test/shots/%s",
            scene.name, scene.cols * cell.w, scene.rows * cell.h,
            raster:version(), #bytes, path))
    end

    local report = table.concat(lines, "\n") .. "\n"
    local wrote, rerr = store_shots:writefile(REPORT, report)
    if not wrote then print("отчёт не записался: " .. tostring(rerr)) end

    return steady and explorer_ok, nil
end

return {main = main}
