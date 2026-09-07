-- Пиксельный пробник: подставка `gfx` на чистом Lua.
--
-- Проверяет то, чего не видно в коде и что на стенде видно только глазом
-- человека: куда легли пиксели, совпали ли попадания с рисунком и выровнено
-- ли по сетке ячеек всё, по чему щёлкают.
--
-- Работает без рантайма и без терминала, за миллисекунды. Это первый из двух
-- уровней; второй — настоящий PNG через `raster:encode`, и он в наборе
-- тестов. Уровни делят ОДИН И ТОТ ЖЕ код примитивов: подставка подменяет
-- `gfx`, а рисует `src/shell/pixels.lua` — тот самый, что поедет на стенд.
--
-- ─── ОГОВОРКА, БЕЗ КОТОРОЙ ПРОБНИК СТАНОВИТСЯ ЛОЖНЫМ СВИДЕТЕЛЕМ ─────────
--
-- Подставка НЕ ЗНАЕТ настоящих метрик шрифта. `font:measure` здесь считает
-- ширину приближением, а не по глифам, поэтому пробник проверяет РАСКЛАДКУ
-- ПРИ ЗАДАННЫХ ИЗМЕРЕНИЯХ, а не сами измерения. Надпись, которая на стенде не
-- поместится в кнопку, здесь поместится.
--
-- Настоящие метрики умеет только второй уровень: там живой `gfx.font` и живой
-- шрифт. Две проверки не заменяют друг друга — эта говорит, куда легли
-- прямоугольники, та — какой ширины оказался текст.

-- Метки для build.py: строки ниже он заменяет телом самих файлов.
local BASE = "src/shell/"

-- Размер ячейки терминала человека, измеренный: Windows Terminal ответил на
-- `CSI 16 t`. Числа здесь не «примерно такие»: на них стоит вся проверка
-- квантования, и подставь мы 8×16 — выравнивание сошлось бы там, где на
-- живом экране не сходится.
local CELL = {w = 10, h = 20}

-- ─── подставка gfx ───────────────────────────────────────────────────────
--
-- Записывает каждый вызов. Пиксели держатся в разреженной таблице: кадр окна
-- это полмиллиона пикселей, и плотный массив здесь считался бы дольше, чем
-- рисуется на стенде.

