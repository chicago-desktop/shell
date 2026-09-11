-- A plain-data tree, one layout for cells, pixels and hit testing.
local geometry = require("geometry")
local scroll = require("scroll")
local input = require("input")
local editor = require("editor")
local text = require("text")
local whole = geometry.whole
local ui = {}
local containers = {row = true, column = true, split = true}
local leaves = {label = true, button = true, input = true, list = true, table = true, checkbox = true,
    statusbar = true, tabs = true, menu = true, image = true, field = true,
    group = true, graph = true, gauge = true, tree = true, calendar = true, clock = true, monitor = true,
    icons = true, select = true, slider = true, spectrum = true, radio = true}
-- Only the ones that take no input can live without an `id`.
local passive = {label = true, statusbar = true, image = true, field = true, group = true, graph = true, gauge = true,
    calendar = true, clock = true, monitor = true, spectrum = true}
-- A node that takes no input: a passive kind, or a table declared `static` —
-- pairs of "name — value" on a properties sheet, which nobody selects. Such a
-- table needs no `id`, takes no focus and no clicks, and keeps no scroll offset.
local function inert(node: any): boolean
    return passive[node.kind] == true or (node.kind == "table" and node.static == true)
end
-- The month grid: six weeks of seven days, a date or false. `first` is the
-- weekday of the 1st, 0 = Monday; `days` is how many days the month has.
-- There is no calendar arithmetic here on purpose: `time` handles leap years.
function ui.month_grid(first: any, days: any): any
    local start = whole(first) % 7
    local count = whole(days)
    local rows = {}
    local day = 1 - start
    for _ = 1, 6 do
        local row = {}
        for column = 1, 7 do
            if day >= 1 and day <= count then row[column] = day else row[column] = false end
            day = day + 1
        end
        rows[#rows + 1] = row
    end
    return rows
end
-- The icon grid: the column and row step in cells, how many rows the picture
-- itself takes and how many are given to the caption. The numbers are the same as
-- in `shell:icons`, and a test checks that: if they drifted apart, they would put
-- the hit one cell away from the picture — exactly the defect the SDK was created for.
--
-- They have to be kept here instead of calling `shell:icons` because of permissions:
-- that module pulls in `tty`, and the layout is also needed by the pixel renderer,
-- which has no terminal at all.
local ICON_GRID = {w = 12, h = 4, drawn = 3, caption = 2}

function ui.icon_grid(): any
    return {w = ICON_GRID.w, h = ICON_GRID.h, drawn = ICON_GRID.drawn, caption = ICON_GRID.caption}
end

-- How many columns fit in the width and how many rows the items take.
-- One arithmetic for layout, hits and scrolling.
function ui.icon_shape(width: any, count: any): (integer, integer)
    local columns = whole(width) // ICON_GRID.w
    if columns < 1 then columns = 1 end
    local total = math.max(0, whole(count))
    local rows = (total + columns - 1) // columns
    return columns, whole(rows)
end

-- The index of the selected row: `selected` is a 1-based index or an item ID. This way
-- the application ties the selection to the item, not to a row that a new
-- measurement shifted, and does not recompute the index itself.
local function selected_index(node: any, rows: any): integer
    local wanted: any = node.selected
    if wanted == nil then return 0 end
    if type(wanted) == "number" then return whole(wanted) end
    for index, row in ipairs(rows) do
        local record: any = row
        if type(record) == "table" and record.id == wanted then return index end
    end
    return 0
end
local runes_of = text.runes
-- List rows and table rows are the same thing for scrolling and selection: a table
-- merely carries cells instead of text and a header row on top.
local function entries(node: any): any
    if node.kind == "table" or node.kind == "tree" then return node.rows or {} end
    return node.items or {}
end
-- Tree: an indent of two cells per level; the plus/minus box, the icon and the caption
-- sit in fixed columns from the indent. One arithmetic for both renderers
-- and for hits: a plus/minus box drawn one cell left of the place where it
-- is pressed is exactly the class of defect the SDK exists for.
function ui.tree_columns(depth: any): any
    local indent = whole(depth) * 2
    return {expander = indent, icon = indent + 2, label = indent + 4}
end
ui.entries = entries
-- Cells of a text string (characters, not bytes): both tabs and menus are measured by them.
local function cells_of(text: any): integer
    return #runes_of(text)
end
-- Tab and menu strips: each caption takes " caption " plus two edges.
-- One layout for both renderers and for hits; a string longer than the strip
-- is cut at whole tabs — half a tab would be pressed "into nowhere".
--
-- `cell` (a plan drawn in pixels) measures a tab by its caption in pixels —
-- 7 px a character, the Liberation Sans 13 average, plus 10 px of air — and
-- rounds up to whole cells: a caption set in a proportional font is half as
-- wide as one cell per character, and Windows 95's four tabs only fit that way.
function ui.spans(labels: any, width: any, pad: any, cell: any?): any
    local out, used = {}, 0
    -- Padding on each side: two cells for tabs (edges and air), one for
    -- menu titles — otherwise "Edit View Help" does not fit into the
    -- calculator, which is 27 cells wide.
    local side = whole(pad or 2)
    local cw = type(cell) == "table" and whole(cell.w) or 0
    for index, entry in ipairs(labels or {}) do
        local title = type(entry) == "table" and tostring(entry.title or entry.text or "?") or tostring(entry)
        local room = cells_of(title) + side * 2
        if cw > 0 then room = math.max(2, (cells_of(title) * 7 + 10 + cw - 1) // cw) end
        if used + room > whole(width) then break end
        out[#out + 1] = {index = index, x = used, w = room, title = title, pad = side,
            accel = type(entry) == "table" and whole(entry.accel) or 0}
        used = used + room
    end
    return out
end
-- A menu's drop-down list: rows under the title, a separator is a row of its own.
-- The width follows the longest caption; everything is in cells, coordinates are 1-based.
function ui.popup(item: any, index: any): any
    local node: any = item.node
    local entry: any = (node.entries or {})[whole(index)]
    local span: any = nil
    for _, candidate in ipairs(item.spans or {}) do
        if candidate.index == whole(index) then span = candidate end
    end
    if not entry or not span then return nil end
    local rows, widest = {}, 8
    for position, choice in ipairs(entry.items or {}) do
        local option: any = choice
        local text = option.separator and "" or tostring(option.text or option.id or "")
        rows[#rows + 1] = {position = position, id = option.id, text = text,
            separator = option.separator and true or false, disabled = option.disabled and true or false,
            accel = whole(option.accel)}
        if cells_of(text) + 4 > widest then widest = cells_of(text) + 4 end
    end
    local rect = item.rect
    return {rect = geometry.rect(rect.x + span.x, rect.y + 1, widest + 2, #rows + 2), rows = rows, index = whole(index)}
end
-- The index of a select's value among its options, 0 when none matches.
local function option_index(node: any): integer
    for index, option in ipairs(node.options or {}) do
        if (option :: any).value == node.value then return whole(index) end
    end
    return 0
end
-- dropdown(item, open, height) -> the open list of a select, or nil
--
-- Straight under the field's row — the row both backends draw the field on —
-- or above it when more options fit there. As many rows as fit, and `first`
-- scrolls them so the cursor row is always shown. In cells: the hit test and
-- both renderers read this one rectangle.
function ui.dropdown(item: any, open: any, height: any): any
    local node, rect = item.node, item.rect
    local options: any = node.options or {}
    local count = #options
    if count == 0 then return nil end
    local row = rect.y + rect.h // 2
    local below, above = whole(height) - row, row - 1
    local shown, top = 0, 0
    if count <= below or below >= above then
        shown, top = whole(math.min(count, below)), row + 1
    else
        shown = whole(math.min(count, above))
        top = row - shown
    end
    if shown < 1 then return nil end
    local cursor = whole(math.max(1, math.min(count, whole(open.cursor))))
    local first = scroll.reveal(whole(open.first), cursor, count, shown)
    local rows = {}
    for index = first + 1, first + shown do
        local option: any = options[index]
        rows[#rows + 1] = {index = index, value = option.value, text = tostring(option.label or option.value or "")}
    end
    return {rect = geometry.rect(rect.x, top, rect.w, shown), rows = rows, first = first, cursor = cursor}
end
-- Table columns across the width of the text area (without the scrollbar):
-- `width` in cells means fixed, otherwise a share by `weight`; one cell between
-- columns. One layout for the header, the rows and both renderers.
function ui.columns(node: any, width: any): any
    local specs: any = node.columns or {}
    local room = whole(width)
    local separators = math.max(0, #specs - 1)
    local fixed, weight = 0, 0
    for _, spec in ipairs(specs) do
        if spec.width ~= nil then fixed = fixed + math.max(1, whole(spec.width))
        else weight = weight + math.max(1, whole(spec.weight or 1)) end
    end
    local flexible = math.max(0, room - separators - fixed)
    local out, position, consumed, weights = {}, 0, 0, 0
    for index, spec in ipairs(specs) do
        local size = math.max(1, whole(spec.width))
        if spec.width == nil then
            weights = weights + math.max(1, whole(spec.weight or 1))
            local allocation = whole(math.floor(flexible * weights / math.max(1, weight)))
            size, consumed = math.max(1, allocation - consumed), allocation
        end
        size = math.min(size, math.max(0, room - position))
        out[index] = {x = position, w = size, align = spec.align == "right" and "right" or "left",
            title = tostring(spec.title or "")}
        position = position + size + 1
    end
    return out
end
-- Container padding: `padding` applies to all four sides, `padding_top`,
-- `padding_right`, `padding_bottom`, `padding_left` override their own side.
-- Dialogs need this: the pixel theme already has a whole row of cells under
-- the bottom frame (the frame is three pixels, but the reserve is a row), and one more
-- cell of padding at the bottom pushed the buttons twice as far from the frame as in Windows 95.
-- cells_for(plan, px, fallback, horizontal, least) -> whole cells
--
-- A measure named in pixels (`size_px`, `padding_px`, `gap_px`) as whole cells
-- along one axis, when the plan draws in pixels: rounded to the nearest cell,
-- never below `least`. The mouse speaks cells, so a layout can only ever be
-- whole cells; the pixel number says which whole number is closest to Windows
-- 95. Without a cell (cells mode) the cell measure `fallback` stands.
local function cells_for(plan: any, px: any, fallback: any, horizontal: boolean, least: integer): integer
    local cell: any = plan.cell
    if cell == nil or px == nil then return whole(math.max(least, whole(fallback or 0))) end
    local unit = whole(horizontal and cell.w or cell.h)
    return whole(math.max(least, (whole(px) * 2 + unit) // (unit * 2)))
end
-- pack(children, rect, node, plan) — the buttons of a right-aligned row, drawn
-- at their Windows 95 size in pixels: `width_px` wide (75 in a dialog),
-- `pack_px` apart (6 by default), packed from the row's right edge. Each
-- drawing is kept inside its own cells: a button's picture in a neighbour's
-- cell would press the neighbour. So the row gives each button whole cells
-- that hold its drawing plus the gap (`size_px = 81` for 75 + 6), and the
-- drawing lands in `item.px` — the pixel column and width the renderer uses.
local function pack(children: any, rect: any, node: any, plan: any)
    local cw = whole(plan.cell.w)
    local gap = whole(node.pack_px or 6)
    local edge = (rect.x + rect.w - 1) * cw
    for index = #children, 1, -1 do
        local child: any = children[index]
        local item: any = child.id ~= nil and plan.by_id[child.id] or nil
        if item and child.kind == "button" and child.width_px ~= nil then
            local left, right = (item.rect.x - 1) * cw + 1, (item.rect.x + item.rect.w - 1) * cw
            local draw_right = whole(math.min(whole(edge), whole(right)))
            local draw_left = whole(math.max(whole(left), draw_right - whole(child.width_px) + 1))
            item.px = {x = draw_left, w = draw_right - draw_left + 1}
            edge = draw_left - 1 - gap
        elseif item then
            edge = (item.rect.x - 1) * cw - gap
        end
    end
end
local function padded(rect: any, node: any, plan: any): any
    local all = whole(math.max(0, whole(node.padding or 0)))
    local function side(name: string): integer
        local value: any = node[name]
        if value == nil then return all end
        return whole(math.max(0, whole(value)))
    end
    local top, right, bottom, left = side("padding_top"), side("padding_right"), side("padding_bottom"), side("padding_left")
    -- In pixels `padding_px` is the padding on every side, rounded to whole
    -- cells per axis: 7 px is one column at an 8–10 px cell and no row at a
    -- 16–20 px one.
    if plan.cell ~= nil and node.padding_px ~= nil then
        left = cells_for(plan, node.padding_px, 0, true, 0)
        top = cells_for(plan, node.padding_px, 0, false, 0)
        right, bottom = left, top
    end
    if top + bottom + right + left == 0 then return rect end
    local x = rect.x + math.min(left, rect.w)
    local y = rect.y + math.min(top, rect.h)
    return geometry.rect(x, y, math.max(0, rect.w - left - right), math.max(0, rect.h - top - bottom))
end

-- The rules under which a tree does not lay out live in ONE place. `add`
-- asserts them (`assert`), `ui.problem` names them without an error. A second
-- list of the same rules would diverge from the first on the rule that is rarely
-- broken.
local function holds_children(kind: any): boolean
    return containers[kind] or kind == "group" or kind == "tabs"
end
local function shape_problem(node: any): any
    if type(node) ~= "table" then return "SDK node must be a table" end
    local kind = node.kind
    if not (containers[kind] or leaves[kind]) then return "unknown SDK control: " .. tostring(kind) end
    if holds_children(kind) and node.children ~= nil and type(node.children) ~= "table" then
        return "SDK " .. tostring(kind) .. " children must be a list"
    end
    if kind == "select" and node.options ~= nil and type(node.options) ~= "table" then
        return "SDK select options must be a list"
    end
    return nil
end
local function id_problem(node: any, taken: any): any
    local id = node.id
    if type(id) ~= "string" or id == "" then return "interactive SDK controls need a stable id" end
    if taken[id] ~= nil then return "duplicate SDK control id: " .. id end
    return nil
end
local function add(node: any, rect: any, plan: any, interaction: any)
    local shape = shape_problem(node)
    assert(shape == nil, tostring(shape))
    local kind = node.kind
    if rect.w < 1 or rect.h < 1 then return end
    if containers[kind] then
        rect = padded(rect, node, plan)
        local children = node.children or {}
        local horizontal = kind == "row" or kind == "split"
        local length = whole(horizontal and rect.w or rect.h)
        local gap = whole(math.max(0, node.gap or 0))
        if plan.cell ~= nil and node.gap_px ~= nil then gap = cells_for(plan, node.gap_px, 0, horizontal, 0) end
        -- A child's fixed size: `size_px` rounded to cells when the plan draws
        -- in pixels, `size` otherwise; nil for a flexible child.
        local function fixed_size(child: any): any
            if plan.cell ~= nil and child.size_px ~= nil then return cells_for(plan, child.size_px, child.size, horizontal, 1) end
            if child.size ~= nil then return whole(math.max(0, whole(child.size))) end
            return nil
        end
        local available = math.max(0, length - gap * math.max(0, #children - 1))
        local fixed, weight = 0, 0
        for _, child in ipairs(children) do
            local own = fixed_size(child)
            if own ~= nil then fixed = fixed + whole(own)
            else weight = weight + math.max(1, whole(child.weight or 1)) end
        end
        local flexible = math.max(0, available - fixed)
        local position, consumed, weights = 0, 0, 0
        -- `align = "right"` puts the children of a row against its far end — the
        -- buttons of a dialog — instead of an empty flexible label in front of
        -- them. With a flexible child there is nothing to align: it takes the rest.
        if horizontal and node.align == "right" and weight == 0 then
            position = math.max(0, length - fixed - gap * math.max(0, #children - 1))
        end
        for _, child in ipairs(children) do
            local own = fixed_size(child)
            local size = whole(own or 0)
            if own == nil then
                weights = weights + math.max(1, whole(child.weight or 1))
                local allocation = whole(math.floor(flexible * weights / math.max(1, weight)))
                size, consumed = allocation - consumed, allocation
            end
            size = math.min(size, math.max(0, length - position))
            local area = horizontal and geometry.rect(rect.x + position, rect.y, size, rect.h)
                or geometry.rect(rect.x, rect.y + position, rect.w, size)
            add(child, area, plan, interaction)
            position = position + size + gap
        end
        if horizontal and node.align == "right" and plan.cell ~= nil then pack(children, rect, node, plan) end
        return
    end
    local id = node.id
    if not inert(node) then
        local bad = id_problem(node, plan.by_id)
        assert(bad == nil, tostring(bad))
    end
    if kind == "group" then
        -- A frame with a title ("Goroutines", "Memory"): the children are inside the frame,
        -- one cell from the edge. The frame itself takes no input.
        local item: any = {node = node, rect = rect}
        plan.items[#plan.items + 1] = item
        if id then plan.by_id[id] = item end
        if rect.h >= 3 and rect.w >= 3 then
            add({kind = "column", children = node.children or {}, padding = node.padding, gap = node.gap,
                padding_top = node.padding_top, padding_right = node.padding_right,
                padding_bottom = node.padding_bottom, padding_left = node.padding_left,
                padding_px = node.padding_px, gap_px = node.gap_px},
                geometry.rect(rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2), plan, interaction)
        end
        return
    end
    if kind == "tabs" then
        -- Tabs are a one-row strip and a page frame under it; the children
        -- are laid out inside the frame. Only the strip is a hit target.
        local strip = geometry.rect(rect.x, rect.y, rect.w, 1)
        local item: any = {node = node, rect = strip, spans = ui.spans(node.labels, rect.w, node.pad, plan.cell),
            frame = geometry.rect(rect.x, rect.y + 1, rect.w, math.max(0, rect.h - 1))}
        plan.items[#plan.items + 1] = item
        plan.by_id[id] = item
        if not node.disabled then plan.focusable[#plan.focusable + 1] = id end
        if rect.h >= 4 and rect.w >= 3 then
            add({kind = "column", children = node.children or {}, padding = node.padding, gap = node.gap,
                padding_top = node.padding_top, padding_right = node.padding_right,
                padding_bottom = node.padding_bottom, padding_left = node.padding_left,
                padding_px = node.padding_px, gap_px = node.gap_px},
                geometry.rect(rect.x + 1, rect.y + 2, rect.w - 2, rect.h - 3), plan, interaction)
        end
        return
    end
    local item: any = {node = node, rect = rect, offset = 0, page = rect.h, bar = nil, header = 0,
        bar_cols = plan.scroll_cols or 1}
    if kind == "menu" then
        -- A menu bar: a strip of titles; the open list goes on top of everything,
        -- so it lands in `plan.overlays` and is drawn last.
        item.spans = ui.spans(node.entries, rect.w, 1)
        local open: any = interaction.menus[id]
        if open and open.index then
            item.popup = ui.popup(item, open.index)
            if item.popup then plan.overlays[#plan.overlays + 1] = item else interaction.menus[id] = nil end
        end
    end
    if kind == "select" then
        -- A select: the field shows the chosen option; the open list is an
        -- overlay, like a menu's, so it is drawn last and hit first.
        item.current = option_index(node)
        local open: any = interaction.menus[id]
        if open then
            item.popup = ui.dropdown(item, open, plan.height)
            if item.popup then
                open.first = item.popup.first
                plan.overlays[#plan.overlays + 1] = item
            else interaction.menus[id] = nil end
        end
    end
    if kind == "icons" then
        -- An icon grid, as in Explorer: the scroll unit is a ROW, not
        -- an item and not a line of text. The row is declared here once, and the bar,
        -- the wheel and the keys all count by it.
        local items = node.items or {}
        -- The grid leaves the scrollbar its columns: in cells the bar lies in
        -- the last cell's air column, and a wider bar in pixels takes that
        -- many columns more.
        local columns, rows_total = ui.icon_shape(rect.w - (item.bar_cols - 1), #items)
        local page = whole(rect.h) // ICON_GRID.h
        if page < 1 then page = 1 end
        item.columns, item.rows_total, item.page = columns, rows_total, page
        item.selected_index = selected_index(node, items)
        item.offset = scroll.clamp(interaction.offsets[id], rows_total, page)
        if item.selected_index > 0 then
            local row = (item.selected_index - 1) // columns + 1
            item.offset = scroll.reveal(item.offset, row, rows_total, page)
        end
        interaction.offsets[id] = item.offset
        item.bar = scroll.bar(item.offset, rows_total, page, rect.h)
        -- The grid cells are computed ONCE and go into the plan: drawing, hits and
        -- selection read them instead of each recomputing them in its own way.
        item.cells = {}
        local room = ICON_GRID.w - 1
        for index, entry in ipairs(items) do
            local row = (index - 1) // columns
            local column = (index - 1) % columns
            local visible_row = row - item.offset
            if visible_row >= 0 and visible_row < page then
                local x = rect.x + column * ICON_GRID.w
                local y = rect.y + visible_row * ICON_GRID.h
                item.cells[#item.cells + 1] = {
                    index = index, item = entry, x = x, y = y, room = room,
                    box = {from = x, to = x + room - 1, top = y, bottom = y + ICON_GRID.drawn - 1},
                    selected = index == item.selected_index,
                }
            end
        end
    end
    if kind == "list" or kind == "table" or kind == "tree" then
        -- A table's first row is the header: the page and the bar are one row shorter.
        item.header = (kind == "table" and node.header ~= false) and 1 or 0
        item.page = math.max(1, whole(rect.h) - whole(item.header))
        local total = #entries(node)
        item.selected_index = selected_index(node, entries(node))
        -- A static table has no `id` to keep an offset under: it stays at the top.
        item.offset = scroll.clamp(id ~= nil and interaction.offsets[id] or 0, total, item.page)
        -- `reveal` brings the row into view ONCE per value: the chat shows
        -- a new message, and the person's scrolling between messages stays theirs.
        -- A permanent "always to the bottom" would knock the wheel off on every frame.
        local wanted: any = node.reveal
        if id ~= nil and wanted ~= nil and interaction.revealed[id] ~= wanted then
            interaction.revealed[id] = wanted
            item.offset = scroll.reveal(item.offset, whole(wanted), total, item.page)
        end
        if id ~= nil then interaction.offsets[id] = item.offset end
        item.bar = scroll.bar(item.offset, total, item.page, math.max(1, rect.h - item.header))
    end
    plan.items[#plan.items + 1] = item
    if id then plan.by_id[id] = item end
    -- The menu is not part of the focus ring — as in Windows, it is reached with Alt and F10.
    if id and not inert(node) and kind ~= "menu" and not node.disabled then plan.focusable[#plan.focusable + 1] = id end
end
-- problem(tree) -> reason | nil
--
-- Why `ui.plan` will not lay out this tree — by the same rules as `add`, but
-- without an error. Needed where an error cannot be caught: the view renderer runs in
-- the compositor's frame, and an error caught by `pcall` in go-lua tears the upvalues of
-- the whole stack below it, that is, of the compositor's loop. It is stricter than `add` in one way: that one
-- does not check nodes that got no space, while here all of them are checked.
function ui.problem(tree: any): any
    local seen: any = {}
    local function walk(node: any): any
        local why = shape_problem(node)
        if why then return why end
        if not containers[node.kind] and not inert(node) then
            why = id_problem(node, seen)
            if why then return why end
            seen[node.id] = true
        end
        if holds_children(node.kind) then
            for _, child in ipairs(node.children or {}) do
                why = walk(child)
                if why then return why end
            end
        end
        return nil
    end
    return walk(tree)
end
-- message(spec) -> tree
--
-- A message sheet inside the window: an icon and a title, lines of text, "OK" at
-- the right edge. This is how "Help → About" and an object's "Properties" are not
-- a separate window: the application returns this sheet from `view` while it is open,
-- and closes it on the button's `activate` (`spec.ok`, by default
-- `"message_ok"`). One form for all windows, not a copy in each.
-- `spec`: `title`, `lines`, `image` (a name from the icon catalog), `icon`,
-- `buttons` (see below; one "OK" by default).
function ui.message(spec: any): any
    local sheet: any = type(spec) == "table" and spec or {}
    local children: any = {
        {kind = "row", size = 4, gap = 1, children = {
            {kind = "image", size = 6, image = sheet.image, icon = sheet.icon or "▩"},
            {kind = "label", text = tostring(sheet.title or "")},
        }},
    }
    for _, line in ipairs(type(sheet.lines) == "table" and sheet.lines or {}) do
        children[#children + 1] = {kind = "label", size = 1, text = tostring(line)}
    end
    children[#children + 1] = {kind = "label", text = ""}
    -- The buttons: "OK" alone by default, `buttons = {{id, text, default}, …}`
    -- for a question, in the given order at the right edge. A button is at
    -- least 10 cells, like "OK", and wider for a longer caption. The default is
    -- the declared one, else the only button.
    local given: any = type(sheet.buttons) == "table" and #sheet.buttons > 0 and sheet.buttons
        or {{id = sheet.ok or "message_ok", text = "OK", default = true}}
    local row: any = {}
    for _, entry in ipairs(given) do
        local spec_button: any = entry
        local caption = tostring(spec_button.text or spec_button.id or "")
        row[#row + 1] = {kind = "button", id = tostring(spec_button.id), size = math.max(10, cells_of(caption) + 4),
            text = caption, default = spec_button.default == true or #given == 1, disabled = spec_button.disabled == true}
    end
    children[#children + 1] = {kind = "row", size = 2, gap = 1, align = "right", children = row}
    return {kind = "column", padding = 1, gap = 0, children = children}
end
-- confirm(spec) -> tree
--
-- A question with "Yes" and "No": `ui.message` with two buttons. `spec.yes` and
-- `spec.no` are their ids ("yes" and "no" by default), `yes_text` and `no_text`
-- rename them. "No" is the default — a question that deletes must not be
-- answered by a stray Enter — and `spec.default = "yes"` moves it.
function ui.confirm(spec: any): any
    local sheet: any = {}
    for key, value in pairs(type(spec) == "table" and spec or {}) do sheet[key] = value end
    local yes_default = sheet.default == "yes"
    sheet.buttons = {
        {id = sheet.yes or "yes", text = sheet.yes_text or "Yes", default = yes_default},
        {id = sheet.no or "no", text = sheet.no_text or "No", default = not yes_default},
    }
    return ui.message(sheet)
end
-- placeholder(node, focused) -> the text an input shows instead of its value
--
-- Only while the value is empty and the field is not focused. One rule for
-- both renderers; the text is drawn, never edited and never sent —
-- `change.value` is only what was typed.
function ui.placeholder(node: any, focused: any): any
    if node.kind ~= "input" or focused then return nil end
    if node.text ~= nil and tostring(node.text) ~= "" then return nil end
    if type(node.placeholder) ~= "string" or node.placeholder == "" then return nil end
    return node.placeholder
end
-- slider_position(node, width) -> the thumb's column offset from the left, 0-based
--
-- A slider's `value` within `min`..`max`, over `width` columns. One rule for
-- the cell renderer's thumb and for the hit test; pixels place the thumb by
-- the same value, in pixels.
function ui.slider_position(node: any, width: any): integer
    local low, high = whole(node.min or 0), whole(node.max or 0)
    if high <= low then return 0 end
    local value = whole(math.max(low, math.min(high, whole(node.value or low))))
    return whole((value - low) * math.max(0, whole(width) - 1) // (high - low))
end
-- spectrum_color(t) -> "#rrggbb"
--
-- The color spectrum of "Display Properties → Settings": at `t` from 0 to 1
-- the hue sweeps from magenta through blue, cyan, green and yellow to red,
-- as the Windows 95 bar reads left to right. Full saturation and value.
function ui.spectrum_color(t: any): string
    local at = math.max(0, math.min(1, tonumber(t) or 0))
    local hue = (1 - at) * 5
    local sector = whole(math.floor(hue))
    local f = hue - sector
    local r, g, b = 1.0, 0.0, 1.0
    if sector == 0 then r, g, b = 1, f, 0
    elseif sector == 1 then r, g, b = 1 - f, 1, 0
    elseif sector == 2 then r, g, b = 0, 1, f
    elseif sector == 3 then r, g, b = 0, 1 - f, 1
    elseif sector == 4 then r, g, b = f, 0, 1 end
    -- Two hex digits by hand: `%02x` in this runtime's string.format prints the
    -- hex of the number's decimal text ("255" → "323535"), not of the number.
    local digits = "0123456789abcdef"
    local function byte(v: any): string
        local n = whole(math.max(0, math.min(255, math.floor(v * 255 + 0.5))))
        return digits:sub(n // 16 + 1, n // 16 + 1) .. digits:sub(n % 16 + 1, n % 16 + 1)
    end
    return "#" .. byte(r) .. byte(g) .. byte(b)
end
function ui.interaction(): any
    return {focus = nil, offsets = {}, capture = nil, editors = {}, armed = nil, menus = {}, revealed = {}}
end
-- release(interaction) — forgets a pressed button and a dragged thumb whose
-- release this window will never see. `ui.plan` drops them only when their
-- control disappears, so a press that lost its release — the window was
-- minimized or covered mid-drag — survived with an unchanged tree. `ui.event`
-- calls this on the next press; a focus-loss event from the compositor would
-- be the other caller, and the base sends none today.
function ui.release(interaction: any)
    interaction.capture = nil
    interaction.armed = nil
end
-- plan(tree, width, height, interaction, options?) -> plan
--
-- `options.scroll_cols` is how many columns the vertical scrollbar of a list,
-- table, tree and icon grid takes: one in cells (the default), in pixels 16 px
-- of whole cells (`widgets.scroll_cols`). It is an input because it depends on
-- the backend. The layout reserves the columns and the hit test reads them
-- from the item (`item.bar_cols`), so the window's plan and the renderer's
-- plan must be given the same number: the window takes it from its context,
-- the renderer from the cell.
--
-- `options.cell = {w, h}` says the plan is drawn in pixels with that cell:
-- then `size_px`, `padding_px` and `gap_px` are rounded to whole cells, tab
-- captions are measured in pixels, and right-aligned button rows are packed in
-- pixels (`pack`). Without it the cell measures stand — the same tree in
-- cells mode.
function ui.plan(tree: any, width: any, height: any, interaction: any, options: any?): any
    local given: any = type(options) == "table" and options or {}
    local cell: any = given.cell
    local known = type(cell) == "table" and whole(cell.w) > 0 and whole(cell.h) > 0
    local plan: any = {items = {}, by_id = {}, focusable = {}, overlays = {},
        width = whole(width), height = whole(height),
        cell = known and {w = whole(cell.w), h = whole(cell.h)} or nil,
        scroll_cols = math.max(1, whole(given.scroll_cols or 1))}
    if interaction.menus == nil then interaction.menus = {} end
    if interaction.revealed == nil then interaction.revealed = {} end
    add(tree, geometry.rect(1, 1, width, height), plan, interaction)
    if not interaction.focus or not plan.by_id[interaction.focus] or plan.by_id[interaction.focus].node.disabled then
        interaction.focus = plan.focusable[1]
    end
    -- Records of vanished controls are released: otherwise another control with the
    -- same `id` on the next screen would inherit someone else's offset or caret, and
    -- a thumb capture would survive the window being minimized.
    for _, field in ipairs({"offsets", "editors", "menus", "revealed"}) do
        local map: any = interaction[field]
        if type(map) == "table" then
            local stale = {}
            for key in pairs(map) do if plan.by_id[key] == nil then stale[#stale + 1] = key end end
            for _, key in ipairs(stale) do map[key] = nil end
        end
    end
    if interaction.capture and plan.by_id[interaction.capture.id] == nil then interaction.capture = nil end
    if interaction.armed and plan.by_id[interaction.armed.id] == nil then interaction.armed = nil end
    -- The black "default" outline goes to the focused button, and when the focus is not on
    -- a button, to the one declared `default`. That is how Windows does it, and that is how Enter does
    -- exactly what is drawn. Decided here once for both renderers.
    local focused = plan.by_id[interaction.focus]
    plan.focus_on_button = focused ~= nil and focused.node.kind == "button"
    return plan
end
-- Whether the button shows the black outline in this plan.
function ui.default_look(plan: any, node: any, focused: boolean): boolean
    if node.disabled then return false end
    if focused then return true end
    return node.default == true and not plan.focus_on_button
end
function ui.hit(plan: any, x: any, y: any): any
    -- An open menu lies on top of everything: it goes first.
    for _, item in ipairs(plan.overlays or {}) do
        if item.popup and geometry.contains(item.popup.rect, x, y) then return item end
    end
    -- A frame (`group`) contains its children: the hit is looked for among them
    -- first, and the frame itself only if nothing else was hit.
    local frame: any = nil
    for _, item in ipairs(plan.items) do
        if geometry.contains(item.rect, x, y) then
            if item.node.kind == "group" then frame = frame or item else return item end
        end
    end
    return frame
end
local function span_at(item: any, x: any): any
    for _, span in ipairs(item.spans or {}) do
        if x >= item.rect.x + span.x and x < item.rect.x + span.x + span.w then return span end
    end
    return nil
end
-- Menu: a click on a title opens or closes it, on a list row it is
-- an action, a click outside closes it and swallows the click. Keys while it is open:
-- arrows, Enter, Esc.
local function menu_event(item: any, state: any, event: any): any
    local node, id = item.node, item.node.id
    local open: any = state.menus[id]
    if event.type == "mouse" then
        if not input.pressed(event) then return nil end
        if open and item.popup and geometry.contains(item.popup.rect, event.x, event.y) then
            local row: any = item.popup.rows[event.y - item.popup.rect.y]
            state.menus[id] = nil
            if row and not row.separator and not row.disabled and row.id then
                return {type = "activate", id = row.id, menu = id}
            end
            return nil
        end
        local span = span_at(item, event.x)
        if span and not (open and open.index == span.index) then
            state.menus[id] = {index = span.index, cursor = 0}
        else state.menus[id] = nil end
        return nil
    end
    local key = input.key(event)
    if not open or not key then return nil end
    local popup: any = item.popup
    local count = popup and #popup.rows or 0
    if key == "esc" then state.menus[id] = nil
    elseif key == "left" or key == "right" then
        local total = #(item.spans or {})
        if total > 0 then
            local next_index = ((open.index - 1 + (key == "left" and -1 or 1)) % total) + 1
            state.menus[id] = {index = next_index, cursor = 0}
        end
    elseif (key == "up" or key == "down") and count > 0 then
        local cursor = whole(open.cursor)
        for _ = 1, count do
            cursor = ((cursor - 1 + (key == "up" and -1 or 1)) % count) + 1
            local row: any = popup.rows[cursor]
            if not row.separator and not row.disabled then break end
        end
        open.cursor = cursor
    elseif key == "enter" and popup then
        local row: any = popup.rows[whole(open.cursor)]
        state.menus[id] = nil
        if row and row.id and not row.separator and not row.disabled then
            return {type = "activate", id = row.id, menu = id}
        end
    end
    return nil
end
-- Select: a click on the field, Enter or Space opens the list with the cursor
-- on the chosen option; while it is open the arrows move the cursor, Enter,
-- Space or a click on a row chooses, Esc and a click elsewhere close it.
-- Closed, the arrows change the value directly, as in a Windows 95 drop-down
-- list. A choice is `change` with the option's value, only when it differs.
local function select_event(item: any, state: any, event: any): any
    local node, id = item.node, item.node.id
    local options: any = node.options or {}
    local count = #options
    local open: any = state.menus[id]
    local function choose(index: any): any
        local option: any = options[whole(index)]
        if option == nil or option.value == node.value then return nil end
        return {type = "change", id = id, value = option.value}
    end
    if event.type == "mouse" then
        if not input.pressed(event) then return nil end
        local popup: any = item.popup
        if open and popup and geometry.contains(popup.rect, event.x, event.y) then
            state.menus[id] = nil
            local row: any = popup.rows[event.y - popup.rect.y + 1]
            return row and choose(row.index) or nil
        end
        if open then state.menus[id] = nil
        elseif count > 0 then state.menus[id] = {cursor = math.max(1, whole(item.current)), first = 0} end
        return nil
    end
    local key = input.key(event)
    if not key or count == 0 then return nil end
    local chooses = key == "enter" or (key == "runes" and event.key == " ")
    if open then
        local cursor = whole(open.cursor)
        if key == "esc" or key == "tab" then state.menus[id] = nil
        elseif chooses then state.menus[id] = nil; return choose(cursor)
        elseif key == "up" then open.cursor = math.max(1, cursor - 1)
        elseif key == "down" then open.cursor = math.min(count, cursor + 1)
        elseif key == "home" then open.cursor = 1
        elseif key == "end" then open.cursor = count end
        return nil
    end
    if chooses then
        state.menus[id] = {cursor = math.max(1, whole(item.current)), first = 0}
        return nil
    end
    local current = whole(item.current)
    if key == "up" then return choose(math.max(1, current - 1))
    elseif key == "down" then return choose(current < 1 and 1 or math.min(count, current + 1))
    elseif key == "home" then return choose(1)
    elseif key == "end" then return choose(count) end
    return nil
end
-- Slider: a click sets the value at the clicked column, ←/↓ and →/↑ step by
-- one, Page Up/Down by a quarter of the range, Home/End go to the ends. A
-- change is `change` with the whole-number value, only when it changes.
local function slider_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local low, high = whole(node.min or 0), whole(node.max or 0)
    if high <= low then return nil end
    local value = whole(math.max(low, math.min(high, whole(node.value or low))))
    local wanted = value
    if event.type == "mouse" then
        if not input.pressed(event) then return nil end
        local span = whole(math.max(1, whole(rect.w) - 1))
        wanted = low + ((whole(event.x) - whole(rect.x)) * (high - low) * 2 + span) // (span * 2)
    else
        local key = input.key(event)
        local page = math.max(1, (high - low) // 4)
        if key == "left" or key == "down" then wanted = value - 1
        elseif key == "right" or key == "up" then wanted = value + 1
        elseif key == "pgup" then wanted = value + page
        elseif key == "pgdown" then wanted = value - page
        elseif key == "home" then wanted = low
        elseif key == "end" then wanted = high
        else return nil end
    end
    wanted = whole(math.max(low, math.min(high, wanted)))
    if wanted == value then return nil end
    return {type = "change", id = node.id, value = wanted}
end
local function tabs_event(item: any, state: any, event: any): any
    local node = item.node
    local labels = node.labels or {}
    if event.type == "mouse" then
        if not input.pressed(event) then return nil end
        local span = span_at(item, event.x)
        if span then return {type = "select", id = node.id, index = span.index, value = labels[span.index]} end
        return nil
    end
    local key = input.key(event)
    if key ~= "left" and key ~= "right" then return nil end
    local total = #(item.spans or {})
    if total == 0 then return nil end
    local current = whole(node.active or 1)
    local index = ((current - 1 + (key == "left" and -1 or 1)) % total) + 1
    return {type = "select", id = node.id, index = index, value = labels[index]}
end
local function list_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local rows = entries(node)
    -- The offset is taken from the STATE, not from the plan: otherwise two events in a row
    -- without a redraw (two wheel clicks) lost the first one.
    local total, header = #rows, whole(item.header)
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, total, item.page)
    if event.action == "wheel" then
        state.offsets[node.id] = scroll.wheel(offset, event.button, total, item.page, node.wheel_step or 3)
    elseif input.pressed(event) then
        local row = event.y - rect.y - header
        -- The table header is not a row: a click on it selects nothing.
        if row < 0 then return nil end
        -- The scrollbar's columns: one in cells, 16 px of whole cells in pixels.
        local bar_left = rect.x + rect.w - whole(item.bar_cols or 1)
        if node.kind == "tree" and event.x < bar_left then
            local index = offset + row + 1
            local line: any = rows[index]
            if not line then return nil end
            local columns = ui.tree_columns(line.depth)
            if line.has_children and event.x == rect.x + columns.expander then
                return {type = "toggle", id = node.id, index = index, value = line}
            end
            return {type = "select", id = node.id, index = index, value = line}
        end
        if event.x >= bar_left then
            -- The bar's columns are not a row, even when there is nothing to scroll.
            if item.bar.limit <= 0 then return nil end
            local shifted, capture = scroll.pointer(offset, total, item.page,
                {x = bar_left, y = rect.y + header, w = rect.x + rect.w - bar_left, h = rect.h - header}, nil, event)
            state.offsets[node.id] = shifted
            state.capture = capture and {id = node.id, grab = capture.grab} or nil
        else
            local index = offset + row + 1
            -- `pointer` tells a click from the arrows: the application is free to treat
            -- a repeated click on an already selected item as a double click.
            if index <= total then return {type = "select", id = node.id, index = index, value = rows[index], pointer = true} end
        end
    end
    return nil
end
-- Icon grid: a click on a cell selects it, the application is free to treat a repeated click
-- on an already selected one as a double click (`pointer = true`), a click on
-- empty space clears the selection — as in Explorer, where emptiness cancels.
local function icons_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local items = node.items or {}
    local total = #items
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, whole(item.rows_total), whole(item.page))
    if event.action == "wheel" then
        state.offsets[node.id] = scroll.wheel(offset, event.button, whole(item.rows_total), whole(item.page),
            node.wheel_step or 1)
        return nil
    end
    if not input.pressed(event) then return nil end
    -- The scrollbar, as in a list: `icon_shape` keeps its columns free of
    -- cells, and a press on them scrolls instead of clearing the selection.
    local bar_left = rect.x + rect.w - whole(item.bar_cols or 1)
    if item.bar and item.bar.limit > 0 and event.x >= bar_left and geometry.contains(rect, event.x, event.y) then
        local shifted, capture = scroll.pointer(offset, whole(item.rows_total), whole(item.page),
            {x = bar_left, y = rect.y, w = rect.x + rect.w - bar_left, h = rect.h}, nil, event)
        state.offsets[node.id] = shifted
        state.capture = capture and {id = node.id, grab = capture.grab} or nil
        return nil
    end
    for _, cell in ipairs(item.cells or {}) do
        local box: any = cell.box
        if event.x >= box.from and event.x <= box.to and event.y >= box.top and event.y <= box.bottom then
            return {type = "select", id = node.id, index = cell.index, value = items[cell.index], pointer = true}
        end
    end
    if geometry.contains(rect, event.x, event.y) and total > 0 then
        return {type = "select", id = node.id, index = 0, value = nil, pointer = true}
    end
    return nil
end
local function activate(node: any): any
    if node.kind == "checkbox" then return {type = "change", id = node.id, value = not node.checked} end
    -- A radio button is chosen, never unchosen by itself: the application
    -- clears its neighbours. Choosing the chosen one again changes nothing.
    if node.kind == "radio" then
        if node.checked then return nil end
        return {type = "change", id = node.id, value = true}
    end
    return {type = "activate", id = node.id}
end
-- One spelling per key for every component. The runtime's terminal decoder
-- names Space `key_type = "space"`, while the components, the editor and the
-- base's typed input know it as the rune " " — so from a real terminal Space
-- neither pressed a focused button nor typed into a field. Shift+Tab arrives
-- as `tab` with `shift`; a decoder that says `backtab` means the same.
local function canonical(event: any)
    if event.type ~= "key" then return end
    if event.key_type == "space" then
        event.key_type, event.key = "runes", " "
    elseif event.key_type == "backtab" then
        event.key_type, event.key, event.shift = "tab", "tab", true
    end
end
function ui.event(plan: any, state: any, original: any): any
    local event = input.normalize(original)
    canonical(event)
    -- A press cannot come while the previous one is still held: its release
    -- happened where this window could not see it. What that press armed or
    -- captured is dropped first — otherwise the next drag anywhere moved the
    -- old thumb, and letting go over the old button pressed it.
    if event.type == "mouse" and event.action == "press" and (state.capture or state.armed) then
        ui.release(state)
    end
    -- The wheel while a button is armed or a thumb is being dragged belongs to no one.
    if (state.armed or state.capture) and event.action == "wheel" then return nil end
    if state.armed and event.type == "mouse" and (event.action == "motion" or event.action == "release") then
        local item = plan.by_id[state.armed.id]
        local inside = item and not item.node.disabled and geometry.contains(item.rect, event.x, event.y)
        state.armed.inside = inside and true or false
        if event.action == "release" then
            state.armed = nil
            if inside and event.button == "left" then return activate(item.node) end
        end
        return nil
    end
    if state.capture and (event.action == "motion" or event.action == "release") then
        local item = plan.by_id[state.capture.id]
        if item then state.offsets[state.capture.id] = scroll.drag(event.y - item.rect.y - whole(item.header), state.capture.grab, item.bar) end
        if event.action == "release" or not item then state.capture = nil end
        return nil
    end
    -- An open menu takes presses entirely: a hit is handled,
    -- a miss closes it, and the click goes no further. Alt+letter opens its own menu.
    for _, item in ipairs(plan.items) do
        -- An open select list takes presses and keys the way a menu does.
        if item.node.kind == "select" and state.menus[item.node.id] and (input.pressed(event) or event.type == "key") then
            if event.type == "mouse" and ui.hit(plan, event.x, event.y) ~= item then
                state.menus[item.node.id] = nil
                return nil
            end
            return select_event(item, state, event)
        end
        if item.node.kind == "menu" then
            local open: any = state.menus[item.node.id]
            if open and (input.pressed(event) or event.type == "key") then
                if event.type == "mouse" then
                    local target = ui.hit(plan, event.x, event.y)
                    if target ~= item then state.menus[item.node.id] = nil; return nil end
                end
                return menu_event(item, state, event)
            end
            if event.type == "key" and event.alt and event.action ~= "release" then
                local letter = tostring(event.key or ""):lower()
                for _, span in ipairs(item.spans or {}) do
                    local title = runes_of(span.title)
                    if span.accel > 0 and title[span.accel] and title[span.accel]:lower() == letter then
                        state.menus[item.node.id] = {index = span.index, cursor = 0}
                        return nil
                    end
                end
            end
        end
    end
    if event.type == "mouse" then
        local item = ui.hit(plan, event.x, event.y)
        if not item or item.node.disabled then return nil end
        if item.node.kind == "table" and item.node.static then return nil end
        if item.node.kind == "menu" then return menu_event(item, state, event) end
        if item.node.kind == "tabs" then
            if input.pressed(event) then state.focus = item.node.id end
            return tabs_event(item, state, event)
        end
        -- The right button over a button belongs to the window (Minesweeper
        -- flags a cell with it): `context` at the PRESS, as in Windows. It
        -- arms nothing and takes no focus, so its release activates nothing.
        if item.node.kind == "button" and item.node.id and event.action == "press" and event.button == "right" then
            return {type = "context", id = item.node.id}
        end
        -- Only what can hold the focus takes it. Otherwise a passive view with an `id`
        -- (a label, a field, a frame, a graph, a status bar…) took the
        -- focus while not being in the `focusable` ring — and Tab no longer found
        -- where to step from. The check uses the same `passive` that builds the ring, not
        -- the name of a single view kind.
        if input.pressed(event) and item.node.id and not passive[item.node.kind] then state.focus = item.node.id end
        if item.node.kind == "list" or item.node.kind == "table" or item.node.kind == "tree" then return list_event(item, state, event) end
        if item.node.kind == "icons" then return icons_event(item, state, event) end
        if item.node.kind == "select" then return select_event(item, state, event) end
        if item.node.kind == "slider" then return slider_event(item, state, event) end
        if (item.node.kind == "button" or item.node.kind == "checkbox" or item.node.kind == "radio") and input.pressed(event) then
            state.armed = {id = item.node.id, inside = true}
        end
        return nil
    end
    local key = input.key(event)
    if key == "tab" then
        for index, id in ipairs(plan.focusable) do
            if id == state.focus then
                state.focus = plan.focusable[(index - 1 + (event.shift and -1 or 1)) % #plan.focusable + 1]
                break
            end
        end
        return nil
    end
    local item = plan.by_id[state.focus]
    if not item then return nil end
    local node = item.node
    if node.kind == "tabs" then return tabs_event(item, state, event) end
    if (node.kind == "button" or node.kind == "checkbox" or node.kind == "radio") and (key == "enter" or (key == "runes" and event.key == " ")) then
        return activate(node)
    elseif (node.kind == "list" or node.kind == "table" or node.kind == "tree") and key then
        local rows = entries(node)
        local total = #rows
        if total == 0 then return nil end
        local chosen = whole(item.selected_index)
        local index = chosen > 0 and chosen or 1
        if node.kind == "tree" then
            -- Tree keys, as in regedit: Enter and → expand, ← collapses
            -- or goes to the parent, → on an expanded node goes to the first child.
            local line: any = rows[math.max(1, math.min(total, index))]
            if key == "enter" and line and line.has_children then
                return {type = "toggle", id = node.id, index = index, value = line}
            elseif key == "right" and line then
                if line.has_children and not line.expanded then return {type = "toggle", id = node.id, index = index, value = line} end
                if not line.has_children then return nil end
                index = index + 1
                state.offsets[node.id] = scroll.reveal(item.offset, math.min(total, index), total, item.page)
                return {type = "select", id = node.id, index = math.min(total, index), value = rows[math.min(total, index)]}
            elseif key == "left" and line then
                if line.expanded then return {type = "toggle", id = node.id, index = index, value = line} end
                local parent = index - 1
                while parent >= 1 and whole(rows[parent].depth) >= whole(line.depth) do parent = parent - 1 end
                if parent < 1 then return nil end
                state.offsets[node.id] = scroll.reveal(item.offset, parent, total, item.page)
                return {type = "select", id = node.id, index = parent, value = rows[parent]}
            end
        end
        if key == "home" then index = 1 elseif key == "end" then index = total
        -- With no selection an arrow selects the FIRST row instead of stepping from it:
        -- otherwise "down" in a fresh list skipped past the first one.
        elseif chosen < 1 and (key == "up" or key == "down" or key == "pgup" or key == "pgdown") then index = 1
        elseif key == "up" then index = index - 1 elseif key == "down" then index = index + 1
        elseif key == "pgup" then index = index - item.page elseif key == "pgdown" then index = index + item.page
        elseif key == "enter" then return {type = "activate", id = node.id, index = index, value = rows[index]}
        else return nil end
        index = whole(math.max(1, math.min(total, index)))
        state.offsets[node.id] = scroll.reveal(item.offset, index, total, item.page)
        return {type = "select", id = node.id, index = index, value = rows[index]}
    elseif node.kind == "icons" and key then
        -- Grid keys: right and left move by items, up and down move by a
        -- row, pages move by a page of rows. The column width is the same as the
        -- layout's, otherwise the down arrow would lead under the wrong icon.
        local items = node.items or {}
        local total = #items
        if total == 0 then return nil end
        local columns = math.max(1, whole(item.columns))
        local chosen = whole(item.selected_index)
        local index = chosen > 0 and chosen or 1
        local moves = key == "left" or key == "right" or key == "up" or key == "down" or key == "pgup" or key == "pgdown"
        if key == "home" then index = 1
        elseif key == "end" then index = total
        -- With no selection any arrow selects the first icon, as in a list.
        elseif chosen < 1 and moves then index = 1
        elseif key == "left" then index = index - 1
        elseif key == "right" then index = index + 1
        elseif key == "up" then index = index - columns
        elseif key == "down" then index = index + columns
        elseif key == "pgup" then index = index - columns * math.max(1, whole(item.page))
        elseif key == "pgdown" then index = index + columns * math.max(1, whole(item.page))
        elseif key == "enter" then return {type = "activate", id = node.id, index = index, value = items[index]}
        else return nil end
        index = whole(math.max(1, math.min(total, index)))
        local row = (index - 1) // columns + 1
        state.offsets[node.id] = scroll.reveal(item.offset, row, whole(item.rows_total), math.max(1, whole(item.page)))
        return {type = "select", id = node.id, index = index, value = items[index]}
    elseif node.kind == "select" then
        return select_event(item, state, event)
    elseif node.kind == "slider" then
        return slider_event(item, state, event)
    elseif node.kind == "input" then
        local editing = state.editors[node.id] or {cursor = #editor.runes(node.text), selected = false}
        state.editors[node.id] = editing
        local value, action = editor.event(tostring(node.text or ""), editing, event)
        if action then return {type = action, id = node.id, value = value} end
    end
    return nil
end
return ui
