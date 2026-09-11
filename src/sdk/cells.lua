local tty = require("tty")
local widgets = require("widgets")
local icon_cells = require("icons")
local ui = require("ui")
local charts = require("charts")
local text = require("text")
local geometry = require("geometry")
local editor = require("editor")
local whole = geometry.whole
local cells = {}
-- A cut is marked, as in pixels: text wider than its room loses its tail to
-- "…". Each backend measures in its own unit — here cells, there the font —
-- so the pixel text keeps what the proportional font fits.
local function ellipsized(value: any, room: any): string
    local shown = tostring(value)
    local width = whole(room)
    if widgets.cells(shown) <= width then return shown end
    if width <= 1 then return widgets.clip(shown, width) end
    return widgets.clip(shown, width - 1) .. "…"
end
function cells.rows(plan: any, interaction: any, width: any, height: any): any
    local canvas = tty.canvas(whole(math.max(1, width)), whole(math.max(1, height)))
    canvas:clear(widgets.styles.face:render(" "))
    local function put(x: any, y: any, text: any, w: any, style: any)
        if w > 0 then canvas:put(whole(x), whole(y), widgets.fit(style, ellipsized(text, w), whole(w)), whole(w)) end
    end
    local styles = widgets.styles
    -- The scrollbar of a list, table, tree and icon grid is one and the same as
    -- the explorer's: `widgets.scrollbar`. The numbers come from the plan (`item.offset`,
    -- `item.page`), and the thumb is computed by the same `scroll.bar` the plan uses
    -- to compute hits and dragging, so the drawn thumb and the pressable one do not
    -- drift apart. There used to be four built-in copies. The column is first filled
    -- with the face color: there is no bar when there is nothing to scroll.
    local function scrollbar(x: any, y: any, h: any, first: any, visible: any, total: any)
        for row = 0, whole(h) - 1 do put(x, y + row, " ", 1, styles.face) end
        widgets.scrollbar(canvas, whole(x), whole(y), whole(h), {first = first, visible = visible, total = total})
    end
    local function strip(item: any, r: any, current: any, opened: any)
        -- The strip of tab or menu titles: " caption " with edges for tabs,
        -- bare for menus; the current one is bold, the open one is inverted.
        local parts, used = {}, 0
        for _, span in ipairs(item.spans or {}) do
            local text = " " .. span.title .. " "
            local style = styles.face
            if span.index == opened then style = styles.select
            elseif span.index == current then style = styles.face_bold
            elseif item.node.kind == "tabs" then style = styles.face_dim end
            local body = span.accel > 0 and widgets.accel(style, text, span.accel) or style:render(text)
            if item.node.kind == "tabs" then parts[#parts + 1] = widgets.bezel(body, false)
            else parts[#parts + 1] = body end
            used = used + span.w
        end
        if used < r.w then parts[#parts + 1] = styles.face:render(string.rep(" ", r.w - used)) end
        canvas:put(whole(r.x), whole(r.y), table.concat(parts), whole(r.w))
    end
    for _, item in ipairs(plan.items) do
        local node, r = item.node, item.rect
        local focused = interaction.focus == node.id
        if node.kind == "group" then
            -- A frame with its title in the top edge — like the Task Manager's boxes.
            local title = " " .. tostring(node.title or "") .. " "
            local top = widgets.edge_top(r.w, false)
            canvas:put(whole(r.x), whole(r.y), top, whole(r.w))
            if r.w > widgets.cells(title) + 2 then
                canvas:put(whole(r.x + 1), whole(r.y), styles.face_bold:render(title), whole(widgets.cells(title)))
            end
            for row = 1, r.h - 2 do
                canvas:put(whole(r.x), whole(r.y + row), styles.light:render("▏"), 1)
                canvas:put(whole(r.x + r.w - 1), whole(r.y + row), styles.shadow:render("▕"), 1)
            end
            if r.h >= 2 then canvas:put(whole(r.x), whole(r.y + r.h - 1), widgets.edge_bottom(r.w, false), whole(r.w)) end
        elseif node.kind == "graph" then
            -- Green on black, a dotted grid where the graph is empty.
            local line = tty.style():foreground("#00ff00"):background("#000000")
            local grid = tty.style():foreground("#004400"):background("#000000")
            local rows, top = charts.graph(node.values or {}, r.w, r.h, node.ceiling or 0)
            for index, row in ipairs(rows) do
                local parts = {}
                local column = 0
                for _, char in ipairs(text.runes(row)) do
                    column = column + 1
                    if char == " " then parts[#parts + 1] = grid:render(column % 4 == 0 and "·" or " ")
                    else parts[#parts + 1] = line:render(char) end
                end
                canvas:put(whole(r.x), whole(r.y + index - 1), table.concat(parts), whole(r.w))
            end
            local cap = string.format("%s%s", tostring(top), tostring(node.unit or ""))
            canvas:put(whole(r.x), whole(r.y), line:render(cap), whole(math.min(r.w, widgets.cells(cap))))
        elseif node.kind == "gauge" then
            local line = tty.style():foreground("#00ff00"):background("#000000")
            local grid = tty.style():foreground("#004400"):background("#000000")
            for row = 0, r.h - 1 do canvas:put(whole(r.x), whole(r.y + row), grid:render(string.rep(" ", r.w)), whole(r.w)) end
            local top = tonumber(node.ceiling) or 0
            if top <= 0 then top = 1 end
            local filled = whole(math.floor(math.min(1, (tonumber(node.value) or 0) / top) * r.w + 0.5))
            if r.h >= 2 then
                canvas:put(whole(r.x), whole(r.y + r.h - 1),
                    line:render(string.rep("█", filled)) .. grid:render(string.rep("░", math.max(0, r.w - filled))), whole(r.w))
            end
            put(r.x, r.y, tostring(node.caption or node.value or ""), r.w, line)
        elseif node.kind == "calendar" then
            -- A header of weekdays, six rows of dates, today inverted.
            local names = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
            local col = math.max(2, whole(r.w) // 7)
            local head = {}
            for _, name in ipairs(names) do head[#head + 1] = widgets.fit(styles.face_bold, name, col) end
            canvas:put(whole(r.x), whole(r.y), table.concat(head), whole(math.min(r.w, col * 7)))
            local grid = ui.month_grid(node.first_weekday, node.days)
            for row_index, row in ipairs(grid) do
                if row_index >= r.h then break end
                local parts = {}
                for column = 1, 7 do
                    local day: any = row[column]
                    local text = day and string.format("%2d", whole(day)) or ""
                    local style = (day and whole(day) == whole(node.day)) and styles.select or styles.face
                    parts[#parts + 1] = widgets.fit(style, text, col)
                end
                canvas:put(whole(r.x), whole(r.y + row_index), table.concat(parts), whole(math.min(r.w, col * 7)))
            end
        elseif node.kind == "clock" then
            -- There are no hands in cells: digital time in the middle of the field.
            local digital = string.format("%02d:%02d:%02d", whole(node.hour), whole(node.minute), whole(node.second))
            for row = 0, r.h - 1 do canvas:put(whole(r.x), whole(r.y + row), styles.field:render(string.rep(" ", r.w)), whole(r.w)) end
            put(r.x + math.max(0, (r.w - 8) // 2), r.y + r.h // 2, digital, math.min(r.w, 8), styles.field)
        elseif node.kind == "field" then
            -- A sunken read-only field: the calculator display, the memory
            -- box. Text is aligned right or left, a cut is marked. The field is
            -- one cell row, the middle one of its rect, like a button or an
            -- input; the other rows stay face (pixels grow it around that row
            -- to the Windows 95 size instead).
            local inner = math.max(0, whole(r.w) - 2)
            local shown = ellipsized(node.text or "", inner)
            local pad = math.max(0, inner - widgets.cells(shown))
            local text = node.align == "right" and (string.rep(" ", pad) .. shown) or (shown .. string.rep(" ", pad))
            canvas:put(whole(r.x), whole(r.y + r.h // 2), widgets.bezel(styles.field:render(text), true), whole(r.w))
        elseif node.kind == "monitor" then
            -- In cells the monitor is a face-colored frame with a desktop-colored screen inside.
            local screen = tty.style():background(tostring(node.color or "#008080"))
            for row = 0, r.h - 1 do
                local edge = row == 0 or row == r.h - 1
                if edge or r.w < 3 then put(r.x, r.y + row, string.rep(" ", r.w), r.w, styles.face)
                else
                    put(r.x, r.y + row, " ", 1, styles.face)
                    put(r.x + 1, r.y + row, string.rep(" ", r.w - 2), r.w - 2, screen)
                    put(r.x + r.w - 1, r.y + row, " ", 1, styles.face)
                end
            end
        elseif node.kind == "image" then
            -- An icon in cells is one character: the font knows nothing about rasters.
            local glyph = tostring(node.icon or "▸")
            put(r.x + math.max(0, (r.w - 1) // 2), r.y + math.max(0, (r.h - 1) // 2), glyph, 1, styles.face)
        elseif node.kind == "statusbar" then
            widgets.statusbar(canvas, r.x, r.y + r.h - 1, r.w, node.fields or {})
        elseif node.kind == "tabs" then
            strip(item, r, whole(node.active or 1), nil)
            -- The page frame with a gap under the active tab — like widgets.tabs.
            local frame = item.frame
            if frame and frame.h >= 2 then
                local gap: any = nil
                for _, span in ipairs(item.spans or {}) do
                    if span.index == whole(node.active or 1) then gap = span end
                end
                local edge = {}
                for column = 0, frame.w - 1 do
                    if gap and column >= gap.x and column < gap.x + gap.w then edge[#edge + 1] = styles.face:render(" ")
                    elseif column == 0 then edge[#edge + 1] = widgets.edge_top(1, false)
                    else edge[#edge + 1] = styles.light:render("▔") end
                end
                canvas:put(whole(frame.x), whole(frame.y), table.concat(edge), whole(frame.w))
                for row = 1, frame.h - 2 do
                    canvas:put(whole(frame.x), whole(frame.y + row), styles.light:render("▏"), 1)
                    canvas:put(whole(frame.x + frame.w - 1), whole(frame.y + row), styles.shadow:render("▕"), 1)
                end
                canvas:put(whole(frame.x), whole(frame.y + frame.h - 1), widgets.edge_bottom(frame.w, false), whole(frame.w))
            end
        elseif node.kind == "menu" then
            local open: any = interaction.menus and interaction.menus[node.id] or nil
            strip(item, r, nil, open and open.index or nil)
        elseif node.kind == "table" then
            -- The header is raised column buttons, as in "Explorer"; rows are
            -- cells in the columns of one layout, right-aligned for numbers.
            local columns = ui.columns(node, r.w - 1)
            local styles = widgets.styles
            local header = whole(item.header)
            if header > 0 then
                put(r.x, r.y, "", r.w - 1, styles.face)
                for index, column in ipairs(columns) do
                    put(r.x + column.x, r.y, " " .. column.title, column.w, styles.face_bold)
                    if index < #columns then put(r.x + column.x + column.w, r.y, "▏", 1, styles.shadow) end
                end
                put(r.x + r.w - 1, r.y, " ", 1, styles.face)
            end
            local rows = ui.entries(node)
            -- A disabled one uses the face color and gray text, with no selection, like
            -- a disabled field: otherwise it looks working and silently does not respond.
            local ground = node.disabled and styles.face_dim or styles.field
            for row = 0, r.h - 1 - header do
                local index = item.offset + row + 1
                local record: any = rows[index]
                local style = not node.disabled and item.selected_index == index and styles.select or ground
                local y = r.y + header + row
                put(r.x, y, "", r.w - 1, style)
                if record then
                    local values: any = type(record) == "table" and (record.cells or record) or {record}
                    for col, column in ipairs(columns) do
                        local value = tostring(values[col] or "")
                        -- Text starts one cell in; a right-aligned value ends one
                        -- cell before its column's end. The same rule in pixels.
                        if column.align == "right" then
                            local clipped = ellipsized(value, column.w - 1)
                            value = string.rep(" ", math.max(0, column.w - 1 - widgets.cells(clipped))) .. clipped
                        else value = " " .. value end
                        put(r.x + column.x, y, value, column.w, style)
                    end
                end
            end
            scrollbar(r.x + r.w - 1, r.y + header, r.h - header, item.offset, item.page, #rows)
        elseif node.kind == "tree" then
            local rows = ui.entries(node)
            local ground = node.disabled and styles.face_dim or styles.field
            for row = 0, r.h - 1 do
                local index = item.offset + row + 1
                local line: any = rows[index]
                local y = r.y + row
                put(r.x, y, "", r.w - 1, ground)
                if line then
                    local parts = {}
                    local trail: any = line.trail or {}
                    for level = 1, #trail do
                        if level == #trail then parts[#parts + 1] = trail[level] and "├ " or "└ "
                        else parts[#parts + 1] = trail[level] and "│ " or "  " end
                    end
                    local columns = ui.tree_columns(line.depth)
                    local prefix = table.concat(parts)
                    put(r.x, y, prefix, math.min(r.w - 1, widgets.cells(prefix)), ground)
                    if line.has_children then
                        put(r.x + columns.expander, y, line.expanded and "-" or "+", 1, ground)
                    end
                    local glyph = line.kind == "folder" and (line.expanded and "▥" or "▤") or "▢"
                    put(r.x + columns.icon, y, glyph, 1, ground)
                    local label = tostring(line.label or "")
                    local style = not node.disabled and item.selected_index == index and styles.select or ground
                    put(r.x + columns.label, y, label, math.max(0, r.w - 1 - columns.label), style)
                end
            end
            scrollbar(r.x + r.w - 1, r.y, r.h, item.offset, item.page, #rows)
        elseif node.kind == "icons" then
            -- The icon with its caption is drawn by the shell's shared library — the same one as
            -- on the desktop and in the explorer. A copy of our own here would mean a third
            -- look of the same icon, diverging on two-line captions.
            local ground = node.disabled and styles.face_dim or styles.field
            for row = 0, r.h - 1 do
                put(r.x, r.y + row, "", r.w - 1, ground)
            end
            for _, cell in ipairs(item.cells or {}) do
                icon_cells.cell(canvas, cell.x, cell.y, cell.item,
                    {room = cell.room, surface = "panel", selected = cell.selected and not node.disabled})
            end
            scrollbar(r.x + r.w - 1, r.y, r.h, item.offset, item.page, item.rows_total)
        elseif node.kind == "list" then
            local ground = node.disabled and styles.face_dim or styles.field
            for row = 0, r.h - 1 do
                local index = item.offset + row + 1
                local value: any = (node.items or {})[index]
                local label = type(value) == "table" and value.text or value
                -- Text starts one cell in, as in a table and in pixels.
                put(r.x, r.y + row, label ~= nil and (" " .. tostring(label)) or "", r.w - 1,
                    not node.disabled and item.selected_index == index and styles.select or ground)
            end
            scrollbar(r.x + r.w - 1, r.y, r.h, item.offset, item.page, #(node.items or {}))
        else
            local label = tostring(node.text or "")
            local style = widgets.styles.face
            if node.kind == "label" and node.alert then style = widgets.styles.alert end
            if node.kind == "button" then
                -- The same button as in Run, the explorer and the chrome: edges, a black
                -- outline on default, reversed edges when pressed, dimmed when
                -- disabled. Our own "[ … ]" diverged from the rest of the shell.
                local armed = interaction.armed
                label = widgets.button(node.text, {
                    room = r.w,
                    default = ui.default_look(plan, node, focused),
                    pressed = node.pressed == true or (armed ~= nil and armed.id == node.id and armed.inside == true),
                    disabled = node.disabled and true or false,
                    focused = focused and not node.disabled,
                })
            elseif node.kind == "checkbox" then
                label = (node.checked and "[x] " or "[ ] ") .. label
                if focused then style = widgets.styles.select end
            elseif node.kind == "input" then
                local editing = interaction.editors[node.id]
                label = editor.visible(editor.shown(node), editing, r.w)
                style = focused and editing and editing.selected and widgets.styles.select or widgets.styles.field
            end
            if node.disabled and node.kind ~= "button" then style = widgets.styles.face_dim end
            -- A multi-line label (`\n`): lines in a row, the block centered in
            -- the rectangle; a single-line one sits in the middle row, as before.
            local lines: any = {}
            if node.kind == "label" and label:find("\n", 1, true) then
                local value: string = label .. "\n"
                for piece in string.gmatch(value, "(.-)\n") do lines[#lines + 1] = piece end
            end
            local first = #lines > 0 and math.max(0, (r.h - #lines) // 2) or r.h // 2
            for row = 0, r.h - 1 do
                if node.kind == "button" and row == r.h // 2 then
                    -- An already rendered string: `fit` would repaint the edges.
                    canvas:put(whole(r.x), whole(r.y + row), tostring(label), whole(r.w))
                elseif #lines > 0 then
                    put(r.x, r.y + row, lines[row - first + 1] or "", r.w, style)
                else put(r.x, r.y + row, row == r.h // 2 and label or "", r.w, style) end
            end
            if node.kind == "input" and focused then
                local editing = interaction.editors[node.id]
                if not (editing and editing.selected) then
                    local shown, caret = editor.visible(editor.shown(node), editing, r.w)
                    local chars = editor.runes(shown)
                    put(r.x + math.min(r.w - 1, caret), r.y + r.h // 2, chars[whole(caret + 1)] or " ", 1, widgets.styles.select)
                end
            end
        end
    end
    -- Open menus go on top of everything, hence after the rest.
    for _, item in ipairs(plan.overlays or {}) do
        local popup: any = item.popup
        local open: any = interaction.menus[item.node.id]
        local body = {}
        for position, row in ipairs(popup.rows) do
            local line: any = row
            local inner = popup.rect.w - 2
            if line.separator then body[#body + 1] = widgets.etched(inner)
            else
                local style = position == whole(open and open.cursor or 0) and styles.select
                    or (line.disabled and styles.face_dim or styles.face)
                local text = " " .. line.text
                local shown = line.accel > 0 and widgets.accel(style, text, line.accel + 1) or style:render(text)
                local pad = inner - widgets.cells(text)
                body[#body + 1] = shown .. style:render(string.rep(" ", math.max(0, pad)))
            end
        end
        widgets.panel(canvas, popup.rect.x, popup.rect.y, popup.rect.w, body, false)
    end
    return canvas:rows()
end
return cells
