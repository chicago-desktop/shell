-- The Windows 95 desktop patterns: 8×8 monochrome tiles, one byte per row,
-- the high bit on the left. A set bit is drawn black, a clear one in the
-- desktop color — the pattern is laid over the color, not instead of it.
--
-- The bits are the originals, decoded from the Windows 95/98 pattern
-- bitmaps (cs.gettysburg.edu/~duncjo01/archive/patterns/windows): Weave,
-- Quilt, Thatches and Tulip match the values Windows 3.1 kept in
-- CONTROL.INI byte for byte, which is how the source was checked. The list
-- and its order are the Display Properties list of Windows 95.
--
-- A pure library: the display window lists the names, the shell looks the
-- chosen one up and hands its rows to the theme.
local patterns = {}

patterns.NONE = "(None)"

patterns.LIST = {
    {name = "Bricks", rows = {187, 95, 174, 93, 186, 117, 234, 245}},
    {name = "Buttons", rows = {170, 125, 198, 71, 198, 127, 190, 85}},
    {name = "Cargo Net", rows = {120, 49, 19, 135, 225, 200, 140, 30}},
    {name = "Circuits", rows = {82, 41, 132, 66, 148, 41, 66, 132}},
    {name = "Cobblestones", rows = {40, 68, 146, 171, 214, 108, 56, 16}},
    {name = "Colosseum", rows = {130, 1, 1, 1, 171, 85, 170, 85}},
    {name = "Daisies", rows = {30, 140, 216, 253, 191, 27, 49, 120}},
    {name = "Dizzy", rows = {62, 7, 225, 7, 62, 112, 195, 112}},
    {name = "Field Effect", rows = {86, 89, 166, 154, 101, 149, 106, 169}},
    {name = "Key", rows = {254, 2, 250, 138, 186, 162, 190, 128}},
    {name = "Live Wire", rows = {239, 239, 14, 254, 254, 254, 224, 239}},
    {name = "Plaid", rows = {240, 240, 240, 240, 170, 85, 170, 85}},
    {name = "Quilt", rows = {130, 68, 40, 17, 40, 68, 130, 1}},
    {name = "Rounder", rows = {215, 147, 40, 215, 40, 147, 213, 215}},
    {name = "Scales", rows = {225, 42, 37, 146, 85, 152, 62, 247}},
    {name = "Stone", rows = {174, 77, 239, 255, 8, 77, 174, 77}},
    {name = "Thatches", rows = {248, 116, 34, 71, 143, 23, 34, 113}},
    {name = "Tulip", rows = {0, 0, 84, 124, 124, 56, 146, 124}},
    {name = "Waffle's Revenge", rows = {77, 154, 8, 85, 239, 154, 77, 154}},
    {name = "Weave", rows = {136, 84, 34, 69, 136, 21, 34, 81}},
}

-- find(name) -> the eight rows of a pattern, or nil for "(None)" and for a
-- name that is not in the list: a desktop without a pattern is the safe
-- reading of a setting nobody can draw.
function patterns.find(name: any): any
    for _, entry in ipairs(patterns.LIST) do
        if entry.name == name then return entry.rows end
    end
    return nil
end

-- items(chosen) -> list rows for the SDK: "(None)" first, then the patterns;
-- the id is the name, which is also what the setting stores.
function patterns.items(): any
    local out: any = {{id = patterns.NONE, text = patterns.NONE}}
    for _, entry in ipairs(patterns.LIST) do out[#out + 1] = {id = entry.name, text = entry.name} end
    return out
end

-- set(rows, x, y) -> whether the pixel of a tile is set; x and y count from
-- one and wrap every eight, so a raster anchored anywhere tiles seamlessly.
function patterns.set(rows: any, x: any, y: any): boolean
    local byte = math.tointeger(rows[((math.tointeger(y) or 1) - 1) % 8 + 1]) or 0
    local bit = 7 - ((math.tointeger(x) or 1) - 1) % 8
    return (byte >> bit) & 1 == 1
end

return patterns