local function new_raster(w, h)
    local self = {}
    local px = {}
    local version = 0
    local ops = {}

    local ink = {}

    local function put(x, y, colour, is_text)
        if x < 1 or y < 1 or x > w or y > h then return false end
        px[(y - 1) * w + x] = colour
        -- Текст помечается отдельно: залитый прямоугольник и надпись того же
        -- цвета иначе неотличимы на карте, а разница между «здесь белая
        -- заливка» и «здесь белая подпись» — это вся разница между «пусто» и
        -- «надпись вылезла за свою деталь».
        if is_text then ink[(y - 1) * w + x] = true end
        return true
    end

    self.__raster = true
    self.__ops = ops
    self.__w, self.__h = w, h

    self.size = function() return w, h end
    self.version = function() return version end

    self.fill = function(_, colour)
        for y = 1, h do for x = 1, w do px[(y - 1) * w + x] = colour end end
        version = version + 1
        ops[#ops+1] = {op = "fill", colour = colour}
    end

    self.rect = function(_, x, y, rw, rh, colour)
        local touched = false
        for row = y, y + rh - 1 do
            for col = x, x + rw - 1 do
                if put(col, row, colour) then touched = true end
            end
        end
        -- Версия двигается только если пиксели двигались: версия, ушедшая
        -- вперёд без рисунка, заставила бы поверхность переотправлять ту же
        -- картинку каждый кадр — неподвижное изображение начало бы мигать.
        if touched then version = version + 1 end
        ops[#ops+1] = {op = "rect", x = x, y = y, w = rw, h = rh, colour = colour}
    end

    self.set = function(_, x, y, colour)
        if put(x, y, colour) then version = version + 1 end
        ops[#ops+1] = {op = "set", x = x, y = y, colour = colour}
    end

    self.text = function(_, x, y, text, opts)
        opts = opts or {}
        local font = opts.font
        local advance = font and font:measure(text) or 0
        local height = font and font:height() or 0
        -- Текст на пиксели не разбирается — глифов у подставки нет. Занятый
        -- прямоугольник помечается, чтобы карта показала, ГДЕ надпись, и
        -- сразу стало видно, если она вылезла за свою деталь.
        for row = y, y + height - 1 do
            for col = x, x + advance - 1 do put(col, row, opts.color or "#000000", true) end
        end
        if advance > 0 then version = version + 1 end
        ops[#ops+1] = {op = "text", x = x, y = y, text = text,
                       w = advance, h = height, colour = opts.color}
        return advance
    end

    self.at = function(x, y) return px[(y - 1) * w + x] end
    self.is_text = function(x, y) return ink[(y - 1) * w + x] == true end
    return self
end

-- Шрифт-подставка. Ширина приближением — см. оговорку в шапке.
local function new_font(size)
    local self = {}
    local advance = math.floor(size * 0.55)
    self.measure = function(_, text)
        local count = 0
        for _ in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
        return count * advance, size
    end
    self.height = function() return size end
    self.ascent = function() return math.floor(size * 0.8) end
    self.size = function() return size end
    return self
end

local gfx = {}
gfx.supported = function() return "sixel", nil end
gfx.cell_size = function() return CELL.w, CELL.h end
gfx.raster = function(w, h) return new_raster(w, h) end
gfx.font = function(_, opts) return new_font((opts and opts.size) or 12) end

-- ─── загрузка примитивов ─────────────────────────────────────────────────
local modules = {gfx = gfx}
local saved_require = require
require = function(name)
    if modules[name] then return modules[name] end
    if saved_require then return saved_require(name) end
    error("нет модуля " .. tostring(name))
end

modules.palette = dofile(BASE .. "palette.lua")
local pixels = dofile(BASE .. "pixels.lua")
local rasters = dofile(BASE .. "rasters.lua")

-- ─── печать ──────────────────────────────────────────────────────────────
--
-- Карта печатается в ЯЧЕЙКАХ, а не в пикселях: тысяча на пятьсот шестьдесят
-- пикселей нечитаема, а мышь всё равно говорит ячейками. Каждая ячейка —
-- буква преобладающего в ней цвета, и рядом та же сетка попаданий. Это и есть
-- проверка «нажимается то, что нарисовано» в тех единицах, в которых щёлкают.

local alphabet = "abcdefghijklmnopqrstuvwxyz"

local function cell_map(raster, hits)
    local w, h = raster:size()
    local cols = math.ceil(w / CELL.w)
    local rows = math.ceil(h / CELL.h)

    local letters, legend, next_letter = {}, {}, 0
    local function mark(colour)
        if not colour then return "." end
        if not letters[colour] then
            next_letter = next_letter + 1
            letters[colour] = alphabet:sub(next_letter, next_letter)
            legend[#legend+1] = letters[colour] .. " = " .. colour
        end
        return letters[colour]
    end

    print(string.format("    растр %d×%d px = %d×%d ячеек%s, версия %d, вызовов %d",
        w, h, cols, rows,
        (w % CELL.w == 0 and h % CELL.h == 0) and "" or "  ◄ НЕ ЦЕЛОЕ ЧИСЛО ЯЧЕЕК",
        raster:version(), #raster.__ops))

    for row = 1, rows do
        local line = {}
        for col = 1, cols do
            -- Преобладающий цвет ячейки: по нему видно, что человек увидит,
            -- когда картинка ляжет в сетку.
            local tally, best, top, text = {}, nil, 0, false
            for y = (row - 1) * CELL.h + 1, math.min(row * CELL.h, h) do
                for x = (col - 1) * CELL.w + 1, math.min(col * CELL.w, w) do
                    local colour = raster.at(x, y)
                    if colour then
                        tally[colour] = (tally[colour] or 0) + 1
                        if tally[colour] > top then top, best = tally[colour], colour end
                    end
                    if raster.is_text(x, y) then text = true end
                end
            end
            local letter = mark(best)
            line[col] = text and letter:upper() or letter
        end

        local marks = {}
        for col = 1, cols do marks[col] = "·" end
        for index, hit in ipairs(hits or {}) do
            if row >= hit.row and row <= (hit.bottom_row or hit.row) then
                -- Буква по НОМЕРУ попадания, а не по первой букве имени:
                -- «minimize» и «maximize» дают одну и ту же букву, и на карте
                -- две разные кнопки выглядели бы одной.
                local letter = alphabet:sub(index, index)
                for col = hit.from, hit.to do
                    if col >= 1 and col <= cols then marks[col] = letter end
                end
            end
        end

        print(string.format("%3d |%s|%s|", row, table.concat(line), table.concat(marks)))
    end
    print("    цвета — " .. table.concat(legend, ", "))
end

-- ─── проверки ────────────────────────────────────────────────────────────
--
-- Пробник не только показывает, но и УТВЕРЖДАЕТ. Правило FR-005 §4а нельзя
-- проверить глазами по снимку: выровнена ли зона захвата по сетке, видно
-- только числом.

local failures = 0
local function check(ok, what)
    if ok then return end
    failures = failures + 1
    print("    ✗ " .. what)
end

-- Два попадания не имеют права делить ячейку.
--
-- Это НЕ придирка и не то, что видно на снимке. Три кнопки заголовка шириной
-- 16 px с шагом 18 px выглядят безупречно, а при ячейке в 10 px их зоны
-- пересекаются: щелчок по общей колонке принадлежит двум кнопкам сразу, и
-- выигрывает та, что нашлась первой. Молча.
local function check_overlap(hits)
    local owner = {}
    for _, hit in ipairs(hits or {}) do
        for row = hit.row, (hit.bottom_row or hit.row) do
            for col = hit.from, hit.to do
                local key = row .. ":" .. col
                local taken = owner[key]
                check(taken == nil,
                    "ячейка " .. col .. "," .. row .. " принадлежит сразу двум: "
                        .. tostring(taken) .. " и " .. tostring(hit.id))
                owner[key] = tostring(hit.id)
            end
        end
    end
end

local function check_hits(raster, hits)
    local w, h = raster:size()
    local cols = math.ceil(w / CELL.w)
    local rows = math.ceil(h / CELL.h)
    for _, hit in ipairs(hits or {}) do
        local name = tostring(hit.id or "без имени")
        check(hit.from >= 1 and hit.to <= cols,
            name .. ": попадание уехало за растр по горизонтали ("
                .. hit.from .. ".." .. hit.to .. " при " .. cols .. " колонках)")
        check(hit.row >= 1 and (hit.bottom_row or hit.row) <= rows,
            name .. ": попадание уехало за растр по вертикали")
        check(hit.from <= hit.to and hit.row <= (hit.bottom_row or hit.row),
            name .. ": вырожденное попадание")
        check(math.floor(hit.from) == hit.from and math.floor(hit.row) == hit.row,
            name .. ": попадание не в целых ячейках — мышь таких координат не знает")
    end
end

-- ─── сцены ───────────────────────────────────────────────────────────────

local function scene(title, cols, rows, paint)
    local raster = gfx.raster(cols * CELL.w, rows * CELL.h)
    print("")
    print("┌── " .. title)
    local hits = paint(raster) or {}
    cell_map(raster, hits)
    check_hits(raster, hits)
    check_overlap(hits)
    return raster, hits
end

local font = gfx.font("", {size = 13})

scene("окно: грань в один пиксель, заголовок и три кнопки", 30, 8, function(raster)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)

    -- Заголовок ВНУТРИ рамки, как на эталоне: полоса начинается после грани.
    pixels.title(raster, 4, 4, w - 6, CELL.h - 2,
        {text = "Мой компьютер", font = font, focused = true}, CELL)

    -- Кнопки заголовка ставятся В ЯЧЕЙКАХ, по две на кнопку, и это не
    -- украшательство: поставленные по пикселям с шагом 18, они выглядели бы
    -- так же, а зоны попадания пересекались бы — пробник это и поймал, когда
    -- сцена была написана по пикселям.
    --
    -- `inset` оставляет рисунку 16×16 внутри двух ячеек: украшение свободно,
    -- интерактив квантован.
    local hits = {}
    local ids = {"minimize", "maximize", "close"}
    for index, id in ipairs(ids) do
        hits[#hits+1] = pixels.button_at(raster, 24 + (index - 1) * 2, 1, 2, 1,
            {id = id, label = "", font = font, inset = 2}, CELL)
    end

    pixels.field(raster, 4, CELL.h + 4, w - 6, h - CELL.h - 7)
    return hits
end)

scene("кнопки диалога: обычная, нажатая", 24, 4, function(raster)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    local hits = {}
    hits[#hits+1] = pixels.button_at(raster, 2, 2, 7, 1,
        {id = "ok", label = "ОК", font = font, inset = 2}, CELL)
    hits[#hits+1] = pixels.button_at(raster, 10, 2, 7, 1,
        {id = "cancel", label = "Отмена", font = font, pressed = true, inset = 2}, CELL)
    return hits
end)

scene("неактивный заголовок отличается фоном, а не яркостью текста", 20, 2, function(raster)
    local w = raster:size()
    pixels.panel(raster, 1, 1, w, 40)
    pixels.title(raster, 2, 2, w - 2, CELL.h - 2, {text = "Не в фокусе", font = font}, CELL)
    return {}
end)

-- ─── ГЛАВНАЯ МЕРА: кадр, нарисованный дважды ────────────────────────────
--
-- Это первое, что пробник обязан уметь мерить, и вот почему.
--
-- Если растры пересоздаются каждый кадр, экран остаётся ПРАВИЛЬНЫМ. Картинка
-- та же, цвета те же, ничего не мигает — просто всё летит заново, и нажатие
-- клавиши стоит сорока семи миллисекунд вместо одной. Глазами такую ошибку не
-- увидеть ни на снимке, ни на стенде: у медленного нет стека вызовов.
--
-- Проверяется единственным способом — версиями. Кадр без изменений не имеет
-- права сдвинуть ни одну.

-- Кадр оболочки в миниатюре: заголовок, две боковые грани, панель задач.
-- Разрезано по СТРОКАМ нарочно (FR-005 §3): одно размещение на всё окно
-- значило бы, что набор текста внутри перерисовывает весь хром.
local function paint_frame(store, state)
    store.begin()

    local title, dirty = store.take("win:title", 30, 1, CELL,
        state.title .. "|" .. tostring(state.focused))
    if dirty then
        pixels.panel(title, 1, 1, 300, CELL.h)
        pixels.title(title, 2, 2, 296, CELL.h - 4,
            {text = state.title, font = font, focused = state.focused}, CELL)
    end
    store.place("win:title", 1, 1)

    for _, side in ipairs({{"left", 1}, {"right", 30}}) do
        local edge, edge_dirty = store.take("win:" .. side[1], 1, 6, CELL, tostring(state.rows))
        if edge_dirty then pixels.panel(edge, 1, 1, CELL.w, 6 * CELL.h) end
        store.place("win:" .. side[1], side[2], 2)
    end

    local bar, bar_dirty = store.take("taskbar", 30, 1, CELL, state.clock)
    if bar_dirty then
        pixels.panel(bar, 1, 1, 300, CELL.h)
        pixels.label(bar, 240, 1, 56, CELL.h, state.clock, font)
    end
    store.place("taskbar", 1, 8)

    if state.menu then
        local menu, menu_dirty = store.take("menu", 12, 5, CELL, state.menu)
        if menu_dirty then pixels.panel(menu, 1, 1, 120, 5 * CELL.h) end
        store.place("menu", 1, 3)
    end

    return store.frame(CELL)
end

-- Снимок кадра: для каждого размещения — САМ РАСТР и его версия.
--
-- Растр здесь не для красоты. Сравнение одних только версий эту ошибку НЕ
-- ЛОВИТ, и это выяснилось мутацией: хранилище, пересоздающее растр каждый
-- кадр, отдаёт свежий буфер с версией 0, рисующий в него код повторяет те же
-- вызовы — и версия приходит ТА ЖЕ САМАЯ. Числа совпадают, а на экран летит
-- всё заново.
--
-- Различает их только тождество: поверхность способна понять, что картинка не
-- менялась, лишь пока это ТОТ ЖЕ растр. Новый объект с тем же номером для неё
-- — новая картинка.
local function snapshot(placements)
    local out = {}
    for _, item in ipairs(placements) do
        out[item.id] = {raster = item.raster, version = item.raster:version()}
    end
    return out
end

local function moved(before, after)
    local names = {}
    for id, now in pairs(after) do
        local was = before[id]
        if not was then
            names[#names+1] = id .. " (появился)"
        elseif was.raster ~= now.raster then
            names[#names+1] = id .. " (ПЕРЕСОЗДАН)"
        elseif was.version ~= now.version then
            names[#names+1] = id
        end
    end
    table.sort(names)
    return names
end

do
    print("")
    print("┌── растры переживают кадр")

    local store = rasters.store()
    local state = {title = "Мой компьютер", focused = true, rows = 6, clock = "21:47"}

    local first = paint_frame(store, state)
    local after_first = snapshot(first)
    print("    первый кадр: размещений " .. #first .. ", растров в хранилище " .. store.size())

    -- Тот же кадр ещё раз. Ни одна версия не имеет права сдвинуться.
    local second = paint_frame(store, state)
    local after_second = snapshot(second)
    local changed = moved(after_first, after_second)
    check(#changed == 0,
        "кадр без изменений сдвинул версии: " .. table.concat(changed, ", ")
            .. " — растры пересоздаются, и экран при этом правильный")
    print("    повтор того же кадра: сдвинулось версий " .. #changed)

    -- Сменились часы — обязана перерисоваться ТОЛЬКО панель задач. Если
    -- перерисовалось больше, значит чей-то ключ зависит от того, от чего
    -- картинка не зависит.
    state.clock = "21:48"
    local third = paint_frame(store, state)
    local ticked = moved(after_second, snapshot(third))
    check(#ticked == 1 and ticked[1] == "taskbar",
        "смена часов перерисовала: " .. table.concat(ticked, ", ") .. " (ожидалась только taskbar)")
    print("    сменились часы: перерисовано " .. table.concat(ticked, ", "))

    -- Открытое меню добавляет размещение; закрытое обязано ИСЧЕЗНУТЬ из
    -- списка, а не остаться картинкой поверх экрана.
    state.menu = "открыто"
    local with_menu = paint_frame(store, state)
    check(#with_menu == #third + 1, "меню не добавило размещения")

    state.menu = nil
    local without_menu = paint_frame(store, state)
    check(#without_menu == #third, "закрытое меню осталось в списке размещений")
    local names = {}
    for _, item in ipairs(without_menu) do names[#names+1] = item.id end
    check(not (table.concat(names, ",")):find("menu", 1, true),
        "меню осталось в кадре после закрытия")
    print("    меню открыто/закрыто: размещений " .. #with_menu .. " / " .. #without_menu
        .. ", растров в хранилище " .. store.size())

    -- Хранилище, которое только растёт, — утечка, и заметна она не отказом, а
    -- памятью. Выброшенное меню обязано уйти и оттуда.
    check(store.size() == #without_menu,
        "в хранилище осталось растров больше, чем в кадре: " .. store.size())
end

print("")
if failures == 0 then
    print("проверок не нарушено")
else
    print("НАРУШЕНО ПРОВЕРОК: " .. failures)
end
