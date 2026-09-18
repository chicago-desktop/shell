-- The characters a terminal draws lines with, as geometry instead of type.
--
-- A frame on someone else's screen is built from block elements — ▛ ▔ ▁ ▟ ▏ ▕
-- — and the fixed-pitch face the shell ships does not contain them. A
-- renderer that asks the font for them draws nothing, and the remote desktop
-- arrives with every border missing: the colours right, the shape gone, which
-- is most of what a desktop looks like.
--
-- Terminals solve this by drawing these characters themselves, and so does
-- this: each one is a handful of rectangles in the cell, given here in unit
-- coordinates (0..1 of the cell's width and height) for the renderer to
-- scale. Geometry does not depend on which fonts a machine has, so the same
-- screen looks the same everywhere — which a fallback face could not promise.
--
-- `shape(char)` returns the rectangles, or nil when the character is ordinary
-- and the font should draw it.

local glyphs = {}

local function rect(x: number, y: number, w: number, h: number): any
    return {x = x, y = y, w = w, h = h}
end

-- The eighths. A block character names how much of the cell is filled and
-- from which side; the rest is arithmetic.
local function lower(eighths: integer): any
    return {rect(0, 1 - eighths / 8, 1, eighths / 8)}
end

local function left(eighths: integer): any
    return {rect(0, 0, eighths / 8, 1)}
end

-- A shade is a proportion of ink, and there is no blending here: a checker of
-- whole rectangles is what the original was on a screen of lit cells, and at
-- eight pixels by twenty it reads as a shade rather than as squares.
local function checker(count: integer, inverted: boolean): any
    local out: any = {}
    local step = 1 / count
    for row = 0, count - 1 do
        for column = 0, count - 1 do
            local filled = (row + column) % 2 == 0
            if inverted then filled = not filled end
            if filled then
                out[#out + 1] = rect(column * step, row * step, step, step)
            end
        end
    end
    return out
end

-- A quarter of the cell, named the way the quadrant characters name them.
local UL, UR, LL, LR = rect(0, 0, 0.5, 0.5), rect(0.5, 0, 0.5, 0.5),
    rect(0, 0.5, 0.5, 0.5), rect(0.5, 0.5, 0.5, 0.5)

-- A line of a box-drawing character: thin, and centred on the cell's middle
-- so that two neighbours meet.
local THIN = 1 / 8
local MID = 0.5 - THIN / 2
local function across(from: number, to: number): any
    return rect(from, MID, to - from, THIN)
end
local function down(from: number, to: number): any
    return rect(MID, from, THIN, to - from)
end

-- An outlined square, for the symbols a terminal uses as small icons.
local function box(): any
    return {rect(0.15, 0.2, 0.7, THIN), rect(0.15, 0.8 - THIN, 0.7, THIN),
        rect(0.15, 0.2, THIN, 0.6), rect(0.85 - THIN, 0.2, THIN, 0.6)}
end

local function with(base: any, extra: any): any
    local out: any = {}
    for _, item in ipairs(base) do out[#out + 1] = item end
    for _, item in ipairs(extra) do out[#out + 1] = item end
    return out
end

local SHAPES: any = {
    -- Block elements, U+2580–U+259F.
    [0x2580] = {rect(0, 0, 1, 0.5)},
    [0x2581] = lower(1), [0x2582] = lower(2), [0x2583] = lower(3),
    [0x2584] = lower(4), [0x2585] = lower(5), [0x2586] = lower(6),
    [0x2587] = lower(7), [0x2588] = {rect(0, 0, 1, 1)},
    [0x2589] = left(7), [0x258A] = left(6), [0x258B] = left(5),
    [0x258C] = left(4), [0x258D] = left(3), [0x258E] = left(2),
    [0x258F] = left(1),
    [0x2590] = {rect(0.5, 0, 0.5, 1)},
    [0x2591] = checker(4, false), [0x2592] = checker(8, false),
    [0x2593] = checker(4, true),
    [0x2594] = {rect(0, 0, 1, 1 / 8)},
    [0x2595] = {rect(7 / 8, 0, 1 / 8, 1)},
    [0x2596] = {LL}, [0x2597] = {LR}, [0x2598] = {UL},
    [0x2599] = {UL, LL, LR}, [0x259A] = {UL, LR},
    [0x259B] = {UL, UR, LL}, [0x259C] = {UL, UR, LR},
    [0x259D] = {UR}, [0x259E] = {UR, LL}, [0x259F] = {UR, LL, LR},
    -- The single lines of box drawing, U+2500–U+253C: enough for a frame.
    [0x2500] = {across(0, 1)}, [0x2502] = {down(0, 1)},
    [0x250C] = {across(MID, 1), down(MID, 1)},
    [0x2510] = {across(0, MID + THIN), down(MID, 1)},
    [0x2514] = {across(MID, 1), down(0, MID + THIN)},
    [0x2518] = {across(0, MID + THIN), down(0, MID + THIN)},
    [0x251C] = {down(0, 1), across(MID, 1)},
    [0x2524] = {down(0, 1), across(0, MID + THIN)},
    [0x252C] = {across(0, 1), down(MID, 1)},
    [0x2534] = {across(0, 1), down(0, MID + THIN)},
    [0x253C] = {across(0, 1), down(0, 1)},
    -- The small icons a terminal desktop draws with: a filled square, a
    -- ruled one, a squared plus. An empty cell in their place is never right.
    [0x25A0] = {rect(0.2, 0.25, 0.6, 0.5)},
    [0x25A3] = with(box(), {rect(0.3, 0.35, 0.4, 0.3)}),
    [0x25A4] = with(box(), {rect(0.25, 0.35, 0.5, THIN), rect(0.25, 0.5, 0.5, THIN),
        rect(0.25, 0.65, 0.5, THIN)}),
    [0x229E] = with(box(), {rect(0.35, 0.47, 0.3, THIN), rect(0.5 - THIN / 2, 0.32, THIN, 0.36)}),
}

-- codepoint reads one UTF-8 character. A byte that starts nothing valid is
-- its own codepoint, which keeps a row that is not UTF-8 drawing instead of
-- failing.
function glyphs.codepoint(char: any): integer
    local text = type(char) == "string" and char or ""
    local lead = text:byte(1)
    if lead == nil then return 0 end
    if lead < 0x80 then return lead end
    local width, value = 1, lead
    if lead >= 0xF0 then width, value = 4, lead - 0xF0
    elseif lead >= 0xE0 then width, value = 3, lead - 0xE0
    elseif lead >= 0xC0 then width, value = 2, lead - 0xC0
    end
    if #text < width then return lead end
    for index = 2, width do
        local byte = text:byte(index)
        if byte == nil or byte < 0x80 or byte > 0xBF then return lead end
        value = value * 64 + (byte - 0x80)
    end
    return math.tointeger(value) or lead
end

-- shape returns the rectangles this character is drawn from, in unit
-- coordinates of the cell, or nil when the font should draw it.
function glyphs.shape(char: any): any
    return SHAPES[glyphs.codepoint(char)]
end

return glyphs
