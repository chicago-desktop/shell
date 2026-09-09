local tty = require("tty")
local widgets = require("widgets")
local ui = require("ui")
local charts = require("charts")
local text = require("text")
local geometry = require("geometry")
local editor = require("editor")
local whole = geometry.whole
local cells = {}
function cells.rows(plan: any, interaction: any, width: any, height: any): any
    local canvas = tty.canvas(whole(math.max(1, width)), whole(math.max(1, height)))
    canvas:clear(widgets.styles.face:render(" "))
    local function put(x: any, y: any, text: any, w: any, style: any)
        if w > 0 then canvas:put(whole(x), whole(y), widgets.fit(style, tostring(text), whole(w)), whole(w)) end
    end
    local styles = widgets.styles
    local function strip(item: any, r: any, current: any, opened: any)
        -- Полоса заголовков вкладок или меню: « подпись » с гранями у вкладок,
        -- голая — у меню; текущая жирная, раскрытая — инверсией.
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
            -- Рамка с заголовком в верхней грани — как у ящиков диспетчера.
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
            -- Зелёное по чёрному, сетка точками там, где график пуст.
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
            -- Заголовок дней недели, шесть строк чисел, сегодня — инверсией.
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
            -- Стрелок в ячейках нет: цифровое время посередине поля.
            local digital = string.format("%02d:%02d:%02d", whole(node.hour), whole(node.minute), whole(node.second))
            for row = 0, r.h - 1 do canvas:put(whole(r.x), whole(r.y + row), styles.field:render(string.rep(" ", r.w)), whole(r.w)) end
            put(r.x + math.max(0, (r.w - 8) // 2), r.y + r.h // 2, digital, math.min(r.w, 8), styles.field)
        elseif node.kind == "field" then
            -- Вдавленное поле только для чтения: табло калькулятора, окошко
            -- памяти. Текст вправо или влево, лишнее обрезается.
            local inner = math.max(0, whole(r.w) - 2)
            local shown = widgets.clip(tostring(node.text or ""), inner)
            local pad = math.max(0, inner - widgets.cells(shown))
            local text = node.align == "right" and (string.rep(" ", pad) .. shown) or (shown .. string.rep(" ", pad))
            for row = 0, r.h - 1 do
                local line = row == r.h // 2 and text or string.rep(" ", inner)
                canvas:put(whole(r.x), whole(r.y + row), widgets.bezel(styles.field:render(line), true), whole(r.w))
            end
        elseif node.kind == "monitor" then
            -- В ячейках монитор — рамка лица и экран цветом стола внутри.
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
            -- Значок в ячейках — один символ: шрифт растров не знает.
            local glyph = tostring(node.icon or "▸")
            put(r.x + math.max(0, (r.w - 1) // 2), r.y + math.max(0, (r.h - 1) // 2), glyph, 1, styles.face)
        elseif node.kind == "statusbar" then
            widgets.statusbar(canvas, r.x, r.y + r.h - 1, r.w, node.fields or {})
        elseif node.kind == "tabs" then
            strip(item, r, whole(node.active or 1), nil)
            -- Рамка страницы с разрывом под активной вкладкой — как у widgets.tabs.
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
            -- Заголовок — выпуклые кнопки колонок, как в «Проводнике»; строки —
            -- ячейки по колонкам одной раскладки, правое выравнивание для чисел.
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
            for row = 0, r.h - 1 - header do
                local index = item.offset + row + 1
                local record: any = rows[index]
                local style = item.selected_index == index and styles.select or styles.field
                local y = r.y + header + row
                put(r.x, y, "", r.w - 1, style)
                if record then
                    local values: any = type(record) == "table" and (record.cells or record) or {record}
                    for col, column in ipairs(columns) do
                        local value = tostring(values[col] or "")
                        if column.align == "right" then
                            local clipped = widgets.clip(value, column.w - 1)
                            value = string.rep(" ", math.max(0, column.w - 1 - widgets.cells(clipped))) .. clipped
                        else value = " " .. value end
                        put(r.x + column.x, y, value, column.w, style)
                    end
                end
                local symbol = " "
                if item.bar.limit > 0 then
                    symbol = row == 0 and "▲" or (row == r.h - 1 - header and "▼" or
                        (row >= item.bar.start and row < item.bar.start + item.bar.size and "█" or "░"))
                end
                put(r.x + r.w - 1, y, symbol, 1, styles.face)
            end
        elseif node.kind == "tree" then
            local rows = ui.entries(node)
            for row = 0, r.h - 1 do
                local index = item.offset + row + 1
                local line: any = rows[index]
                local y = r.y + row
                put(r.x, y, "", r.w - 1, styles.field)
                if line then
                    local parts = {}
                    local trail: any = line.trail or {}
                    for level = 1, #trail do
                        if level == #trail then parts[#parts + 1] = trail[level] and "├ " or "└ "
                        else parts[#parts + 1] = trail[level] and "│ " or "  " end
                    end
                    local columns = ui.tree_columns(line.depth)
                    local prefix = table.concat(parts)
                    put(r.x, y, prefix, math.min(r.w - 1, widgets.cells(prefix)), styles.field)
                    if line.has_children then
                        put(r.x + columns.expander, y, line.expanded and "-" or "+", 1, styles.field)
                    end
                    local glyph = line.kind == "folder" and (line.expanded and "▥" or "▤") or "▢"
                    put(r.x + columns.icon, y, glyph, 1, styles.field)
                    local label = tostring(line.label or "")
                    local style = item.selected_index == index and styles.select or styles.field
                    put(r.x + columns.label, y, label, math.max(0, r.w - 1 - columns.label), style)
                end
                local symbol = " "
                if item.bar.limit > 0 then
                    symbol = row == 0 and "▲" or (row == r.h - 1 and "▼" or
                        (row >= item.bar.start and row < item.bar.start + item.bar.size and "█" or "░"))
                end
                put(r.x + r.w - 1, y, symbol, 1, styles.face)
            end
        elseif node.kind == "list" then
            for row = 0, r.h - 1 do
                local index = item.offset + row + 1
                local value: any = (node.items or {})[index]
                local label = type(value) == "table" and value.text or value
                put(r.x, r.y + row, label or "", r.w - 1,
                    item.selected_index == index and widgets.styles.select or widgets.styles.field)
                local symbol = " "
                if item.bar.limit > 0 then
                    symbol = row == 0 and "▲" or (row == r.h - 1 and "▼" or
                        (row >= item.bar.start and row < item.bar.start + item.bar.size and "█" or "░"))
                end
                put(r.x + r.w - 1, r.y + row, symbol, 1, widgets.styles.face)
            end
        else
            local label = tostring(node.text or "")
            local style = widgets.styles.face
            if node.kind == "label" and node.alert then style = widgets.styles.alert end
            if node.kind == "button" then
                -- Та же кнопка, что у Run, проводника и хрома: грани, чёрный
                -- контур у default, грани наоборот при нажатии, тусклая —
                -- недоступная. Своя «[ … ]» расходилась с остальной оболочкой.
                local armed = interaction.armed
                label = widgets.button(node.text, {
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
            for row = 0, r.h - 1 do
                if node.kind == "button" and row == r.h // 2 then
                    -- Уже отрисованная строка: `fit` перекрасил бы грани.
                    canvas:put(whole(r.x), whole(r.y + row), tostring(label), whole(r.w))
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
    -- Раскрытые меню — поверх всего, поэтому после остальных.
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
