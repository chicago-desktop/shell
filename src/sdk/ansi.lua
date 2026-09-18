-- Styled terminal rows, decoded into cells a renderer can paint.
--
-- A row that came from a terminal is text with SGR sequences in it. The
-- cells renderer never needs this: the runtime's canvas is ANSI-aware and
-- takes such a row whole. The pixel renderer does, because it draws one rune
-- at a time and has to know the ink and the paper of each.
--
-- Only SGR (`ESC [ ... m`) is read. Everything else a row may carry — other
-- CSI sequences, OSC 8 hyperlinks — is skipped rather than drawn: a cursor
-- move inside a row that is already laid out would be a lie, and a link is
-- not a thing pixels can be clicked on here. What cannot be understood is
-- dropped, never printed: a half-understood escape printed as text is how a
-- screen fills with "8;2;255;255;255m".
--
-- Colours come back as `#rrggbb`, or nil for "whatever the renderer calls
-- default". The caller owns the default, because the default is the theme's,
-- not the terminal's.

local ansi = {}

local ESC = 27

-- The sixteen the terminal names, in xterm's values. These are the terminal's
-- colours and not the shell's: a program that asks for red means its own red.
local BASE = {
    [0] = "#000000", [1] = "#cd0000", [2] = "#00cd00", [3] = "#cdcd00",
    [4] = "#0000ee", [5] = "#cd00cd", [6] = "#00cdcd", [7] = "#e5e5e5",
    [8] = "#7f7f7f", [9] = "#ff0000", [10] = "#00ff00", [11] = "#ffff00",
    [12] = "#5c5cff", [13] = "#ff00ff", [14] = "#00ffff", [15] = "#ffffff",
}

local CUBE_LEVELS = {[0] = 0, [1] = 95, [2] = 135, [3] = 175, [4] = 215, [5] = 255}

