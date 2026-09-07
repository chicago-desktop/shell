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

local SHOTS = "app:shots"
local FONTS = "app:system_fonts"
local FACE = "LiberationSans-Regular.ttf"

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

local function load_font(size)
    local store, err = fs.get(FONTS)
    if err or not store then return nil, "шрифты не открылись: " .. tostring(err) end
    local data, rerr = store:readfile(FACE)
    if rerr or not data then return nil, "шрифт не прочитан: " .. tostring(rerr) end
    local face = gfx.font(data, {size = size})
    return face, nil
end

-- ─── сцены ───────────────────────────────────────────────────────────────
--
-- Те же, что у подставки: снимок и карта обязаны показывать одно и то же,
-- иначе один из двух уровней проверяет не то, что второй.

local function scene_window(raster, cell, font)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    pixels.title(raster, 4, 4, w - 6, cell.h - 2,
        {text = "Мой компьютер", font = font, focused = true}, cell)

    local ids = {"minimize", "maximize", "close"}
    for index, id in ipairs(ids) do
        pixels.button_at(raster, 24 + (index - 1) * 2, 1, 2, 1,
            {id = id, label = "", font = font, inset = 2}, cell)
    end

    pixels.field(raster, 4, cell.h + 4, w - 6, h - cell.h - 7)
end

local function scene_buttons(raster, cell, font)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    pixels.button_at(raster, 2, 2, 7, 1,
        {id = "ok", label = "ОК", font = font, inset = 2}, cell)
    pixels.button_at(raster, 10, 2, 7, 1,
        {id = "cancel", label = "Отмена", font = font, pressed = true, inset = 2}, cell)
end

local function scene_titles(raster, cell, font)
    local w = raster:size()
    pixels.panel(raster, 1, 1, w, cell.h * 2)
    pixels.title(raster, 2, 2, w - 2, cell.h - 2,
        {text = "В фокусе", font = font, focused = true}, cell)
    pixels.title(raster, 2, cell.h + 2, w - 2, cell.h - 2,
        {text = "Не в фокусе", font = font}, cell)
end

local SCENES = {
    {name = "window", cols = 30, rows = 8, paint = scene_window},
    {name = "buttons", cols = 24, rows = 4, paint = scene_buttons},
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
    local store, serr = fs.get(SHOTS)
    if not store then
        print("ОТКАЗ: каталог снимков не открылся: " .. tostring(serr))
        return false, serr
    end

    local cell, source = cell_size(spec)
    say("ячейка " .. cell.w .. "×" .. cell.h .. " px (" .. source .. ")")

    local font, ferr = load_font(13)
    if not font then
        print("ОТКАЗ: " .. tostring(ferr))
        return false, ferr
    end

    -- Метрики шрифта печатаются рядом со снимком: подставка их не знает и
    -- считает приближением, а расхождение между уровнями иначе обнаружится
    -- тем, что надпись не влезла в кнопку на стенде.
    local sample = "Мой компьютер"
    local tw, th = font:measure(sample)
    say(string.format("шрифт %d px, высота строки %d, ascent %d; «%s» = %d×%d px",
        font:size(), font:height(), font:ascent(), sample, tw, th))


    local steady = check_frames(cell, font)
    if not steady then
        say("ОТКАЗ: растры не переживают кадр — экран будет правильным, а летать будет всё")
    end

    for _, scene in ipairs(SCENES) do
        local raster = gfx.raster(scene.cols * cell.w, scene.rows * cell.h)
        scene.paint(raster, cell, font)

        local bytes, eerr = raster:encode("png")
        if not bytes then
            say("ОТКАЗ: " .. scene.name .. " не закодировался: " .. tostring(eerr))
            return false, eerr
        end

        local path = scene.name .. ".png"
        local ok, werr = store:writefile(path, bytes)
        if not ok then
            say("ОТКАЗ: " .. path .. " не записался: " .. tostring(werr))
            return false, werr
        end
        say(string.format("%-10s %4d×%-4d px  версия %d  %d байт  → test/shots/%s",
            scene.name, scene.cols * cell.w, scene.rows * cell.h,
            raster:version(), #bytes, path))
    end

    local report = table.concat(lines, "\n") .. "\n"
    local wrote, rerr = store:writefile(REPORT, report)
    if not wrote then print("отчёт не записался: " .. tostring(rerr)) end

    return steady, nil
end

return {main = main}
