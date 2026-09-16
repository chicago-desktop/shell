-- Generic renderer: registered once, shared by every declarative application.
local ui = require("ui")
local charts = require("charts")
local text_lib = require("text")
local geometry = require("geometry")
local editor = require("editor")
local pixels = require("pixels")
local images = require("images")
local bitmap = require("bitmap")
local gfx = require("gfx")
local widgets = require("widgets")
local palette = require("palette")
local whole = geometry.whole
local color = palette.exact
local render = {}
-- A copy of the interaction for laying out one frame. `ui.plan` clamps offsets,
-- moves the focus and forgets stale menus in the table it is given — writes
-- into the maps one level down — and the table the renderer receives is the
-- compositor's copy of the window state, kept between frames.
local function detached(interaction: any): any
    local copy: any = {}
    for key, value in pairs(interaction) do
        if type(value) == "table" then
            local inner: any = {}
            for name, item in pairs(value) do inner[name] = item end
            copy[key] = inner
        else
            copy[key] = value
        end
    end
    return copy
end
-- checked(window) -> the window's SDK state, or nil and why it cannot be laid
-- out. One gate for the whole raster and for the rows.
local function checked(window: any): (any, any)
    local state: any = window.content_state
    if type(state) ~= "table" or state.sdk ~= 1 then return nil, "SDK: state version 1 expected" end
    -- The shape is checked as a whole, not by the version alone: a state without
    -- `interaction` (a window that has not seen a single event yet, a foreign
    -- provider) crashed `ui.plan` on `interaction.menus` — and with it the
    -- frame of the whole shell. An empty interaction is enough for the layout.
    if type(state.ui) ~= "table" then return nil, "SDK: state.ui is not a component tree" end
    -- A tree that `ui.plan` will not lay out is reported with a reason instead of
    -- throwing: the error cannot be caught with `pcall` here (chrome_pixels, paint_view),
    -- and a thrown one would crash the frame of the whole shell.
    local problem = ui.problem(state.ui)
    if problem then return nil, "SDK: " .. tostring(problem) end
    return state, nil
end
-- laid_out(state, inner, cell) -> plan, interaction. The layout works on a
-- copy, so the compositor's interaction stays as the window published it.
local function laid_out(state: any, inner: any, cell: any): (any, any)
    local interaction = detached(type(state.interaction) == "table" and state.interaction or ui.interaction())
    local plan = ui.plan(state.ui, inner.cols, inner.rows, interaction, {scroll_cols = widgets.scroll_cols(cell.w), cell = cell})
    return plan, interaction
end
-- ceiling_caption(ceiling, unit) — a graph's ceiling label, "40 MB".
-- `+ 0.0`: an integer under %f prints "%!f(lua.LInteger=…)" in this runtime's
-- string.format. tonumber and math.max already return floats, so paint passes
-- none today; a literal or math.tointeger would.
function render.ceiling_caption(ceiling: number, unit: any): string
    return string.format("%.0f", ceiling + 0.0) .. tostring(unit or "")
