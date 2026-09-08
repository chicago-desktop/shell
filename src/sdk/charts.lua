-- Графики SDK: столбцы блочными символами для ячеек и круглый потолок.
--
-- Чистая библиотека без рантайма: её читают оба отрисовщика и диспетчер
-- задач. Раньше жила в модели диспетчера; график нужен любому окну, которое
-- показывает историю числа, поэтому переехал сюда вместе с тестами.

local charts = {}

local geometry = require("geometry")
local whole = geometry.whole

local LEVELS = {" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

-- Круглый потолок шкалы: 1-2-2.5-5-10 × степень десяти, не ниже максимума.
-- `math.log(v, base)` в этом Lua второго аргумента не знает — делится.
function charts.round_ceiling(value: any): number
    local n = tonumber(value) or 0
    if n <= 0 then return 0 end
    local magnitude = 10 ^ math.floor(math.log(n) / math.log(10))
    for _, step in ipairs({1, 2, 2.5, 5, 10}) do
        local candidate = step * magnitude
        if candidate >= n then return candidate end
    end
    return 10 * magnitude
end

-- graph(history, width, height, ceiling) -> строки, потолок
--
-- Последнее измерение справа; строки сверху вниз; столбец выше строки
-- делится на полные снизу и дробную сверху; недостающие слева — пустота.
function charts.graph(history: any, width: any, height: any, ceiling: any): (any, any)
    local w, h = whole(width), whole(height)
    local rows: {string} = {}
    if w < 1 or h < 1 then return rows, 1 end

    local list: any = type(history) == "table" and history or {}
    local count = whole(#list)
    local top = tonumber(ceiling) or 0
    if top <= 0 then
        local peak = 0
        for _, value in ipairs(list) do
            local number = tonumber(value) or 0
            if number > peak then peak = number end
        end
        top = charts.round_ceiling(peak)
    end
    if top <= 0 then top = 1 end

    local units = h * 8
    local columns: {integer} = {}
    for column = 1, w do
        local index = count - w + column
        local filled = -1
        if index >= 1 then
            local value = tonumber(list[index]) or 0
            if value > top then value = top end
            filled = whole(math.floor(value / top * units + 0.5))
            if filled < 0 then filled = 0 end
            if filled > units then filled = units end
        end
        columns[column] = filled
    end

    for row = 1, h do
        local parts: {string} = {}
        local floor = (h - row) * 8
        for column = 1, w do
            local filled = columns[column]
            local glyph = " "
            if filled >= 0 then
                local level = filled - floor
                if level >= 8 then glyph = LEVELS[9]
                elseif level > 0 then glyph = LEVELS[level + 1] end
            end
            parts[column] = glyph
        end
        rows[row] = table.concat(parts)
    end
    return rows, top
end

-- Потолок истории — по её максимуму, круглый.
function charts.ceiling_of(history: any): number
    local peak = 0
    for _, value in ipairs(type(history) == "table" and history or {}) do
        local number = tonumber(value) or 0
        if number > peak then peak = number end
    end
    return math.max(1, charts.round_ceiling(peak))
end

return charts
