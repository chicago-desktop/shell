-- Хранилище растров между кадрами.
--
-- Это тот механизм, без которого пиксельная тема выглядит безупречно и при
-- этом работает вчетверо медленнее, чем должна (FR-005 §4).
--
-- ─── Почему ошибка невидима ─────────────────────────────────────────────
--
-- Размещение отправляется заново, когда меняется `version` растра, а версия
-- двигается на каждой записи. Тема, создающая растр в функции отрисовки,
-- получает НОВЫЙ растр каждый кадр — и переотправляет всё каждый кадр.
--
-- Экран при этом ПРАВИЛЬНЫЙ. Картинка та же, цвета те же, ничего не мигает.
-- Просто каждое нажатие клавиши в окне с bash стоит сорока семи миллисекунд
-- вместо одной, и по ssh это чувствуется, а в коде не видно. У медленного нет
-- стека вызовов.
--
-- ─── Как это устроено ───────────────────────────────────────────────────
--
-- Растр берётся по имени и по КЛЮЧУ — отпечатку того состояния, из которого
-- он нарисован. Совпал ключ и размер — растр отдаётся как есть, и рисовать в
-- него ЗАПРЕЩЕНО: любая запись сдвинет версию и отправит картинку заново.
-- Поэтому `take` отдаёт вторым значением признак «надо рисовать», а не
-- оставляет это на совесть вызывающего.
--
--     local raster, dirty = store:take("win:w1:title", 60, 1, cell, key)
--     if dirty then draw_title(raster, …) end
--     store:place("win:w1:title", x, y)
--
-- Ключ — строка, и собирает её тот, кто рисует: только он знает, от чего
-- зависит его картинка. Заголовок зависит от текста, ширины и фокуса; стол —
-- от раскладки значков. Ключ, забывший поле, даёт картинку, которая не
-- обновляется, — и это ровно та ошибка, которую видно глазом, в отличие от
-- обратной.
--
-- ─── Список полон ───────────────────────────────────────────────────────
--
-- Размещение, которого нет в кадре, снимается с экрана (FR-005 §5). Поэтому
-- кадр открывается `begin`, а `sweep` выбрасывает всё, чего в нём не назвали:
-- так исчезает закрытое меню — не рисованием поверх, а отсутствием в списке.

local gfx = require("gfx")

local rasters = {}

local geometry = require("geometry")
local whole = geometry.whole

-- store() -> хранилище
function rasters.store(): any
    local kept: any = {}
    local used: any = {}
    local order: any = {}
    local self: any = {}

    -- Начало кадра. Список названного обнуляется — то, что не назовут, уйдёт
    -- с экрана.
    function self.begin()
        used = {}
        order = {}
    end

    -- take(id, cols, rows, cell, key) -> растр, надо ли рисовать
    --
    -- Размер в ЯЧЕЙКАХ, а не в пикселях: размещение всё равно ложится по
    -- сетке, и растр, чья высота не кратна ячейке, оставляет полосу чужого
    -- фона снизу. Пиксели считаются здесь, в одном месте.
    function self.take(id, cols: any, rows: any, cell: any, key)
        local unit: any = type(cell) == "table" and cell or {}
        local cw = math.max(1, whole(unit.w))
        local ch = math.max(1, whole(unit.h))
        local width = math.max(1, whole(cols)) * cw
        local height = math.max(1, whole(rows)) * ch
        local stamp = tostring(key or "")

        local slot: any = kept[id]
        if slot and slot.width == width and slot.height == height and slot.key == stamp then
            used[id] = slot
            return slot.raster, false
        end

        -- Размер сменился — нужен новый буфер: растр не растягивается.
        -- Сменился только ключ — буфер тот же, и это важно: пересоздание ради
        -- перерисовки выбросило бы то единственное, ради чего всё хранится.
        local raster = (slot and slot.width == width and slot.height == height)
            and slot.raster or gfx.raster(width, height)

        slot = {raster = raster, width = width, height = height, key = stamp}
        kept[id] = slot
        used[id] = slot
        return raster, true
    end

    -- Куда лечь. Координаты в ЯЧЕЙКАХ, единичные, как везде здесь.
    function self.place(id, col: any, row: any)
        local slot: any = used[id]
        if not slot then return false, "растр не взят в этом кадре: " .. tostring(id) end
        slot.col = whole(col)
        slot.row = whole(row)
        order[#order + 1] = id
        return true, nil
    end

    -- Кадр целиком: размещения в том порядке, в каком их назвали.
    --
    -- `sweep` выбрасывает всё, чего в кадре не назвали. Растр, оставшийся в
    -- хранилище от закрытого меню, не стоил бы ничего на экране, но стоил бы
    -- памяти и однажды вернулся бы, когда меню открыли снова с тем же ключом
    -- и другим содержимым.
    function self.frame(cell: any)
        local unit: any = type(cell) == "table" and cell or {}
        local cw = math.max(1, whole(unit.w))
        local ch = math.max(1, whole(unit.h))

        local out = {}
        for _, id in ipairs(order) do
            local slot: any = used[id]
            if slot and slot.col then
                out[#out + 1] = {
                    id = id, raster = slot.raster,
                    x = slot.col, y = slot.row,
                    cols = slot.width // cw, rows = slot.height // ch,
                }
            end
        end

        for id in pairs(kept) do
            if not used[id] then kept[id] = nil end
        end
        return out
    end

    -- Сколько растров хранится. Для проверок: хранилище, которое только
    -- растёт, — это утечка, и заметна она не отказом, а памятью.
    function self.size(): integer
        local count = 0
        for _ in pairs(kept) do count = count + 1 end
        return count
    end

    return self
end

return rasters
