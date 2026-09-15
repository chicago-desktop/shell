-- "Display Properties", the pure model: desktop colors, the color format
-- check, resolution captions. Nothing about the database and the compositor:
-- that belongs to the window.
local geometry = require("geometry")
local whole = geometry.whole

local model = {}

model.DEFAULT = "#008080"

-- Desktop colors: the set of the standard classic palette, teal first,
-- since it is the default desktop. A user color from the database that is
-- not here is shown as a separate "Other" line rather than replaced by the
-- nearest one.
model.COLORS = {
    {id = "#008080", text = "Teal"},
    {id = "#000080", text = "Navy"},
    {id = "#008000", text = "Green"},
    {id = "#808080", text = "Gray"},
    {id = "#800000", text = "Maroon"},
    {id = "#808000", text = "Olive"},
    {id = "#800080", text = "Purple"},
    {id = "#000000", text = "Black"},
    {id = "#c0c0c0", text = "Silver"},
    {id = "#0000ff", text = "Blue"},
    {id = "#00ffff", text = "Cyan"},
    {id = "#ffffff", text = "White"},
}

-- `short` is the caption in cells, where the four captions do not fit whole.
model.TABS = {{text = "Background"}, {text = "Screen Saver", short = "Saver"}, {text = "Appearance"}, {text = "Settings"}}

function model.valid(hex: any): boolean
    return type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") ~= nil
end

-- List rows: the standard colors plus "Other" if the chosen one is not among
-- them.
function model.color_items(chosen: any): any
    local items = {}
    local known = false
    for _, entry in ipairs(model.COLORS) do
        items[#items + 1] = {id = entry.id, text = entry.text}
        if entry.id == chosen then known = true end
    end
    if model.valid(chosen) and not known then
        items[#items + 1] = {id = chosen, text = "Other (" .. tostring(chosen) .. ")"}
    end
    return items
end

-- Resolution: cells and pixels on one line in the field, the cell size as a
-- caption under it. Without a cell size pixels are not invented: "80×24
-- cells" is more honest than "640×480" from a fallback value.
function model.resolution(screen: any, cell: any): string
    local s: any = type(screen) == "table" and screen or {}
    local c: any = type(cell) == "table" and cell or {}
    local cols, rows = whole(s.width), whole(s.height)
    if cols < 1 or rows < 1 then return "unknown" end
    -- In the original's words: "640 by 480 pixels".
    local text = string.format("%d by %d cells", cols, rows)
    if whole(c.w) > 0 and whole(c.h) > 0 then
        text = text .. string.format(", %d by %d pixels", cols * whole(c.w), rows * whole(c.h))
    end
    return text
end

function model.cell_text(cell: any): string
    local c: any = type(cell) == "table" and cell or {}
    if whole(c.w) > 0 and whole(c.h) > 0 then
        return string.format("Terminal cell %d × %d px", whole(c.w), whole(c.h))
    end
    return "The terminal did not report a cell size"
end

-- Palette: the runtime forces TrueColor on; the frame mode is named by the
-- compositor and goes as a caption.
function model.palette(): string
    return "True Color (24 bit)"
end

function model.graphics(pixels: any): string
    if pixels == true then return "Pixel graphics: yes" end
    return "Pixel graphics: no, cells only"
end

return model