-- whole() keeps an index an integer. In this Lua an arithmetic result can be
-- a float, and a float key does not find the integer one it equals, so a
-- palette entry would silently come back nil.
local function whole(value: any): integer
    local exact = math.tointeger(value)
    if exact ~= nil then return exact end
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local function hex2(value: integer): string
    local digits = "0123456789abcdef"
    local high = whole(value // 16) + 1
    local low = whole(value - whole(value // 16) * 16) + 1
    return digits:sub(high, high) .. digits:sub(low, low)
end

-- The 256 the terminal can name: sixteen by name, a 6×6×6 cube, and a ramp
-- of greys. Built once.
local PALETTE: any = {}
do
    for index = 0, 15 do PALETTE[index] = BASE[index] end
    for r = 0, 5 do
        for g = 0, 5 do
            for b = 0, 5 do
                local index = whole(16 + r * 36 + g * 6 + b)
                PALETTE[index] = "#" .. hex2(CUBE_LEVELS[r]) .. hex2(CUBE_LEVELS[g]) .. hex2(CUBE_LEVELS[b])
            end
        end
    end
    for step = 0, 23 do
        local level = whole(8 + step * 10)
        PALETTE[whole(232 + step)] = "#" .. hex2(level) .. hex2(level) .. hex2(level)
    end
end

-- indexed returns the colour of a palette entry, or nil when the number is
-- not one. nil means default, which is the honest answer for a number this
-- palette has no colour for.
function ansi.indexed(index: any): any
    return PALETTE[whole(index)]
end

-- runes splits a row into characters, by UTF-8's own lengths. A byte that
-- starts nothing valid is taken as one character, so a row that is not UTF-8
-- still draws instead of vanishing.
local function runes(text: string): any
    local out, position, size = {}, 1, #text
    while position <= size do
        local lead = text:byte(position)
        local width = 1
        if lead >= 0xF0 then
            width = 4
        elseif lead >= 0xE0 then
            width = 3
        elseif lead >= 0xC0 then
            width = 2
        end
        if position + width - 1 > size then width = 1 end
        out[#out + 1] = text:sub(position, position + width - 1)
        position = position + width
    end
    return out
end

local function blank(): any
    return {char = " ", fg = nil, bg = nil, bold = false, underline = false, reverse = false}
end

-- apply reads one SGR sequence's parameters into the pen.
--
-- Unknown parameters are ignored one by one rather than abandoning the whole
-- sequence: a row styled by a program that knows more attributes than this
-- still gets the colours it asked for.
local function apply(pen: any, params: any)
    local index = 1
    while index <= #params do
        local code = params[index]
        if code == 0 then
            pen.fg, pen.bg = nil, nil
            pen.bold, pen.underline, pen.reverse = false, false, false
        elseif code == 1 then pen.bold = true
        elseif code == 22 then pen.bold = false
        elseif code == 4 then pen.underline = true
        elseif code == 24 then pen.underline = false
        elseif code == 7 then pen.reverse = true
        elseif code == 27 then pen.reverse = false
        elseif code >= 30 and code <= 37 then pen.fg = PALETTE[code - 30]
        elseif code >= 90 and code <= 97 then pen.fg = PALETTE[code - 90 + 8]
        elseif code == 39 then pen.fg = nil
        elseif code >= 40 and code <= 47 then pen.bg = PALETTE[code - 40]
        elseif code >= 100 and code <= 107 then pen.bg = PALETTE[code - 100 + 8]
        elseif code == 49 then pen.bg = nil
        elseif code == 38 or code == 48 then
            local kind = params[index + 1]
            local colour: any = nil
            if kind == 5 and params[index + 2] ~= nil then
                colour = PALETTE[whole(params[index + 2])]
                index = index + 2
            elseif kind == 2 and params[index + 4] ~= nil then
                colour = "#" .. hex2(whole(params[index + 2])) .. hex2(whole(params[index + 3]))
                    .. hex2(whole(params[index + 4]))
                index = index + 4
            end
            if code == 38 then pen.fg = colour else pen.bg = colour end
        end
        index = index + 1
    end
end

-- skip walks past one escape sequence and says where the text resumes, and
-- whether the sequence was an SGR worth applying.
local function skip(text: string, position: integer): integer, any
    local size = #text
    local next_byte = text:byte(position + 1)
    if next_byte == nil then return position + 1, nil end
    -- CSI: parameters, then one letter that names the sequence.
    if next_byte == 0x5B then
        local cursor = position + 2
        local params_from = cursor
        while cursor <= size do
            local byte = text:byte(cursor)
            if byte >= 0x40 and byte <= 0x7E then
                if byte == 0x6D then
                    return cursor + 1, text:sub(params_from, cursor - 1)
                end
                return cursor + 1, nil
            end
            cursor = cursor + 1
        end
        return size + 1, nil
    end
    -- OSC: runs until BEL or ESC \.
    if next_byte == 0x5D then
        local cursor = position + 2
        while cursor <= size do
            local byte = text:byte(cursor)
            if byte == 7 then return cursor + 1, nil end
            if byte == ESC and text:byte(cursor + 1) == 0x5C then return cursor + 2, nil end
            cursor = cursor + 1
        end
        return size + 1, nil
    end
    return position + 2, nil
end

local function numbers(params: string): any
    local out = {}
    if params == "" then return {0} end
    for piece in (params .. ";"):gmatch("([^;]*);") do
        out[#out + 1] = math.tointeger(tonumber(piece)) or 0
    end
    return out
end

-- decode turns one styled row into exactly `columns` cells.
--
-- Short rows are padded and long ones are cut, so a renderer can walk the
-- result without checking its length. Padding carries the pen as it stands
-- at the end of the row: a row whose background was set to the end means the
-- background to the end, which is how a terminal paints a filled bar.
function ansi.decode(row: any, columns: any): any
    local width = whole(columns)
    local text = type(row) == "string" and row or ""
    local cells, pen = {}, {fg = nil, bg = nil, bold = false, underline = false, reverse = false}
    local position, size = 1, #text
    while position <= size and #cells < width do
        if text:byte(position) == ESC then
            local resume, params = skip(text, position)
            if params ~= nil then apply(pen, numbers(params)) end
            position = resume
        else
            local from = position
            while position <= size and text:byte(position) ~= ESC do
                position = position + 1
            end
            for _, char in ipairs(runes(text:sub(from, position - 1))) do
                if #cells >= width then break end
                cells[#cells + 1] = {char = char, fg = pen.fg, bg = pen.bg,
                    bold = pen.bold, underline = pen.underline, reverse = pen.reverse}
            end
        end
    end
    while #cells < width do
        cells[#cells + 1] = {char = " ", fg = pen.fg, bg = pen.bg,
            bold = pen.bold, underline = pen.underline, reverse = pen.reverse}
    end
    return cells
end

-- ink returns the colours a cell is actually painted in, with reverse video
-- resolved and the caller's defaults filled in. A renderer should ask this
-- rather than read fg and bg itself: reverse is easy to forget, and a screen
-- that forgets it loses every selection and every menu bar.
function ansi.ink(cell: any, default_fg: any, default_bg: any): any, any
    local item: any = cell or blank()
    local fg = item.fg or default_fg
    local bg = item.bg or default_bg
    if item.reverse then return bg, fg end
    return fg, bg
end

ansi.blank = blank

return ansi
