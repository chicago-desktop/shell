-- Desktop widgets in the shell (FR-006 §4–7): where they stand, the hit of a
-- widget row, the tree a widget's body shows, and the widget drawn in cells.
--
-- One layout for both themes, like `chrome.desktop_spot` for icons: the cell
-- theme draws widgets here, the pixel theme paints its rows at the same
-- rectangles, and both return the hits of `gadgets.hit`. A second layout
-- would put a widget one cell away from where it is pressed in one of the two
-- modes. Pure: strings and arithmetic, the canvas comes from the caller.
local ui = require("ui")
local cells = require("cells")
local widgets = require("widgets")

local whole = widgets.whole

local gadgets = {}

-- An empty row between widgets and an empty column between the columns; the
-- right column itself stands one column in from the screen's edge (`x =
-- width - w`), as the icon grid stands one in from the left.
gadgets.GAP = 1
-- The right column and one more to its left. A widget that fits in neither
-- is not drawn, and it has no hits.
gadgets.COLUMNS = 2
-- The panel's frame around the body, in cells: the raised edge itself in
-- cells, the 2-px edge and its padding in pixels. `widgets.panel` draws an
-- edge of exactly one cell, so this is one.
gadgets.INSET = 1
-- The body's last row of a widget whose process stopped.
gadgets.STOPPED = "stopped"
-- The least panel that is still a panel: two edges and a column between them.
local LEAST_W, LEAST_H = 3, 2

-- layout(list, width, top, bottom) -> {{id, x, y, w, h, widget}, …}
--
-- Effective content geometry shared with the compositor's SDK resize path.
function gadgets.geometry(widget: any, screen: any): any
    local outer = math.max(0, math.min(whole(widget.w), whole(screen) // 3))
    return {width = math.max(0, outer - 2 * gadgets.INSET),
        height = math.max(0, whole(widget.h) - 2 * gadgets.INSET)}
end

-- `list` is `state.widgets` in display order, `top` and `bottom` the first
-- and the last row of the desktop. A widget wider than a third of the screen
-- stands at a third, and its tree is laid out at that width. Widgets go down
-- the right column, the first one row under `top`, an empty row between; the
-- first that does not fit under the previous one opens the second column,
-- whose right edge is one empty column left of the first column's widest.
-- A widget that fits in neither is left out.
function gadgets.layout(list: any, width: any, top: any, bottom: any): any
    local out: any = {}
    local screen = whole(width)
    local first, last = whole(math.max(1, whole(top))), whole(bottom)
    if screen < LEAST_W or last < first then return out end
    local column: any = {index = 1, right = screen - gadgets.GAP, y = first + gadgets.GAP, widest = 0}
    for _, entry in ipairs(type(list) == "table" and list or {}) do
        local widget: any = entry
        local id: any = type(widget) == "table" and widget.id or nil
        if type(id) == "string" and id ~= "" then
            local w = whole(gadgets.geometry(widget, screen).width + 2 * gadgets.INSET)
            local h = whole(widget.h)
            if w >= LEAST_W and h >= LEAST_H then
                if column.y + h - 1 > last and column.widest > 0 and column.index < gadgets.COLUMNS then
                    column = {index = column.index + 1, right = column.right - column.widest - gadgets.GAP,
                        y = first + gadgets.GAP, widest = 0}
                end
                local x = column.right - w + 1
                if x >= 1 and column.y + h - 1 <= last then
                    out[#out + 1] = {id = id, x = x, y = column.y, w = w, h = h, widget = widget}
                    column.y = column.y + h + gadgets.GAP
                    column.widest = math.max(column.widest, w)
                end
            end
        end
    end
    return out
end

-- hit(spot, row) -> the hit of one widget row, the shape of an icon row plus
-- `widget` (FR-006 §5). `entry` is what a click opens — the entry's
-- `meta.opens` — under the name icon records use, so the base's open path
-- does not branch.
function gadgets.hit(spot: any, row: any): any
    local widget: any = spot.widget
    return {row = row, from = spot.x, to = spot.x + spot.w - 1, widget = spot.id,
        entry = type(widget.opens) == "string" and widget.opens ~= "" and widget.opens or nil,
        title = type(widget.title) == "string" and widget.title ~= "" and widget.title or nil}
end

-- hits(spots) -> a hit per row of every laid out widget, in layout order.
function gadgets.hits(spots: any): any
    local out: any = {}
    for _, entry in ipairs(spots) do
        local spot: any = entry
        for row = spot.y, spot.y + spot.h - 1 do out[#out + 1] = gadgets.hit(spot, row) end
    end
    return out
end

-- title(widget) — the caption the frame draws; none is an empty string.
function gadgets.title(widget: any): string
    return type(widget.title) == "string" and widget.title or ""
end

-- body(widget) -> tree, problem
--
-- The tree a widget's body shows, one rule for both themes: nothing while the
-- first state has not come (`waiting` — not yesterday's numbers, not a hang);
-- the reason as an alert label when the state is not a tree `ui.plan` lays
-- out, the frame and the title unchanged; and for a stopped widget its last
-- tree with "stopped" in the body's last row.
function gadgets.body(widget: any): (any, any)
    local state: any = widget.content_state
    local tree: any = {kind = "column", children = {}}
    local problem: any = nil
    if widget.waiting ~= true then
        if type(state) ~= "table" or state.sdk ~= 1 then problem = "SDK state version 1 expected"
        elseif type(state.ui) ~= "table" then problem = "the state carries no component tree"
        else problem = ui.problem(state.ui) end
        if problem then tree = {kind = "label", alert = true, wrap = true, text = tostring(problem)}
        else tree = state.ui end
    end
    if widget.stopped == true then
        tree = {kind = "column", children = {tree, {kind = "label", size = 1, alert = true, text = gadgets.STOPPED}}}
    end
    return tree, problem
end

-- framed(widget) -> the tree over the whole panel, the body inside the
-- frame's cell of padding. The pixel theme lays this out at the panel's size
-- and paints the frame over the ring; the cell theme lays the body out at the
-- inner rectangle and draws the frame with the cell primitives. The same
-- rectangle either way.
function gadgets.framed(widget: any): (any, any)
    local tree, problem = gadgets.body(widget)
    return {kind = "column", padding = gadgets.INSET, children = {tree}}, problem
end

-- key(widget) — what a widget's rows depend on besides its tree's revision:
-- the title the frame draws and the two flags that change the body while the
-- revision stands still.
function gadgets.key(widget: any): string
    return gadgets.title(widget) .. "\30" .. (widget.waiting == true and "waiting" or "")
        .. "\30" .. (widget.stopped == true and "stopped" or "")
end

-- plan(tree, width, height) -> plan, interaction for a widget's body in
-- cells. A widget takes no input, so nothing in it is drawn focused: `ui.plan`
-- hands the focus to the first focusable control, and it is taken back here.
function gadgets.plan(tree: any, width: any, height: any): (any, any)
    local interaction = ui.interaction()
    local plan = ui.plan(tree, width, height, interaction)
    interaction.focus = nil
    plan.focus_on_button = false
    return plan, interaction
end

-- draw(canvas, spot) — a widget in cells: the raised panel of the cell
-- primitives, the title in its top edge where the SDK's `group` puts its
-- caption, and the body laid out by `ui.plan` and drawn by `cells.rows` at
-- the inner rectangle.
function gadgets.draw(canvas: any, spot: any)
    local w, h = whole(spot.w), whole(spot.h)
    local inner_w, inner_h = w - gadgets.INSET * 2, h - gadgets.INSET * 2
    local body: any = {}
    if inner_w >= 1 and inner_h >= 1 then
        local plan, interaction = gadgets.plan(gadgets.body(spot.widget), inner_w, inner_h)
        body = cells.rows(plan, interaction, inner_w, inner_h)
    end
    widgets.panel(canvas, spot.x, spot.y, w, body, false)
    local title = gadgets.title(spot.widget)
    if title ~= "" and w > 4 then
        local shown = " " .. widgets.clip(title, w - 4) .. " "
        canvas:put(whole(spot.x + 1), whole(spot.y), widgets.styles.face_bold:render(shown), widgets.cells(shown))
    end
end

return gadgets
