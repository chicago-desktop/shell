-- SDK charts: bars of block characters for cells, and a round ceiling.
--
-- A pure library with no runtime: both renderers and the Task Manager read
-- it. It used to live in the Task Manager model; any window that shows the
-- history of a number needs a graph, so it moved here together with its tests.

local charts = {}

local geometry = require("geometry")
local whole = geometry.whole

local LEVELS = {" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

-- Round ceiling of the scale: 1-2-2.5-5-10 × a power of ten, not below the maximum.
-- `math.log(v, base)` in this Lua does not know the second argument, so we divide.
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

-- graph(history, width, height, ceiling) -> rows, ceiling
--
-- The latest measurement is on the right; rows go top to bottom; a bar taller
-- than a row splits into full ones at the bottom and a fractional one on top;
-- missing ones on the left are empty.
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

-- The ceiling of a history is taken from its maximum, rounded.
function charts.ceiling_of(history: any): number
    local peak = 0
    for _, value in ipairs(type(history) == "table" and history or {}) do
        local number = tonumber(value) or 0
        if number > peak then peak = number end
    end
    return math.max(1, charts.round_ceiling(peak))
end

return charts
