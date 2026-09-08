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
    group = true, graph = true, gauge = true, tree = true}
-- Без `id` живут только те, что не принимают ввод.
local passive = {label = true, statusbar = true, image = true, field = true, group = true, graph = true, gauge = true}
local runes_of = text.runes
-- Строки списка и таблицы — одно и то же для прокрутки и выбора: таблица
-- лишь несёт ячейки вместо текста и строку заголовка сверху.
local function entries(node: any): any
    if node.kind == "table" or node.kind == "tree" then return node.rows or {} end
    return node.items or {}
end
-- Дерево: отступ в две ячейки на уровень; крестик, значок и подпись —
-- в фиксированных колонках от отступа. Одна арифметика на оба отрисовщика
-- и на попадания: крестик, нарисованный на ячейку левее того места, где
-- нажимается, — ровно тот класс дефекта, ради которого SDK и есть.
function ui.tree_columns(depth: any): any
    local indent = whole(depth) * 2
    return {expander = indent, icon = indent + 2, label = indent + 4}
end
ui.entries = entries
-- Ячейки строки текста (символы, не байты): и вкладки, и меню меряются ими.
local function cells_of(text: any): integer
    return #runes_of(text)
end
-- Полосы вкладок и меню: каждая подпись занимает « подпись » плюс две грани.
-- Одна раскладка на оба отрисовщика и на попадания; строка длиннее полосы
-- обрезается по целым вкладкам — половина вкладки нажимается «в никуда».
function ui.spans(labels: any, width: any): any
    local out, used = {}, 0
    for index, entry in ipairs(labels or {}) do
        local title = type(entry) == "table" and tostring(entry.title or entry.text or "?") or tostring(entry)
        local room = cells_of(title) + 4
        if used + room > whole(width) then break end
        out[#out + 1] = {index = index, x = used, w = room, title = title,
            accel = type(entry) == "table" and whole(entry.accel) or 0}
        used = used + room
    end
    return out
