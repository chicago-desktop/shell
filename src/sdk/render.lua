-- Generic renderer: registered once, shared by every declarative application.
local ui = require("ui")
local charts = require("charts")
local text_lib = require("text")
local geometry = require("geometry")
local editor = require("editor")
local pixels = require("pixels")
local palette = require("palette")
local whole = geometry.whole
local color = palette.exact
local render = {}
function render.placement(window: any, inner: any, cell: any, fonts: any, store: any): (any, any)
    local state: any = window.content_state
    if type(state) ~= "table" or state.sdk ~= 1 then return nil, "SDK: ожидается состояние версии 1" end
    local plan = ui.plan(state.ui, inner.cols, inner.rows, state.interaction)
    local id = "win:" .. tostring(window.id) .. ":sdk"
    local raster, dirty = store.take(id, inner.cols, inner.rows, cell, tostring(window.state_revision or state.revision))
    if dirty then
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
                    -- Ярлык, а не кнопка: свет слева и сверху со скошенным
                    -- углом, тень и чёрный справа, снизу грани нет — ярлык
                    -- стоит на рамке страницы. Активный на два пикселя выше
                    -- и сливается со страницей.
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
                    -- Заголовок меню — по центру своих ячеек, подсветка на
                    -- шесть пикселей шире текста с каждой стороны, как в
                    -- оригинале; ячейки заголовка шире текста, потому что
                    -- попадание считается в ячейках без шрифта.
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
            local focused = state.interaction.focus == node.id
            if node.kind == "calendar" then
                -- Календарь: дни недели, сетка месяца, сегодня синим.
                if font then
                    local names = {"Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"}
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
                -- Часы «Дата и время» Windows 95, по пикселям оригинала:
                -- циферблат на лице без белого поля; шестьдесят меток по
                -- кругу — минутные выпуклые точки 3×3 (тень сверху-слева,
                -- свет снизу-справа), часовые бирюзовые с чёрной тенью;
                -- стрелки — сужающиеся бирюзовые клинья с белым бликом и
                -- серой тенью, секундная — тонкая серая, в центре красная
                -- точка.
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
                -- Выпуклый многоугольник построчно: клин стрелки — остриё,
                -- два плеча у основания и короткий хвост за центром.
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
                -- Дерево, как в regedit: пунктирные линии предков, крестики,
                -- значки папок и записей, выделение только на подписи.
                local rows = ui.entries(node)
                raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
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
                        local room = x + w - cell.w - label_x - 4
                        local caption = pixels.ellipsize(font, tostring(line.label or ""), whole(math.max(0, room)))
                        local selected = item.selected_index == index
                        if selected then raster:rect(whole(label_x - 2), whole(top + 2), whole(font:measure(caption)) + 4, whole(cell.h - 4), color.select_bg) end
                        raster:text(whole(label_x), whole(top + (cell.h - 15) // 2), caption,
                            {font = font, color = selected and color.select_fg or color.field_text})
                    end
                end
                pixels.scrollbar(raster, x + w - cell.w, y, cell.w, h, item.bar, cell.h, cell.h)
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "group" then
                -- Рамка с заголовком: грань на полстроки ниже, чтобы подпись
                -- сидела на ней, как в диалогах Windows.
                local ty = y + (cell.h - 15) // 2
                pixels.etched(raster, whole(x), whole(y + cell.h // 2), whole(w), whole(h - cell.h // 2))
                if font then
                    local title = tostring(node.title or "")
                    local tw = whole(font:measure(title))
                    raster:rect(whole(x + 6), whole(y), whole(math.min(w - 12, tw + 8)), whole(cell.h), color.face)
                    raster:text(whole(x + 10), whole(ty), title, {font = font, color = color.face_text})
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
                        local cap = string.format("%.0f", ceiling) .. tostring(node.unit or "")
                        local lw = math.min(gw - 4, whole(font:measure(cap)) + 4)
                        raster:rect(whole(gx + 2), whole(gy + 2), whole(lw), whole(math.min(16, gh)), "#000000")
                        raster:text(whole(gx + 4), whole(gy + 2), cap, {font = font, color = "#00ff00"})
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
                -- Поле только для чтения: до 26 px по центру своих строк, текст
                -- по центру высоты с отступом от граней. `face = true` — фон
                -- лица, а не белый: окошко памяти калькулятора, пустое поле.
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
                -- Монитор из «Свойств экрана»: серый корпус с объёмной гранью,
                -- экран цветом `color` (стол), подставка снизу. Пропорции
                -- 4:3 по меньшей стороне, по центру своего прямоугольника.
                -- Корпус 8 px вокруг экрана и подставка 8 px под ним — из
                -- высоты, ширина от неё по 4:3.
                local screen_h = whole(math.min(h - 26, (w - 24) * 3 // 4))
                local screen_w = whole(screen_h * 4 // 3)
                if screen_w >= 24 and screen_h >= 18 then
                    local body_w, body_h = screen_w + 16, screen_h + 16
                    local left = whole(x + (w - body_w) // 2)
                    local top = whole(y + (h - body_h - 8) // 2)
                    pixels.panel(raster, left, top, body_w, body_h)
                    pixels.edge(raster, left + 6, top + 6, screen_w + 4, screen_h + 4, false)
                    raster:rect(left + 8, top + 8, screen_w, screen_h, tostring(node.color or color.desktop))
                    -- Индикатор питания и подставка.
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
            elseif node.kind == "statusbar" then
                -- Вдавленные поля в одну строку, как у проводника: последний
                -- растягивается, у остальных ширина своя или по тексту.
                -- Ширина поля объявлена в ячейках — в пиксели здесь.
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
                -- Разрыв рамки под активной вкладкой: она сливается со страницей.
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
                local open: any = state.interaction.menus and state.interaction.menus[node.id] or nil
                strip(item, x, y, nil, open and open.index or nil)
            elseif node.kind == "table" then
                -- Та же раскладка колонок, что в ячейках; заголовок — выпуклые
                -- кнопки, числа прижаты к правому краю по ширине шрифта.
                local columns = ui.columns(node, rect.w - 1)
                local rows = ui.entries(node)
                local header = whole(item.header)
                raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
                if header > 0 then
                    raster:rect(whole(x), whole(y), whole(w), whole(cell.h), color.face)
                    for _, column in ipairs(columns) do
                        local cx, cw = x + column.x * cell.w, column.w * cell.w + cell.w
                        if column.x + column.w >= rect.w - 1 then cw = column.w * cell.w end
                        pixels.bevel(raster, whole(cx), whole(y), whole(cw), whole(cell.h), true)
                        text(cx + 4, y, cw - 8, cell.h, column.title)
                    end
                end
                for row = 0, rect.h - 1 - header do
                    local index = item.offset + row + 1
                    local record: any = rows[index]
                    local selected = item.selected_index == index
                    local row_y = y + (row + header) * cell.h
                    if selected then raster:rect(whole(x), whole(row_y), whole(w - cell.w), whole(cell.h), color.select_bg) end
                    if record then
                        local values: any = type(record) == "table" and (record.cells or record) or {record}
                        for col, column in ipairs(columns) do
                            local value = tostring(values[col] or "")
                            local cx, cw = x + column.x * cell.w, column.w * cell.w
                            local tint = selected and color.select_fg or color.field_text
                            if column.align == "right" and font then
                                local shown = pixels.ellipsize(font, value, whole(math.max(0, cw - 8)))
                                local measured = whole(font:measure(shown))
                                text(cx + math.max(4, cw - 4 - measured), row_y, cw - 4, cell.h, shown, tint)
                            else text(cx + 4, row_y, cw - 8, cell.h, value, tint) end
                        end
                    end
                end
                pixels.scrollbar(raster, x + w - cell.w, y + header * cell.h, cell.w, h - header * cell.h, item.bar, cell.h, cell.h)
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "list" then
                raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
                for row = 0, rect.h - 1 do
                    local index = item.offset + row + 1
                    local selected = item.selected_index == index
                    local value: any = (node.items or {})[index]
                    local label = type(value) == "table" and value.text or value
                    local row_y = y + row * cell.h
                    if selected then raster:rect(whole(x), whole(row_y), whole(w - cell.w), whole(cell.h), color.select_bg) end
                    text(x + 3, row_y, w - cell.w - 6, cell.h, label, selected and color.select_fg or color.field_text)
                end
                pixels.scrollbar(raster, x + w - cell.w, y, cell.w, h, item.bar, cell.h, cell.h)
                pixels.edge(raster, whole(x), whole(y), whole(w), whole(h), false)
            elseif node.kind == "button" then
                -- Обычная кнопка — 23 px по центру своих строк; `fill` —
                -- на весь прямоугольник минус `inset` со всех сторон (так
                -- клавиши калькулятора стоят с зазором в четыре пикселя).
                -- `bold` — жирная подпись, как у клавиш оригинала.
                local pad = whole(node.inset)
                local bx, bw = x + pad, w - pad * 2
                local bh = node.fill and whole(h) - pad * 2 or math.min(23, whole(h))
                local by = node.fill and whole(y + pad) or whole(y + (h - bh) // 2)
                local armed = state.interaction.armed
                local face_font: any = (node.bold and fonts and fonts.bold) or font
                pixels.button(raster, bx, by, bw, bh, {label = node.text, font = face_font,
                    default = ui.default_look(plan, node, focused), focused = focused, disabled = node.disabled,
                    pressed = node.pressed == true or (armed ~= nil and armed.id == node.id and armed.inside == true), color = node.ink}, cell)
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
                -- Поле ввода — до 24 px по центру своих строк: в одной строке
                -- ячеек текст упирался бы в грани, отдайте ему две.
                local fh = math.min(24, whole(h))
                y, h = y + (h - fh) // 2, fh
                pixels.field(raster, whole(x), whole(y), whole(w), whole(h))
                if node.disabled then raster:rect(whole(x + 2), whole(y + 2), whole(w - 4), whole(h - 4), color.face) end
                local editing = state.interaction.editors[node.id]
                local shown, caret = editor.visible(node.text, editing, rect.w)
                if focused and editing and editing.selected then
                    raster:rect(whole(x + 3), whole(y + 2), whole(math.max(1, w - 6)), whole(math.max(1, h - 4)), color.select_bg)
                end
                text(x + 4, y, w - 8, h, shown, focused and editing and editing.selected and color.select_fg or (node.disabled and color.shadow or color.field_text))
                if focused and font and not (editing and editing.selected) then
                    local chars = editor.runes(shown)
                    local before = table.concat(chars, "", 1, whole(math.max(0, caret)))
                    local cx = math.min(whole(x + w - 3), whole(x + 4) + whole(font:measure(before)))
                    raster:rect(whole(cx), whole(y + math.max(2, (h - 15) // 2)), 1, whole(math.min(15, h - 4)), color.field_text)
                end
            else text(x + 2, y, w - 4, h, node.text, node.alert and color.alert or nil) end
        end
    end
    -- Раскрытые меню — поверх всего, поэтому после остальных и в том же растре.
    if dirty then
        local font = fonts and fonts.face
        for _, item in ipairs(plan.overlays or {}) do
            local popup: any = item.popup
            local open: any = state.interaction.menus[item.node.id]
            local px, py = (popup.rect.x - 1) * cell.w + 1, (popup.rect.y - 1) * cell.h + 1
            local pw, ph = popup.rect.w * cell.w, popup.rect.h * cell.h
            pixels.panel(raster, whole(px), whole(py), whole(pw), whole(ph))
            for position, row in ipairs(popup.rows) do
                local line: any = row
                local ry = py + position * cell.h
                if line.separator then
                    raster:rect(whole(px + 4), whole(ry + cell.h // 2 - 1), whole(pw - 8), 1, color.shadow)
                    raster:rect(whole(px + 4), whole(ry + cell.h // 2), whole(pw - 8), 1, color.light)
                elseif font then
                    local chosen = position == whole(open and open.cursor or 0)
                    if chosen then raster:rect(whole(px + 3), whole(ry), whole(pw - 6), whole(cell.h), color.select_bg) end
                    local tint = chosen and color.select_fg or (line.disabled and color.shadow or color.face_text)
                    raster:text(whole(px + 2 * cell.w), whole(ry + (cell.h - 15) // 2), line.text, {font = font, color = tint})
                end
            end
        end
    end
    return {id = id, raster = raster, x = inner.x, y = inner.y, cols = inner.cols, rows = inner.rows}, nil
end
return render