end
-- menu_box(popup, cell) -> {x, y, w, h, first} — a menu's open list in pixels:
-- the panel's box and `first`, the top of the first item row. A pixel plan
-- (`lead` 0, ui.popup) has no frame rows: the panel is the item rows, its top
-- pixel row the one under the bar — the classic drop-down touches the bar.
-- A cells plan (`lead` 1) keeps its frame rows, and the panel is drawn tight
-- around the items, 4 px into them: a whole frame row is a couple dozen
-- pixels of emptiness no classic menu had.
-- A drop-down's frame: a 2 px raised edge and 1 px of face on every side.
render.MENU_FRAME = 3
function render.menu_box(popup: any, cell: any): any
    local lead = whole(popup.lead or 0)
    local px, py = (popup.rect.x - 1) * cell.w + 1, (popup.rect.y - 1) * cell.h + 1
    local first = py + lead * cell.h
    local pad = lead > 0 and 4 or 0
    return {x = px, y = first - pad, w = popup.rect.w * cell.w, h = #popup.rows * cell.h + pad * 2, first = first}
end
-- paint(raster, plan, interaction, cell, fonts) — the whole client into `raster`.
local function paint(raster: any, plan: any, interaction: any, cell: any, fonts: any)
    do
        raster:fill(color.face)
        local font = fonts and fonts.face
        local function text(x: any, y: any, w: any, h: any, value: any, tint: any?)
            if not font or w < 1 or h < 1 then return end
            raster:text(whole(x), whole(y + math.max(0, (h - 15) // 2)), pixels.ellipsize(font, tostring(value or ""), whole(w)),
                {font = font, color = tint or color.face_text})
        end
        local function strip(item: any, x: any, y: any, current: any, opened: any)
            for _, span in ipairs(item.spans or {}) do
                local sx, sw = x + span.x * cell.w, span.w * cell.w
                if item.node.kind == "tabs" then
                    -- A tab, not a button: light on the left and top with a beveled
                    -- corner, shadow and black on the right, no edge at the bottom — the tab
                    -- stands on the page frame. The active one is two pixels higher
                    -- and merges with the page.
                    local active = span.index == current
                    local lift = active and 0 or 2
                    local tx, ty, tw, th = whole(sx), whole(y + lift), whole(sw), whole(cell.h - lift + (active and 1 or 0))
                    raster:rect(tx, ty, tw, th, color.face)
                    raster:rect(tx, ty + 2, 1, th - 2, color.light)
                    raster:rect(tx + 1, ty + 1, 1, 1, color.light)
                    raster:rect(tx + 2, ty, tw - 4, 1, color.light)
                    raster:rect(tx + tw - 2, ty + 1, 1, 1, color.frame)
                    raster:rect(tx + tw - 2, ty + 2, 1, th - 2, color.shadow)
                    raster:rect(tx + tw - 1, ty + 2, 1, th - 2, color.frame)
                    pixels.label(raster, tx, ty, tw, th - (active and 1 or 0), span.title, font, color.face_text)
                    if font and span.accel > 0 then
                        local runes: any = text_lib.runes(span.title)
                        if runes[span.accel] then
                            local before = whole(font:measure(table.concat(runes, "", 1, span.accel - 1)))
                            local left = tx + (tw - whole(font:measure(span.title))) // 2
                            raster:rect(whole(left + before), whole(ty + (th - (active and 1 or 0) - whole(font:height())) // 2 + whole(font:height()) - 2),
                                math.max(1, whole(font:measure(runes[span.accel]))), 1, color.face_text)
                        end
                    end
                else
                    -- A menu title is centered in its cells, the highlight is
                    -- six pixels wider than the text on each side, as in the
                    -- original; the title's cells are wider than the text because
                    -- hits are counted in cells, without the font.
                    local pressed = span.index == opened
                    if font then
                        local runes: any = text_lib.runes(span.title)
                        local tint = pressed and color.select_fg or color.face_text
                        local measured = whole(font:measure(span.title))
                        local tx = sx + (sw - measured) // 2
                        if pressed then raster:rect(whole(tx - 6), whole(y), whole(measured + 12), whole(cell.h), color.select_bg) end
                        raster:text(whole(tx), whole(y + (cell.h - 15) // 2), span.title, {font = font, color = tint})
                        if span.accel > 0 and runes[span.accel] then
                            local before = whole(font:measure(table.concat(runes, "", 1, span.accel - 1)))
                            raster:rect(whole(tx + before), whole(y + (cell.h - 15) // 2 + 13),
                                math.max(1, whole(font:measure(runes[span.accel]))), 1, tint)
                        end
                    end
                end
            end
        end
        for _, item in ipairs(plan.items) do
            local node, rect = item.node, item.rect
            local x, y = (rect.x - 1) * cell.w + 1, (rect.y - 1) * cell.h + 1
            local w, h = rect.w * cell.w, rect.h * cell.h
            -- The scrollbar of a list, table, tree and icon grid takes the plan's
            -- columns (`item.bar_cols`, 16 px in whole cells), flush right. Its
            -- arrow buttons are square, as in the original, and never taller than
            -- one row, because the hit test counts an arrow as one row.
            local bar_w = whole(item.bar_cols or 1) * cell.w
            local focused = interaction.focus == node.id
            if node.kind == "calendar" then
                -- Calendar: weekdays, the month grid, today in blue.
                if font then
                    local names = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
                    local column = whole(w // 7)
                    local head_h = 18
                    local row_h = whole(math.max(1, (h - head_h) // 6))
                    for index, name in ipairs(names) do
                        local tw = whole(font:measure(name))
                        raster:text(whole(x + (index - 1) * column + (column - tw) // 2), whole(y + 1), name, {font = font, color = color.face_text})
                    end
                    raster:rect(whole(x), whole(y + head_h - 2), whole(column * 7), 1, color.shadow)
                    for row_index, row in ipairs(ui.month_grid(node.first_weekday, node.days)) do
                        for column_index = 1, 7 do
                            local day: any = row[column_index]
                            if day then
                                local label = tostring(day)
                                local tw = whole(font:measure(label))
                                local cx = x + (column_index - 1) * column
                                local cy = y + head_h + (row_index - 1) * row_h
                                local today = whole(day) == whole(node.day)
                                if today then raster:rect(whole(cx), whole(cy), whole(column), whole(row_h), color.select_bg) end
                                raster:text(whole(cx + (column - tw) // 2), whole(cy + (row_h - 15) // 2), label,
                                    {font = font, color = today and color.select_fg or color.face_text})
                            end
                        end
                    end
                end
            elseif node.kind == "clock" then
                -- The classic "Date/Time" clock, following the original's pixels:
                -- the dial sits on the face with no white field; sixty marks around
                -- the circle — minute marks are raised 3×3 dots (shadow top-left,
                -- light bottom-right), hour marks are teal with a black shadow;
                -- the hands are tapering teal wedges with a white highlight and
                -- a gray shadow, the second hand is thin and gray, with a red
                -- dot in the center.
                local side = whole(math.min(w, h))
                local left, top = whole(x + (w - side) // 2), whole(y + (h - side) // 2)
                local cx, cy = left + side // 2, top + side // 2
                local radius = side // 2 - 4
                local teal, cyan = "#008080", "#00ffff"
                local function at(angle: any, distance: any): (integer, integer)
                    local radians = math.rad(tonumber(angle) or 0)
                    return whole(cx + math.floor(math.sin(radians) * distance + 0.5)),
                        whole(cy - math.floor(math.cos(radians) * distance + 0.5))
                end
                for tick = 0, 59 do
                    local px, py = at(tick * 6, radius)
                    if tick % 5 == 0 then
                        raster:rect(px - 1, py - 1, 3, 3, color.frame)
                        raster:rect(px - 1, py - 1, 2, 1, cyan)
                        raster:set(px - 1, py, cyan)
                        raster:set(px, py, teal)
                    else
                        raster:rect(px - 1, py - 1, 2, 1, color.shadow)
                        raster:set(px - 1, py, color.shadow)
                        raster:set(px + 1, py, color.light)
                        raster:rect(px, py + 1, 2, 1, color.light)
                    end
                end
                -- A convex polygon, row by row: a hand's wedge is the tip,
                -- two shoulders at the base and a short tail past the center.
                local function polygon(points: any, tint: any)
                    local lowest, highest = math.huge, -math.huge
                    for _, point in ipairs(points) do
                        local py: number = tonumber(point[2]) or 0
                        lowest = math.min(lowest, py); highest = math.max(highest, py)
                    end
                    for row = whole(lowest), whole(highest) do
                        local from, to = math.huge, -math.huge
                        for index, a in ipairs(points) do
                            local b = points[index % #points + 1]
                            local ax: number, ay: number = tonumber(a[1]) or 0, tonumber(a[2]) or 0
                            local bx: number, by: number = tonumber(b[1]) or 0, tonumber(b[2]) or 0
                            if (row >= math.min(ay, by)) and (row <= math.max(ay, by)) and ay ~= by then
                                local t = (row - ay) / (by - ay)
                                local px: number = ax + (bx - ax) * t
                                from = math.min(from, px); to = math.max(to, px)
                            elseif ay == by and row == ay then
                                from = math.min(from, ax, bx); to = math.max(to, ax, bx)
                            end
                        end
                        if from <= to then
                            raster:rect(whole(math.floor(from + 0.5)), row, whole(math.floor(to + 0.5)) - whole(math.floor(from + 0.5)) + 1, 1, tint)
                        end
                    end
                end
                local function hand(angle: any, length: any, half: any)
                    local radians = math.rad(tonumber(angle) or 0)
                    local dx, dy = math.sin(radians), -math.cos(radians)
                    local nx, ny = -dy, dx
                    local reach = whole(length)
                    local function shape(shift_x: any, shift_y: any, narrow: any): any
                        local wide = math.max(1, whole(half) - whole(narrow))
                        return {
                            {cx + dx * reach + shift_x, cy + dy * reach + shift_y},
                            {cx + dx * reach * 0.12 + nx * wide + shift_x, cy + dy * reach * 0.12 + ny * wide + shift_y},
                            {cx - dx * 7 + shift_x, cy - dy * 7 + shift_y},
                            {cx + dx * reach * 0.12 - nx * wide + shift_x, cy + dy * reach * 0.12 - ny * wide + shift_y},
                        }
                    end
                    polygon(shape(2, 2, 0), color.shadow)
                    polygon(shape(-1, -1, 0), color.light)
                    polygon(shape(0, 0, 1), teal)
                end
                local hour, minute, second = whole(node.hour) % 12, whole(node.minute), whole(node.second)
                hand(hour * 30 + minute / 2, radius * 0.55, 5)
                hand(minute * 6 + second / 10, radius * 0.85, 4)
                local function line(x0: any, y0: any, x1: any, y1: any, tint: any)
                    local ax, ay, bx, by = whole(x0), whole(y0), whole(x1), whole(y1)
                    local ddx, ddy = math.abs(bx - ax), -math.abs(by - ay)
                    local sx, sy = ax < bx and 1 or -1, ay < by and 1 or -1
                    local err = ddx + ddy
                    while true do
                        raster:set(ax, ay, tint)
                        if ax == bx and ay == by then break end
                        local twice = err * 2
                        if twice >= ddy then err = err + ddy; ax = ax + sx end
                        if twice <= ddx then err = err + ddx; ay = ay + sy end
                    end
                end
                local sx2, sy2 = at(second * 6, radius * 0.9)
                line(cx, cy, sx2, sy2, color.shadow)
                raster:rect(cx - 1, cy - 1, 3, 2, "#ff0000")
            elseif node.kind == "tree" then
                -- A tree, as in regedit: dotted ancestor lines, plus/minus boxes,
                -- folder and entry icons, selection on the caption only.
                local rows = ui.entries(node)
                -- A disabled one uses the face color and gray text, with no selection, like
                -- a disabled input field: otherwise it looks working and stays silent.
                raster:rect(whole(x), whole(y), whole(w), whole(h), node.disabled and color.face or color.field)
                local function dotted_v(px: any, from: any, to: any)
                    for py = whole(from), whole(to), 2 do raster:rect(whole(px), py, 1, 1, color.shadow) end
                end
                local function dotted_h(from: any, to: any, py: any)
                    for px = whole(from), whole(to), 2 do raster:rect(px, whole(py), 1, 1, color.shadow) end
                end
                for row = 0, rect.h - 1 do
                    local index = item.offset + row + 1
                    local line: any = rows[index]
                    if not line then break end
                    local top = y + row * cell.h
                    local mid_y = top + cell.h // 2
                    local columns = ui.tree_columns(line.depth)
                    local exp_x = x + columns.expander * cell.w
                    local mid_x = exp_x + cell.w // 2
                    local trail: any = line.trail or {}
                    for level, more in ipairs(trail) do
                        local lx = x + (level - 1) * 2 * cell.w + cell.w // 2
                        if level == #trail then
                            dotted_v(lx, top, more and top + cell.h - 1 or mid_y)
                            dotted_h(lx, mid_x - 5, mid_y)
                        elseif more then dotted_v(lx, top, top + cell.h - 1) end
                    end
                    if line.has_children then
                        raster:rect(whole(mid_x - 4), whole(mid_y - 4), 9, 9, color.field)
                        pixels.edge(raster, whole(mid_x - 4), whole(mid_y - 4), 9, 9, false)
                        raster:rect(whole(mid_x - 2), whole(mid_y), 5, 1, color.face_text)
                        if not line.expanded then raster:rect(whole(mid_x), whole(mid_y - 2), 1, 5, color.face_text) end
                        if line.expanded then dotted_v(mid_x, mid_y + 5, top + cell.h - 1) end
                    end
                    local icon_x = x + columns.icon * cell.w
                    if line.kind == "folder" then
                        pixels.icon(raster, whole(icon_x), whole(mid_y - 8), {kind = "folder", image = line.expanded and "folder_open" or "folder"}, 16)
                    else
                        pixels.icon(raster, whole(icon_x), whole(mid_y - 8), {kind = "document", image = line.image or "document"}, 16)
                    end
                    if font then
                        local label_x = x + columns.label * cell.w
                        local room = x + w - bar_w - label_x - 4
                        local caption = pixels.ellipsize(font, tostring(line.label or ""), whole(math.max(0, room)))
                        local selected = not node.disabled and item.selected_index == index
                        if selected then raster:rect(whole(label_x - 2), whole(top + 2), whole(font:measure(caption)) + 4, whole(cell.h - 4), color.select_bg) end
                        raster:text(whole(label_x), whole(top + (cell.h - 15) // 2), caption,
                            {font = font, color = selected and color.select_fg or (node.disabled and color.shadow or color.field_text)})
                    end
                end
                pixels.scrollbar(raster, x + w - bar_w, y, bar_w, h, item.bar, cell.h, math.min(bar_w, cell.h))
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "group" and node.style == "sunken" then
                -- A sunken pane — the Welcome tip's: a background of its own
                -- inside a field's double bevel, and no title. It is drawn
                -- before its children, and they paint only their text and
                -- pictures, so the background shows between them.
                raster:rect(whole(x), whole(y), whole(w), whole(h), ui.pane_color(node.background) or color.field)
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "group" then
                -- A frame with a title: the edge is half a row lower so that the caption
                -- sits on it, as in classic dialogs.
                local ty = y + (cell.h - 15) // 2
                pixels.etched(raster, whole(x), whole(y + cell.h // 2), whole(w), whole(h - cell.h // 2))
                if font then
                    local title = tostring(node.title or "")
                    local tw = whole(font:measure(title))
                    -- The title 9 px in from the frame's edge, on two pixels of
                    -- face either side, as in the original.
                    raster:rect(whole(x + 7), whole(y), whole(math.min(w - 14, tw + 4)), whole(cell.h), color.face)
                    raster:text(whole(x + 9), whole(ty), title, {font = font, color = node.disabled and color.shadow or color.face_text})
                end
            elseif node.kind == "graph" then
                pixels.field(raster, whole(x), whole(y), whole(w), whole(h))
                local gx, gy, gw, gh = x + 2, y + 2, w - 4, h - 4
                if gw > 4 and gh > 4 then
                    raster:rect(whole(gx), whole(gy), whole(gw), whole(gh), "#000000")
                    for line_x = gx + 16, gx + gw - 1, 16 do raster:rect(whole(line_x), whole(gy), 1, whole(gh), "#004400") end
                    for line_y = gy + 12, gy + gh - 1, 12 do raster:rect(whole(gx), whole(line_y), whole(gw), 1, "#004400") end
                    local values: any = node.values or {}
                    local ceiling = tonumber(node.ceiling) or 0
                    if ceiling <= 0 then ceiling = charts.ceiling_of(values) end
                    local count = math.min(#values, math.max(1, gw // 3))
                    local previous: any = nil
                    for index = 1, count do
                        local n = tonumber(values[#values - count + index]) or 0
                        local px = gx + gw - (count - index) * 3 - 1
                        local py = gy + gh - 1 - whole(math.floor(math.min(1, n / ceiling) * (gh - 1)))
                        if previous then
                            for step = 0, px - previous.x do
                                local at = previous.y + whole(math.floor((py - previous.y) * step / math.max(1, px - previous.x)))
                                raster:rect(whole(previous.x + step), whole(at), 1, 1, "#00ff00")
                            end
                        end
                        raster:rect(whole(px), whole(py), 1, 1, "#00ff00")
                        previous = {x = px, y = py}
                    end
                    if font then
                        local cap = render.ceiling_caption(ceiling, node.unit)
                        local lw = math.min(gw - 4, whole(font:measure(cap)) + 4)
                        raster:rect(whole(gx + 2), whole(gy + 2), whole(lw), whole(math.min(16, gh)), "#000000")
                        raster:text(whole(gx + 4), whole(gy + 2), cap, {font = font, color = "#00ff00"})
                    end
                end
            elseif node.kind == "gauge" and node.orient == "horizontal" then
                -- The classic progress bar: up to 18 px centred in its rows,
                -- a one-pixel sunken edge on the face, and navy blocks 8 px
                -- wide 2 px apart — the filled share of the blocks that fit
                -- (`ui.gauge_filled`, the cells' rule too). No caption.
                local bh = whole(math.min(18, h))
                local by = whole(y + (h - bh) // 2)
                raster:rect(whole(x), by, whole(w), bh, color.face)
                pixels.bevel(raster, whole(x), by, whole(w), bh, false)
                local ix, iy, iw, ih = whole(x + 2), by + 2, whole(w - 4), bh - 4
                if iw >= 8 and ih >= 1 then
                    for block = 1, ui.gauge_filled(node, (iw + 2) // 10) do
                        raster:rect(ix + (block - 1) * 10, iy, 8, ih, color.select_bg)
                    end
                end
            elseif node.kind == "gauge" then
                pixels.field(raster, whole(x), whole(y), whole(w), whole(h))
                local gx, gy, gw, gh = x + 2, y + 2, w - 4, h - 4
                if gw > 8 and gh > 12 then
                    raster:rect(whole(gx), whole(gy), whole(gw), whole(gh), "#000000")
                    local count = math.max(0, (gh - 23) // 5)
                    local top = tonumber(node.ceiling) or 0
                    if top <= 0 then top = 1 end
                    local lit = whole(math.floor(math.min(1, (tonumber(node.value) or 0) / top) * count + 0.5))
                    for index = 1, count do
                        local tint = index <= lit and "#00ff00" or "#004400"
                        raster:rect(whole(gx + 5), whole(gy + gh - 21 - index * 5), whole(math.max(1, gw // 2 - 6)), 3, tint)
                        raster:rect(whole(gx + gw // 2 + 1), whole(gy + gh - 21 - index * 5), whole(math.max(1, gw // 2 - 6)), 3, tint)
                    end
                    if font then
                        local caption = pixels.ellipsize(font, tostring(node.caption or node.value or ""), whole(gw - 6))
                        local cw = whole(font:measure(caption))
                        raster:text(whole(gx + gw - 3 - cw), whole(gy + gh - 18), caption, {font = font, color = "#00ff00"})
                    end
                end
            elseif node.kind == "field" then
                -- A read-only field: up to 26 px centered in its rows, the text
                -- vertically centered with a margin from the edges. `face = true` means a face-colored
                -- background, not white: the calculator's memory box, an empty field.
                local fh = math.min(whole(h), 26)
                local fy = y + (h - fh) // 2
                pixels.field(raster, whole(x), whole(fy), whole(w), whole(fh))
                if node.face then raster:rect(whole(x + 2), whole(fy + 2), whole(w - 4), whole(fh - 4), color.face) end
                if font then
                    local shown = pixels.ellipsize(font, tostring(node.text or ""), whole(math.max(0, w - 12)))
                    local tx = x + 6
                    if node.align == "right" then tx = x + w - 6 - whole(font:measure(shown)) end
                    raster:text(whole(tx), whole(fy + (fh - whole(font:height())) // 2), shown,
                        {font = font, color = node.face and color.face_text or color.field_text})
                end
            elseif node.kind == "monitor" then
                -- The monitor from "Display Properties": a gray case with a raised edge,
                -- the screen in `color` (the desktop), a stand at the bottom. Proportions
                -- are 4:3 by the smaller side, centered in its rectangle.
                -- The case is 8 px around the screen and the stand 8 px below it — taken from
                -- the height, and the width follows from it at 4:3.
                local screen_h = whole(math.min(h - 26, (w - 24) * 3 // 4))
                local screen_w = whole(screen_h * 4 // 3)
                if screen_w >= 24 and screen_h >= 18 then
                    local body_w, body_h = screen_w + 16, screen_h + 16
                    local left = whole(x + (w - body_w) // 2)
                    local top = whole(y + (h - body_h - 8) // 2)
                    pixels.panel(raster, left, top, body_w, body_h)
                    pixels.edge(raster, left + 6, top + 6, screen_w + 4, screen_h + 4, false)
                    raster:rect(left + 8, top + 8, screen_w, screen_h, tostring(node.color or color.desktop))
                    -- `pattern`: eight bit rows, high bit on the left, a set bit
                    -- black over the desktop color — the desktop as it will be.
                    local tile: any = node.pattern
                    if type(tile) == "table" and #tile == 8 then
                        for py = 0, screen_h - 1 do
                            local byte = whole(tile[py % 8 + 1])
                            for px = 0, screen_w - 1 do
                                if (byte >> (7 - px % 8)) & 1 == 1 then raster:set(left + 8 + px, top + 8 + py, "#000000") end
                            end
                        end
                    end
                    -- `wallpaper` (a file of the wallpaper folder) and
                    -- `wallpaper_mode`: the picture over the screen at 1:1 —
                    -- tiled, or centred and cut by the screen's edges (gfx has
                    -- no scaling, so a large picture shows its middle).
                    local found: any = type(node.wallpaper) == "string" and images.wallpaper(node.wallpaper) or nil
                    if found then
                        local picture = found :: gfx.Raster
                        local iw, ih = picture:size()
                        local screen = gfx.raster(screen_w, screen_h)
                        screen:fill(tostring(node.color or color.desktop))
                        if node.wallpaper_mode == "tile" then
                            for ty = 1, screen_h, ih do
                                for tx = 1, screen_w, iw do screen:blit(picture, tx, ty) end
                            end
                        else
                            screen:blit(picture, (screen_w - iw) // 2 + 1, (screen_h - ih) // 2 + 1)
                        end
                        raster:blit(screen, left + 8, top + 8)
                    end
                    -- Power indicator and stand.
                    raster:rect(left + body_w - 12, top + body_h - 5, 4, 2, "#00c000")
                    pixels.panel(raster, left + body_w // 2 - 12, top + body_h, 24, 4)
                    pixels.panel(raster, left + body_w // 2 - 24, top + body_h + 4, 48, 4)
                end
            elseif node.kind == "image" then
                local side = whole(node.size_px or 32)
                if w >= side and h >= side then
                    pixels.icon(raster, whole(x + (w - side) // 2), whole(y + (h - side) // 2),
                        {kind = node.icon_kind or "program", image = node.image}, side)
                end
            elseif node.kind == "picture" then
                -- A pack's `pictures/<file>.png` at 1:1, left-aligned at the
                -- rect's top, never scaled, and never past the rect: a larger
                -- picture is cut to it (gfx blits whole rasters, so the cut is
                -- a raster of the rect's size). A picture that is not there, or
                -- does not decode, is its `text` in bold — never a hole.
                local found: any = node.png ~= nil and bitmap.source(node.png) or (type(node.image) == "string" and images.picture(node.image) or nil)
                if found then
                    local picture = found :: gfx.Raster
                    local pw, ph = picture:size()
                    if node.fit == "contain" and w > 0 and h > 0 then
                        local scale = math.min(w/pw,h/ph)
                        local sw,sh = whole(math.max(1,math.floor(pw*scale))),whole(math.max(1,math.floor(ph*scale)))
                        if sw ~= pw or sh ~= ph then picture = picture:scaled(sw,sh,{smooth = scale < 1}) end
                        raster:rect(whole(x),whole(y),whole(w),whole(h),node.background or color.face)
                        x,y = x+(w-sw)//2,y+(h-sh)//2
                        pw,ph = sw,sh
                    end
                    -- `align = "center"`: across the rect's width, when it is
                    -- narrower than the rect — the Welcome illustration under
                    -- its text. A wider picture is cut from the left as before.
                    if node.align == "center" and node.fit ~= "contain" and pw < w then
                        x = x + (w - pw) // 2
                        w = w - (w - pw) // 2
                    end
                    local cut_w, cut_h = whole(math.min(pw, w)), whole(math.min(ph, h))
                    if cut_w == pw and cut_h == ph then
                        raster:blit(picture, whole(x), whole(y))
                    elseif cut_w >= 1 and cut_h >= 1 then
                        local cut = gfx.raster(cut_w, cut_h)
                        cut:fill(color.face)
                        cut:blit(picture, 1, 1)
                        raster:blit(cut, whole(x), whole(y))
                    end
                else
                    local bold: any = fonts and (fonts.bold or fonts.face) or nil
                    if bold and w >= 1 and h >= 1 then
                        local line = whole(math.min(h, cell.h))
                        raster:text(whole(x), whole(y + math.max(0, (line - 15) // 2)),
                            pixels.ellipsize(bold, tostring(node.text or ""), whole(w)), {font = bold, color = color.face_text})
                    end
                end
            elseif node.kind == "spectrum" then
                -- The palette's spectrum bar: a sunken box up to 15 px in its
                -- rows, the hue sweeping left to right (`ui.spectrum_color`).
                local bh = whole(math.min(15, h))
                local by = whole(y + (h - bh) // 2)
                pixels.edge(raster, whole(x), by, whole(w), bh, false)
                local inner = whole(w - 4)
                for column = 0, inner - 1 do
                    raster:rect(whole(x + 2 + column), by + 2, 1, whole(math.max(1, bh - 4)),
                        ui.spectrum_color(column / math.max(1, inner - 1)))
                end
            elseif node.kind == "slider" then
                -- A trackbar: a sunken 4 px track and an 11 px raised thumb at
                -- the value, as in the original.
                local low, high = whole(node.min or 0), whole(node.max or 0)
                local value = whole(math.max(low, math.min(high, whole(node.value or low))))
                local cy = whole(y + h // 2)
                pixels.edge(raster, whole(x + 5), cy - 2, whole(math.max(4, w - 10)), 4, false)
                local th = whole(math.min(21, h))
                local travel = whole(math.max(0, w - 10 - 11))
                local tx = whole(x + 5 + (high > low and (value - low) * travel // (high - low) or 0))
                pixels.button(raster, tx, whole(y + (h - th) // 2), 11, th, {disabled = node.disabled == true}, cell)
                if focused and not node.disabled then pixels.focus_rect(raster, whole(x + 1), whole(y + 1), whole(w - 2), whole(h - 2)) end
            elseif node.kind == "statusbar" then
                -- Sunken fields in one row, as in the explorer: the last one
                -- stretches, the others have their own width or fit the text.
                -- A field's width is declared in cells — converted to pixels here.
                local fields: any = {}
                for _, entry in ipairs(node.fields or {}) do
                    local field: any = type(entry) == "table" and entry or {text = tostring(entry)}
                    fields[#fields + 1] = {text = field.text, width = whole(field.width) > 0 and whole(field.width) * cell.w or 0}
                end
                pixels.statusbar(raster, x, y + h - cell.h, w, cell.h, fields, font)
            elseif node.kind == "tabs" then
                local frame = item.frame
                if frame and frame.h >= 1 then
                    local fy = (frame.y - 1) * cell.h + 1
                    pixels.panel(raster, whole(x), whole(fy), whole(frame.w * cell.w), whole(frame.h * cell.h))
                end
                strip(item, x, y, whole(node.active or 1), nil)
                -- A gap in the frame under the active tab: it merges with the page.
                for _, span in ipairs(item.spans or {}) do
                    if span.index == whole(node.active or 1) and frame then
                        raster:rect(whole(x + span.x * cell.w + 1), whole(y + cell.h), whole(span.w * cell.w - 2), 1, color.face)
                    end
                end
                if focused and font then
                    for _, span in ipairs(item.spans or {}) do
                        if span.index == whole(node.active or 1) then
                            pixels.focus_rect(raster, whole(x + span.x * cell.w + 3), whole(y + 3), whole(span.w * cell.w - 6), whole(cell.h - 5))
                        end
                    end
                end
            elseif node.kind == "menu" then
                local open: any = interaction.menus and interaction.menus[node.id] or nil
                strip(item, x, y, nil, open and open.index or nil)
            elseif node.kind == "table" then
                -- The same column layout as in cells; the header is raised
                -- buttons, numbers are pushed to the right edge by the font's width.
                local columns = ui.columns(node, rect.w - whole(item.bar_cols or 1))
                local rows = ui.entries(node)
                local header = whole(item.header)
                raster:rect(whole(x), whole(y), whole(w), whole(h), node.disabled and color.face or color.field)
                if header > 0 then
                    raster:rect(whole(x), whole(y), whole(w), whole(cell.h), color.face)
                    for _, column in ipairs(columns) do
                        local cx, cw = x + column.x * cell.w, column.w * cell.w + cell.w
                        if column.x + column.w >= rect.w - whole(item.bar_cols or 1) then cw = column.w * cell.w end
                        pixels.bevel(raster, whole(cx), whole(y), whole(cw), whole(cell.h), true)
                        text(cx + cell.w, y, cw - cell.w, cell.h, column.title)
                    end
                end
                for row = 0, rect.h - 1 - header do
                    local index = item.offset + row + 1
                    local record: any = rows[index]
                    local selected = not node.disabled and ui.is_selected(item, index)
                    local row_y = y + (row + header) * cell.h
                    if selected then raster:rect(whole(x), whole(row_y), whole(w - bar_w), whole(cell.h), color.select_bg) end
                    if record then
                        local values: any = type(record) == "table" and (record.cells or record) or {record}
                        for col, column in ipairs(columns) do
                            local raw: any = values[col]
                            local value = ui.cell_text(raw)
                            local cx, cw = x + column.x * cell.w, column.w * cell.w
                            local tint = selected and color.select_fg or (node.disabled and color.shadow or color.field_text)
                            -- A cell's `image`: a 16 px picture two pixels in,
                            -- the text 3 px after it (Explorer's Details). No
                            -- `image`, a `kind`: that kind's picture by the one
                            -- rule an icon's comes from (`images.name_for`) — a
                            -- folder row shows a folder with nothing named.
                            local inset = cell.w
                            local picture: any = nil
                            if type(raw) == "table" then picture = images.name_for({image = raw.image, kind = raw.kind}) end
                            if type(picture) == "string" and picture ~= "" and cw >= 16 + cell.w then
                                pixels.icon(raster, whole(cx + 2), whole(row_y + (cell.h - 16) // 2),
                                    {kind = raw.kind or "document", image = picture}, 16)
                                inset = 21
                            end
                            -- Text starts one cell in; a right-aligned value ends
                            -- one cell before its column's end — the rule of cells.
                            if column.align == "right" and font then
                                local shown = pixels.ellipsize(font, value, whole(math.max(0, cw - inset)))
                                local measured = whole(font:measure(shown))
                                text(cx + math.max(inset, cw - cell.w - measured), row_y, cw - cell.w, cell.h, shown, tint)
                            else text(cx + inset, row_y, cw - inset, cell.h, value, tint) end
                        end
                    end
                end
                pixels.scrollbar(raster, x + w - bar_w, y + header * cell.h, bar_w, h - header * cell.h, item.bar, cell.h,
                    math.min(bar_w, cell.h))
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "icons" then
                -- An icon grid in pixels: a real 32×32 raster from the package
                -- (`pixels.icon` falls back to primitives by itself), a two-line caption
                -- below it, and the blue rectangle HUGS the caption, not the
                -- column — that is exactly how the original shows where the name ends.
                raster:rect(whole(x), whole(y), whole(w), whole(h), node.disabled and color.face or color.field)
                local side = 32
                for _, spot in ipairs(item.cells or {}) do
                    local box: any = spot.box
                    local bx = x + (box.from - rect.x) * cell.w
                    local by = y + (box.top - rect.y) * cell.h
                    local bw = (box.to - box.from + 1) * cell.w
                    local caption = tostring((spot.item :: any).title or (spot.item :: any).text or "")
                    local chosen = spot.selected and not node.disabled
                    local ink = chosen and color.select_fg or (node.disabled and color.shadow or color.field_text)
                    if node.small == true or item.flow then
                        -- Small Icons: the 16 px picture two pixels in, the
                        -- caption 3 px after it on the same row, the band
                        -- hugging the caption as in the large grid.
                        pixels.icon(raster, whole(bx + 2), whole(by + (cell.h - 16) // 2), spot.item, 16)
                        if font then
                            local left, top = bx + 21, by + (cell.h - 15) // 2
                            local shown = pixels.ellipsize(font, caption, whole(math.max(0, bw - 23)))
                            local measured = whole(font:measure(shown))
                            if chosen then raster:rect(whole(left - 1), whole(top - 1), whole(measured + 2), 16, color.select_bg) end
                            raster:text(whole(left), whole(top), shown, {font = font, color = ink})
                        end
                    else
                        pixels.icon(raster, whole(bx + (bw - side) // 2), whole(by + 2), spot.item, side)
                        local lines = pixels.wrap(font, caption, whole(bw - 4), 2)
                        local top = by + 2 + side + 3
                        for line_index, line in ipairs(lines) do
                            local measured = font and whole(font:measure(line)) or 0
                            local left = bx + (bw - measured) // 2
                            if chosen then
                                raster:rect(whole(left - 1), whole(top - 1), whole(measured + 2), 16, color.select_bg)
                            end
                            raster:text(whole(left), whole(top), line, {font = font, color = ink})
                            top = top + 15
                            if line_index >= 2 then break end
                        end
                    end
                end
                if item.flow then
                    -- The List view scrolls sideways: its bar is the last
                    -- row, as the editor's, and only when the columns do not fit.
                    if item.hbar then
                        pixels.hscrollbar(raster, x, y + (rect.h - 1) * cell.h, w, cell.h, item.hbar, cell.w, cell.w)
                    end
                else
                    pixels.scrollbar(raster, x + w - bar_w, y, bar_w, h, item.bar, cell.h, math.min(bar_w, cell.h))
                end
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "editor" then
                -- The multi-line editor: white under a sunken edge, the plan's
                -- rows in the fixed-pitch face, a rune in each 8-px column
                -- (`ui.MONO_PX`) from 4 px in, the selection a navy band per
                -- row, the caret a 1-px bar as the field's; the bars last, over
                -- whatever runs past the text.
                local mono: any = fonts and (fonts.mono or fonts.face)
                local text_h = whole(item.page) * cell.h
                local tx0 = x + ui.EDITOR_INSET
                raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
                for row_index, shown in ipairs(item.visible or {}) do
                    local line: any = shown
                    local ry = y + (row_index - 1) * cell.h
                    for _, glyph in ipairs(line.glyphs) do
                        local from = whole(math.max(0, whole(glyph.x)))
                        local gx = tx0 + from * ui.MONO_PX
                        if glyph.selected then
                            raster:rect(whole(gx), whole(ry + (cell.h - 16) // 2), whole((whole(glyph.x) + whole(glyph.w) - from) * ui.MONO_PX),
                                16, color.select_bg)
                        end
                        if mono and glyph.char ~= "\t" then
                            raster:text(whole(gx), whole(ry + (cell.h - 15) // 2), glyph.char,
                                {font = mono, color = glyph.selected and color.select_fg or color.field_text})
                        end
                    end
                    local caret: any = line.caret
                    if focused and not item.selecting and caret ~= nil and caret >= 0 and caret <= whole(item.columns) then
                        raster:rect(whole(tx0 + caret * ui.MONO_PX - 1), whole(ry + (cell.h - 15) // 2), 1, 15, color.field_text)
                    end
                end
                pixels.scrollbar(raster, x + w - bar_w, y, bar_w, text_h, item.bar, cell.h, math.min(bar_w, cell.h))
                if item.hbar then
                    pixels.hscrollbar(raster, x, y + text_h, w - bar_w, cell.h, item.hbar, cell.w, cell.w)
                    raster:rect(whole(x + w - bar_w), whole(y + text_h), whole(bar_w), whole(cell.h), color.face)
                end
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "text" then
                -- The plan's lines, the same ones cells draw: the font never
                -- re-wraps them, it only cuts what it does not fit.
                raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
                local lines: any = item.lines or {}
                for row = 0, rect.h - 1 do
                    local line: any = lines[item.offset + row + 1]
                    if line ~= nil then
                        text(x + cell.w, y + row * cell.h, w - cell.w - bar_w, cell.h, line, color.field_text)
                    end
                end
                pixels.scrollbar(raster, x + w - bar_w, y, bar_w, h, item.bar, cell.h, math.min(bar_w, cell.h))
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "list" then
                raster:rect(whole(x), whole(y), whole(w), whole(h), node.disabled and color.face or color.field)
                for row = 0, rect.h - 1 do
                    local index = item.offset + row + 1
                    local selected = not node.disabled and ui.is_selected(item, index)
                    local value: any = (node.items or {})[index]
                    local label = type(value) == "table" and value.text or value
                    local row_y = y + row * cell.h
                    if selected then raster:rect(whole(x), whole(row_y), whole(w - bar_w), whole(cell.h), color.select_bg) end
                    -- Text starts one cell in, as in a table and in cells.
                    text(x + cell.w, row_y, w - cell.w - bar_w, cell.h, label,
                        selected and color.select_fg or (node.disabled and color.shadow or color.field_text))
                end
                pixels.scrollbar(raster, x + w - bar_w, y, bar_w, h, item.bar, cell.h, math.min(bar_w, cell.h))
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "button" then
                -- A regular button is 23 px centered in its rows; `fill` means
                -- the whole rectangle minus `inset` on every side (this is how
                -- the calculator keys stand with a four-pixel gap).
                -- `bold` means a bold caption, like the original's keys.
                local pad = whole(node.inset)
                local bx, bw = x + pad, w - pad * 2
                -- A packed button (a dialog row): its classic width, placed
                -- by the plan inside its own cells.
                if item.px then bx, bw = item.px.x, item.px.w end
                local bh = node.fill and whole(h) - pad * 2 or math.min(23, whole(h))
                local by = node.fill and whole(y + pad) or whole(y + (h - bh) // 2)
                local armed = interaction.armed
                local face_font: any = (node.bold and fonts and fonts.bold) or font
                local pressed = node.pressed == true or (armed ~= nil and armed.id == node.id and armed.inside == true)
                -- `image` is a picture instead of the caption — the Minesweeper
                -- face. It comes from the icon catalog or an image pack
                -- (`images.get`, 16 px unless `image_px`); a picture that is not
                -- there, or does not fit, leaves the caption, which is also what
                -- cells show.
                local picture: any, pw, ph = nil, 0, 0
                if type(node.image) == "string" and node.image ~= "" then
                    local found: any = images.get(node.image, whole(node.image_px or 16))
                    if found then
                        local fw: any, fh: any = found:size()
                        if whole(fw) <= bw - 4 and whole(fh) <= bh - 4 then picture, pw, ph = found, whole(fw), whole(fh) end
                    end
                end
                pixels.button(raster, bx, by, bw, bh, {label = picture and "" or node.text, font = face_font,
                    default = ui.default_look(plan, node, focused), focused = focused, disabled = node.disabled,
                    pressed = pressed, color = node.ink}, cell)
                if picture then
                    local shift = pressed and 1 or 0
                    raster:blit(picture, whole(bx + (bw - pw) // 2 + shift), whole(by + (bh - ph) // 2 + shift))
                end
            elseif node.kind == "radio" then
                -- The classic radio button, 12×12: an outer ring shadow above
                -- and light below the diagonal, an inner ring black and face, a
                -- white well, a black dot when chosen; grey when disabled.
                local top = whole(y + (h - 12) // 2)
                if w >= 12 and h >= 12 then
                    for py = 0, 11 do
                        for px = 0, 11 do
                            local dx, dy = px - 5.5, py - 5.5
                            local d = math.sqrt(dx * dx + dy * dy)
                            local upper = px + py < 11
                            local ink: any = nil
                            if d < 6 and d >= 5 then ink = upper and color.shadow or color.light
                            elseif d < 5 and d >= 4 then ink = upper and color.frame or color.face
                            elseif d < 4 then
                                ink = node.disabled and color.face or color.field
                                if node.checked and d < 2 then ink = node.disabled and color.shadow or color.frame end
                            end
                            if ink then raster:set(whole(x + px), top + py, ink) end
                        end
                    end
                end
                text(x + 18, y, w - 18, h, node.text, node.disabled and color.shadow or color.face_text)
                if focused and not node.disabled and font and w >= 22 and h >= 17 then
                    local tw = math.min(whole(w - 18), whole(font:measure(tostring(node.text or ""))))
                    pixels.focus_rect(raster, whole(x + 16), whole(y + (h - 17) // 2), tw + 4, 17)
                end
            elseif node.kind == "checkbox" then
                local top = whole(y + (h - 13) // 2)
                if w >= 13 and h >= 13 then pixels.checkbox(raster, x, top, node.checked, node.disabled) end
                local tint = node.disabled and color.shadow or color.face_text
                text(x + 18, y, w - 18, h, node.text, tint)
                if focused and not node.disabled and font and w >= 22 and h >= 17 then
                    local tw = math.min(whole(w - 18), whole(font:measure(tostring(node.text or ""))))
                    pixels.focus_rect(raster, whole(x + 16), whole(y + (h - 17) // 2), tw + 4, 17)
                end
            elseif node.kind == "input" then
                -- An input field is up to 24 px centered in its rows: in a single row
                -- of cells the text would press against the edges, so give it two.
                local fh = math.min(24, whole(h))
                y, h = y + (h - fh) // 2, fh
                pixels.field(raster, whole(x), whole(y), whole(w), whole(h))
                if node.disabled then raster:rect(whole(x + 2), whole(y + 2), whole(w - 4), whole(h - 4), color.face) end
                local editing = interaction.editors[node.id]
                local shown, caret = editor.visible(editor.shown(node), editing, rect.w)
                if focused and editing and editing.selected then
                    raster:rect(whole(x + 3), whole(y + 2), whole(math.max(1, w - 6)), whole(math.max(1, h - 4)), color.select_bg)
                end
                -- The placeholder: grey while the value is empty and the field is
                -- not focused; drawn only, never edited or sent.
                local placeholder = ui.placeholder(node, focused)
                text(x + 4, y, w - 8, h, placeholder or shown, placeholder and color.shadow
                    or (focused and editing and editing.selected and color.select_fg or (node.disabled and color.shadow or color.field_text)))
                if focused and font and not (editing and editing.selected) then
                    local chars = editor.runes(shown)
                    local before = table.concat(chars, "", 1, whole(math.max(0, caret)))
                    local cx = math.min(whole(x + w - 3), whole(x + 4) + whole(font:measure(before)))
                    raster:rect(whole(cx), whole(y + math.max(2, (h - 15) // 2)), 1, whole(math.min(15, h - 4)), color.field_text)
                end
            elseif node.kind == "select" then
                -- A drop-down list: a field up to 24 px, like an input, with the
                -- classic arrow button inside its right edge and the chosen
                -- option's label, highlighted while focused.
                local fh = math.min(24, whole(h))
                y, h = y + (h - fh) // 2, fh
                pixels.field(raster, whole(x), whole(y), whole(w), whole(h))
                if node.disabled then raster:rect(whole(x + 2), whole(y + 2), whole(w - 4), whole(h - 4), color.face) end
                local bw = whole(math.min(16, w - 4))
                local bx = whole(x + w - 2 - bw)
                local open = interaction.menus ~= nil and interaction.menus[node.id] ~= nil
                pixels.button(raster, bx, whole(y + 2), bw, whole(h - 4), {pressed = open}, cell)
                pixels.mark_drop(raster, bx + (bw - 8) // 2, whole(y + 2 + (h - 4 - 8) // 2), 8,
                    node.disabled and color.shadow or color.face_text)
                local option: any = (node.options or {})[whole(item.current)]
                local caption = option and tostring(option.label or option.value or "") or ""
                local room = bx - x - 6
                local lit = focused and not node.disabled and caption ~= ""
                if lit then
                    raster:rect(whole(x + 3), whole(y + 3), whole(math.max(1, room)), whole(math.max(1, h - 6)), color.select_bg)
                end
                text(x + 4, y, room - 2, h, caption, lit and color.select_fg or (node.disabled and color.shadow or color.field_text))
            elseif node.kind == "label" and node.wrap == true then
                -- A wrapped label: words in lines of the label's width by the
                -- font, 15 px apart from the top, as many as its height holds;
                -- only the last line is cut with "…".
                local lines = pixels.wrap(font, tostring(node.text or ""), whole(w - 4), math.max(1, whole(h) // 15))
                for index, piece in ipairs(lines) do
                    text(x + 2, y + (index - 1) * 15, w - 4, 15, piece, node.alert and color.alert or nil)
                end
            elseif node.kind == "label" and tostring(node.text or ""):find("\n", 1, true) then
                -- A multi-line label: lines split by `\n`, a 15 px step — like
                -- the font's, not the cell's (20 px): two lines of a hint in
                -- neighboring cells read as two paragraphs.
                local lines: any = {}
                local value: string = tostring(node.text or "") .. "\n"
                for piece in string.gmatch(value, "(.-)\n") do lines[#lines + 1] = piece end
                local block = #lines * 15
                local top = y + math.max(0, (h - block) // 2)
                for index, piece in ipairs(lines) do
                    text(x + 2, top + (index - 1) * 15, w - 4, 15, piece, node.alert and color.alert or nil)
                end
            elseif node.kind == "label" and node.align == "center" and font then
                -- A centered label: the caption in the middle of its width by the font.
                local shown = pixels.ellipsize(font, tostring(node.text or ""), whole(math.max(0, w - 4)))
                local tw = whole(font:measure(shown))
                text(x + math.max(2, (w - tw) // 2), y, w - 4, h, shown, node.alert and color.alert or (node.disabled and color.shadow or nil))
            else text(x + 2, y, w - 4, h, node.text, node.alert and color.alert or (node.disabled and color.shadow or nil)) end
        end
    end
    -- Open menus go on top of everything, hence after the rest and in the same raster.
    do
        local font = fonts and fonts.face
        -- A select's open list: a white box with a black frame straight under
        -- (or over) the field, the cursor row in the selection colors.
        local menus: any = {}
        for _, item in ipairs(plan.overlays or {}) do
            if item.node.kind == "select" then
                local popup: any = item.popup
                local lx, ly = (popup.rect.x - 1) * cell.w + 1, (popup.rect.y - 1) * cell.h + 1
                local lw, lh = popup.rect.w * cell.w, popup.rect.h * cell.h
                raster:rect(whole(lx), whole(ly), whole(lw), whole(lh), color.frame)
                raster:rect(whole(lx + 1), whole(ly + 1), whole(lw - 2), whole(lh - 2), color.field)
                for position, row in ipairs(popup.rows) do
                    local line: any = row
                    local ry = ly + (position - 1) * cell.h
                    local chosen = line.index == popup.cursor
                    if chosen then raster:rect(whole(lx + 2), whole(ry + 1), whole(lw - 4), whole(cell.h - 2), color.select_bg) end
                    if font then
                        raster:text(whole(lx + 4), whole(ry + (cell.h - 15) // 2), pixels.ellipsize(font, line.text, whole(lw - 8)),
                            {font = font, color = chosen and color.select_fg or color.field_text})
                    end
                end
            else menus[#menus + 1] = item end
        end
        -- One drop-down list: the menu's and its open submenu's, by one rule.
        -- The rows are whole cells (hits are counted by them); the classic
        -- frame lies inside them. So each item has a BAND — its row, less
        -- the frame where the frame reaches into it (a pixel plan's first
        -- and last row) — and the highlight, the text and the marks are
        -- centred in the band, not in the row: otherwise the first item sat
        -- right under the bar and the last one on the bottom edge.
        local frame = render.MENU_FRAME
        local function drop(popup: any, cursor: any)
            local box = render.menu_box(popup, cell)
            raster:rect(whole(box.x), whole(box.y), whole(box.w), whole(box.h), color.face)
            pixels.frame_edge(raster, box.x, box.y, box.w, box.h)
            for position, row in ipairs(popup.rows) do
                local line: any = row
                local ry = box.first + (position - 1) * cell.h
                local top = whole(math.max(whole(ry), whole(box.y) + frame))
                local band = whole(math.min(whole(ry + cell.h), whole(box.y + box.h) - frame)) - top
                if line.separator then
                    -- Dark over light, 2 px in from the frame.
                    local inset = frame + 2
                    raster:rect(whole(box.x + inset), whole(top + band // 2 - 1), whole(box.w - 2 * inset), 1, color.shadow)
                    raster:rect(whole(box.x + inset), whole(top + band // 2), whole(box.w - 2 * inset), 1, color.light)
                elseif font then
                    local chosen = position == whole(cursor)
                    if chosen then
                        raster:rect(whole(box.x + frame), top, whole(box.w - 2 * frame), band, color.select_bg)
                    end
                    local tint = chosen and color.select_fg or (line.disabled and color.shadow or color.face_text)
                    local tx, ty = box.x + 2 * cell.w, top + (band - 15) // 2
                    raster:text(whole(tx), whole(ty), line.text, {font = font, color = tint})
                    -- The accelerator is an underlined letter, as on the bar.
                    local runes: any = text_lib.runes(line.text)
                    if line.accel > 0 and runes[line.accel] then
                        local before = whole(font:measure(table.concat(runes, "", 1, line.accel - 1)))
                        raster:rect(whole(tx + before), whole(ty + 13),
                            math.max(1, whole(font:measure(runes[line.accel]))), 1, tint)
                    end
                    -- The marks stand in the 8 px column before the text:
                    -- the 7 px check ends 4 px before it, the 6 px bullet too.
                    if line.checked then pixels.mark_check(raster, whole(tx - 11), whole(top + (band - 7) // 2), tint)
                    elseif line.bullet then pixels.mark_bullet(raster, whole(tx - 10), whole(top + (band - 6) // 2), tint) end
                    -- The shortcut ends where the text's cell of air begins
                    -- at the right, the mirror of the text's start.
                    local shortcut = tostring(line.shortcut or "")
                    if shortcut ~= "" then
                        raster:text(whole(box.x + box.w - 2 * cell.w - whole(font:measure(shortcut))), whole(ty), shortcut,
                            {font = font, color = tint})
                    end
                    if line.submenu then
                        pixels.mark_submenu(raster, whole(box.x + box.w - 12), whole(top + (band - 7) // 2), 7, tint)
                    end
                end
            end
        end
        for _, item in ipairs(menus) do
            local popup: any = item.popup
            local open: any = interaction.menus[item.node.id]
            drop(popup, open and open.cursor or 0)
            if popup.sub then drop(popup.sub, open and open.sub_cursor or 0) end
        end
    end
end
-- placement(window, inner, cell, fonts, store) -> the whole client as ONE
-- placement `win:<id>:sdk`. Snapshots and tools take the picture from here;
-- the compositor takes `rows`.
function render.placement(window: any, inner: any, cell: any, fonts: any, store: any): (any, any)
    local state, why = checked(window)
    if not state then return nil, why end
    local id = "win:" .. tostring(window.id) .. ":sdk"
    local raster, dirty = store.take(id, inner.cols, inner.rows, cell, tostring(window.state_revision or state.revision))
    -- The raster first: a clean one is reused as it is, and the tree is laid
    -- out only for a frame that is actually painted — before, every frame of
    -- the shell laid out every SDK window and threw the plan away.
    if dirty then
        local plan, interaction = laid_out(state, inner, cell)
        paint(raster, plan, interaction, cell, fonts)
    end
    return {id = id, raster = raster, x = inner.x, y = inner.y, cols = inner.cols, rows = inner.rows}, nil
end

-- ─── The client by rows ─────────────────────────────────────────────────
--
-- One raster for the whole client was re-rasterised AND re-sent whole on
-- every revision: a keypress in the registry editor, a Task Manager tick —
-- 500×300 px encoded again because the version moved, although one row
-- changed. So the compositor takes the client as ONE PLACEMENT PER ROW,
-- `win:<id>:sdk:row:<n>`, the chrome's rule: the surface re-sends a placement
-- only when its raster changed, and an unchanged row keeps its raster and
-- its version.
--
-- A row's key is a fingerprint of what that row draws: every plan item that
-- crosses it, with its node and its state (geometry, offsets, the scrollbar,
-- focus, a pressed button, an editor's caret, an open list), and the overlays
-- over it. Lists, tables and trees are fingerprinted per row — the entry in
-- that row and whether it is selected — so moving the selection repaints two
-- rows, not the list. The plan is built once per revision, as before; the
-- same revision in the next frame reuses the keys without a layout.
--
-- The pixels of a dirty row come from ONE full rasterisation, blitted row by
-- row: `paint` walks every item whatever the target, so painting row by row
-- would cost the whole walk once per dirty row. The full raster is a scratch
-- one, not the store's: the store sweeps what a frame did not place, and a
-- full raster taken but never placed would come back new and be repainted
-- every frame.
local memo: any = {}
local LINES: any = {list = true, table = true, tree = true}
-- sig(value, skip) — a stable text of plain data, keys sorted; `children`
-- is left out (a container's children are items of their own).
local function sig(value: any, skip: any?): string
    if type(value) ~= "table" then return type(value):sub(1, 1) .. tostring(value) end
    local keys: any = {}
    for key in pairs(value) do
        if key ~= "children" and not (skip ~= nil and skip[key]) then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a: any, b: any): boolean return tostring(a) < tostring(b) end)
    local parts = {}
    for _, key in ipairs(keys) do parts[#parts + 1] = tostring(key) .. "=" .. sig(value[key]) end
    return "{" .. table.concat(parts, ",") .. "}"
end
-- What an item draws on every row it crosses: its node (without the entries
-- of a list-like node, which are per row) and its state.
local function item_sig(item: any, plan: any, interaction: any): string
    local node: any = item.node
    local id = node.id
    -- The List view is keyed per row too (`cells_sig`): a selection move
    -- repaints the two rows it touches, not the whole view.
    local lines = LINES[node.kind] == true or (node.kind == "icons" and item.flow == true)
    local armed: any = interaction.armed
    local capture: any = interaction.capture
    local menus: any = interaction.menus or {}
    local editors: any = interaction.editors or {}
    return table.concat({
        -- A list-like node's entries and its `selected` are per row (`line_sig`):
        -- in the shared part they would repaint every row on a selection move.
        -- An editor's text is per row (`item.visible`); its node's `text` is
        -- only the first value and its document is drawn from the plan.
        sig(node, lines and {items = true, rows = true, selected = true} or (node.kind == "editor" and {text = true} or nil)),
        sig(item.rect),
        tostring(item.offset), tostring(item.header), lines and "" or tostring(item.selected_index),
        sig(item.bar), sig(item.px), tostring(item.current), tostring(item.bar_cols),
        sig(item.spans), sig(item.frame), sig(item.popup), lines and "" or sig(item.cells),
        sig(item.hbar), tostring(item.left), tostring(item.selecting),
        id ~= nil and interaction.focus == id and "F" or "",
        id ~= nil and armed ~= nil and armed.id == id and (armed.inside and "A" or "a") or "",
        id ~= nil and capture ~= nil and capture.id == id and "C" or "",
        (id ~= nil and node.kind ~= "editor") and sig(editors[id]) or "", id ~= nil and sig(menus[id]) or "",
        node.kind == "button" and tostring(plan.focus_on_button) or "",
        -- A picture's raster by identity: a file replaced in its pack is a new
        -- raster under the same node, and its rows must be painted again.
        node.kind == "picture" and tostring(node.png or (images.picture(node.image))) or "",
    }, ";")
end
-- The entry a list-like item draws in one row, and whether it is selected.
local function line_sig(item: any, row: integer): string
    local node: any, rect: any = item.node, item.rect
    local at = row - whole(rect.y) - whole(item.header)
    if at < 0 then return "header" end
    local index = whole(item.offset) + at + 1
    local entries: any = node.kind == "list" and (node.items or {}) or (node.rows or {})
    return tostring(index) .. ":" .. sig(entries[index]) .. (ui.is_selected(item, index) and ":selected" or "")
end
-- The cells the List view draws in one row, with their selection.
local function cells_sig(item: any, row: integer): string
    local parts: any = {}
    for _, cell in ipairs(item.cells or {}) do
        if whole(cell.y) == row then parts[#parts + 1] = sig(cell) end
    end
    return table.concat(parts, "|")
end
local function row_keys(plan: any, interaction: any, rows: integer, base: string): any
    local common: any = {}
    for index, item in ipairs(plan.items) do common[index] = item_sig(item, plan, interaction) end
    local keys: any = {}
    for row = 1, rows do
        local parts: any = {base}
        for index, item in ipairs(plan.items) do
            local r: any = item.rect
            local frame: any = item.frame
            if row >= r.y and row <= r.y + r.h - 1 then
                parts[#parts + 1] = common[index]
                if LINES[item.node.kind] then parts[#parts + 1] = line_sig(item, row)
                elseif item.flow then parts[#parts + 1] = cells_sig(item, row) end
                -- An editor's text row: its runes, their selection, the caret on it.
                if item.node.kind == "editor" then parts[#parts + 1] = sig((item.visible or {})[row - r.y + 1]) end
            elseif frame and row >= frame.y and row <= frame.y + frame.h - 1 then
                -- Tabs draw their page frame below their rect, which is the
                -- strip alone. The frame's top row holds the gap under the
                -- active tab and that tab's last pixel row, so it carries the
                -- whole item: keyed by the frame only, it kept the gap under
                -- the tab that was active before and the new one stood on the
                -- frame line. The other frame rows draw only its edges.
                parts[#parts + 1] = row == frame.y and common[index] or ("frame:" .. sig(frame))
            end
        end
        for _, item in ipairs(plan.overlays or {}) do
            local popup: any = item.popup
            local sub: any = popup and popup.sub or nil
            -- An open submenu may reach below its list: its rows are the overlay's too.
            if popup and ((row >= popup.rect.y and row <= popup.rect.y + popup.rect.h - 1)
                or (sub ~= nil and row >= sub.rect.y and row <= sub.rect.y + sub.rect.h - 1)) then
                parts[#parts + 1] = "over:" .. sig(popup) .. sig((interaction.menus or {})[item.node.id])
            end
        end
        keys[row] = table.concat(parts, "\30")
    end
    return keys
end
-- cut(spec) -> a placement per row, `<prefix><n>`, keyed by the rows' content.
--
-- The one mechanism behind a window's client (`rows`) and a tree drawn in
-- any rectangle (`tree_rows`, a desktop widget). The keys are built once per
-- revision; without a revision they are built every frame, and a row whose
-- content did not change is still not repainted. The pixels of the dirty rows
-- come from one full rasterisation. `spec.lay()` lays the tree out,
-- `spec.base` names what every row depends on beyond the plan, and
-- `spec.decorate(raster)` paints over the full raster after the tree — a
-- frame around it, in the same rows, never a placement of its own.
local function cut(spec: any): any
    local cell: any, store: any, fonts: any = spec.cell, spec.store, spec.fonts
    local cw, ch = math.max(1, whole(cell.w)), math.max(1, whole(cell.h))
    local cols, count = whole(spec.cols), whole(spec.rows)
    -- The font set by identity: `use_fonts` makes a new set when the fonts
    -- change, and the rows are repainted with them.
    local base = tostring(cols) .. "x" .. tostring(count) .. "@" .. cw .. "x" .. ch .. "|" .. tostring(fonts)
        .. tostring(spec.base or "")
    local revision: any = spec.revision
    local seen: any = revision ~= nil and memo[spec.memo] or nil
    local plan: any, interaction: any = nil, nil
    local keys: any
    if seen and seen.revision == revision and seen.base == base then
        keys = seen.keys
    else
        plan, interaction = spec.lay()
        keys = row_keys(plan, interaction, count, base)
        memo[spec.memo] = revision ~= nil and {revision = revision, base = base, keys = keys} or nil
    end
    local full: any = nil
    local out = {}
    for row = 1, count do
        local id = spec.prefix .. row
        local raster, dirty = store.take(id, cols, 1, cell, keys[row])
        if dirty then
            if full == nil then
                if plan == nil then plan, interaction = spec.lay() end
                full = gfx.raster(cols * cw, count * ch)
                paint(full, plan, interaction, cell, fonts)
                if spec.decorate ~= nil then spec.decorate(full) end
            end
            raster:blit(full, 1, 1 - (row - 1) * ch)
        end
        out[#out + 1] = {id = id, raster = raster, x = spec.x, y = spec.y + row - 1, cols = cols, rows = 1}
    end
    return out
end
-- rows(window, inner, cell, fonts, store) -> a placement per client row
function render.rows(window: any, inner: any, cell: any, fonts: any, store: any): (any, any)
    local state, why = checked(window)
    if not state then return nil, why end
    local placed = cut({memo = tostring(window.id), prefix = "win:" .. tostring(window.id) .. ":sdk:row:",
        x = inner.x, y = inner.y, cols = inner.cols, rows = inner.rows, cell = cell, fonts = fonts, store = store,
        revision = tostring(window.state_revision or state.revision), base = "",
        lay = function(): (any, any)
            local plan, interaction = laid_out(state, inner, cell)
            return plan, interaction
        end})
    return placed, nil
end
-- tree_rows(spec) -> a placement per row of a tree that takes no input, or
-- nil and why
--
-- A tree that is not a window's client — a desktop widget (FR-006 §7): the
-- row keys and the one rasterisation of `rows`, over any rectangle, with the
-- caller's frame painted into the same rows.
--   id        the placements are `<id>:row:<n>`; `forget(id)` drops the keys
--   tree      the component tree, laid out over the whole rectangle
--   x, y, cols, rows   the rectangle on the screen, in cells
--   cell, fonts, store as for `rows`
--   revision  optional: the keys are kept while it stands; without it the
--             tree is laid out every frame and still only changed rows repaint
--   key       what `decorate` draws, part of every row's key
--   decorate  optional function(raster) painting over the laid out tree
-- Nothing in the tree is drawn focused: it never gets an event.
function render.tree_rows(spec: any): (any, any)
    local tree: any = spec.tree
    if type(tree) ~= "table" then return nil, "SDK: not a component tree" end
    local problem = ui.problem(tree)
    if problem then return nil, "SDK: " .. tostring(problem) end
    local cell: any = spec.cell
    local cols, count = whole(spec.cols), whole(spec.rows)
    local function lay(): (any, any)
        local interaction = ui.interaction()
        local plan = ui.plan(tree, cols, count, interaction, {scroll_cols = widgets.scroll_cols(cell.w), cell = cell})
        interaction.focus = nil
        plan.focus_on_button = false
        return plan, interaction
    end
    local id = tostring(spec.id)
    local placed = cut({memo = id, prefix = id .. ":row:", x = spec.x, y = spec.y, cols = cols, rows = count,
        cell = cell, fonts = spec.fonts, store = spec.store,
        revision = spec.revision ~= nil and tostring(spec.revision) or nil,
        base = "|" .. tostring(spec.key or ""), lay = lay, decorate = spec.decorate})
    return placed, nil
end
-- forget(id) — the row keys of a closed window or of a widget that is gone.
function render.forget(id: any)
    memo[tostring(id)] = nil
end
-- remembered(id) — whether row keys are kept for `id`; for the tests of
-- whoever must call `forget`.
function render.remembered(id: any): boolean
    return memo[tostring(id)] ~= nil
end
return render
