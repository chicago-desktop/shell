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
    icons = true, select = true, slider = true, spectrum = true, radio = true, text = true, editor = true,
    picture = true, separator = true, terminal = true}
-- Only the ones that take no input can live without an `id`.
local passive = {label = true, statusbar = true, image = true, field = true, group = true, graph = true, gauge = true,
    calendar = true, clock = true, monitor = true, spectrum = true, picture = true, separator = true, terminal = true}
-- A node that takes no input: a passive kind, or a table declared `static` —
-- pairs of "name — value" on a properties sheet, which nobody selects. Such a
-- table needs no `id`, takes no focus and no clicks, and keeps no scroll offset.
-- A `text` without an `id` is the same: it has nowhere to keep its offset, so
-- it stays at the top and takes no input.
local function inert(node: any): boolean
    return passive[node.kind] == true or (node.kind == "table" and node.static == true)
        or (node.kind == "text" and node.id == nil)
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
-- The Small Icons grid (`icons` with `small = true`): a 16 px picture with
-- the caption at its right, one row high, 15 cells a column — the glyph, a
-- space, twelve cells of caption and a cell of air; 150 px at a 10 px cell,
-- the classic column. No caption rows: the caption is on the picture's row.
local SMALL_GRID = {w = 15, h = 1, drawn = 1, caption = 0}

function ui.icon_grid(small: any?): any
    local grid = small and SMALL_GRID or ICON_GRID
    return {w = grid.w, h = grid.h, drawn = grid.drawn, caption = grid.caption}
end

-- How many columns fit in the width and how many rows the items take.
-- One arithmetic for layout, hits and scrolling.
function ui.icon_shape(width: any, count: any, small: any?): (integer, integer)
    local columns = whole(width) // (small and SMALL_GRID or ICON_GRID).w
    if columns < 1 then columns = 1 end
    local total = math.max(0, whole(count))
    local rows = (total + columns - 1) // columns
    return columns, whole(rows)
end

-- The List view (`icons` with `small = true, flow = "columns"`, FR-008 §4):
-- the small icons fill a column top to bottom, then the next one to the
-- right. A column is as wide as the widest caption plus the glyph, its space
-- and a cell of air — counted in cells, as the plan has no font (the pixel
-- caption is narrower and fits) — within these bounds and never wider than
-- the view.
local LIST_COLUMN = {least = 8, most = 32}

