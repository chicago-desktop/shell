-- The UI kit for desktop widgets (FR-006 §8): builders of plain trees for the
-- shapes a widget shows — a value, a meter, a history, a few lines — and a
-- stack of them. A widget composes these and never touches geometry: the
-- rows each shape takes are the kit's, and the shell lays the tree out inside
-- the widget's panel with the same `ui.plan` a window uses.
--
-- Every tree is passive — labels, an image, a gauge, a graph — because a
-- widget has no focus and never receives input (FR-006 §1). A passive node
-- needs no `id`, so two shapes built by the same builder never collide in one
-- tree. Pure: no runtime modules.
local charts = require("charts")
local text = require("text")

local gadget = {}

-- Rows each shape takes at the kit's width of 20 cells. A history is
-- flexible: it takes what the stack leaves it, and four rows is the least
-- that shows a graph under its caption.
gadget.ROWS = {stat = 3, meter = 2, history = 4}
gadget.WIDTH = 20
-- `lines` shows at most this many; the rest is dropped, not squeezed.
gadget.MAX_LINES = 4
-- Rows between the shapes of a stack. None: a 20×5 widget has three body
-- rows, and a gap row would take a third of them.
gadget.GAP = 0
-- The picture of `stat` takes four columns: exactly its 32 px at an 8 px
-- cell, 32 px with air at 10 px. In cells it is one character.
local IMAGE_COLS = 4

local function runes(value: string): integer
    return #text.runes(value)
end

-- amount(value, unit) -> the value as text: a whole number without a
-- fraction, any other number with one decimal, text as it is. `unit` is
-- appended as it is, with its own leading space (" MB"), the way a graph
-- takes its unit. `+ 0.0` under `%.1f`: an integer under %f prints
-- "%!f(lua.LInteger=…)" in this runtime's string.format.
function gadget.amount(value: any, unit: any): string
    local shown: string
    if type(value) == "number" then
        local integral = math.tointeger(value)
        if integral ~= nil then shown = string.format("%d", integral)
        else shown = string.format("%.1f", value + 0.0) end
    else
        shown = tostring(value or "")
    end
    return shown .. (unit ~= nil and tostring(unit) or "")
end

-- stat{caption, value, unit?, image?, icon?} — a value with its caption
-- under it ("38 MB" over "Heap"), three rows. The value stands in two rows
-- and the caption is dimmed: the SDK has one interface font, so "big" is
-- room, not size. `image` is a picture name — the shell's catalog or an image
-- pack's `<entry>/<file>` — drawn 32 px to the left in pixels; `icon` is the
-- character cells show in its place.
function gadget.stat(spec: any): any
    local s: any = type(spec) == "table" and spec or {}
    local children: any = {}
    if type(s.image) == "string" and s.image ~= "" then
        children[#children + 1] = {kind = "image", size = IMAGE_COLS, image = s.image, icon = s.icon}
    end
    children[#children + 1] = {kind = "column", children = {
        {kind = "label", size = gadget.ROWS.stat - 1, text = gadget.amount(s.value, s.unit)},
        {kind = "label", size = 1, text = tostring(s.caption or ""), disabled = true},
    }}
    return {kind = "row", size = gadget.ROWS.stat, gap = 1, children = children}
end

-- meter{caption, value, ceiling, unit?} — the caption, a gauge toward
-- `ceiling` and the value on one line, two rows. Each text takes its length
-- plus a cell: in pixels a cell is wider than the font's average letter.
function gadget.meter(spec: any): any
    local s: any = type(spec) == "table" and spec or {}
    local caption = tostring(s.caption or "")
    local shown = gadget.amount(s.value, s.unit)
    local children: any = {}
    if caption ~= "" then children[#children + 1] = {kind = "label", size = runes(caption) + 1, text = caption} end
    children[#children + 1] = {kind = "gauge", value = tonumber(s.value) or 0, ceiling = tonumber(s.ceiling) or 0, caption = ""}
    children[#children + 1] = {kind = "label", size = runes(shown) + 1, text = shown}
    return {kind = "row", size = gadget.ROWS.meter, gap = 1, children = children}
end

-- history{caption?, values, ceiling?, unit?} — the caption over a graph of
-- the values, the latest on the right. Without a ceiling it is
-- `charts.ceiling_of(values)`, named in the tree, so both renderers scale to
-- the same round number. No `size`: in a stack it takes the rest.
function gadget.history(spec: any): any
    local s: any = type(spec) == "table" and spec or {}
    local values: any = type(s.values) == "table" and s.values or {}
    local ceiling = tonumber(s.ceiling) or 0
    if ceiling <= 0 then ceiling = charts.ceiling_of(values) end
    local caption = tostring(s.caption or "")
    local children: any = {}
    if caption ~= "" then children[#children + 1] = {kind = "label", size = 1, text = caption} end
    children[#children + 1] = {kind = "graph", values = values, ceiling = ceiling, unit = s.unit}
    return {kind = "column", children = children}
end

-- lines{lines} — up to `MAX_LINES` short lines of text (place, condition,
-- wind), a row each.
function gadget.lines(spec: any): any
    local s: any = type(spec) == "table" and spec or {}
    local children: any = {}
    for index, line in ipairs(type(s.lines) == "table" and s.lines or {}) do
        if index > gadget.MAX_LINES then break end
        children[#children + 1] = {kind = "label", size = 1, text = tostring(line)}
    end
    return {kind = "column", size = #children, children = children}
end

-- stack{…} — the shapes one under another, `GAP` rows apart; a history in it
-- takes the rows the others leave.
function gadget.stack(parts: any): any
    local children: any = {}
    for _, part in ipairs(type(parts) == "table" and parts or {}) do children[#children + 1] = part end
    return {kind = "column", gap = gadget.GAP, children = children}
end

return gadget
