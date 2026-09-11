local scroll = require("scroll")
-- What the contents of "My Computer" look like.
--
-- Separated from the window process along the same boundary that separates
-- the theme from the compositor: only strings and arithmetic here, not a
-- single call into the runtime. That is why a frame can be viewed with a
-- probe without starting either the window or the runtime — and a
-- full-screen program cannot be checked any other way.
--
-- ─── ONE LAYOUT, TWO BACKENDS ───────────────────────────────────────────
--
-- The file is split into three parts, and the split is not cosmetic.
--
--   `render.layout`  — WHAT and WHERE. Pure numbers: rows, field, grid,
--                      icon rectangles, hits. Not a single paint.
--   `render.cells`   — draws with characters into a `tty` canvas.
--   `render.pixels`  — draws with pixels into rasters.
--
-- The shell must work in a plain xterm, where there are no graphics at all
-- (FR-005 §8b), and it has no right to die there silently. So there are two
-- backends, and the price of the second is paid precisely by their layout
-- being shared.
--
-- HITS ARE COMPUTED BY THE LAYOUT, NOT BY THE DRAWING. They used to be
-- returned by whoever drew — and that was right while there was one drawer.
-- With two drawers "one table" no longer means "the function that draws" but
-- the layout: two backends that each compute hits their own way will drift
-- apart silently, and a click will land on a neighbour in one of the two
-- modes.
--
-- The icon rectangle is still taken from `icons.box` — the same function
-- `icons.cell` uses when it draws.

local icons = require("icons")
local widgets = require("widgets")

local render = {}

-- The menu bar: it has only items that have an action, and the actions are
-- the same as those of the toolbar buttons and keys. There is no "Edit" —
-- Explorer has nothing to cut and paste. An item is `{id, title}`; the window
-- executes it with the same function as the toolbar button with that `id`.
render.MENU = {
    {text = "File", accel = 1, items = {{id = "close", title = "Close"}}},
    {text = "View", accel = 1, items = {{id = "refresh", title = "Refresh"}}},
    {text = "Go", accel = 1, items = {
        {id = "back", title = "Back"}, {id = "forward", title = "Forward"}, {id = "up", title = "Up One Level"},
    }},
    {text = "Help", accel = 1, items = {{id = "about", title = "About My Computer"}}},
}

-- The toolbar of a Windows 95 folder window: back, forward, up · cut, copy,
-- paste · undo · delete, properties · four views. Back and forward through
-- the window's history and up work. The rest are declared `disabled` and
-- drawn faded, as in Windows 95, where they are grey while there is nothing
-- to cut: the toolbar does not change shape. A click on a faded one is
-- silent — as in Windows.
-- There are no captions — the toolbar is one row, and with captions it does
-- not fit into the window.
render.TOOLS = {
    {id = "back", icon = "←", title = "Back"},
    {id = "forward", icon = "→", title = "Forward"},
    {id = "up", icon = "↑", title = "Up"},
    {sep = true},
    {id = "cut", icon = "✂", title = "Cut", disabled = true},
    {id = "copy", icon = "⧉", title = "Copy", disabled = true},
    {id = "paste", icon = "⎘", title = "Paste", disabled = true},
    {sep = true},
    {id = "undo", icon = "↶", title = "Undo", disabled = true},
    {sep = true},
    {id = "delete", icon = "✕", title = "Remove", disabled = true},
    {id = "properties", icon = "▤", title = "Properties", disabled = true},
    {sep = true},
    {id = "view_large", icon = "▦", title = "Large Icons", pressed = true},
    {id = "view_small", icon = "▩", title = "Small Icons", disabled = true},
    {id = "view_list", icon = "≡", title = "List", disabled = true},
    {id = "view_details", icon = "☷", title = "Details", disabled = true},
}
-- There is no "Refresh" on the Windows 95 toolbar — it is in the "View" menu
-- and on F5 (and here also Ctrl+R). The button would not fit: the toolbar is
-- 64 cells, the window is 70.

