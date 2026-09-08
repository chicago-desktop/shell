local test = require("test")
local ui = require("ui")
local cells = require("cells")
local editor = require("editor")
local input = require("input")
local scroll = require("scroll")
local geometry = require("geometry")
local render = require("render")
local pixels = require("pixels")
local rasters = require("rasters")
local fixture = require("fixture")
local catalog = require("catalog")
local chrome = require("chrome")
local registry = require("registry")
local fs = require("fs")
local gfx = require("gfx")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local function body(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then value = value:data() end
    if type(value) == "table" and value[1] then value = value[1] end
    return value
end
local function receive(stream: any, predicate: any): any
    local deadline = time.after("8s")
    while true do
        local picked = channel.select({stream:case_receive(), deadline:case_receive()})
        test.is_true(picked.ok and picked.channel ~= deadline, "SDK lifecycle timed out")
        local value = body(picked.value)
        if predicate(value) then return value end
    end
end
local function ask(service: any, replies: any, topic: any, value: any): any
    value.reply_to = tostring(process.pid())
    assert(process.send(service, topic, value))
    return receive(replies, function(reply) return reply.command == topic end)
end
local function define_tests()
    test.describe("Window SDK", function()
        test.it("lays out disjoint controls at actual client sizes and clamps after data shrink", function()
            for _, size in ipairs({{60, 20}, {37, 12}, {10, 4}, {1, 1}}) do
                local context = {width = size[1], height = size[2]}
                local model = fixture.definition.init(nil, context)
                local interaction = ui.interaction()
                interaction.offsets.documents = 999
                local tree = fixture.definition.view(model, context)
                local plan = ui.plan(tree, context.width, context.height, interaction)
                for index, item in ipairs(plan.items) do
                    test.is_true(item.rect.x >= 1 and item.rect.y >= 1)
                    test.is_true(item.rect.x + item.rect.w <= context.width + 1)
                    test.is_true(item.rect.y + item.rect.h <= context.height + 1)
                    test.eq(ui.hit(plan, item.rect.x, item.rect.y), item)
                    for other = index + 1, #plan.items do
                        local b = plan.items[other].rect
                        test.is_true(item.rect.x + item.rect.w <= b.x or b.x + b.w <= item.rect.x
                            or item.rect.y + item.rect.h <= b.y or b.y + b.h <= item.rect.y)
                    end
                end
                model.items = {}
                ui.plan(fixture.definition.view(model, context), context.width, context.height, interaction)
                if plan.by_id.documents then test.eq(interaction.offsets.documents, 0) end
            end
        end)
        test.it("shares wheel, page, keyboard selection and drag geometry", function()
            local model = fixture.definition.init(nil, {})
            local state = ui.interaction()
            local tree = {kind = "list", id = "items", items = model.items, selected = 1}
            local plan = ui.plan(tree, 20, 10, state)
            local action = ui.event(plan, state, {type = "key", key = "page_down", action = "press"})
            test.eq(action.index, 11)
            test.eq(state.offsets.items, 1)
            test.is_nil(ui.event(plan, state, {type = "key", key = "page_down", action = "release"}))
            ui.event(plan, state, {type = "mouse", action = "wheel", button = "wheel_down", x = 3, y = 4})
            -- Колесо считает от СОСТОЯНИЯ (1 после Page Down), а не от плана
            -- (0): два события без перерисовки не теряют первое.
            test.eq(state.offsets.items, 4)
            state.offsets.items = 0
            plan = ui.plan(tree, 20, 10, state)
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 20, y = 2})
            test.not_nil(state.capture)
            ui.event(plan, state, {type = "mouse", action = "motion", button = "left", x = 90, y = 40})
            test.eq(state.offsets.items, 70)
            ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = 90, y = 40})
            test.is_nil(state.capture)
            test.eq(scroll.clamp(90, 3, 20), 0)
            test.eq(scroll.wheel(10, "right", 80, 10, 3), 10)
            test.eq(input.normalize({type = "key", key_type = "pgdn"}).key_type, "pgdown")
        end)
        test.it("activates buttons on release inside and cancels an outside release", function()
            local state = ui.interaction()
            local tree = {kind = "button", id = "apply", text = "Применить"}
            local plan = ui.plan(tree, 12, 2, state)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 1, y = 2}))
            test.is_true(state.armed.inside)
            ui.event(plan, state, {type = "mouse", action = "motion", button = "left", x = 13, y = 2})
            test.is_false(state.armed.inside)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = 13, y = 2}))
            test.is_nil(state.armed)
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 12, y = 2})
            ui.event(plan, state, {type = "mouse", action = "motion", button = "left", x = -2, y = 2})
            ui.event(plan, state, {type = "mouse", action = "motion", button = "left", x = 12, y = 2})
            test.is_true(state.armed.inside)
            local action = ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = 12, y = 2})
            test.eq(action.type, "activate")
            test.eq(action.id, "apply")
            test.is_nil(state.armed)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = 12, y = 2}))
            tree.disabled = true
            plan = ui.plan(tree, 12, 2, state)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 1, y = 1}))
            test.is_nil(state.armed)
            test.is_nil(ui.event(plan, state, {type = "key", key = "enter", action = "press"}))
        end)
        test.it("toggles a checkbox through change actions, skips disabled controls and ignores key release", function()
            local state = ui.interaction()
            local checkbox = {kind = "checkbox", id = "include", checked = false, text = "Включая вложенные папки"}
            local tree = {kind = "column", children = {checkbox,
                {kind = "button", id = "disabled", disabled = true}, {kind = "button", id = "close"}}}
            local plan = ui.plan(tree, 30, 3, state)
            test.eq(state.focus, "include")
            test.is_nil(ui.event(plan, state, {type = "key", key = " ", key_type = "runes", action = "release"}))
            local action = ui.event(plan, state, {type = "key", key = " ", key_type = "runes", action = "press"})
            test.eq(action.type, "change")
            test.eq(action.id, "include")
            test.is_true(action.value)
            checkbox.checked = action.value
            plan = ui.plan(tree, 30, 3, state)
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 20, y = 1})
            action = ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = 20, y = 1})
            test.is_false(action.value)
            ui.event(plan, state, {type = "key", key = "tab", action = "press"})
            test.eq(state.focus, "close")
        end)
        test.it("table: one column layout for header, rows, hits and both renderers", function()
            local rows = {}
            for index = 1, 30 do
                rows[index] = {id = "m" .. index, cells = {"org/module-" .. index, "0.1." .. index, tostring(index * 1000) .. " КБ", "приложение"}}
            end
            local node = {kind = "table", id = "modules", selected = 2, rows = rows, columns = {
                {title = "Модуль", weight = 3}, {title = "Версия", width = 8},
                {title = "Размер", width = 10, align = "right"}, {title = "Откуда", weight = 1},
            }}
            local interaction = ui.interaction()
            local plan = ui.plan(node, 60, 10, interaction)
            local item = plan.by_id.modules
            test.eq(item.header, 1, "первая строка — заголовок")
            test.eq(item.page, 9, "страница без заголовка")
            local columns = ui.columns(node, 59)
            test.eq(#columns, 4)
            test.eq(columns[2].w, 8)
            test.eq(columns[3].align, "right")
            test.eq(columns[4].x + columns[4].w, 59, "колонки заполняют ширину без полосы")
            test.eq(columns[2].x, columns[1].x + columns[1].w + 1, "между колонками одна ячейка")
            -- Щелчок по заголовку ничего не выбирает; по первой строке под ним — первую.
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 3, y = 1}))
            local picked = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 3, y = 2})
            test.eq(picked.type, "select")
            test.eq(picked.index, 1)
            test.eq(picked.value.id, "m1")
            -- Клавиатура: вниз со второй строки — третья, конец — последняя, сдвиг открывает её.
            interaction.focus = "modules"
            local moved = ui.event(plan, interaction, {type = "key", action = "press", key_type = "down"})
            test.eq(moved.index, 3)
            local last = ui.event(plan, interaction, {type = "key", action = "press", key_type = "end"})
            test.eq(last.index, 30)
            test.eq(interaction.offsets.modules, 21, "30 строк на странице в 9: сдвиг 21")
            -- Ячейки: число прижато к правому краю своей колонки, заголовок сверху.
            local lines = cells.rows(ui.plan(node, 60, 10, ui.interaction()), ui.interaction(), 60, 10)
            local function plain(text: any): string return (tostring(text):gsub("\27%[[%d;]*m", "")) end
            local header = plain(lines[1])
            test.is_true(header:find("Модуль", 1, true) ~= nil and header:find("Размер", 1, true) ~= nil, header)
            local first = plain(lines[2])
            local size_col = columns[3]
            -- Срез по СИМВОЛАМ, не по байтам: «КБ» — четыре байта на две ячейки.
            local runes = {}
            for char in first:gmatch("[%z\1-\127\194-\244][\128-\191]*") do runes[#runes + 1] = char end
            local cell_text = table.concat(runes, "", size_col.x + 1, size_col.x + size_col.w)
            -- Одна ячейка отступа справа — как у Проводника; левее текста только пробелы.
            test.is_true(cell_text:match("^%s+1000 КБ ?$") ~= nil, "размер у правого края: [" .. cell_text .. "]")
            -- Пиксели: рисуется и переиспользуется, снимок — в test/shots.
            local font_files = assert(fs.get("app:system_fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13}))
            local state = {sdk = 1, revision = 1, ui = {kind = "column", padding = 1, children = {node}}, interaction = ui.interaction()}
            local window = {id = "sdk-table", state_revision = 1, content_state = state}
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement(window, {x = 1, y = 1, cols = 60, rows = 12}, {w = 8, h = 18}, {face = font}, store))
            assert(assert(fs.get("app:shots")):writefile("sdk-table.png", assert(placed.raster:encode("png"))))
        end)

        test.it("tabs, menu and statusbar: one strip layout, page frame, popup on top, both renderers", function()
            local function tree(active: any)
                return {kind = "column", children = {
                    {kind = "menu", id = "bar", size = 1, entries = {
                        {title = "Файл", accel = 1, items = {
                            {id = "open", text = "Открыть", accel = 1},
                            {separator = true},
                            {id = "quit", text = "Выход", accel = 2},
                        }},
                        {title = "Правка", accel = 1, items = {{id = "copy", text = "Копировать"}}},
                    }},
                    {kind = "tabs", id = "pages", labels = {"Общие", "Сеть", "Прочее"}, active = active, children = {
                        {kind = "label", id = nil, text = "страница"},
                    }},
                    {kind = "statusbar", size = 1, fields = {{text = "Готово", width = 12}, {text = "1 объект"}}},
                }}
            end
            local state = ui.interaction()
            local plan = ui.plan(tree(1), 40, 12, state)
            local tabs = plan.by_id.pages
            test.eq(tabs.rect.h, 1, "полоса вкладок — одна строка")
            test.eq(tabs.frame.y, 3, "рамка страницы сразу под полосой")
            test.eq(#tabs.spans, 3)
            test.eq(tabs.spans[2].x, tabs.spans[1].w, "вкладки идут встык")
            -- Ребёнок лежит внутри рамки, на ячейку от её края.
            local child: any = nil
            for _, item in ipairs(plan.items) do if item.node.text == "страница" then child = item end end
            test.not_nil(child)
            test.eq(child.rect.x, 2)
            test.eq(child.rect.y, tabs.frame.y + 1)
            test.eq(ui.hit(plan, 5, child.rect.y), child, "попадание в страницу — в ребёнка, не во вкладки")
            -- Щелчок по второй вкладке и стрелка вправо на фокусе.
            local picked = ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2 + tabs.spans[2].x, y = 2})
            test.eq(picked.type, "select")
            test.eq(picked.index, 2)
            test.eq(state.focus, "pages")
            plan = ui.plan(tree(2), 40, 12, state)
            local moved = ui.event(plan, state, {type = "key", action = "press", key_type = "right"})
            test.eq(moved.index, 3)
            -- Меню: заголовок раскрывает, список ложится поверх, строка даёт действие.
            local bar = plan.by_id.bar
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2, y = 1}))
            test.eq(state.menus.bar.index, 1, "первый заголовок раскрыт")
            plan = ui.plan(tree(2), 40, 12, state)
            test.eq(#plan.overlays, 1, "раскрытый список — поверх")
            local popup = plan.by_id.bar.popup
            test.eq(popup.rect.y, 2)
            test.eq(#popup.rows, 3)
            test.is_true(popup.rows[2].separator)
            -- Список лежит над вкладками: попадание в его строку — в меню.
            test.eq(ui.hit(plan, popup.rect.x + 2, popup.rect.y + 3), plan.by_id.bar)
            local chosen = ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = popup.rect.x + 2, y = popup.rect.y + 3})
            test.eq(chosen.type, "activate")
            test.eq(chosen.id, "quit")
            test.is_nil(state.menus.bar, "после выбора свёрнуто")
            -- Alt+П раскрывает «Правка»; щелчок мимо сворачивает и съедается.
            plan = ui.plan(tree(2), 40, 12, state)
            ui.event(plan, state, {type = "key", action = "press", key_type = "runes", key = "п", alt = true})
            test.eq(state.menus.bar.index, 2)
            plan = ui.plan(tree(2), 40, 12, state)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 5, y = 8}))
            test.is_nil(state.menus.bar)
            -- Клавиатура в раскрытом меню: вниз, вниз (через разделитель), Enter.
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2, y = 1})
            plan = ui.plan(tree(2), 40, 12, state)
            ui.event(plan, state, {type = "key", action = "press", key_type = "down"})
            ui.event(plan, state, {type = "key", action = "press", key_type = "down"})
            test.eq(state.menus.bar.cursor, 3, "разделитель пропущен")
            local entered = ui.event(plan, state, {type = "key", action = "press", key_type = "enter"})
            test.eq(entered.id, "quit")
            -- Ячейки: статусная строка внизу с обоими полями.
            local lines = cells.rows(ui.plan(tree(1), 40, 12, ui.interaction()), ui.interaction(), 40, 12)
            local function plain(text: any): string return (tostring(text):gsub("\27%[[%d;]*m", "")) end
            local last = plain(lines[12])
            test.is_true(last:find("Готово", 1, true) ~= nil and last:find("1 объект", 1, true) ~= nil, last)
            test.is_true(plain(lines[1]):find("Файл", 1, true) ~= nil, "строка меню сверху")
            -- Пиксели: с раскрытым меню, снимок в test/shots.
            local font_files = assert(fs.get("app:system_fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13}))
            local shown = ui.interaction()
            shown.menus.bar = {index = 1, cursor = 1}
            shown.focus = "pages"
            local content = {sdk = 1, revision = 1, ui = tree(2), interaction = shown}
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "sdk-panels", state_revision = 1, content_state = content},
                {x = 1, y = 1, cols = 40, rows = 12}, {w = 8, h = 18}, {face = font}, store))
            assert(assert(fs.get("app:shots")):writefile("sdk-panels.png", assert(placed.raster:encode("png"))))
        end)

        test.it("edits Unicode without deleting on key release", function()
            local state = {cursor = 3, selected = false}
            local value = editor.event("кот", state, {type = "key", key_type = "backspace", action = "release"})
            test.eq(value, "кот")
            value = editor.event(value, state, {type = "key", key_type = "left"})
            value = editor.event(value, state, {type = "key", key_type = "backspace"})
            test.eq(value, "кт")
            editor.event(value, state, {type = "key", key_type = "runes", key = "a", ctrl = true})
            value = editor.event(value, state, {type = "paste", text = "новый\nтекст"})
            test.eq(value, "новый текст")
        end)
        test.it("discovers the application from registry metadata with no theme-specific renderer", function()
            local found = assert(catalog.list())
            local present = false
            for _, item in ipairs(found.programs) do if item.entry == "app:sdk_demo" then present = true end end
            test.is_true(present)
            test.not_nil(registry.get("butschster.windows.sdk:render"))
        end)
        test.it("reuses an unchanged raster and exports the real SDK controls", function()
            local font_files = assert(fs.get("app:system_fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13}))
            local context = {width = 60, height = 20}
            local model = fixture.definition.init(nil, context)
            local state = {sdk = 1, revision = 1, ui = fixture.definition.view(model, context), interaction = ui.interaction()}
            local window = {id = "sdk-demo", state_revision = 1, content_state = state}
            local inner = {x = 1, y = 1, cols = 60, rows = 20}
            local store = rasters.store()
            store.begin()
            local first = assert(render.placement(window, inner, {w = 8, h = 18}, {face = font}, store))
            local bytes = assert(first.raster:encode("png"))
            store.begin()
            local second = assert(render.placement(window, inner, {w = 8, h = 18}, {face = font}, store))
            test.eq(first.raster, second.raster)
            test.eq(bytes, assert(second.raster:encode("png")))
            assert(assert(fs.get("app:shots")):writefile("sdk-controls.png", bytes))
            local samples = assert(gfx.raster(560, 280))
            samples:fill("#c0c0c0")
            samples:text(16, 12, "Windows SDK — стандартные элементы", {font = font, color = "#000000"})
            local variants = {
                {label = "Найти", caption = "Обычная"},
                {label = "Найти", default = true, caption = "По умолчанию"},
                {label = "Найти", default = true, focused = true, caption = "Фокус"},
                {label = "Найти", pressed = true, caption = "Нажата"},
                {label = "Стоп", disabled = true, caption = "Недоступна"},
            }
            for index, variant in ipairs(variants) do
                local x = 16 + (index - 1) * 108
                samples:text(x, 43, variant.caption, {font = font, color = "#000000"})
                variant.font = font
                pixels.button(samples, x, 64, 96, 23, variant, {w = 8, h = 18})
            end
            samples:text(16, 105, "Имя:", {font = font, color = "#000000"})
            pixels.field(samples, 65, 102, 220, 22)
            samples:rect(69, 105, 76, 15, "#000080")
            samples:text(71, 105, "winword.exe", {font = font, color = "#ffffff"})
            pixels.checkbox(samples, 65, 139, true, false)
            samples:text(83, 137, "Включая вложенные папки", {font = font, color = "#000000"})
            pixels.checkbox(samples, 65, 165, false, false)
            samples:text(83, 163, "Учитывать регистр", {font = font, color = "#000000"})
            pixels.checkbox(samples, 65, 191, true, true)
            samples:text(84, 190, "Недоступный параметр", {font = font, color = "#ffffff"})
            samples:text(83, 189, "Недоступный параметр", {font = font, color = "#808080"})
            pixels.field(samples, 315, 102, 229, 105)
            samples:rect(317, 104, 225, 18, "#000080")
            samples:text(322, 105, "Документы", {font = font, color = "#ffffff"})
            samples:text(322, 125, "Программы", {font = font, color = "#000000"})
            samples:text(322, 145, "Мой компьютер", {font = font, color = "#000000"})
            samples:text(16, 237, "Двойные грани · пунктир фокуса · тиснёная подпись", {font = font, color = "#000000"})
            assert(assert(fs.get("app:shots")):writefile("sdk-button-states.png", assert(samples:encode("png"))))
            local bold = assert(gfx.font(assert(font_files:readfile("LiberationSans-Bold.ttf")), {size = 13}))
            chrome.use_fonts(font, bold)
            chrome.use_cell_size(8, 18)
            local inset = chrome.window_insets()
            local scene = {width = 90, height = 30, top = 1, bottom = 28, items = {}, clock = "12:00",
                focused_id = "sdk-demo", windows = {{id = "sdk-demo", entry = "app:sdk_demo",
                    title = "Пример SDK", image = "program", window_type = "app", content = "pixels",
                    render = "butschster.windows.sdk:render", content_state = state, state_revision = 1,
                    x = 15, y = 4, w = context.width + inset.left + inset.right,
                    h = context.height + inset.top + inset.bottom}}}
            local painted = chrome.paint(scene, 8, 18)
            local canvas = assert(gfx.raster(720, 540))
            canvas:fill("#008080")
            for _, placement in ipairs(painted.placements) do
                canvas:blit(placement.raster, (placement.x - 1) * 8 + 1, (placement.y - 1) * 18 + 1)
            end
            assert(assert(fs.get("app:shots")):writefile("sdk-window.png", assert(canvas:encode("png"))))
        end)
        test.it("opens through the real compositor, resizes and closes in pixels and cells", function()
            local replies = assert(process.listen("desktop.reply", {message = true}))
            local frames = assert(process.listen("sdk.frame", {message = true}))
            for _, mode in ipairs({"pixels", "cells"}) do
                local service = "app.sdk.test." .. mode
                local view = assert(tty.viewport({width = 100, height = 34}))
                local composer, spawn_error = process.with_options({terminal = assert(view:grant())})
                    :spawn_monitored("app:sdk_composer", "app:processes", service, tostring(process.pid()), mode)
                test.not_nil(composer, "композитор не поднялся в режиме " .. mode .. ": " .. tostring(spawn_error))
                local deadline = time.now():unix_nano() + 8000000000
                while not process.registry.lookup(service) and time.now():unix_nano() < deadline do
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.not_nil(process.registry.lookup(service))
                local opened = ask(service, replies, "desktop.open", {entry = "app:sdk_demo"})
                test.is_true(opened.ok, tostring(opened.error))
                test.eq(opened.window.title, "Пример SDK")
                test.eq(opened.window.content, mode)
                if mode == "pixels" then
                    -- Свой канал приложения доехал действием.
                    receive(frames, function(value) return value.id == opened.window.id
                        and tostring(value.state.ui.children[2].children[2].children[1].text) == "канал сработал" end)
                    local frame = receive(frames, function(value) return value.id == opened.window.id end)
                    local plan = ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
                    local bar = plan.by_id.documents.rect
                    local x, y = frame.x + bar.x + bar.w - 1, frame.y + bar.y + 1
                    assert(view:send({type = "mouse", action = "press", button = "left", x = x, y = y}))
                    assert(view:send({type = "mouse", action = "motion", button = "left", x = 99, y = 32}))
                    assert(view:send({type = "mouse", action = "release", button = "left", x = 99, y = 32}))
                    receive(frames, function(value) return value.state.interaction.offsets.documents > 50 and value.state.interaction.capture == nil end)
                end
                local resized = ask(service, replies, "desktop.resize", {id = opened.window.id, w = 40, h = 15})
                test.is_true(resized.ok, tostring(resized.error))
                if mode == "pixels" then
                    -- Ошибка в update — видимое состояние, а не исчезнувшее окно;
                    -- его кнопка «Закрыть» закрывает окно штатно.
                    local frame = receive(frames, function(value) return value.id == opened.window.id and value.width == 40 - 2 end)
                    local plan = ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
                    local crash = plan.by_id.crash.rect
                    local cx, cy = frame.x + crash.x, frame.y + crash.y
                    assert(view:send({type = "mouse", action = "press", button = "left", x = cx, y = cy}))
                    assert(view:send({type = "mouse", action = "release", button = "left", x = cx, y = cy}))
                    local fallen = receive(frames, function(value)
                        return value.id == opened.window.id and value.state.ui.children[1].text ~= nil
                            and tostring(value.state.ui.children[1].text):find("остановлено", 1, true) ~= nil end)
                    test.is_true(tostring(fallen.state.ui.children[2].text):find("нарочно", 1, true) ~= nil,
                        "запасное дерево называет причину")
                    local fallback = ui.plan(fallen.state.ui, fallen.width, fallen.height, fallen.state.interaction)
                    local close = fallback.by_id.sdk_close.rect
                    assert(view:send({type = "mouse", action = "press", button = "left", x = fallen.x + close.x, y = fallen.y + close.y}))
                    -- Нажатие взводит кнопку ЗАПАСНОГО дерева: план после ошибки
                    -- обязан быть новым, а не тем, что был у приложения.
                    local armed = receive(frames, function(value) return value.id == opened.window.id and value.state.interaction.armed ~= nil end)
                    test.eq(armed.state.interaction.armed.id, "sdk_close")
                    assert(view:send({type = "mouse", action = "release", button = "left", x = fallen.x + close.x, y = fallen.y + close.y}))
                else
                    -- Клавиша, не взятая компонентом, доходит приложению: Esc закрывает.
                    assert(view:send({type = "key", key = "esc", key_type = "esc", action = "press"}))
                end
                local remaining = 1
                local listed: any = nil
                deadline = time.now():unix_nano() + 8000000000
                while remaining > 0 and time.now():unix_nano() < deadline do
                    listed = ask(service, replies, "desktop.list", {})
                    remaining = #listed.windows
                    channel.select({time.after("20ms"):case_receive()})
                end
                local dump = {}
                if remaining > 0 then
                    for key, value in pairs(listed.windows[1]) do dump[#dump + 1] = tostring(key) .. "=" .. tostring(value) end
                    table.sort(dump)
                end
                test.eq(remaining, 0, "окно не закрылось в режиме " .. mode .. ": " .. table.concat(dump, " "))
                assert(process.send(service, "desktop.quit", {}))
                view:close()
            end
        end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