-- list_shape(items, width, height) -> {column, lines, total, fit, bar}: the
-- column's width, how many items a column holds, how many columns there are,
-- how many fit whole, and whether the horizontal bar takes the last row (it
-- does only when the columns do not fit).
function ui.list_shape(items: any, width: any, height: any): any
    local list: any = type(items) == "table" and items or {}
    local widest = 0
    for _, entry in ipairs(list) do
        local caption: any = type(entry) == "table" and (entry.title or entry.text) or entry
        widest = whole(math.max(widest, #editor.runes(tostring(caption or ""))))
    end
    local w, h = whole(math.max(1, whole(width))), whole(math.max(1, whole(height)))
    local column = whole(math.min(w, math.max(LIST_COLUMN.least, math.min(LIST_COLUMN.most, widest + 3))))
    local lines = h
    local total = (#list + lines - 1) // lines
    local bar = total * column > w and h > 1
    if bar then
        lines = h - 1
        total = (#list + lines - 1) // lines
    end
    return {column = column, lines = whole(lines), total = whole(total), fit = whole(math.max(1, w // column)), bar = bar}
end

-- entry_key(entry, index) -> what a selection set names an entry by: its
-- `id`, or its 1-based position when it has none.
function ui.entry_key(entry: any, index: any): any
    if type(entry) == "table" and entry.id ~= nil then return entry.id end
    return whole(index)
end

-- The index of the selected row: `selected` is a 1-based index or an item ID. This way
-- the application ties the selection to the item, not to a row that a new
-- measurement shifted, and does not recompute the index itself.
--
-- A multi-selection (`selected = {[id] = true}`, `icons`, `table` and `list`)
-- has no single selected row; the index is then the cursor the keys move
-- from: the `anchor` — the entry the last click or key stood on — while it is
-- there, else the first selected entry in view order.
local function selected_index(node: any, rows: any, anchor: any?): integer
    local wanted: any = node.selected
    if wanted == nil then return 0 end
    if type(wanted) == "number" then return whole(wanted) end
    if type(wanted) == "table" then
        local first = 0
        for index, row in ipairs(rows) do
            local key = ui.entry_key(row, index)
            if anchor ~= nil and key == anchor then return index end
            if first == 0 and wanted[key] == true then first = index end
        end
        return first
    end
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
-- is_selected(item, index) -> whether row or icon `index` is drawn selected:
-- in a multi-selection its key is in the set, otherwise it is the selected
-- row. One rule for both renderers and for the rows' keys.
function ui.is_selected(item: any, index: any): boolean
    local node: any = item.node
    local wanted: any = node.selected
    local at = whole(index)
    if type(wanted) == "table" then
        local entry: any = entries(node)[at]
        return entry ~= nil and wanted[ui.entry_key(entry, at)] == true
    end
    return at > 0 and at == whole(item.selected_index)
end
-- cell_text(value) -> the text of a table cell: a string, or `text` of a cell
-- that carries a picture (`{text, image, icon}`).
function ui.cell_text(value: any): string
    if type(value) == "table" then return tostring(value.text or "") end
    return tostring(value or "")
end
-- The multi-line editor's columns in pixels: 8 px, Fixedsys' width and
-- Liberation Mono 13's "M" (a test pins the two together). A number of the
-- plan, not a measure at draw time, because the window's own process plans
-- too — its keys walk display rows and its clicks find columns — and it has
-- no font to measure; a measured width would wrap the drawn rows at one width
-- and the caret's at another. Column 0 stands `EDITOR_INSET` px inside the
-- field's left edge. In cells a column is a cell.
ui.MONO_PX = 8
ui.EDITOR_INSET = 4
-- Two presses in one cell this close are a double click.
local DOUBLE_MS = 500
-- editor_column(item, x) -> the display column (from the view's left) under
-- the pointer's cell `x`: in pixels the column under the cell's middle.
function ui.editor_column(item: any, x: any): integer
    local offset = whole(x) - whole(item.rect.x)
    local cell: any = item.cell
    if cell == nil then return whole(math.max(0, offset)) end
    local width = whole(cell.w)
    return whole(math.max(0, (offset * width + width // 2 - ui.EDITOR_INSET) // ui.MONO_PX))
end
-- wrap_text(value, width, wrap) -> the lines of a `text` view
--
-- The lines the plan keeps for a read-only text and both renderers draw: the
-- text's own lines, each broken after the last space that fits `width`
-- characters (a word longer than a line is cut). Leading spaces stay, so
-- indented text keeps its indent. `wrap = false` keeps every line whole; the
-- renderer then cuts what does not fit. Width is counted in characters, the
-- unit of a cell, in both renderers: pixels draw the same lines, never their own.
function ui.wrap_text(value: any, width: any, wrap: any): {string}
    local room = whole(math.max(1, whole(width)))
    local out: {string} = {}
    local source = (tostring(value or ""):gsub("\r\n", "\n"))
    for line in (source .. "\n"):gmatch("(.-)\n") do
        local runes: any = runes_of(line)
        if wrap == false or #runes <= room then
            out[#out + 1] = line
        else
            local start = 1
            while start <= #runes do
                local stop = start + room - 1
                if stop >= #runes then
                    stop = #runes
                else
                    local cut = stop
                    while cut > start and runes[cut] ~= " " do cut = cut - 1 end
                    if cut > start then stop = cut end
                end
                out[#out + 1] = table.concat(runes, "", start, stop)
                start = stop + 1
            end
        end
    end
    return out
end
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
-- wide as one cell per character, and the original's four tabs only fit that way.
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
--
-- `lead` is how many frame rows stand before the first item — the one rule the
-- hit test and both renderers read. Cells draw a box, so the list has a frame
-- row above and below its items (`lead` 1). A pixel plan (`pixel_rows`) has
-- none: the frame is pixels inside the item rows, and the first item lies in
-- the row straight under the bar, as the classic drop-down touches the bar.
-- A separator stays a whole row: the mouse knows only rows, and a thinner one
-- would move every item below it off the row its hit is counted by.
--
-- menu_rows(items) -> the rows of a drop-down list and its inner width. A row
-- keeps what both renderers draw: the text with its accelerator, a
-- `shortcut` ("Ctrl+Z") right-aligned in a column after the widest text, a
-- `checked` checkmark or a `bullet` radio mark in the left margin, and
-- `submenu` when the item opens a list of its own. The width is the widest
-- text plus four cells, at least eight, as it always was; a list with
-- shortcuts grows by the widest shortcut plus two cells, and one without
-- keeps its width, so every existing menu stays as it was drawn.
local function menu_rows(items: any): (any, integer)
    local rows, widest, keys = {}, 8, 0
    for position, choice in ipairs(type(items) == "table" and items or {}) do
        local option: any = choice
        local text = option.separator and "" or tostring(option.text or option.id or "")
        local shortcut = (not option.separator and option.shortcut ~= nil) and tostring(option.shortcut) or ""
        rows[#rows + 1] = {position = position, id = option.id, text = text,
            separator = option.separator and true or false, disabled = option.disabled and true or false,
            accel = whole(option.accel), shortcut = shortcut, checked = option.checked == true,
            bullet = option.bullet == true,
            submenu = not option.separator and type(option.items) == "table" and #option.items > 0}
        if cells_of(text) + 4 > widest then widest = cells_of(text) + 4 end
        if cells_of(shortcut) > keys then keys = cells_of(shortcut) end
    end
    if keys > 0 then widest = widest + keys + 2 end
    return rows, widest
end
function ui.popup(item: any, index: any, pixel_rows: any?): any
    local node: any = item.node
    local entry: any = (node.entries or {})[whole(index)]
    local span: any = nil
    for _, candidate in ipairs(item.spans or {}) do
        if candidate.index == whole(index) then span = candidate end
    end
    if not entry or not span then return nil end
    local rows, widest = menu_rows(entry.items)
    local rect = item.rect
    local lead = pixel_rows and 0 or 1
    return {rect = geometry.rect(rect.x + span.x, rect.y + 1, widest + 2, #rows + lead * 2), rows = rows,
        index = whole(index), lead = lead}
end
-- submenu_items(node, index, position) -> the items of the submenu the row at
-- `position` of menu `index` opens, or nil: no such row, a disabled one, or
-- one without items. The keys read it from the node, the plan lays it out.
-- list_items(node, index) -> the rows of menu `index`; a context menu
-- (`popup`) has one list, its own `items`.
local function list_items(node: any, index: any): any
    if type(node.popup) == "table" then return node.items end
    local entry: any = (node.entries or {})[whole(index)]
    return entry and entry.items or nil
end
local function submenu_items(node: any, index: any, position: any): any
    local option: any = (list_items(node, index) or {})[whole(position)]
    if type(option) ~= "table" or option.separator or option.disabled then return nil end
    if type(option.items) ~= "table" or #option.items == 0 then return nil end
    return option.items
end
-- submenu(item, popup, position, width, height) -> the open submenu of the row
-- at `position`, or nil
--
-- One level, as the Start menu's folders: to the right of the list, its first
-- item on the row that opened it (the same `lead` as the list's, so the rule
-- holds in both modes), to the left when the client has no room at the right,
-- and moved up when it would run past the bottom. Rows as the list's.
function ui.submenu(item: any, popup: any, position: any, width: any, height: any): any
    local items = submenu_items(item.node, popup.index, position)
    if items == nil then return nil end
    local rows, widest = menu_rows(items)
    local lead = whole(popup.lead)
    local w, h = widest + 2, #rows + lead * 2
    local x = whole(popup.rect.x) + whole(popup.rect.w)
    if x + w - 1 > whole(width) then x = math.max(1, whole(popup.rect.x) - w) end
    local y = whole(popup.rect.y) + whole(position) - 1
    if y + h - 1 > whole(height) then y = math.max(1, whole(height) - h + 1) end
    return {rect = geometry.rect(x, y, w, h), rows = rows, lead = lead, parent = whole(position)}
end
-- context_popup(node, width, height, pixel_rows) -> a context menu's list:
-- its top-left at the cell of `popup = {x, y}`, flipped to end at that cell
-- when it would run past the client's right or bottom edge; the rows and the
-- `lead` of a bar menu's list.
function ui.context_popup(node: any, width: any, height: any, pixel_rows: any?): any
    local rows, widest = menu_rows(node.items)
    if #rows == 0 then return nil end
    local lead = pixel_rows and 0 or 1
    local w, h = widest + 2, #rows + lead * 2
    local x, y = whole(node.popup.x), whole(node.popup.y)
    if x + w - 1 > whole(width) then x = whole(math.max(1, x - w + 1)) end
    if y + h - 1 > whole(height) then y = whole(math.max(1, y - h + 1)) end
    return {rect = geometry.rect(x, y, w, h), rows = rows, index = 1, lead = lead}
end
-- context_menu(spec) -> a context menu node: `id` ("context" by default), `x`
-- and `y` (the cell a `context` action carries) and `items`, the rows of a
-- menu's list. The window puts it anywhere in its tree while it is open.
function ui.context_menu(spec: any): any
    local given: any = type(spec) == "table" and spec or {}
    return {kind = "menu", id = given.id or "context", popup = {x = given.x, y = given.y}, items = given.items or {}}
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
-- cell of padding at the bottom pushed the buttons twice as far from the frame as in the original.
-- cells_for(plan, px, fallback, horizontal, least) -> whole cells
--
-- A measure named in pixels (`size_px`, `padding_px`, `gap_px`) as whole cells
-- along one axis, when the plan draws in pixels: rounded to the nearest cell,
-- never below `least`. The mouse speaks cells, so a layout can only ever be
-- whole cells; the pixel number says which whole number is closest to the
-- original. Without a cell (cells mode) the cell measure `fallback` stands.
local function cells_for(plan: any, px: any, fallback: any, horizontal: boolean, least: integer): integer
    local cell: any = plan.cell
    if cell == nil or px == nil then return whole(math.max(least, whole(fallback or 0))) end
    local unit = whole(horizontal and cell.w or cell.h)
    return whole(math.max(least, (whole(px) * 2 + unit) // (unit * 2)))
end
-- The cells that HOLD a drawing of `px` pixels: rounded up, never to the
-- nearest. A 32 px picture at a 10 px cell needs four cells; the nearest
-- three would be 30 px, and the renderer, which never draws past its cells,
-- would drop the picture — the Run… dialog lost its icon that way on a
-- 10×20 terminal while it kept it at 8×18.
local function cells_up(plan: any, px: any, fallback: any, horizontal: boolean, least: integer): integer
    local cell: any = plan.cell
    if cell == nil or px == nil then return whole(math.max(least, whole(fallback or 0))) end
    local unit = whole(horizontal and cell.w or cell.h)
    return whole(math.max(least, (whole(px) + unit - 1) // unit))
end
-- picture_size(plan, node, horizontal) -> the cells a `picture` takes along its
-- parent's axis, or nil for a flexible one.
--
-- Down a column it is the picture's height: `size_px` when given, else its
-- natural height — `natural_h`, which `app.run` measures in the window's own
-- process and publishes with the tree, so the compositor lays out exactly the
-- rows the window hit-tests — rounded UP to whole cells, so the renderer's
-- rect holds it. Unmeasured (cells, a file that is not there, a window that
-- may not read the pack) it is its text: `size`, else one row. Across a row it
-- is `size`, else the natural width in pixels, else it shares the rest.
local function picture_size(plan: any, node: any, horizontal: boolean): any
    if node.fill == true then return nil end
    if horizontal then
        if node.size ~= nil then return whole(math.max(0, whole(node.size))) end
        if plan.cell ~= nil and node.natural_w ~= nil then return cells_up(plan, node.natural_w, nil, true, 1) end
        return nil
    end
    if plan.cell ~= nil then
        local px: any = node.size_px or node.natural_h
        if px ~= nil then return cells_up(plan, px, nil, false, 1) end
    end
    if node.size ~= nil then return whole(math.max(0, whole(node.size))) end
    return 1
end
-- pack(children, rect, node, plan) — the buttons of a right-aligned row, drawn
-- at their classic size in pixels: `width_px` wide (75 in a dialog),
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
    if kind == "gauge" and node.orient ~= nil and node.orient ~= "horizontal" and node.orient ~= "vertical" then
        return "SDK gauge orient must be \"horizontal\" or \"vertical\": " .. tostring(node.orient)
    end
    -- A group is the etched frame with a title, or a sunken pane with a
    -- background of its own (the Welcome tip). An unknown style would draw as
    -- the frame and look like a choice that was honoured.
    if kind == "group" and node.style ~= nil and node.style ~= "etched" and node.style ~= "sunken" then
        return "SDK group style must be \"etched\" or \"sunken\": " .. tostring(node.style)
    end
    if kind == "group" and node.background ~= nil and ui.pane_color(node.background) == nil then
        return "SDK group background must be \"field\", \"info\" or #rrggbb: " .. tostring(node.background)
    end
    if kind == "picture" and node.align ~= nil and node.align ~= "left" and node.align ~= "center" then
        return "SDK picture align must be \"left\" or \"center\": " .. tostring(node.align)
    end
    -- The editor is fixed-pitch only: its columns are the plan's, and a
    -- proportional face would put the caret between the letters it drew.
    if kind == "editor" and node.font ~= nil and node.font ~= "mono" then
        return "SDK editor font must be \"mono\" (the fixed-pitch face): " .. tostring(node.font)
    end
    if kind == "menu" then
        -- A row is checked or a bullet, never both: two marks in one margin
        -- would draw one over the other. Submenus are one level deep, as the
        -- plan lays them out; a deeper list would be silently unreachable.
        local function rows_problem(items: any, depth: integer): any
            if items == nil then return nil end
            if type(items) ~= "table" then return "SDK menu items must be a list" end
            for _, choice in ipairs(items) do
                local option: any = choice
                if type(option) ~= "table" then return "SDK menu item must be a table" end
                if option.checked == true and option.bullet == true then
                    return "SDK menu item cannot be both checked and a bullet: " .. tostring(option.id or option.text)
                end
                if option.items ~= nil then
                    if depth > 1 then return "SDK menu submenus are one level deep: " .. tostring(option.id or option.text) end
                    local deeper = rows_problem(option.items, depth + 1)
                    if deeper then return deeper end
                end
            end
            return nil
        end
        if node.entries ~= nil and type(node.entries) ~= "table" then return "SDK menu entries must be a list" end
        -- An entry may be a bare title (a string, as `ui.spans` reads it): it
        -- has no list to check.
        for _, entry in ipairs(node.entries or {}) do
            local why = type(entry) == "table" and rows_problem(entry.items, 1) or nil
            if why then return why end
        end
        if node.popup ~= nil then
            if type(node.popup) ~= "table" or tonumber(node.popup.x) == nil or tonumber(node.popup.y) == nil then
                return "SDK context menu popup must be {x, y}"
            end
            local why = rows_problem(node.items, 1)
            if why then return why end
        end
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
        -- A context menu (`menu` with `popup`) floats: it takes no room in its
        -- container and is laid over the whole client after the others.
        local children: any, floating: any = {}, {}
        for _, child in ipairs(node.children or {}) do
            if type(child) == "table" and child.kind == "menu" and child.popup ~= nil then floating[#floating + 1] = child
            else children[#children + 1] = child end
        end
        local horizontal = kind == "row" or kind == "split"
        local length = whole(horizontal and rect.w or rect.h)
        local gap = whole(math.max(0, node.gap or 0))
        if plan.cell ~= nil and node.gap_px ~= nil then gap = cells_for(plan, node.gap_px, 0, horizontal, 0) end
        -- A child's fixed size: `size_px` rounded to cells when the plan draws
        -- in pixels, `size` otherwise; nil for a flexible child.
        local function fixed_size(child: any): any
            -- A picture's `size_px` is its height, not a length along any axis.
            if type(child) == "table" and child.kind == "picture" then return picture_size(plan, child, horizontal) end
            -- A separator is one row down a column unless it says otherwise:
            -- a line that took the rest would push the buttons under it away.
            if type(child) == "table" and child.kind == "separator" and child.size == nil and not horizontal then
                return 1
            end
            if plan.cell ~= nil and child.size_px ~= nil then
                if child.kind == "image" then return cells_up(plan, child.size_px, child.size, horizontal, 1) end
                return cells_for(plan, child.size_px, child.size, horizontal, 1)
            end
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
        for _, child in ipairs(floating) do add(child, geometry.rect(1, 1, plan.width, plan.height), plan, interaction) end
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
    if kind == "menu" and type(node.popup) == "table" then
        -- A context menu: no bar, its one list open at the pointer's cell for
        -- as long as the tree carries the node; its rect is the list's, so it
        -- covers and takes nothing else.
        local open: any = interaction.menus[id]
        if open == nil then
            open = {index = 1, cursor = 0}
            interaction.menus[id] = open
        end
        item.spans = {}
        item.popup = ui.context_popup(node, plan.width, plan.height, plan.cell ~= nil)
        if item.popup then
            item.rect = item.popup.rect
            if open.sub ~= nil then item.popup.sub = ui.submenu(item, item.popup, open.sub, plan.width, plan.height) end
            plan.overlays[#plan.overlays + 1] = item
        else
            item.rect = geometry.rect(1, 1, 0, 0)
        end
    elseif kind == "menu" then
        -- A menu bar: a strip of titles; the open list goes on top of everything,
        -- so it lands in `plan.overlays` and is drawn last.
        item.spans = ui.spans(node.entries, rect.w, 1)
        local open: any = interaction.menus[id]
        if open and open.index then
            item.popup = ui.popup(item, open.index, plan.cell ~= nil)
            if item.popup then
                -- The open submenu lies in the popup: one overlay, one hit, one
                -- fingerprint. A row that no longer opens one leaves none.
                if open.sub ~= nil then
                    item.popup.sub = ui.submenu(item, item.popup, open.sub, plan.width, plan.height)
                end
                plan.overlays[#plan.overlays + 1] = item
            else interaction.menus[id] = nil end
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
    if kind == "icons" and node.flow == "columns" then
        -- The List view: columns filled top to bottom and scrolled sideways
        -- by COLUMNS — the wheel, the bar and the keys count them. No
        -- vertical bar: a column holds as many items as the view has rows.
        local items = node.items or {}
        local shape = ui.list_shape(items, rect.w, rect.h)
        item.flow, item.column, item.lines = true, shape.column, shape.lines
        item.columns_total, item.fit, item.page, item.bar_cols = shape.total, shape.fit, shape.fit, 0
        item.selected_index = selected_index(node, items, id ~= nil and interaction.anchors[id] or nil)
        item.offset = scroll.clamp(id ~= nil and interaction.offsets[id] or 0, shape.total, shape.fit)
        if item.selected_index > 0 then
            item.offset = scroll.reveal(item.offset, (item.selected_index - 1) // shape.lines + 1, shape.total, shape.fit)
        end
        if id ~= nil then interaction.offsets[id] = item.offset end
        item.hbar = shape.bar and scroll.bar(item.offset, shape.total, shape.fit, rect.w) or nil
        item.cells = {}
        for index, entry in ipairs(items) do
            local shown = (index - 1) // shape.lines - item.offset
            local x = rect.x + shown * shape.column
            -- The last column may be partial: its cells keep what fits, the
            -- caption cut with "…"; narrower than the glyph and two cells, none.
            local room = whole(math.min(shape.column - 1, rect.x + rect.w - x))
            if shown >= 0 and room >= 3 then
                local y = rect.y + (index - 1) % shape.lines
                item.cells[#item.cells + 1] = {
                    index = index, item = entry, x = x, y = y, room = room,
                    box = {from = x, to = x + room - 1, top = y, bottom = y},
                    selected = ui.is_selected(item, index),
                }
            end
        end
    elseif kind == "icons" then
        -- An icon grid, as in Explorer: the scroll unit is a ROW, not
        -- an item and not a line of text. The row is declared here once, and the bar,
        -- the wheel and the keys all count by it.
        local items = node.items or {}
        -- `small = true` is the Small Icons view: the same grid walk on the
        -- smaller step (`SMALL_GRID`), a row one cell high.
        local grid = node.small == true and SMALL_GRID or ICON_GRID
        -- The grid leaves the scrollbar its columns: in cells the bar lies in
        -- the last cell's air column, and a wider bar in pixels takes that
        -- many columns more.
        local columns, rows_total = ui.icon_shape(rect.w - (item.bar_cols - 1), #items, node.small == true)
        local page = whole(rect.h) // grid.h
        if page < 1 then page = 1 end
        item.columns, item.rows_total, item.page = columns, rows_total, page
        item.selected_index = selected_index(node, items, id ~= nil and interaction.anchors[id] or nil)
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
        local room = grid.w - 1
        for index, entry in ipairs(items) do
            local row = (index - 1) // columns
            local column = (index - 1) % columns
            local visible_row = row - item.offset
            if visible_row >= 0 and visible_row < page then
                local x = rect.x + column * grid.w
                local y = rect.y + visible_row * grid.h
                item.cells[#item.cells + 1] = {
                    index = index, item = entry, x = x, y = y, room = room,
                    box = {from = x, to = x + room - 1, top = y, bottom = y + grid.drawn - 1},
                    selected = ui.is_selected(item, index),
                }
            end
        end
    end
    if kind == "list" or kind == "table" or kind == "tree" then
        -- A table's first row is the header: the page and the bar are one row shorter.
        item.header = (kind == "table" and node.header ~= false) and 1 or 0
        item.page = math.max(1, whole(rect.h) - whole(item.header))
        local total = #entries(node)
        item.selected_index = selected_index(node, entries(node), id ~= nil and interaction.anchors[id] or nil)
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
    if kind == "text" then
        -- A read-only text: wrapped ONCE here, by the rect's width minus the
        -- scrollbar's columns and the cell of air on the left, and both
        -- renderers draw `item.lines`. The scroll unit is a line. Without an
        -- `id` there is no offset to keep: the text stays at the top.
        item.lines = ui.wrap_text(node.text, whole(rect.w) - whole(item.bar_cols) - 1, node.wrap)
        local total = #item.lines
        item.page = whole(math.max(1, whole(rect.h)))
        item.offset = scroll.clamp(id ~= nil and interaction.offsets[id] or 0, total, item.page)
        if id ~= nil then interaction.offsets[id] = item.offset end
        item.bar = scroll.bar(item.offset, total, item.page, rect.h)
    end
    if kind == "terminal" then
        -- Someone else's screen, laid out by whoever owns it: the rows arrive
        -- styled and are drawn as they came. The only thing decided here is
        -- how much of that screen fits.
        --
        -- In pixels a column is a mono glyph and not a terminal cell, the
        -- same rule the editor follows. The alternative — stretching each
        -- glyph to the cell's width — resamples a bitmap face at a fraction
        -- nobody chose, and the whole point of drawing someone else's screen
        -- in pixels is that it stops looking cheap.
        --
        -- The node takes no input here: a terminal's keys belong to whatever
        -- is on the other side, and the window forwards them itself.
        item.page = whole(math.max(1, whole(rect.h)))
        item.columns = whole(math.max(1, whole(rect.w)))
        if plan.cell ~= nil then
            item.columns = whole(math.max(1, (whole(rect.w) * whole(plan.cell.w)) // ui.MONO_PX))
        end
        item.rows = node.rows or {}
        item.cursor = node.cursor
    end
    if kind == "editor" then
        -- The multi-line editor (FR-007 §3). The document is the state's: made
        -- from the node's `text` the first time, never read from it again.
        local document: any = interaction.editors[id]
        if not editor.document(document) then
            document = editor.new(node.text)
            interaction.editors[id] = document
        end
        local wrap = node.wrap == true
        local tab = whole(math.max(1, whole(node.tab or editor.TAB)))
        -- Without wrap the last row is the horizontal bar; the vertical bar
        -- takes its columns always.
        local page = whole(math.max(1, whole(rect.h) - (wrap and 0 or 1)))
        local text_cells = whole(math.max(1, whole(rect.w) - whole(item.bar_cols)))
        local columns = text_cells
        if plan.cell ~= nil then
            columns = whole(math.max(1, (text_cells * whole(plan.cell.w) - ui.EDITOR_INSET - 2) // ui.MONO_PX))
        end
        local rows = editor.layout(document.lines, columns, wrap, tab)
        if document.reveal then
            editor.reveal(document, rows, tab, page, (not wrap) and columns or nil)
            document.reveal = false
        end
        local widest = 0
        if not wrap then
            for _, row in ipairs(rows) do
                widest = whole(math.max(widest, editor.columns(editor.runes(document.lines[row.line]), 0, row.stop, tab)))
            end
        end
        -- One column past the widest line: the caret stands after its end.
        local span = widest + 1
        document.top = scroll.clamp(document.top, #rows, page)
        document.left = wrap and 0 or scroll.clamp(document.left, span, columns)
        item.document, item.rows, item.tab, item.wrap, item.cell = document, rows, tab, wrap, plan.cell
        item.page, item.columns, item.offset, item.left, item.span = page, columns, document.top, document.left, span
        item.bar = scroll.bar(document.top, #rows, page, page)
        item.hbar = (not wrap) and scroll.bar(document.left, span, columns, text_cells) or nil
        item.selecting = editor.selected(document)
        -- What each text row draws — its runes from the view's left, each
        -- selected or not, and the caret's column on its row — once, for
        -- both renderers and the rows' keys.
        local caret_row, caret_x = editor.locate(document, rows, tab)
        item.visible = {}
        for row_index = 1, page do
            local row: any = rows[document.top + row_index]
            if row == nil then break end
            local shown: any = {}
            for _, glyph in ipairs(editor.glyphs(document, row, tab)) do
                local x = whole(glyph.x) - document.left
                if x + whole(glyph.w) > 0 and x < columns then
                    shown[#shown + 1] = {char = glyph.char, x = x, w = glyph.w, selected = glyph.selected}
                end
            end
            item.visible[row_index] = {glyphs = shown,
                caret = document.top + row_index == caret_row and caret_x - document.left or nil}
        end
    end
    plan.items[#plan.items + 1] = item
    if id then plan.by_id[id] = item end
    -- The menu is not part of the focus ring — as in the original, it is reached with Alt and F10.
    if id and not inert(node) and kind ~= "menu" and not node.disabled then plan.focusable[#plan.focusable + 1] = id end
end
-- The named backgrounds of a sunken pane: the field's white, and the pale
-- yellow of an information pane — the original's tooltips and the Welcome
-- tip's panel.
ui.PANE_COLORS = {field = "#ffffff", info = "#ffffe1"}

-- pane_color(value) -> "#rrggbb" | nil
--
-- A group's `background`: a named one, or a colour written out. Nil for
-- anything else, so `problem` refuses it by name rather than the renderer
-- drawing something nobody asked for.
function ui.pane_color(value: any): any
    if value == nil then return ui.PANE_COLORS.field end
    if type(value) ~= "string" then return nil end
    local named = ui.PANE_COLORS[value]
    if named then return named end
    if string.match(value, "^#%x%x%x%x%x%x$") then return string.lower(value) end
    return nil
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
-- gauge_filled(node, units) -> how many of `units` a gauge fills
--
-- `value` toward `ceiling`, clamped to 0..1, rounded to the nearest unit —
-- the cells of a bar, the blocks of a progress bar. One rule for both
-- renderers of a horizontal gauge; a ceiling of zero or less counts as one,
-- as the vertical gauge has always read it.
function ui.gauge_filled(node: any, units: any): integer
    local top = tonumber(node.ceiling) or 0
    if top <= 0 then top = 1 end
    local fraction = math.max(0, math.min(1, (tonumber(node.value) or 0) / top))
    return whole(math.floor(fraction * math.max(0, whole(units)) + 0.5))
end
-- spectrum_color(t) -> "#rrggbb"
--
-- The color spectrum of "Display Properties → Settings": at `t` from 0 to 1
-- the hue sweeps from magenta through blue, cyan, green and yellow to red,
-- as the classic bar reads left to right. Full saturation and value.
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
    return {focus = nil, offsets = {}, capture = nil, editors = {}, armed = nil, menus = {}, revealed = {}, anchors = {}}
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
-- Where a pointer lands on someone else's screen.
--
-- A `terminal` item is measured in mono glyphs when the plan draws pixels and
-- in cells when it does not (see the `terminal` branch of the plan), so a
-- click on a cell is not a click on a column. The conversion lives here, with
-- the decision it follows: a window that worked it out for itself would copy
-- the rule, and the copy would outlive the original.
--
-- The middle of the cell is what is converted, not its left edge: a pointer
-- standing on a cell means the column under the middle of that cell, and the
-- edges of the two are not the same places.
--
-- Returns the item and one-based column and row of that screen, or nil when
-- the pointer is over something else.
--
-- `anywhere` answers for a pointer outside the view as well, clamped to its
-- edge. That is what a captured drag needs: the button went down on the
-- screen, so the release belongs to it even if the pointer has left the
-- window by then. Without it the far side is told the button went down and
-- never that it came up, and whatever was being dragged stays stuck to the
-- pointer.
function ui.terminal_at(plan: any, x: any, y: any, anywhere: any?): any, any, any
    local px, py = whole(x), whole(y)
    for _, item in ipairs(plan and plan.items or {}) do
        local rect: any = item.rect
        local inside = rect ~= nil
            and px >= whole(rect.x) and px <= whole(rect.x) + whole(rect.w) - 1
            and py >= whole(rect.y) and py <= whole(rect.y) + whole(rect.h) - 1
        if item.node.kind == "terminal" and rect ~= nil and (inside or anywhere == true) then
            local across = px - whole(rect.x)
            local column = across + 1
            if plan.cell ~= nil then
                local middle = across * whole(plan.cell.w) + whole(plan.cell.w) // 2
                column = middle // ui.MONO_PX + 1
            end
            column = math.max(1, math.min(whole(item.columns), column))
            local row = math.max(1, math.min(whole(item.page), py - whole(rect.y) + 1))
            return item, column, row
        end
    end
    return nil, nil, nil
end

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
    if interaction.anchors == nil then interaction.anchors = {} end
    add(tree, geometry.rect(1, 1, width, height), plan, interaction)
    if not interaction.focus or not plan.by_id[interaction.focus] or plan.by_id[interaction.focus].node.disabled then
        interaction.focus = plan.focusable[1]
    end
    -- Records of vanished controls are released: otherwise another control with the
    -- same `id` on the next screen would inherit someone else's offset or caret, and
    -- a thumb capture would survive the window being minimized.
    for _, field in ipairs({"offsets", "editors", "menus", "revealed", "anchors"}) do
        local map: any = interaction[field]
        if type(map) == "table" then
            local stale = {}
            -- A document outlives its editor's absence from the tree: a sheet
            -- over Notepad must not lose the text under it.
            for key, value in pairs(map) do
                if plan.by_id[key] == nil and not (field == "editors" and editor.document(value)) then
                    stale[#stale + 1] = key
                end
            end
            for _, key in ipairs(stale) do map[key] = nil end
        end
    end
    if interaction.capture and plan.by_id[interaction.capture.id] == nil then interaction.capture = nil end
    if interaction.armed and plan.by_id[interaction.armed.id] == nil then interaction.armed = nil end
    -- The black "default" outline goes to the focused button, and when the focus is not on
    -- a button, to the one declared `default`. That is how the original does it, and that is how Enter does
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
        local popup: any = item.popup
        if popup and (geometry.contains(popup.rect, x, y)
            or (popup.sub ~= nil and geometry.contains(popup.sub.rect, x, y))) then return item end
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
-- step_row(rows, cursor, step) -> the next row from `cursor` that can be
-- chosen, around the ends, skipping separators and disabled items.
local function step_row(rows: any, cursor: any, step: integer): integer
    local count = #rows
    local at = whole(cursor)
    for _ = 1, count do
        at = ((at - 1 + step) % count) + 1
        local row: any = rows[at]
        if not row.separator and not row.disabled then break end
    end
    return at
end
-- Menu: a click on a title opens or closes it, on a list row it is
-- an action, a click outside closes it and swallows the click. Keys while it is open:
-- arrows, Enter, Esc, F10.
--
-- A row with `items` opens its submenu (`open.sub` is that row's position,
-- `open.sub_cursor` the row inside it, 0 while the keys stay in the list): a
-- click or the pointer over it, → or Enter on it; ← and Esc close it again,
-- as the Start menu's folders do. A choice in the submenu is `activate` with
-- the leaf's `id`.
local function menu_event(item: any, state: any, event: any): any
    local node, id = item.node, item.node.id
    local open: any = state.menus[id]
    local popup: any = item.popup
    local sub: any = popup and popup.sub or nil
    local function row_at(list: any): any
        return list.rows[event.y - list.rect.y + 1 - list.lead]
    end
    -- enter(position) — the keys go into the submenu of that row, on its
    -- first row that can be chosen. The rows are read from the node, not the
    -- plan: → then ↓ between two frames would find no submenu in the plan.
    local function enter(position: any): boolean
        local items = submenu_items(node, open.index, position)
        if items == nil then return false end
        local rows = menu_rows(items)
        open.cursor, open.sub, open.sub_cursor = whole(position), whole(position), step_row(rows, 0, 1)
        return true
    end
    if event.type == "mouse" then
        if event.action == "motion" then
            -- The pointer walks the menu as it walks the Start menu: the row
            -- under it takes the cursor, a row with a submenu opens it and
            -- any other row closes it; over another title the open menu
            -- moves there.
            if not open then return nil end
            if sub and geometry.contains(sub.rect, event.x, event.y) then
                local row: any = row_at(sub)
                if row and not row.separator then open.sub_cursor = row.position end
            elseif popup and geometry.contains(popup.rect, event.x, event.y) then
                local row: any = row_at(popup)
                if row and not row.separator then
                    open.cursor = row.position
                    if row.submenu and not row.disabled then
                        if open.sub ~= row.position then open.sub, open.sub_cursor = row.position, 0 end
                    else open.sub, open.sub_cursor = nil, nil end
                end
            elseif event.y == item.rect.y then
                local span = span_at(item, event.x)
                if span and span.index ~= open.index then state.menus[id] = {index = span.index, cursor = 0} end
            end
            return nil
        end
        if not input.pressed(event) then return nil end
        if open and sub and geometry.contains(sub.rect, event.x, event.y) then
            local row: any = row_at(sub)
            state.menus[id] = nil
            if row and not row.separator and not row.disabled and row.id then
                return {type = "activate", id = row.id, menu = id}
            end
            return nil
        end
        if open and popup and geometry.contains(popup.rect, event.x, event.y) then
            local row: any = row_at(popup)
            -- A row with a submenu opens it: it is not a choice.
            if row and row.submenu and not row.disabled then
                open.cursor, open.sub, open.sub_cursor = row.position, row.position, 0
                return nil
            end
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
    local count = popup and #popup.rows or 0
    local inner: any = open.sub ~= nil and submenu_items(node, open.index, open.sub) or nil
    local inner_rows: any = inner ~= nil and menu_rows(inner) or nil
    local inside = inner_rows ~= nil and whole(open.sub_cursor) > 0
    -- A context menu that closes says so, `dismiss`: the window drops its node
    -- (not `close`, which is the window's own).
    local floating = type(node.popup) == "table"
    if key == "f10" then
        state.menus[id] = nil
        if floating then return {type = "dismiss", id = id} end
    elseif key == "esc" then
        if open.sub ~= nil then open.sub, open.sub_cursor = nil, nil
        else
            state.menus[id] = nil
            if floating then return {type = "dismiss", id = id} end
        end
    elseif key == "left" and open.sub ~= nil then
        open.sub, open.sub_cursor = nil, nil
    elseif key == "right" and not inside and popup and enter(open.cursor) then
        return nil
    elseif key == "left" or key == "right" then
        local total = #(item.spans or {})
        if total > 0 then
            local next_index = ((open.index - 1 + (key == "left" and -1 or 1)) % total) + 1
            state.menus[id] = {index = next_index, cursor = 0}
        end
    elseif (key == "up" or key == "down") and inside then
        open.sub_cursor = step_row(inner_rows, open.sub_cursor, key == "up" and -1 or 1)
    elseif (key == "up" or key == "down") and count > 0 then
        open.cursor = step_row(popup.rows, open.cursor, key == "up" and -1 or 1)
        open.sub, open.sub_cursor = nil, nil
    elseif key == "enter" and inside then
        local row: any = inner_rows[whole(open.sub_cursor)]
        state.menus[id] = nil
        if row and row.id and not row.separator and not row.disabled then
            return {type = "activate", id = row.id, menu = id}
        end
    elseif key == "enter" and popup then
        if enter(open.cursor) then return nil end
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
-- Closed, the arrows change the value directly, as in a classic drop-down
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
-- multi(node) -> whether the node keeps a multi-selection set
-- (`selected = {[id] = true}`) rather than one selected row.
local function multi(node: any): boolean
    return type(node.selected) == "table"
end
-- picked(item, state, index, event) -> the selection set after a click on
-- entry `index` (0: empty space), as in Explorer: a click alone selects that
-- entry, Ctrl toggles it in the set, Shift selects the range from the anchor
-- to it in view order. A click and Ctrl+click move the anchor, Shift keeps it.
-- A click on empty space clears the set, Ctrl+click there keeps it.
local function picked(item: any, state: any, index: integer, event: any): any
    local node: any = item.node
    local rows: any = entries(node)
    if state.anchors == nil then state.anchors = {} end
    local current: any = multi(node) and node.selected or {}
    local out: any = {}
    local key: any = index > 0 and ui.entry_key(rows[index], index) or nil
    if event.ctrl then
        for name, on in pairs(current) do if on == true then out[name] = true end end
        if key ~= nil then
            if out[key] then out[key] = nil else out[key] = true end
            state.anchors[node.id] = key
        end
    elseif event.shift and key ~= nil then
        -- The anchor from the state, not the plan: a click and a Shift+click
        -- between two frames see the anchor the first one set.
        local from = 0
        local anchor: any = state.anchors[node.id]
        for at, row in ipairs(rows) do
            if anchor ~= nil and ui.entry_key(row, at) == anchor then from = at end
        end
        if from < 1 then from = whole(item.selected_index) end
        if from < 1 then from = index end
        for at = math.min(from, index), math.max(from, index) do out[ui.entry_key(rows[at], at)] = true end
        state.anchors[node.id] = ui.entry_key(rows[from], from)
    elseif key ~= nil then
        out[key] = true
        state.anchors[node.id] = key
    end
    return out
end
-- every(rows) -> the set of all entries: Ctrl+A of a multi-selection.
local function every(rows: any): any
    local out: any = {}
    for at, row in ipairs(rows) do out[ui.entry_key(row, at)] = true end
    return out
end
-- chosen_one(node, state, rows, index, action) -> `action`, carrying the set
-- of the one entry a key moved to when the node keeps a multi-selection.
local function chosen_one(node: any, state: any, rows: any, index: integer, action: any): any
    if multi(node) then
        local key = ui.entry_key(rows[index], index)
        if state.anchors == nil then state.anchors = {} end
        state.anchors[node.id] = key
        action.selected = {[key] = true}
    end
    return action
end
local function list_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local rows = entries(node)
    -- The offset is taken from the STATE, not from the plan: otherwise two events in a row
    -- without a redraw (two wheel clicks) lost the first one.
    local total, header = #rows, whole(item.header)
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, total, item.page)
    if event.action == "wheel" then
        local moved = scroll.wheel(offset, event.button, total, item.page, node.wheel_step or 3)
        state.offsets[node.id] = moved
        -- The wheel pushing down with the last row on screen is `end`: the
        -- application may load the next page. It is the only thing the wheel
        -- says, so a window learns it without polling the offset.
        if event.button == "wheel_down" and total > 0 and moved >= scroll.limit(total, item.page) then
            return {type = "end", id = node.id, offset = moved, total = total}
        end
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
            -- `pointer`, as for a list: a second click is told from a key re-selecting the row.
            return {type = "select", id = node.id, index = index, value = line, pointer = true}
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
            if index <= total then
                local action: any = {type = "select", id = node.id, index = index, value = rows[index], pointer = true}
                if multi(node) then action.selected = picked(item, state, index, event) end
                return action
            end
            -- Below the last row a multi-selection clears, as empty space does in Explorer.
            if multi(node) then
                return {type = "select", id = node.id, index = 0, value = nil, pointer = true,
                    selected = picked(item, state, 0, event)}
            end
        end
    end
    return nil
end
-- A read-only text scrolls by lines: the wheel, a press on the bar, and the
-- arrows, Page Up/Down, Home and End while it has the focus. Every move is
-- `scroll` with the new offset — an action, so the key does not reach the
-- application as a bare `key`, and the SDK redraws it whatever `update` says.
local function text_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local total, page = #(item.lines or {}), whole(item.page)
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, total, page)
    if event.type == "mouse" then
        if event.action == "wheel" then
            offset = scroll.wheel(offset, event.button, total, page, node.wheel_step or 3)
        elseif input.pressed(event) then
            local bar_left = rect.x + rect.w - whole(item.bar_cols or 1)
            if event.x < bar_left or item.bar.limit <= 0 then return nil end
            local shifted, capture = scroll.pointer(offset, total, page,
                {x = bar_left, y = rect.y, w = rect.x + rect.w - bar_left, h = rect.h}, nil, event)
            offset = shifted
            state.capture = capture and {id = node.id, grab = capture.grab} or nil
        else
            return nil
        end
    else
        local key = input.key(event)
        if key ~= "up" and key ~= "down" and key ~= "pgup" and key ~= "pgdown" and key ~= "home" and key ~= "end" then
            return nil
        end
        offset = scroll.key(offset, key, total, page)
    end
    state.offsets[node.id] = offset
    return {type = "scroll", id = node.id, offset = offset, total = total}
end
-- Icon grid: a click on a cell selects it, the application is free to treat a repeated click
-- on an already selected one as a double click (`pointer = true`), a click on
-- empty space clears the selection — as in Explorer, where emptiness cancels.
local function icons_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local items = node.items or {}
    local total = #items
    -- The List view scrolls by COLUMNS: the wheel turns them, and its bar is
    -- the last row, as the editor's.
    local rows_total, page = whole(item.rows_total), whole(item.page)
    if item.flow then rows_total, page = whole(item.columns_total), whole(item.fit) end
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, rows_total, page)
    if event.action == "wheel" then
        state.offsets[node.id] = scroll.wheel(offset, event.button, rows_total, page, node.wheel_step or 1)
        return nil
    end
    if not input.pressed(event) then return nil end
    local bar_row = rect.y + rect.h - 1
    if item.flow and item.hbar ~= nil and event.y == bar_row and geometry.contains(rect, event.x, event.y) then
        if item.hbar.limit <= 0 then return nil end
        local turned = {type = "mouse", action = "press", button = "left", x = event.y, y = event.x}
        local shifted, capture = scroll.pointer(offset, rows_total, page, {x = bar_row, y = rect.x, w = 1, h = rect.w},
            nil, turned)
        state.offsets[node.id] = shifted
        state.capture = capture and {id = node.id, grab = capture.grab, axis = "columns"} or nil
        return nil
    end
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
            local action: any = {type = "select", id = node.id, index = cell.index, value = items[cell.index], pointer = true}
            if multi(node) then action.selected = picked(item, state, whole(cell.index), event) end
            return action
        end
    end
    if geometry.contains(rect, event.x, event.y) and total > 0 then
        local action: any = {type = "select", id = node.id, index = 0, value = nil, pointer = true}
        if multi(node) then action.selected = picked(item, state, 0, event) end
        return action
    end
    return nil
end
-- context_at(item, state, event) -> the `context` of a right press on a
-- list, a table, a tree or an icon grid: the entry under the pointer (a tree's
-- visible row; `index` 0 and no
-- `value` on the empty field) and the cell, where the window opens its menu
-- (`ui.context_menu`). The scroll bar and a table's header have none. The
-- press takes the focus, as a left one does.
local function context_at(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    if event.x >= rect.x + rect.w - whole(item.bar_cols or 1) then return nil end
    -- The List view's horizontal bar is no entry's row.
    if item.flow and item.hbar ~= nil and whole(event.y) == rect.y + rect.h - 1 then return nil end
    local index = 0
    if node.kind == "icons" then
        for _, cell in ipairs(item.cells or {}) do
            local box: any = cell.box
            if event.x >= box.from and event.x <= box.to and event.y >= box.top and event.y <= box.bottom then
                index = whole(cell.index)
            end
        end
    else
        local row = whole(event.y) - whole(rect.y) - whole(item.header)
        if row < 0 then return nil end
        local at = whole(state.offsets[node.id] or item.offset) + row + 1
        if at <= #entries(node) then index = at end
    end
    state.focus = node.id
    return {type = "context", id = node.id, index = index, value = index > 0 and entries(node)[index] or nil,
        x = whole(event.x), y = whole(event.y)}
end
-- The editor's pointer and keys. The document is read from the state, the
-- rows and the bars from the plan.
--
-- editor_place(item, document, event) -> the document place under the
-- pointer: its display row (clamped to the document) and column.
local function editor_place(item: any, document: any, event: any): any
    local row = whole(document.top) + whole(event.y) - whole(item.rect.y) + 1
    row = whole(math.max(1, math.min(#item.rows, row)))
    return editor.at(document, item.rows, item.tab, row, ui.editor_column(item, event.x) + whole(document.left))
end
local function scrolled(item: any, document: any): any
    return {type = "scroll", id = item.node.id, offset = whole(document.top), total = #item.rows}
end
local function slid(item: any, document: any): any
    return {type = "scroll", id = item.node.id, offset = whole(document.left), total = whole(item.span)}
end
-- A key or a paste for the focused editor: an edit is `change` (marked
-- `drawn`: the text is edited already), a move is `caret`; what the model
-- does not take — Ctrl+Z/X/C/V, Esc — goes on to the window as a key.
local function editor_key(item: any, state: any, event: any): any
    local node = item.node
    local document: any = state.editors[node.id]
    if not editor.document(document) then return nil end
    local outcome = editor.key(document, event, {columns = item.columns, wrap = item.wrap, tab = item.tab,
        page = item.page, read_only = node.read_only == true})
    if outcome == "change" then return {type = "change", id = node.id, drawn = true} end
    if outcome == "caret" then return {type = "caret", id = node.id} end
    return nil
end
-- The pointer: the wheel scrolls three rows; a press on the vertical bar, or
-- on the horizontal one (the same rule turned on its side), scrolls or grabs
-- the thumb; a press in the text puts the caret and starts a drag, with Shift
-- it extends, and a second press in the same cell within `DOUBLE_MS` takes
-- the word (`event.time`, stamped by `app.run`).
local function editor_event(item: any, state: any, event: any): any
    local node, rect = item.node, item.rect
    local document: any = state.editors[node.id]
    if not editor.document(document) then return nil end
    if event.action == "wheel" then
        document.top = scroll.wheel(document.top, event.button, #item.rows, item.page, node.wheel_step or 3)
        return scrolled(item, document)
    end
    if event.action ~= "press" or event.button ~= "left" then return nil end
    local bar_left = rect.x + rect.w - whole(item.bar_cols or 1)
    local text_bottom = rect.y + whole(item.page) - 1
    if event.x >= bar_left and event.y <= text_bottom then
        if item.bar.limit <= 0 then return nil end
        local shifted, capture = scroll.pointer(document.top, #item.rows, item.page,
            {x = bar_left, y = rect.y, w = rect.x + rect.w - bar_left, h = item.page}, nil, event)
        document.top = shifted
        state.capture = capture and {id = node.id, grab = capture.grab, axis = "rows"} or nil
        return scrolled(item, document)
    end
    if event.y > text_bottom then
        if item.hbar == nil or event.x >= bar_left or item.hbar.limit <= 0 then return nil end
        local turned = {type = "mouse", action = "press", button = "left", x = event.y, y = event.x}
        local shifted, capture = scroll.pointer(document.left, item.span, item.columns,
            {x = text_bottom + 1, y = rect.x, w = 1, h = bar_left - rect.x}, nil, turned)
        document.left = shifted
        state.capture = capture and {id = node.id, grab = capture.grab, axis = "columns"} or nil
        return slid(item, document)
    end
    local place = editor_place(item, document, event)
    local click: any = document.click
    local double = not event.shift and click ~= nil and click.x == event.x and click.y == event.y
        and event.time ~= nil and click.time ~= nil and event.time - click.time <= DOUBLE_MS
    if double then
        editor.word(document, place)
        document.click = nil
    else
        editor.press(document, place, event.shift == true)
        document.click = {x = event.x, y = event.y, time = event.time}
        state.capture = {id = node.id, axis = "text"}
    end
    return {type = "caret", id = node.id}
end
-- A drag the editor captured: a thumb of either bar, or the selection
-- running from the press to the pointer (past the text the view follows the
-- caret).
local function editor_drag(item: any, state: any, event: any): any
    local document: any = state.editors[item.node.id]
    local capture: any = state.capture
    if not editor.document(document) then return nil end
    if capture.axis == "rows" then
        document.top = scroll.drag(event.y - item.rect.y, capture.grab, item.bar)
        return scrolled(item, document)
    end
    if capture.axis == "columns" then
        document.left = scroll.drag(event.x - item.rect.x, capture.grab, item.hbar)
        return slid(item, document)
    end
    if event.action ~= "motion" then return nil end
    editor.press(document, editor_place(item, document, event), true)
    return {type = "caret", id = item.node.id}
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
        if item and item.node.kind == "editor" then
            local dragged = editor_drag(item, state, event)
            if event.action == "release" then state.capture = nil end
            return dragged
        end
        if item and state.capture.axis == "columns" and item.hbar ~= nil then
            -- The List view's thumb runs along its bottom row.
            state.offsets[state.capture.id] = scroll.drag(event.x - item.rect.x, state.capture.grab, item.hbar)
        elseif item then
            state.offsets[state.capture.id] = scroll.drag(event.y - item.rect.y - whole(item.header), state.capture.grab, item.bar)
        end
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
            local motion = event.type == "mouse" and event.action == "motion"
            if open and (input.pressed(event) or event.type == "key" or motion) then
                if event.type == "mouse" then
                    local target = ui.hit(plan, event.x, event.y)
                    -- The pointer passing elsewhere leaves the menu open; a
                    -- press elsewhere closes it and goes no further.
                    if target ~= item then
                        if motion then return nil end
                        state.menus[item.node.id] = nil
                        if type(item.node.popup) == "table" then return {type = "dismiss", id = item.node.id} end
                        return nil
                    end
                end
                return menu_event(item, state, event)
            end
            -- F10 opens the first menu, as in the original (and closes it again,
            -- in `menu_event`).
            if input.key(event) == "f10" and not open then
                state.menus[item.node.id] = {index = 1, cursor = 0}
                return nil
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
        if item.node.kind == "text" and item.node.id == nil then return nil end
        if item.node.kind == "menu" then return menu_event(item, state, event) end
        if item.node.kind == "tabs" then
            if input.pressed(event) then state.focus = item.node.id end
            return tabs_event(item, state, event)
        end
        -- The right button over a button belongs to the window (Minesweeper
        -- flags a cell with it): `context` at the PRESS, as in the original. It
        -- arms nothing and takes no focus, so its release activates nothing.
        if item.node.kind == "button" and item.node.id and event.action == "press" and event.button == "right" then
            return {type = "context", id = item.node.id}
        end
        if (item.node.kind == "list" or item.node.kind == "table" or item.node.kind == "icons" or item.node.kind == "tree")
            and item.node.id and event.action == "press" and event.button == "right" then
            return context_at(item, state, event)
        end
        -- Only what can hold the focus takes it. Otherwise a passive view with an `id`
        -- (a label, a field, a frame, a graph, a status bar…) took the
        -- focus while not being in the `focusable` ring — and Tab no longer found
        -- where to step from. The check uses the same `passive` that builds the ring, not
        -- the name of a single view kind.
        if input.pressed(event) and item.node.id and not passive[item.node.kind] then state.focus = item.node.id end
        if item.node.kind == "list" or item.node.kind == "table" or item.node.kind == "tree" then return list_event(item, state, event) end
        if item.node.kind == "text" then return text_event(item, state, event) end
        if item.node.kind == "editor" then return editor_event(item, state, event) end
        if item.node.kind == "icons" then return icons_event(item, state, event) end
        if item.node.kind == "select" then return select_event(item, state, event) end
        if item.node.kind == "slider" then return slider_event(item, state, event) end
        if (item.node.kind == "button" or item.node.kind == "checkbox" or item.node.kind == "radio") and input.pressed(event) then
            state.armed = {id = item.node.id, inside = true}
        end
        return nil
    end
    local key = input.key(event)
    -- A focused editor takes its keys before the Tab ring — Tab types a tab
    -- there, unless the document is read-only — and a paste is its text.
    local writing: any = plan.by_id[state.focus]
    if writing and writing.node.kind == "editor" and (event.type == "key" or event.type == "paste")
        and not (key == "tab" and writing.node.read_only == true) then
        return editor_key(writing, state, event)
    end
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
        -- Ctrl+A selects every row of a multi-selection.
        if multi(node) and key == "runes" and event.ctrl and tostring(event.key or ""):lower() == "a" then
            return {type = "select", id = node.id, index = chosen, value = rows[chosen], selected = every(rows)}
        end
        -- Pushing past the last row — ↓, Page Down or End with the last row
        -- already selected — is `end`, as the wheel at the bottom is.
        if chosen == total and (key == "down" or key == "pgdown" or key == "end") then
            return {type = "end", id = node.id, offset = whole(item.offset), total = total}
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
        return chosen_one(node, state, rows, index, {type = "select", id = node.id, index = index, value = rows[index]})
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
        if multi(node) and key == "runes" and event.ctrl and tostring(event.key or ""):lower() == "a" then
            return {type = "select", id = node.id, index = chosen, value = items[chosen], selected = every(items)}
        end
        if key == "home" then index = 1
        elseif key == "end" then index = total
        -- With no selection any arrow selects the first icon, as in a list.
        elseif chosen < 1 and moves then index = 1
        elseif item.flow then
            -- The List view: ↑/↓ within the column, ←/→ to the same row of
            -- the next column (its last item when that column is shorter),
            -- pages by the columns that fit whole.
            local lines = math.max(1, whole(item.lines))
            local column, last = (index - 1) // lines, (total - 1) // lines
            if key == "up" then
                if (index - 1) % lines > 0 then index = index - 1 end
            elseif key == "down" then
                if (index - 1) % lines < lines - 1 then index = index + 1 end
            elseif key == "left" then
                if column > 0 then index = index - lines end
            elseif key == "right" then
                if column < last then index = index + lines end
            elseif key == "pgup" then index = index - lines * math.max(1, whole(item.fit))
            elseif key == "pgdown" then index = index + lines * math.max(1, whole(item.fit))
            elseif key == "enter" then return {type = "activate", id = node.id, index = index, value = items[index]}
            else return nil end
        elseif key == "left" then index = index - 1
        elseif key == "right" then index = index + 1
        elseif key == "up" then index = index - columns
        elseif key == "down" then index = index + columns
        elseif key == "pgup" then index = index - columns * math.max(1, whole(item.page))
        elseif key == "pgdown" then index = index + columns * math.max(1, whole(item.page))
        elseif key == "enter" then return {type = "activate", id = node.id, index = index, value = items[index]}
        else return nil end
        index = whole(math.max(1, math.min(total, index)))
        if item.flow then
            local column = (index - 1) // math.max(1, whole(item.lines)) + 1
            state.offsets[node.id] = scroll.reveal(item.offset, column, whole(item.columns_total), math.max(1, whole(item.fit)))
        else
            local row = (index - 1) // columns + 1
            state.offsets[node.id] = scroll.reveal(item.offset, row, whole(item.rows_total), math.max(1, whole(item.page)))
        end
        return chosen_one(node, state, items, index, {type = "select", id = node.id, index = index, value = items[index]})
    elseif node.kind == "text" and key then
        return text_event(item, state, event)
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
