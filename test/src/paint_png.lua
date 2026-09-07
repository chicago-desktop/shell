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
local rasters = require("rasters")
local chrome_pixels = require("chrome_pixels")
local render = require("render")
local render_pixels = require("render_pixels")

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
    local function screen_shot()
        chrome_pixels.use_fonts(font, bold)

        local cols, rows = 100, 28
        local state: any = {
            width = cols, height = rows, top = 1, bottom = rows - 1,
            windows = {
                {id = "w1", title = "Командная строка", x = 20, y = 4, w = 52, h = 14,
                 window_type = "app"},
                {id = "w2", title = "Свойства системы", x = 44, y = 12, w = 44, h = 10,
                 window_type = "dialog"},
            },
            focused_id = "w2",
            items = {
                {id = "s1", kind = "shortcut", entry = "app:computer",
                 title = "Мой компьютер", x = 2, y = 1},
                {id = "f1", kind = "folder", title = "Программы", x = 2, y = 5},
                {id = "s2", kind = "shortcut", entry = "app:bin", title = "Корзина", x = 2, y = 9},
                {id = "s3", kind = "shortcut", entry = "app:gone", title = "Старая программа",
                 x = 2, y = 13, broken = true},
            },
            selected = "f1",
            clock = "21:47",
            status = "Свойства системы · 40x7 · окон: 2",
        }

        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local screen = gfx.raster(cols * cell.w, rows * cell.h)
        -- Стол заливкой: в живом кадре это стили ЯЧЕЕК, а не картинка
        -- (FR-005 §3а). Здесь он закрашен, чтобы снимок показывал то же, что
        -- увидит человек, — но в кадр такой растр не попадает никогда.
        screen:fill(color_desktop)

        for _, item in ipairs(painted.placements) do
            screen:blit(item.raster, (item.x - 1) * cell.w + 1, (item.y - 1) * cell.h + 1)
        end

        local bytes = screen:encode("png")
        if bytes then
            store_shots:writefile("desktop.png", bytes)
            say(string.format("экран: размещений %d, значков %d, кнопок панели %d → desktop.png",
                #painted.placements, #painted.hits.desktop, #painted.hits.bars))
        end
    end

    local steady = check_frames(cell, font)
    if not steady then
        say("ОТКАЗ: растры не переживают кадр — экран будет правильным, а летать будет всё")
    end

    screen_shot()

    local explorer_ok = explorer_shots(rasters.store())
    if not explorer_ok then
        say("ОТКАЗ: проводник пересоздаёт растры — экран останется СТАРЫМ, не медленным")
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