-- Rows occupied by something other than contents: menu bar, toolbar, status
-- bar. Declared as numbers rather than computed in place, so that the field
-- and the hits are computed from one source.
render.MENU_ROW = 1
render.TOOL_ROW = 2
-- The address bar is its own row under the toolbar (as in Windows 98; in 95
-- it is a dropdown list on the toolbar itself, but in cells it does not fit
-- there).
render.ADDRESS_ROW = 3
render.FIELD_TOP = 4

-- The gap between icon columns. The grid STEP and the picture WIDTH are
-- different numbers, and here it is visible to the eye: a caption that took
-- up the whole column runs into the neighbour's caption, and the two become
-- one unreadable line. The desktop does not have this, because there an
-- icon's place is named by a person or the compositor; only this window
-- builds a grid, so it is the one to keep the gap.
render.GAP = 1

-- layout(view, width, height) -> plan
--
-- The plan is the only table both backends compute from:
--
--   rows      row numbers: menu, toolbar, field, status
--   field     the rectangle of the list field, in cells
--   inner     its interior, where the icons go
--   shape     the grid: columns, rows, total rows, which one to start from
--   tools     toolbar buttons, with hits
--   menu_hits menu bar titles; menu_popup — the open list, if any
--   cells     icons: the object index, its place and its hit
--   scroll    the scrollbar, if it is needed
--   status    the two fields of the status bar, as ready-made text
--
-- Not a single call to the canvas and not a single paint: the plan is
-- computed even when there is nowhere to draw.
-- Shared by the pixel state provider and the painter. Hits remain cell-aligned.
function render.pixel_metrics(cell_w: any, cell_h: any): any
    local cw, ch = math.max(1, widgets.whole(cell_w)), math.max(1, widgets.whole(cell_h))
    local tool_rows = math.max(1, (26 + ch - 1) // ch)
    local address_rows = math.max(1, (24 + ch - 1) // ch)
    return {grid = {w = (88 + cw - 1) // cw, h = (72 + ch - 1) // ch,
            drawn = (66 + ch - 1) // ch},
        padding = 0, address_row = 2 + tool_rows, field_top = 2 + tool_rows + address_rows,
        address_rows = address_rows, tool_rows = tool_rows,
        -- A toolbar button is 23×22 px, as in Windows 95; its place is whole cells.
        tool_span = math.max(1, (24 + cw - 1) // cw),
        -- The scrollbar is the SDK lists' bar: 16 px in whole cells.
        scroll_cols = widgets.scroll_cols(cw),
        arrow_rows = math.max(1, (16 + ch - 1) // ch), icon_size = 32}
end

function render.layout(view: any, width: any, height: any, metrics: any?): any
    local state: any = type(view) == "table" and view or {}
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local sizing: any = type(metrics) == "table" and metrics or {}
    local grid = sizing.grid or icons.grid()
    local padding = sizing.padding or 1
    local field_top = math.min(widgets.whole(sizing.field_top or render.FIELD_TOP), math.max(2, widgets.whole(height) - 1))
    local scroll_cols = sizing.scroll_cols or 1
    local objects: any = type(state.objects) == "table" and state.objects or {}

    local field_h = h - field_top
    local inner_x, inner_y = padding + 1, field_top + padding
    local inner_w, inner_h = w - padding * 2, field_h - padding * 2

    local plan: any = {
        width = w, height = h,
        rows = {menu = render.MENU_ROW, tool = render.TOOL_ROW,
                field = field_top, status = h},
        -- The toolbar height comes from the metrics, not "everything between
        -- the menu and the field": in cells the address bar also lies between
        -- them, and a two-row toolbar would catch its clicks.
        tool_rows = widgets.whole(sizing.tool_rows or 1), icon_size = sizing.icon_size or 16,
        field = {x = 1, y = field_top, w = w, h = field_h},
        inner = {x = inner_x, y = inner_y, w = inner_w, h = inner_h},
        menu = render.MENU,
        tools = {},
        cells = {},
        scroll = nil,
        failure = state.failure,
        -- The address bar: its row comes from the metrics for pixels and from
        -- a constant for cells; the hits of the field, the ▾ button and the
        -- list rows are computed HERE and are the same for both backends.
        address = {
            row = widgets.whole(sizing.address_row or render.ADDRESS_ROW),
            rows = widgets.whole(sizing.address_rows or 1),
            text = tostring(state.address or state.title or ""),
            items = type(state.address_items) == "table" and state.address_items or {},
            open = state.address_open == true,
        },
    }
    -- The menu bar: the titles are laid out by the same function that draws
    -- them in cells; the open list lies under its title on top of everything
    -- else.
    plan.menu_hits = widgets.menu_hits(1, render.MENU_ROW, w, render.MENU)
    local open_menu: any = nil
    for _, hit in ipairs(plan.menu_hits) do
        if hit.index == state.menu_open then open_menu = hit end
    end
    if open_menu then
        local items: any = {}
        for index, entry in ipairs(render.MENU) do
            if index == open_menu.index then items = entry.items or {} end
        end
        local room = 6
        for _, item in ipairs(items) do room = math.max(room, widgets.cells(item.title) + 4) end
        room = math.min(room, w)
        local from = math.max(1, math.min(open_menu.from, w - room + 1))
        -- In cells the list's top frame is the row under the menu and the
        -- items are below it. In pixels (`metrics`) the frame is pixels inside
        -- the item rows, and the first item lies straight under the bar, as the
        -- Windows 95 drop-down touches it. `lead` is that one rule for the hits
        -- and both backends.
        local lead = type(metrics) == "table" and 0 or 1
        local rows = widgets.dropdown_hits(from, render.MENU_ROW + lead, room, #items)
        for index, row in ipairs(rows) do row.id = items[index].id end
        plan.menu_popup = {index = open_menu.index, items = items, hits = rows, from = from, width = room,
            lead = lead}
    end

    plan.address.hits = widgets.address_hits(1, plan.address.row, w)
    for _, hit in pairs(plan.address.hits) do
        hit.bottom_row = hit.row + plan.address.rows - 1
    end
    if plan.address.open and plan.address.hits.field and #plan.address.items > 0 then
        local field: any = plan.address.hits.field
        plan.address.dropdown = widgets.dropdown_hits(field.from, plan.address.row + plan.address.rows,
            field.to - field.from + 1, #plan.address.items)
    end

    -- The toolbar is laid out by the same function that draws it: a button's
    -- width is computed from its caption, and a formula of our own here would
    -- give a button one cell to the left of where it appears.
    if plan.tool_rows > 0 then plan.tools = widgets.toolbar_hits(1, render.TOOL_ROW, w, render.TOOLS, sizing.tool_span) end
    for _, button in ipairs(plan.tools) do
        button.bottom_row = button.row + plan.tool_rows - 1
        -- A button armed by the mouse is drawn sunken until release.
        if state.armed_tool ~= nil and button.id == state.armed_tool then button.pressed = true end
    end

    if not state.failure and inner_w > 0 and inner_h > 0 then
        local shape = render.shape(width, height, #objects, state.offset, metrics)
        plan.shape = shape

        if shape.scrolling and shape.rows > 0 and inner_h >= 2 * (sizing.arrow_rows or 1) then
            plan.scroll = {x = inner_x + inner_w - scroll_cols, y = inner_y, h = inner_h,
                           w = scroll_cols, arrow_rows = sizing.arrow_rows or 1,
                           first = shape.first, visible = shape.rows, total = shape.total}
        end

        for index = 1, #objects do
            local slot = index - 1
            local column = slot % shape.columns
            local row = slot // shape.columns - shape.first
            if row >= 0 and row < shape.rows then
                local x = inner_x + column * grid.w
                local y = inner_y + row * grid.h
                -- The rectangle comes from `icons.box`, the same function
                -- `icons.cell` uses when it draws.
                local box: any = icons.box(x, y, grid.w - render.GAP)
                if sizing.grid then
                    box = {from = x, to = x + grid.w - render.GAP - 1,
                        top = y, bottom = y + grid.drawn - 1}
                end
                if box then
                    plan.cells[#plan.cells + 1] = {
                        index = index, object = objects[index],
                        x = x, y = y, room = grid.w - render.GAP,
                        selected = index == state.selected,
                        from = box.from, to = box.to,
                        top = box.top, bottom = box.bottom,
                    }
                end
            end
        end
    else
        plan.shape = render.shape(width, height, #objects, state.offset, metrics)
    end

    -- The counter is window contents, not chrome: it is recomputed on every
    -- folder opening, and a channel "the window tells the theme its line"
    -- would mean that the compositor knows about the structure of someone
    -- else's window.
    local count = state.failure and "—" or (tostring(#objects) .. " object(s)")

    -- The right field talks about what is being looked at. The order is not
    -- arbitrary: a notice matters more than the selected object, and the
    -- selected object matters more than the title, which is visible in the
    -- window frame anyway. This way `detail` stops being data nobody can be
    -- shown: a drive's full id does not fit into a caption, but here it fits.
    local right: any = state.notice
    if not right and widgets.whole(state.selected) > 0 then
        local chosen: any = objects[state.selected]
        right = type(chosen) == "table" and chosen.detail or nil
    end
    plan.status = {count = count, detail = right or tostring(state.title or "")}

    return plan
end

-- Hits from the plan. Gathered in one place so that a backend does not have
-- to rebuild them: if it rebuilds them, it will diverge. There is no
-- scrollbar here: the window resolves a click on it with `scroll.pointer`
-- over `plan.scroll`, with the same geometry as SDK lists.
function render.hits(plan: any): any
    local address: any = plan.address or {}
    local popup: any = plan.menu_popup or {}
    local out: any = {cells = {}, tools = plan.tools or {},
        menu = plan.menu_hits or {}, menu_popup = popup.hits or {},
        address = address.hits or {}, dropdown = address.dropdown or {}}
    for _, cell in ipairs(plan.cells or {}) do
        out.cells[#out.cells + 1] = {
            index = cell.index, from = cell.from, to = cell.to,
            top = cell.top, bottom = cell.bottom,
        }
    end
    return out
end

-- ─── cell backend ────────────────────────────────────────────────────────

-- cells(canvas, plan) -> {cells = …, tools = …, menu = …, …}
--
-- Draws with characters. Does NOT compute hits — takes them from the plan.
function render.cells(canvas, plan: any): any
    local hits = render.hits(plan)

    canvas:clear(widgets.styles.face:render(" "))

    widgets.menu_bar(canvas, 1, plan.rows.menu, plan.width, plan.menu)
    widgets.toolbar(canvas, 1, plan.rows.tool, plan.width, render.TOOLS)

    -- The list field: a sunken frame from the theme, a white inside of our
    -- own. Icons lie on white, as in Explorer, not on the grey face of the
    -- panel.
    widgets.field(canvas, plan.field.x, plan.field.y, plan.field.w, plan.field.h)

    local inner: any = plan.inner
    if inner.w > 0 and inner.h > 0 then
        local blank = widgets.styles.field:render(string.rep(" ", inner.w))
        for row = 0, inner.h - 1 do canvas:put(inner.x, inner.y + row, blank, inner.w) end
    end

    if plan.failure then
        canvas:put(inner.x + 1, inner.y,
            widgets.fit(widgets.styles.field, tostring(plan.failure), inner.w - 2), inner.w - 2)
    else
        if plan.scroll then
            widgets.scrollbar(canvas, plan.scroll.x, plan.scroll.y, plan.scroll.h, {
                first = plan.scroll.first, visible = plan.scroll.visible,
                total = plan.scroll.total,
            })
        end

        for _, cell in ipairs(plan.cells) do
            icons.cell(canvas, cell.x, cell.y, cell.object,
                {surface = "panel", room = cell.room, selected = cell.selected})
        end
    end

    widgets.statusbar(canvas, 1, plan.rows.status, plan.width, {
        {text = plan.status.count, width = 16},
        {text = plan.status.detail},
    })

    -- The address bar and its list are drawn last: the list lies over the
    -- field, and drawing it earlier would mean painting over it with icons.
    if plan.address then
        widgets.address_bar(canvas, 1, plan.address.row, plan.width, plan.address.text)
        if plan.address.dropdown and #plan.address.dropdown > 0 then
            local field: any = plan.address.hits.field
            widgets.dropdown(canvas, field.from, plan.address.row + 1,
                field.to - field.from + 1, plan.address.items, #plan.address.items)
        end
    end

    -- The open menu — on top of both the address and the field.
    if plan.menu_popup then
        widgets.dropdown(canvas, plan.menu_popup.from, plan.rows.menu + 1, plan.menu_popup.width,
            plan.menu_popup.items, 0)
    end

    return hits
end

-- window(canvas, view, width, height) -> {cells = …, tools = …, scroll = …}
--
-- The former entry point, kept for the window: layout plus the cell backend.
--
-- `view`: objects, title, failure, notice, selected, offset.
--
-- `failure` is "not read", and then there are no objects at all. `notice` is
-- a third state between it and "everything is shown": read, but not
-- everything, or a double click did not work. A notice does not hide objects
-- and does not pass itself off as a failure.
function render.window(canvas, view: any, width: any, height: any)
    local plan = render.layout(view, width, height)
    local hits = render.cells(canvas, plan)
    return hits
end

-- The grid layout: how many columns, how many rows are visible, how many
-- there are in total and which one to start from. Computed ONCE and here —
-- because the "up" and "down" keys (they move through the grid, not through
-- the list) and scrolling live by these same numbers. Computed in three
-- places, they drift apart, and the down arrow takes the selection past the
-- edge of what is visible.
--
-- `first` arrives in `state.offset` and is CLAMPED here: a window narrowed
-- after scrolling would otherwise show emptiness below the last row.
function render.shape(width: any, height: any, count: any, offset: any, metrics: any?): any
    local sizing: any = type(metrics) == "table" and metrics or {}
    local grid = sizing.grid or icons.grid()
    local padding = sizing.padding or 1
    local field_top = math.min(widgets.whole(sizing.field_top or render.FIELD_TOP), math.max(2, widgets.whole(height) - 1))
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local total_objects = widgets.whole(count)

    local inner_w = w - padding * 2
    local inner_h = h - field_top - padding * 2

    -- The grid STEP and the picture HEIGHT are different numbers, and here
    -- that is worth a whole row: the step is four rows, the picture three,
    -- and the last row does not need a gap below it — the field frame is
    -- under it. Count by the step, and a field of fifteen rows would fit
    -- three rows instead of four, and the fourth would go under a scroll that
    -- would not exist at all without it.
    local rows = (inner_h - grid.drawn) // grid.h + 1
    -- Zero means "the picture does not fit entirely". Not one: a row that
    -- was short of a line would climb onto the status bar and stay there.
    if rows < 0 or inner_h < grid.drawn then rows = 0 end

    local function columns_in(room: any): integer
        local columns = widgets.whole(room) // grid.w
        if columns < 1 then columns = 1 end
        return columns
    end

    local columns = columns_in(inner_w)
    local total = (total_objects + columns - 1) // columns
    local scrolling = total > rows

    -- A scrollbar that appeared takes a column, and the remaining width may
    -- fit one column of icons fewer — which makes more rows. The second pass
    -- accounts for exactly that; a third is not needed: the bar is already
    -- there, and the field will not get narrower by more than one column.
    if scrolling then
        columns = columns_in(inner_w - (sizing.scroll_cols or 1))
        total = (total_objects + columns - 1) // columns
        scrolling = total > rows
    end

    local first = scroll.clamp(offset, total, rows)

    return {
        columns = columns, rows = rows, total = total,
        first = scrolling and first or 0, scrolling = scrolling,
    }
end

-- How many objects fit in a row. The "left" and "right" keys do not need
-- this, but "up" and "down" move through the grid — by as much as it was
-- laid out.
function render.columns(width: any, height: any, count: any): integer
    local shape: any = render.shape(width, height, count, 0)
    return (math.tointeger(shape.columns) or 1)
end

return render