end
-- Выпадающий список меню: строки под заголовком, разделитель — своя строка.
-- Ширина — по самой длинной подписи; всё в ячейках, координаты с 1.
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
-- Колонки таблицы по ширине текстовой области (без полосы прокрутки):
-- `width` в ячейках — фиксированная, иначе доля `weight`; между колонками
-- одна ячейка. Одна раскладка на заголовок, строки, оба отрисовщика.
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
local function add(node: any, rect: any, plan: any, interaction: any)
    assert(type(node) == "table", "SDK node must be a table")
    local kind = node.kind
    assert(containers[kind] or leaves[kind], "unknown SDK control: " .. tostring(kind))
    if rect.w < 1 or rect.h < 1 then return end
    if containers[kind] then
        rect = geometry.inset(rect, node.padding or 0)
        local children = node.children or {}
        local horizontal = kind == "row" or kind == "split"
        local length = whole(horizontal and rect.w or rect.h)
        local gap = whole(math.max(0, node.gap or 0))
        local available = math.max(0, length - gap * math.max(0, #children - 1))
        local fixed, weight = 0, 0
        for _, child in ipairs(children) do
            if child.size ~= nil then fixed = fixed + math.max(0, whole(child.size))
            else weight = weight + math.max(1, whole(child.weight or 1)) end
        end
        local flexible = math.max(0, available - fixed)
        local position, consumed, weights = 0, 0, 0
        for _, child in ipairs(children) do
            local size = math.max(0, whole(child.size))
            if child.size == nil then
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
        return
    end
    local id = node.id
    if not passive[kind] then
        assert(type(id) == "string" and id ~= "", "interactive SDK controls need a stable id")
        assert(plan.by_id[id] == nil, "duplicate SDK control id: " .. id)
    end
    if kind == "group" then
        -- Рамка с заголовком («Горутины», «Память»): дети внутри рамки,
        -- на ячейку от края. Сама рамка ввода не принимает.
        local item: any = {node = node, rect = rect}
        plan.items[#plan.items + 1] = item
        if id then plan.by_id[id] = item end
        if rect.h >= 3 and rect.w >= 3 then
            add({kind = "column", children = node.children or {}, padding = node.padding, gap = node.gap},
                geometry.rect(rect.x + 1, rect.y + 1, rect.w - 2, rect.h - 2), plan, interaction)
        end
        return
    end
    if kind == "tabs" then
        -- Вкладки — полоса в одну строку и рамка страницы под ней; дети
        -- раскладываются внутри рамки. Попадание — только полоса.
        local strip = geometry.rect(rect.x, rect.y, rect.w, 1)
        local item: any = {node = node, rect = strip, spans = ui.spans(node.labels, rect.w),
            frame = geometry.rect(rect.x, rect.y + 1, rect.w, math.max(0, rect.h - 1))}
        plan.items[#plan.items + 1] = item
        plan.by_id[id] = item
        if not node.disabled then plan.focusable[#plan.focusable + 1] = id end
        if rect.h >= 4 and rect.w >= 3 then
            add({kind = "column", children = node.children or {}, padding = node.padding, gap = node.gap},
                geometry.rect(rect.x + 1, rect.y + 2, rect.w - 2, rect.h - 3), plan, interaction)
        end
        return
    end
    local item: any = {node = node, rect = rect, offset = 0, page = rect.h, bar = nil, header = 0}
    if kind == "menu" then
        -- Строка меню: полоса заголовков; раскрытый список — поверх всего,
        -- поэтому попадает в `plan.overlays` и рисуется последним.
        item.spans = ui.spans(node.entries, rect.w)
        local open: any = interaction.menus[id]
        if open and open.index then
            item.popup = ui.popup(item, open.index)
            if item.popup then plan.overlays[#plan.overlays + 1] = item else interaction.menus[id] = nil end
        end
    end
    if kind == "list" or kind == "table" or kind == "tree" then
        -- У таблицы первая строка — заголовок: страница и полоса на одну меньше.
        item.header = (kind == "table" and node.header ~= false) and 1 or 0
        item.page = math.max(1, whole(rect.h) - whole(item.header))
        local total = #entries(node)
        item.offset = scroll.clamp(interaction.offsets[id], total, item.page)
        interaction.offsets[id] = item.offset
        item.bar = scroll.bar(item.offset, total, item.page, math.max(1, rect.h - item.header))
    end
    plan.items[#plan.items + 1] = item
    if id then plan.by_id[id] = item end
    -- Меню в кольцо фокуса не входит — как в Windows, к нему ходят Alt и F10.
    if id and not passive[kind] and kind ~= "menu" and not node.disabled then plan.focusable[#plan.focusable + 1] = id end
end
function ui.interaction(): any
    return {focus = nil, offsets = {}, capture = nil, editors = {}, armed = nil, menus = {}}
end
function ui.plan(tree: any, width: any, height: any, interaction: any): any
    local plan: any = {items = {}, by_id = {}, focusable = {}, overlays = {}}
    if interaction.menus == nil then interaction.menus = {} end
    add(tree, geometry.rect(1, 1, width, height), plan, interaction)
    if not interaction.focus or not plan.by_id[interaction.focus] or plan.by_id[interaction.focus].node.disabled then
        interaction.focus = plan.focusable[1]
    end
    -- Чёрный контур «по умолчанию» — у кнопки в фокусе, а когда фокус не на
    -- кнопке — у объявленной `default`. Так в Windows, и так Enter делает
    -- ровно то, что нарисовано. Решается здесь один раз для обоих отрисовщиков.
    local focused = plan.by_id[interaction.focus]
    plan.focus_on_button = focused ~= nil and focused.node.kind == "button"
    return plan
end
-- Показать ли кнопке чёрный контур в этом плане.
function ui.default_look(plan: any, node: any, focused: boolean): boolean
    if node.disabled then return false end
    if focused then return true end
    return node.default == true and not plan.focus_on_button
end
function ui.hit(plan: any, x: any, y: any): any
    -- Раскрытое меню лежит поверх всего: сначала оно.
    for _, item in ipairs(plan.overlays or {}) do
        if item.popup and geometry.contains(item.popup.rect, x, y) then return item end
    end
    -- Рамка (`group`) содержит своих детей: попадание ищется среди них
    -- первым, сама рамка — только если не попали ни в кого.
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
-- Меню: щелчок по заголовку раскрывает или сворачивает, по строке списка —
-- действие, мимо — сворачивает и съедает щелчок. Клавиши, пока раскрыто:
-- стрелки, Enter, Esc.
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
    -- Сдвиг берётся из СОСТОЯНИЯ, а не из плана: два события подряд без
    -- перерисовки (два щелчка колеса) иначе теряли первое.
    local total, header = #rows, whole(item.header)
    local offset = scroll.clamp(state.offsets[node.id] or item.offset, total, item.page)
    if event.action == "wheel" then
        state.offsets[node.id] = scroll.wheel(offset, event.button, total, item.page, node.wheel_step or 3)
    elseif input.pressed(event) then
        local row = event.y - rect.y - header
        -- Заголовок таблицы — не строка: щелчок по нему ничего не выбирает.
        if row < 0 then return nil end
        if node.kind == "tree" and event.x < rect.x + rect.w - 1 then
            local index = offset + row + 1
            local line: any = rows[index]
            if not line then return nil end
            local columns = ui.tree_columns(line.depth)
            if line.has_children and event.x == rect.x + columns.expander then
                return {type = "toggle", id = node.id, index = index, value = line}
            end
            return {type = "select", id = node.id, index = index, value = line}
        end
        if event.x == rect.x + rect.w - 1 then
            -- Колонка полосы — не строка, даже когда прокручивать нечего.
            if item.bar.limit <= 0 then return nil end
            local shifted, capture = scroll.pointer(offset, total, item.page,
                {x = rect.x + rect.w - 1, y = rect.y + header, w = 1, h = rect.h - header}, nil, event)
            state.offsets[node.id] = shifted
            state.capture = capture and {id = node.id, grab = capture.grab} or nil
        else
            local index = offset + row + 1
            if index <= total then return {type = "select", id = node.id, index = index, value = rows[index]} end
        end
    end
    return nil
end
local function activate(node: any): any
    if node.kind == "checkbox" then return {type = "change", id = node.id, value = not node.checked} end
    return {type = "activate", id = node.id}
end
function ui.event(plan: any, state: any, original: any): any
    local event = input.normalize(original)
    -- Колесо во время взвода кнопки или перетаскивания ползунка — ничьё.
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
    -- Раскрытое меню забирает нажатия целиком: попал — обработано,
    -- мимо — свернулось, щелчок не ушёл дальше. Alt+буква раскрывает своё.
    for _, item in ipairs(plan.items) do
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
        if item.node.kind == "menu" then return menu_event(item, state, event) end
        if item.node.kind == "tabs" then
            if input.pressed(event) then state.focus = item.node.id end
            return tabs_event(item, state, event)
        end
        -- Фокус берёт только то, что умеет его держать: метка с `id` иначе
        -- забирала фокус, и Tab переставал находить, откуда шагать.
        if input.pressed(event) and item.node.id and item.node.kind ~= "label" then state.focus = item.node.id end
        if item.node.kind == "list" or item.node.kind == "table" or item.node.kind == "tree" then return list_event(item, state, event) end
        if (item.node.kind == "button" or item.node.kind == "checkbox") and input.pressed(event) then
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
    if (node.kind == "button" or node.kind == "checkbox") and (key == "enter" or (key == "runes" and event.key == " ")) then
        return activate(node)
    elseif (node.kind == "list" or node.kind == "table" or node.kind == "tree") and key then
        local rows = entries(node)
        local total = #rows
        if total == 0 then return nil end
        local index = whole(node.selected or 1)
        if node.kind == "tree" then
            -- Клавиши дерева, как в regedit: Enter и → раскрывают, ← закрывает
            -- или уходит к родителю, → у раскрытой — к первому ребёнку.
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
        elseif key == "up" then index = index - 1 elseif key == "down" then index = index + 1
        elseif key == "pgup" then index = index - item.page elseif key == "pgdown" then index = index + item.page
        elseif key == "enter" then return {type = "activate", id = node.id, index = index, value = rows[index]}
        else return nil end
        index = whole(math.max(1, math.min(total, index)))
        state.offsets[node.id] = scroll.reveal(item.offset, index, total, item.page)
        return {type = "select", id = node.id, index = index, value = rows[index]}
    elseif node.kind == "input" then
        local editing = state.editors[node.id] or {cursor = #editor.runes(node.text), selected = false}
        state.editors[node.id] = editing
        local value, action = editor.event(tostring(node.text or ""), editing, event)
        if action then return {type = action, id = node.id, value = value} end
    end
    return nil
end
return ui
