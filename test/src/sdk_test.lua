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
local shell_icons = require("shell_icons")
local app = require("app")
local widgets = require("widgets")

local function define_tests()
    test.describe("Window SDK icon grid", function()
        test.it("keeps the same step as the shell icon library", function()
            -- Two tables of the same thing diverge exactly on the keys that both
            -- rarely need. Here they must match: the SDK lays out, `shell:icons` draws,
            -- and if they drifted apart by a cell they would put the hit somewhere
            -- other than under the picture.
            local sdk_grid = ui.icon_grid()
            local shell_grid = shell_icons.grid()
            test.eq(sdk_grid.w, shell_grid.w)
            test.eq(sdk_grid.h, shell_grid.h)
            test.eq(sdk_grid.drawn, shell_grid.drawn)
            test.eq(sdk_grid.caption, shell_grid.caption)
        end)

        test.it("wraps items into rows, scrolls by row and walks the grid with arrows", function()
            local items = {}
            for index = 1, 13 do items[#items + 1] = {id = "n" .. index, title = "node " .. index} end
            local tree: any = {kind = "icons", id = "grid", items = items, selected = 1}
            local state = ui.interaction()
            -- Three columns of 12 cells and two visible rows of four.
            local plan = ui.plan(tree, 38, 8, state)
            local grid = plan.by_id.grid
            test.eq(grid.columns, 3, "the width is divided by the column step")
            test.eq(grid.rows_total, 5, "thirteen items make five rows")
            test.eq(grid.page, 2, "the page is counted in ROWS, not in items")
            test.eq(#grid.cells, 6, "only the visible rows are drawn")

            local first: any = grid.cells[1]
            local picked = ui.event(plan, state, {type = "mouse", action = "press", button = "left",
                x = first.box.from, y = first.box.top})
            test.eq(picked.type, "select")
            test.eq(picked.index, 1)
            test.is_true(picked.pointer, "a mouse click is marked so that the window can recognize a double click")

            -- The down arrow moves by a row, not to the neighboring item.
            state.focus = "grid"
            local moved = ui.event(plan, state, {type = "key", action = "press", key_type = "down"})
            test.eq(moved.index, 4, "down moves by the column width")

            local scrolled = ui.plan({kind = "icons", id = "grid", items = items, selected = 13}, 38, 8, state)
            test.is_true(scrolled.by_id.grid.offset > 0, "the item selected at the end is brought into view")
        end)
    end)

    test.describe("Window SDK", function()
        test.it("padding_bottom = 0 puts the last row against the frame while the other sides keep padding", function()
            local tree = {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
                {kind = "label", text = "top"},
                {kind = "row", size = 2, gap = 1, children = {
                    {kind = "label", text = ""},
                    {kind = "button", id = "ok", size = 10, text = "OK"},
                }},
            }}
            local plan = ui.plan(tree, 40, 6, ui.interaction())
            local ok = plan.by_id.ok.rect
            test.eq(ok.y + ok.h - 1, 6, "the buttons reach the last row of the client area")
            test.eq(ok.x + ok.w - 1, 39, "the right padding stays")
            local same = ui.plan({kind = "column", padding = 1, gap = 0, children = tree.children}, 40, 6, ui.interaction())
            test.eq(same.by_id.ok.rect.y + same.by_id.ok.rect.h - 1, 5, "without an override there is a cell of padding at the bottom")
        end)

        test.it("lays out disjoint controls at actual client sizes and clamps after data shrink", function()
            for _, size in ipairs({{60, 20}, {37, 12}, {10, 4}, {1, 1}}) do
                local context = app.context({width = size[1], height = size[2]})
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
            local model = fixture.definition.init(nil, app.context({}))
            local state = ui.interaction()
            local tree = {kind = "list", id = "items", items = model.items, selected = 1}
            local plan = ui.plan(tree, 20, 10, state)
            local action = ui.event(plan, state, {type = "key", key = "page_down", action = "press"})
            test.eq(action.index, 11)
            test.eq(state.offsets.items, 1)
            test.is_nil(ui.event(plan, state, {type = "key", key = "page_down", action = "release"}))
            ui.event(plan, state, {type = "mouse", action = "wheel", button = "wheel_down", x = 3, y = 4})
            -- The wheel counts from the STATE (1 after Page Down), not from the plan
            -- (0): two events without a redraw do not lose the first one.
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
            local tree = {kind = "button", id = "apply", text = "Apply"}
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
        test.it("gives a right press on a button to the window as context and arms nothing", function()
            local state = ui.interaction()
            local tree = {kind = "column", children = {
                {kind = "button", id = "cell", size = 1, text = ""},
                {kind = "label", size = 1, text = "caption"},
                {kind = "button", id = "off", size = 1, text = "", disabled = true},
            }}
            local plan = ui.plan(tree, 12, 3, state)
            local action = ui.event(plan, state, {type = "mouse", action = "press", button = "right", x = 3, y = 1})
            test.eq(action and action.type, "context", "a right press on a button reaches the window")
            test.eq(action and action.id, "cell")
            test.is_nil(state.armed, "a right press does not arm the button: its release must not activate it")
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "release", button = "right", x = 3, y = 1}),
                "the release of the right button is not a second action")
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "right", x = 3, y = 2}),
                "a label takes no context press")
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "right", x = 3, y = 3}),
                "a disabled button takes none either")
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "middle", x = 3, y = 1}),
                "only the right button is the context button")
        end)
        test.it("draws a button's picture from an image pack in pixels and keeps the caption when it is missing", function()
            local store = rasters.store()
            store.begin()
            local inner, cell = {x = 1, y = 1, cols = 6, rows = 2}, {w = 8, h = 18}
            local function png(id: string, node: any): any
                local placed = assert(render.placement({id = id, content_state = {sdk = 1, revision = 1, ui = node}},
                    inner, cell, {}, store))
                return placed.raster:encode("png")
            end
            local caption = png("caption", {kind = "button", id = "face", text = ":)"})
            local picture = png("picture", {kind = "button", id = "face", text = ":)", image = "app:test_images/smile"})
            local missing = png("missing", {kind = "button", id = "face", text = ":)", image = "app:test_images/absent"})
            test.is_true(picture ~= caption, "the picture is drawn instead of the caption")
            test.eq(missing, caption, "a picture that is not there leaves the caption as it was")
        end)
        test.it("toggles a checkbox through change actions, skips disabled controls and ignores key release", function()
            local state = ui.interaction()
            local checkbox = {kind = "checkbox", id = "include", checked = false, text = "Include subfolders"}
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
                rows[index] = {id = "m" .. index, cells = {"org/module-" .. index, "0.1." .. index, tostring(index * 1000) .. " КБ", "application"}}
            end
            local node = {kind = "table", id = "modules", selected = 2, rows = rows, columns = {
                {title = "Module", weight = 3}, {title = "Version", width = 8},
                {title = "Size", width = 10, align = "right"}, {title = "Source", weight = 1},
            }}
            local interaction = ui.interaction()
            local plan = ui.plan(node, 60, 10, interaction)
            local item = plan.by_id.modules
            test.eq(item.header, 1, "the first row is the header")
            test.eq(item.page, 9, "the page without the header")
            local columns = ui.columns(node, 59)
            test.eq(#columns, 4)
            test.eq(columns[2].w, 8)
            test.eq(columns[3].align, "right")
            test.eq(columns[4].x + columns[4].w, 59, "the columns fill the width without the bar")
            test.eq(columns[2].x, columns[1].x + columns[1].w + 1, "one cell between columns")
            -- A click on the header selects nothing; a click on the first row below it selects the first one.
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 3, y = 1}))
            local picked = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 3, y = 2})
            test.eq(picked.type, "select")
            test.eq(picked.index, 1)
            test.eq(picked.value.id, "m1")
            -- Keyboard: down from the second row gives the third, End gives the last, and the offset reveals it.
            interaction.focus = "modules"
            local moved = ui.event(plan, interaction, {type = "key", action = "press", key_type = "down"})
            test.eq(moved.index, 3)
            local last = ui.event(plan, interaction, {type = "key", action = "press", key_type = "end"})
            test.eq(last.index, 30)
            test.eq(interaction.offsets.modules, 21, "30 rows on a page of 9: offset 21")
            -- Cells: the number is pushed to the right edge of its column, the header is on top.
            local lines = cells.rows(ui.plan(node, 60, 10, ui.interaction()), ui.interaction(), 60, 10)
            local function plain(text: any): string return (tostring(text):gsub("\27%[[%d;]*m", "")) end
            local header = plain(lines[1])
            test.is_true(header:find("Module", 1, true) ~= nil and header:find("Size", 1, true) ~= nil, header)
            local first = plain(lines[2])
            local size_col = columns[3]
            -- Slice by CHARACTERS, not bytes: "КБ" is four bytes over two cells.
            local runes = {}
            for char in first:gmatch("[%z\1-\127\194-\244][\128-\191]*") do runes[#runes + 1] = char end
            local cell_text = table.concat(runes, "", size_col.x + 1, size_col.x + size_col.w)
            -- One cell of padding on the right, as in Explorer; only spaces to the left of the text.
            test.is_true(cell_text:match("^%s+1000 КБ ?$") ~= nil, "the size is at the right edge: [" .. cell_text .. "]")
            -- Pixels: drawn and reused, the snapshot goes to test/shots.
            local font_files = assert(fs.get("app:system_fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
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
                        {title = "File", accel = 1, items = {
                            {id = "open", text = "Open", accel = 1},
                            {separator = true},
                            {id = "quit", text = "Exit", accel = 2},
                        }},
                        {title = "Edit", accel = 1, items = {{id = "copy", text = "Copy"}}},
                    }},
                    {kind = "tabs", id = "pages", labels = {"General", "Network", "Other"}, active = active, children = {
                        {kind = "label", id = nil, text = "page"},
                    }},
                    {kind = "statusbar", size = 1, fields = {{text = "Ready", width = 12}, {text = "1 object"}}},
                }}
            end
            local state = ui.interaction()
            local plan = ui.plan(tree(1), 40, 12, state)
            local tabs = plan.by_id.pages
            test.eq(tabs.rect.h, 1, "the tab strip is one row")
            test.eq(tabs.frame.y, 3, "the page frame is right under the strip")
            test.eq(#tabs.spans, 3)
            test.eq(tabs.spans[2].x, tabs.spans[1].w, "the tabs go edge to edge")
            -- The child lies inside the frame, one cell from its edge.
            local child: any = nil
            for _, item in ipairs(plan.items) do if item.node.text == "page" then child = item end end
            test.not_nil(child)
            test.eq(child.rect.x, 2)
            test.eq(child.rect.y, tabs.frame.y + 1)
            test.eq(ui.hit(plan, 5, child.rect.y), child, "a hit on the page goes to the child, not to the tabs")
            -- A click on the second tab, and the right arrow on the focused tabs.
            local picked = ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2 + tabs.spans[2].x, y = 2})
            test.eq(picked.type, "select")
            test.eq(picked.index, 2)
            test.eq(state.focus, "pages")
            plan = ui.plan(tree(2), 40, 12, state)
            local moved = ui.event(plan, state, {type = "key", action = "press", key_type = "right"})
            test.eq(moved.index, 3)
            -- Menu: the title opens it, the list lies on top, a row gives an action.
            local bar = plan.by_id.bar
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2, y = 1}))
            test.eq(state.menus.bar.index, 1, "the first title is open")
            plan = ui.plan(tree(2), 40, 12, state)
            test.eq(#plan.overlays, 1, "the open list is on top")
            local popup = plan.by_id.bar.popup
            test.eq(popup.rect.y, 2)
            test.eq(#popup.rows, 3)
            test.is_true(popup.rows[2].separator)
            -- The list lies over the tabs: a hit on its row goes to the menu.
            test.eq(ui.hit(plan, popup.rect.x + 2, popup.rect.y + 3), plan.by_id.bar)
            local chosen = ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = popup.rect.x + 2, y = popup.rect.y + 3})
            test.eq(chosen.type, "activate")
            test.eq(chosen.id, "quit")
            test.is_nil(state.menus.bar, "closed after the choice")
            -- Alt+E opens "Edit"; a click outside closes it and is swallowed.
            plan = ui.plan(tree(2), 40, 12, state)
            ui.event(plan, state, {type = "key", action = "press", key_type = "runes", key = "e", alt = true})
            test.eq(state.menus.bar.index, 2)
            plan = ui.plan(tree(2), 40, 12, state)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 5, y = 8}))
            test.is_nil(state.menus.bar)
            -- Keyboard in an open menu: down, down (across the separator), Enter.
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 2, y = 1})
            plan = ui.plan(tree(2), 40, 12, state)
            ui.event(plan, state, {type = "key", action = "press", key_type = "down"})
            ui.event(plan, state, {type = "key", action = "press", key_type = "down"})
            test.eq(state.menus.bar.cursor, 3, "the separator is skipped")
            local entered = ui.event(plan, state, {type = "key", action = "press", key_type = "enter"})
            test.eq(entered.id, "quit")
            -- Cells: the status bar at the bottom with both fields.
            local lines = cells.rows(ui.plan(tree(1), 40, 12, ui.interaction()), ui.interaction(), 40, 12)
            local function plain(text: any): string return (tostring(text):gsub("\27%[[%d;]*m", "")) end
            local last = plain(lines[12])
            test.is_true(last:find("Ready", 1, true) ~= nil and last:find("1 object", 1, true) ~= nil, last)
            test.is_true(plain(lines[1]):find("File", 1, true) ~= nil, "the menu bar is on top")
            -- Pixels: with an open menu, the snapshot goes to test/shots.
            local font_files = assert(fs.get("app:system_fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
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
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local context = app.context({width = 60, height = 20})
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
            samples:text(16, 12, "Windows SDK — standard controls", {font = font, color = "#000000"})
            local variants = {
                {label = "Find", caption = "Normal"},
                {label = "Find", default = true, caption = "Default"},
                {label = "Find", default = true, focused = true, caption = "Focus"},
                {label = "Find", pressed = true, caption = "Pressed"},
                {label = "Stop", disabled = true, caption = "Disabled"},
            }
            for index, variant in ipairs(variants) do
                local x = 16 + (index - 1) * 108
                samples:text(x, 43, variant.caption, {font = font, color = "#000000"})
                variant.font = font
                pixels.button(samples, x, 64, 96, 23, variant, {w = 8, h = 18})
            end
            samples:text(16, 105, "Name:", {font = font, color = "#000000"})
            pixels.field(samples, 65, 102, 220, 22)
            samples:rect(69, 105, 76, 15, "#000080")
            samples:text(71, 105, "winword.exe", {font = font, color = "#ffffff"})
            -- Use the SDK itself: a hand-painted label can retain an obsolete
            -- shadow even after the production renderer has been fixed.
            local labels = {id = "sdk-labels", state_revision = 1, content_state = {
                sdk = 1, interaction = ui.interaction(), ui = {kind = "column", children = {
                    {kind = "checkbox", id = "folders", text = "Include subfolders", checked = true},
                    {kind = "checkbox", id = "case", text = "Match case"},
                    {kind = "checkbox", id = "disabled", text = "Unavailable option", checked = true, disabled = true},
                }}}}
            local label_image = assert(render.placement(labels, {x = 1, y = 1, cols = 28, rows = 3},
                {w = 8, h = 26}, {face = font}, store))
            samples:blit(label_image.raster, 65, 133)
            pixels.field(samples, 315, 102, 229, 105)
            samples:rect(317, 104, 225, 18, "#000080")
            samples:text(322, 105, "Documents", {font = font, color = "#ffffff"})
            samples:text(322, 125, "Programs", {font = font, color = "#000000"})
            samples:text(322, 145, "My Computer", {font = font, color = "#000000"})
            samples:text(16, 237, "Double edges · dotted focus outline · text without a white shadow", {font = font, color = "#000000"})
            assert(assert(fs.get("app:shots")):writefile("sdk-button-states.png", assert(samples:encode("png"))))
            local bold = assert(gfx.font(assert(font_files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            chrome.use_fonts(font, bold)
            chrome.use_cell_size(8, 18)
            local inset = chrome.window_insets()
            local scene = {width = 90, height = 30, top = 1, bottom = 28, items = {}, clock = "12:00",
                focused_id = "sdk-demo", windows = {{id = "sdk-demo", entry = "app:sdk_demo",
                    title = "SDK Example", image = "program", window_type = "app", content = "pixels",
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
                test.not_nil(composer, "the compositor did not start in mode " .. mode .. ": " .. tostring(spawn_error))
                local deadline = time.now():unix_nano() + 8000000000
                while not process.registry.lookup(service) and time.now():unix_nano() < deadline do
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.not_nil(process.registry.lookup(service))
                local opened = ask(service, replies, "desktop.open", {entry = "app:sdk_demo"})
                test.is_true(opened.ok, tostring(opened.error))
                test.eq(opened.window.title, "SDK Example")
                test.eq(opened.window.content, mode)
                if mode == "pixels" then
                    -- The application's own channel arrived as an action.
                    receive(frames, function(value) return value.id == opened.window.id
                        and tostring(value.state.ui.children[2].children[2].children[1].text) == "channel fired" end)
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
                    -- An error in update is visible state, not a vanished window;
                    -- its "Close" button closes the window the normal way.
                    local frame = receive(frames, function(value) return value.id == opened.window.id and value.width == 40 - 2 end)
                    local plan = ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
                    local crash = plan.by_id.crash.rect
                    local cx, cy = frame.x + crash.x, frame.y + crash.y
                    assert(view:send({type = "mouse", action = "press", button = "left", x = cx, y = cy}))
                    assert(view:send({type = "mouse", action = "release", button = "left", x = cx, y = cy}))
                    local fallen = receive(frames, function(value)
                        return value.id == opened.window.id and value.state.ui.children[1].text ~= nil
                            and tostring(value.state.ui.children[1].text):find("stopped", 1, true) ~= nil end)
                    test.is_true(tostring(fallen.state.ui.children[2].text):find("on purpose", 1, true) ~= nil,
                        "the fallback tree names the reason")
                    local fallback = ui.plan(fallen.state.ui, fallen.width, fallen.height, fallen.state.interaction)
                    local close = fallback.by_id.sdk_close.rect
                    assert(view:send({type = "mouse", action = "press", button = "left", x = fallen.x + close.x, y = fallen.y + close.y}))
                    -- The press arms the button of the FALLBACK tree: the plan after the error
                    -- must be a new one, not the one the application had.
                    local armed = receive(frames, function(value) return value.id == opened.window.id and value.state.interaction.armed ~= nil end)
                    test.eq(armed.state.interaction.armed.id, "sdk_close")
                    assert(view:send({type = "mouse", action = "release", button = "left", x = fallen.x + close.x, y = fallen.y + close.y}))
                else
                    -- The program must have redrawn at the new size before the
                    -- key: an Esc written into its pty while it still handles
                    -- the resize (SIGWINCH) is read as the start of a sequence
                    -- and lost. The compositor's frame used to lend it ~15 ms
                    -- by accident; it no longer paints in the command's path,
                    -- so the test waits for the evidence — every row fits the
                    -- new client (40 − 2 columns) and the label is back.
                    local redrawn = false
                    local wait_until = time.now():unix_nano() + 5000000000
                    local rows_seen: any = {}
                    while not redrawn and time.now():unix_nano() < wait_until do
                        local shown = ask(service, replies, "desktop.screen", {id = opened.window.id})
                        rows_seen = {}
                        for _, row in ipairs(shown.rows or {}) do
                            local plain = tostring(row):gsub("\27%[[%d;:]*m", "")
                            rows_seen[#rows_seen + 1] = plain
                            if plain:find("registry", 1, true) then redrawn = true end
                        end
                        for _, plain in ipairs(rows_seen) do
                            local _, runes = plain:gsub("[%z\1-\127\194-\244][\128-\191]*", "")
                            if runes > 40 - 2 then redrawn = false end
                        end
                        if not redrawn then channel.select({time.after("50ms"):case_receive()}) end
                    end
                    test.is_true(redrawn, "the program redrew at 40×15 before the key: " .. table.concat(rows_seen, "|"))
                    -- A key no component took reaches the application: Esc closes.
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
                test.eq(remaining, 0, "the window did not close in mode " .. mode .. ": " .. table.concat(dump, " "))
                assert(process.send(service, "desktop.quit", {}))
                view:close()
            end
        end)
    end)

    -- Open defects from the 2026-09-08 review (docs/sdk-review-2026-09-08.md) and
    -- cells: one scrollbar, a dimmed `disabled`.
    test.describe("Window SDK review follow-up", function()
        local function fonts(): any
            local files = assert(fs.get("app:system_fonts"))
            local face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            return {face = face, bold = face}
        end
        local function shot(tree: any, w: integer, h: integer): any
            local state = ui.interaction()
            local plan = ui.plan(tree, w, h, state)
            return cells.rows(plan, state, w, h)
        end
        -- The last visible character of a row of the cell frame — that is where the bar stands.
        local function last_glyph(row: any): string
            local plain = (tostring(row):gsub("\27%[[%d;:]*m", ""))
            local last = ""
            for glyph in plain:gmatch("[%z\1-\127\194-\244][\128-\191]*") do last = glyph end
            return last
        end
        local function bar_column(rows: any, from: integer, to: integer): string
            local out = {}
            for index = from, to do out[#out + 1] = last_glyph(rows[index]) end
            return table.concat(out)
        end

        test.it("go-lua: an error under pcall tears upvalues in the frames BELOW too — a tripwire", function()
            -- Measured 2026-09-11: the upvalue split after a caught error
            -- (docs/bugreports/go-lua-pcall-error-closes-upvalues.md in the stand)
            -- affects not only the frame that called pcall but also the frames below it.
            -- That is why the compositor's frame has no `pcall` around the view library
            -- (chrome_pixels, paint_view): below it is the base's loop with
            -- closures. This test asserts the CURRENT behavior of the VM.
            -- If it turns red, go-lua has been fixed: bring back the guard around the view and
            -- flip the expectation here to 2.
            local function owner(): integer
                local value = 1
                local function bump() value = value + 1 end
                local function deeper() return pcall(function() error("on purpose") end) end
                deeper()
                bump()
                return value
            end
            test.eq(owner(), 1, "the closure's write is not visible to the owner below pcall")
        end)

        test.it("A8: a state without interaction gives a frame, a tree that is not a table is refused with a reason", function()
            local store = rasters.store()
            store.begin()
            local inner, cell = {x = 1, y = 1, cols = 24, rows = 4}, {w = 8, h = 18}
            local tree = {kind = "column", children = {{kind = "label", text = "hi"}, {kind = "button", id = "ok", text = "OK"}}}
            local placed, why = render.placement({id = "bare", content_state = {sdk = 1, revision = 1, ui = tree}},
                inner, cell, fonts(), store)
            test.not_nil(placed, tostring(why))
            local refused, reason = render.placement({id = "shapeless", content_state = {sdk = 1, revision = 1, ui = "text"}},
                inner, cell, fonts(), store)
            test.is_nil(refused)
            test.is_true(tostring(reason):find("state.ui", 1, true) ~= nil, tostring(reason))
        end)

        test.it("A6: an error in ui.event sends the window to the fallback tree and does not skip dispose", function()
            -- Observations live in a table, not in locals: an error under pcall tears
            -- the upvalue between a closure and its owner (the go-lua trap).
            local seen: any = {views = 0, disposed = false, failure = nil}
            local original = ui.event
            local definition = {
                init = function(args: any, context: any): any
                    -- The `window.input` listener is open before `init`: an event
                    -- sent to ourselves here will reach the loop.
                    process.send(process.pid(), "window.input",
                        {event = {type = "mouse", action = "press", button = "left", x = 1, y = 1}})
                    process.send(process.pid(), "window.input", {event = {type = "close"}})
                    return {}
                end,
                view = function(): any
                    seen.views = seen.views + 1
                    return {kind = "button", id = "go", text = "Go"}
                end,
                dispose = function(model: any, context: any)
                    seen.disposed = true
                    seen.failure = context.failure
                end,
            }
            -- The substitute removes itself on the first call: if the guard in
            -- app.run broke, the error would fly out of the test before the restore, and
            -- the following tests would get someone else's `ui.event` (that is what happened on
            -- the first mutation). The test and `app` share the same `ui` table.
            ui.event = function()
                ui.event = original
                error("on purpose in ui.event")
            end
            app.run(definition, nil, "sdk-review-a6", nil, {width = 20, height = 4, cell_w = 8, cell_h = 18})
            ui.event = original
            test.is_true(seen.disposed, "dispose was not called")
            test.is_true(tostring(seen.failure):find("on purpose in ui.event", 1, true) ~= nil, tostring(seen.failure))
            test.eq(seen.views, 1, "after the error the fallback tree is drawn, not the application's view")
        end)

        test.it("A2: a passive view with an id does not take focus on click, Tab after the click moves on", function()
            local state = ui.interaction()
            local tree = {kind = "column", children = {
                {kind = "field", id = "readout", size = 2, text = "42"},
                {kind = "button", id = "first", size = 2, text = "First"},
                {kind = "button", id = "second", size = 2, text = "Second"},
            }}
            local plan = ui.plan(tree, 20, 6, state)
            test.eq(state.focus, "first")
            local field = plan.by_id.readout.rect
            ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = field.x, y = field.y})
            ui.event(plan, state, {type = "mouse", action = "release", button = "left", x = field.x, y = field.y})
            test.eq(state.focus, "first", "a read-only field does not take focus")
            ui.event(plan, state, {type = "key", key = "tab", action = "press"})
            test.eq(state.focus, "second", "Tab after the click steps further")
        end)

        test.it("A12: with no selection an arrow selects the first row, not the second", function()
            for _, kind in ipairs({"list", "table", "tree"}) do
                local rows = {}
                for index = 1, 5 do
                    if kind == "list" then rows[index] = "row " .. index
                    elseif kind == "table" then rows[index] = {cells = {"row " .. index}}
                    else rows[index] = {label = "row " .. index, depth = 0} end
                end
                local node: any = {kind = kind, id = "rows"}
                if kind == "list" then node.items = rows else node.rows = rows end
                if kind == "table" then node.columns = {{title = "Name"}} end
                for _, key in ipairs({"down", "up", "page_down"}) do
                    local state = ui.interaction()
                    local plan = ui.plan(node, 20, 6, state)
                    test.eq(state.focus, "rows")
                    local action = ui.event(plan, state, {type = "key", key = key, action = "press"})
                    test.eq(action.index, 1, kind .. ": " .. key .. " with no selection")
                end
            end
            local items = {}
            for index = 1, 6 do items[index] = {id = "i" .. index, title = "icon " .. index} end
            for _, key in ipairs({"down", "right", "up"}) do
                local state = ui.interaction()
                local plan = ui.plan({kind = "icons", id = "grid", items = items}, 36, 12, state)
                local action = ui.event(plan, state, {type = "key", key = key, action = "press"})
                test.eq(action.index, 1, "icons: " .. key .. " with no selection")
            end
        end)

        test.it("there is one scrollbar in cells: list, table, tree and icons draw it the same way", function()
            local list_rows, tree_rows, table_rows = {}, {}, {}
            for index = 1, 20 do
                list_rows[index] = "row " .. index
                tree_rows[index] = {label = "row " .. index, depth = 0}
                table_rows[index] = {cells = {"row " .. index}}
            end
            -- scroll.bar(0, 20, 10, 10): arrow, thumb 4 of 8, arrow.
            local expected = "▲████░░░░▼"
            test.eq(bar_column(shot({kind = "list", id = "l", items = list_rows}, 20, 10), 1, 10), expected, "list")
            test.eq(bar_column(shot({kind = "tree", id = "t", rows = tree_rows}, 20, 10), 1, 10), expected, "tree")
            test.eq(bar_column(shot({kind = "table", id = "g", columns = {{title = "Name"}}, rows = table_rows}, 20, 11), 2, 11),
                expected, "table under the header")
            -- Icons: 12 items at 2 per row make 6 rows, a page is 3 rows in 12 lines.
            local icons = {}
            for index = 1, 12 do icons[index] = {id = "i" .. index, title = "icon " .. index} end
            test.eq(bar_column(shot({kind = "icons", id = "n", items = icons}, 24, 12), 1, 12), "▲█████░░░░░▼", "icons")
            -- Nothing to scroll: there is no bar, the column is filled with the face color.
            test.eq(bar_column(shot({kind = "list", id = "s", items = {"a", "b"}}, 20, 4), 1, 4), "    ")
        end)

        test.it("disabled list, table, tree and icons are dimmed in both backends", function()
            local probe = widgets.styles.face_dim:render("x")
            local dim = probe:sub(1, (probe:find("x", 1, true) or 1) - 1)
            test.is_true(dim ~= "", "the dimmed style has no escape sequence of its own")
            local nodes: any = {
                list = {kind = "list", id = "l", items = {"alpha", "beta"}, selected = 1},
                table = {kind = "table", id = "g", columns = {{title = "Name"}}, rows = {{cells = {"alpha"}}}, selected = 1},
                tree = {kind = "tree", id = "t", rows = {{label = "alpha", depth = 0}}, selected = 1},
                icons = {kind = "icons", id = "n", items = {{id = "a", title = "alpha"}}, selected = 1},
            }
            local face = fonts()
            for kind, node in pairs(nodes) do
                local enabled = table.concat(shot(node, 24, 6), "\n")
                node.disabled = true
                local disabled = table.concat(shot(node, 24, 6), "\n")
                node.disabled = nil
                test.is_nil(enabled:find(dim, 1, true), kind .. ": the enabled one is not dimmed")
                test.not_nil(disabled:find(dim, 1, true), kind .. ": the disabled one is dimmed in cells")

                local store = rasters.store()
                store.begin()
                local inner, cell = {x = 1, y = 1, cols = 24, rows = 6}, {w = 8, h = 18}
                local on = assert(render.placement({id = "on-" .. kind, content_state = {sdk = 1, revision = 1, ui = node}},
                    inner, cell, face, store))
                local lit = on.raster:encode("png")
                node.disabled = true
                local off = assert(render.placement({id = "off-" .. kind, content_state = {sdk = 1, revision = 1, ui = node}},
                    inner, cell, face, store))
                node.disabled = nil
                test.is_true(off.raster:encode("png") ~= lit, kind .. ": the disabled one looks different in pixels")
            end
        end)
    end)

    -- Leftovers of docs/sdk-review-2026-09-08.md that were still open by code.
    test.describe("Window SDK renderer and input, review leftovers", function()
        -- A stable text of a table with sorted keys: the interaction is compared
        -- before and after, not trusted.
        local function dump(value: any): string
            if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
            local entries: any = {}
            for key, item in pairs(value) do entries[#entries + 1] = {name = tostring(key), item = item} end
            table.sort(entries, function(a: any, b: any) return a.name < b.name end)
            local parts = {}
            for _, entry in ipairs(entries) do parts[#parts + 1] = entry.name .. "=" .. dump(entry.item) end
            return "{" .. table.concat(parts, ",") .. "}"
        end

        test.it("A9: a clean raster is reused without a layout, and the compositor's interaction stays as it was", function()
            local tree = {kind = "column", children = {
                {kind = "list", id = "items", items = {"one", "two", "three"}},
                {kind = "button", id = "ok", size = 2, text = "OK"},
            }}
            local interaction = ui.interaction()
            interaction.offsets.items = 99        -- ui.plan clamps this,
            interaction.focus = "gone"             -- moves this,
            interaction.menus.gone = {index = 1}   -- and forgets this.
            local window = {id = "a9", state_revision = 1,
                content_state = {sdk = 1, revision = 1, ui = tree, interaction = interaction}}
            local before = dump(interaction)
            -- The counter lives in a table field: go-lua splits upvalues after
            -- an error caught by pcall.
            local calls: any = {count = 0}
            local plan = ui.plan
            ui.plan = function(...) calls.count = calls.count + 1; return plan(...) end
            local store = rasters.store()
            local inner, cell = {x = 1, y = 1, cols = 30, rows = 8}, {w = 8, h = 18}
            store.begin()
            local first, why = render.placement(window, inner, cell, {}, store)
            store.begin()
            local second = render.placement(window, inner, cell, {}, store)
            ui.plan = plan
            test.not_nil(first, tostring(why))
            test.eq(calls.count, 1, "the second frame of the same revision is not laid out again")
            test.eq(second and second.raster, first and first.raster, "the clean raster is reused")
            test.eq(dump(interaction), before, "the renderer leaves the compositor's interaction as it was")
        end)

        test.it("A14: Space presses and types whatever the decoder calls it, and Shift+Tab steps back", function()
            local tree = {kind = "column", children = {
                {kind = "button", id = "first", size = 2, text = "First"},
                {kind = "checkbox", id = "check", size = 1, text = "Check"},
                {kind = "input", id = "field", size = 2, text = ""},
            }}
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 30, 10, interaction)
            local function key(event: any): any
                event.type, event.action = "key", "press"
                return ui.event(plan, interaction, event)
            end
            -- The runtime's decoder says "space"; typed input and old tests say " ".
            for _, space in ipairs({{key_type = "space", key = "space"}, {key_type = "runes", key = " "}}) do
                local name = "Space as " .. space.key_type
                interaction.focus = "first"
                local pressed = key({key_type = space.key_type, key = space.key})
                test.eq(pressed and (pressed.type .. ":" .. tostring(pressed.id)), "activate:first", name .. " presses the button")
                interaction.focus = "check"
                local toggled = key({key_type = space.key_type, key = space.key})
                test.eq(toggled and toggled.type, "change", name .. " toggles the checkbox")
                interaction.focus = "field"
                local typed = key({key_type = space.key_type, key = space.key})
                test.eq(typed and typed.value, " ", name .. " types into the field")
            end
            interaction.focus = "first"
            key({key_type = "tab", key = "tab", shift = true})
            test.eq(interaction.focus, "field", "Shift+Tab from the first control wraps to the last")
            key({key_type = "backtab", key = "backtab"})
            test.eq(interaction.focus, "check", "backtab steps back the same way")
            key({key_type = "tab", key = "tab"})
            test.eq(interaction.focus, "field", "plain Tab steps forward")
        end)

        test.it("A11: a new press drops a button and a thumb whose release was never seen", function()
            local items = {}
            for index = 1, 30 do items[index] = "row " .. index end
            local tree = {kind = "column", children = {
                {kind = "list", id = "items", items = items},
                {kind = "button", id = "ok", size = 2, text = "OK"},
            }}
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 30, 12, interaction)
            local ok, list = plan.by_id.ok.rect, plan.by_id.items.rect
            ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = ok.x, y = ok.y})
            test.not_nil(interaction.armed, "a press arms the button")
            -- The window is minimized now, and the release goes to no one; a thumb
            -- was being dragged too. Later the person presses elsewhere.
            interaction.capture = {id = "items", grab = 0}
            ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = list.x, y = list.y})
            test.is_nil(interaction.capture, "the new press drops the old capture")
            test.is_nil(interaction.armed, "and the old armed button")
            local offset = interaction.offsets.items
            ui.event(plan, interaction, {type = "mouse", action = "motion", button = "left", x = list.x, y = list.y + 6})
            test.eq(interaction.offsets.items, offset, "a drag after the new press does not move the old thumb")
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "release", button = "left", x = ok.x, y = ok.y}),
                "letting go over the old button does not press it")

            interaction.armed, interaction.capture = {id = "ok", inside = true}, {id = "items", grab = 0}
            ui.release(interaction)
            test.is_nil(interaction.armed)
            test.is_nil(interaction.capture)
        end)
    end)

    -- One rule per divergence between the backends, expressed in cells. Cells
    -- are read as row strings; pixels through a stub raster that records every
    -- caption the renderer hands to `raster:text` and where it starts.
    test.describe("Window SDK: one rule for cells and pixels", function()
        local CELL = {w = 10, h = 20}
        local function font(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        local function captions(tree: any, cols: integer, rows: integer, face: any): any
            local drawn: any = {list = {}}
            local raster: any = {fill = function() end, rect = function() end, set = function() end, blit = function() end,
                text = function(_, x, y, caption) drawn.list[#drawn.list + 1] = {x = x, y = y, text = caption}; return 0 end}
            local store: any = {take = function() return raster, true end}
            local placed, why = render.placement({id = "rule", state_revision = 1,
                content_state = {sdk = 1, revision = 1, ui = tree}}, {x = 1, y = 1, cols = cols, rows = rows}, CELL, {face = face}, store)
            assert(placed, tostring(why))
            return drawn.list
        end
        local function caption_of(list: any, wanted: string): any
            for _, entry in ipairs(list) do if entry.text == wanted then return entry end end
            return nil
        end
        local function lines(tree: any, cols: integer, rows: integer): (any, any)
            local interaction = ui.interaction()
            local plan = ui.plan(tree, cols, rows, interaction)
            local out = {}
            for index, row in ipairs(cells.rows(plan, interaction, cols, rows)) do
                out[index] = (tostring(row):gsub("\27%[[%d;:]*m", ""))
            end
            return out, plan
        end

        test.it("list and table text start one cell in; a right-aligned column ends one cell early", function()
            local face = font()
            local tree = {kind = "column", children = {
                {kind = "list", id = "items", size = 3, items = {"one", "two"}},
                {kind = "table", id = "sizes", size = 3,
                    columns = {{title = "Name", weight = 1}, {title = "Size", width = 8, align = "right"}},
                    rows = {{id = "a", cells = {"alpha", "12"}}}},
            }}
            local rows, plan = lines(tree, 30, 6)
            local list, grid = plan.by_id.items.rect, plan.by_id.sizes.rect
            local size = ui.columns(plan.by_id.sizes.node, grid.w - 1)[2]
            -- In pixels the bar is 16 px of whole cells — two at this cell —
            -- so there the columns end one cell earlier.
            local pixel_size = ui.columns(plan.by_id.sizes.node, grid.w - widgets.scroll_cols(CELL.w))[2]
            -- Cells.
            test.eq(rows[list.y]:sub(list.x, list.x + 3), " one", "cells: a list row starts one cell in")
            local data = rows[grid.y + 1]
            test.eq(data:sub(grid.x, grid.x + 5), " alpha", "cells: a table cell starts one cell in")
            local ends_at = select(2, data:find("12", 1, true))
            test.eq(ends_at, grid.x + size.x + size.w - 2, "cells: a right-aligned value ends one cell before its column's end")
            -- Pixels: the same cells, in pixels.
            local drawn = captions(tree, 30, 6, face)
            local one, alpha, twelve = caption_of(drawn, "one"), caption_of(drawn, "alpha"), caption_of(drawn, "12")
            test.eq(one and one.x, (list.x - 1) * CELL.w + 1 + CELL.w, "pixels: a list row starts one cell in")
            test.eq(alpha and alpha.x, (grid.x - 1) * CELL.w + 1 + CELL.w, "pixels: a table cell starts one cell in")
            test.eq(twelve and (twelve.x + face:measure("12")), (grid.x - 1 + pixel_size.x + pixel_size.w - 1) * CELL.w + 1,
                "pixels: a right-aligned value ends one cell before its column's end")
        end)

        test.it("a caption that does not fit is cut with an ellipsis in both; one that fits is whole", function()
            local face = font()
            local long = "Changes take effect after wippy update and a restart"
            local tree = {kind = "column", children = {
                {kind = "label", size = 1, text = long},
                {kind = "label", size = 1, text = "Short"},
            }}
            local rows = lines(tree, 20, 2)
            local cut = rows[1]:gsub("%s+$", "")
            test.eq(cut:sub(-3), "…", "cells: the cut is marked: " .. cut)
            test.eq(long:find(cut:sub(1, -4), 1, true), 1, "cells: what is left is the start of the caption")
            test.eq(rows[2]:gsub("%s+$", ""), "Short", "cells: a caption that fits is whole")
            local drawn = captions(tree, 20, 2, face)
            local first = drawn[1] and drawn[1].text or ""
            test.eq(first:sub(-3), "…", "pixels: the cut is marked with the same ellipsis: " .. first)
            test.eq(long:find(first:sub(1, -4), 1, true), 1, "pixels: what is left is the start of the caption")
            test.not_nil(caption_of(drawn, "Short"), "pixels: a caption that fits is whole")
        end)

        test.it("a field takes one cell row in cells, the middle one, like a button", function()
            local rows = lines({kind = "column", children = {{kind = "field", size = 3, text = "42"}}}, 12, 3)
            test.is_nil(rows[1]:find("[^ ]"), "the row above the field is face: " .. rows[1])
            test.not_nil(rows[2]:find("42", 1, true), "the middle row holds the field")
            test.is_nil(rows[3]:find("[^ ]"), "the row below the field is face: " .. rows[3])
        end)
    end)

    -- The Windows 95 scrollbar is 16 px. In pixels it takes 16 px of whole
    -- cells — two at an 8 or 10 px cell, one at 20 — in every list, table,
    -- tree and icon grid, the same as the explorer's. The layout reserves
    -- those columns, so a press on the bar's leftmost column scrolls. In cells
    -- the bar stays one column.
    test.describe("Window SDK: the scrollbar is 16 px in pixels", function()
        local EXPECTED: any = {[8] = 2, [10] = 2, [20] = 1}
        local function scene(): any
            local items, rows, nodes, icons = {}, {}, {}, {}
            for index = 1, 30 do
                items[index] = "item " .. index
                rows[index] = {id = "r" .. index, cells = {"row " .. index, tostring(index)}}
                nodes[index] = {id = "n" .. index, label = "node " .. index, depth = 0, kind = "entry"}
            end
            for index = 1, 40 do icons[index] = {id = "i" .. index, title = "Icon " .. index} end
            return {kind = "column", children = {
                {kind = "list", id = "list", size = 4, items = items},
                {kind = "table", id = "table", size = 5, rows = rows,
                    columns = {{title = "Name", weight = 1}, {title = "Size", width = 6, align = "right"}}},
                {kind = "tree", id = "tree", size = 4, rows = nodes},
                {kind = "icons", id = "icons", size = 8, items = icons},
            }}
        end
        local function face(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        -- What the renderer draws, through a stub raster: every rectangle and
        -- every caption with its place.
        local function drawn(cell: any, font: any): any
            local out: any = {rects = {}, texts = {}}
            local raster: any = {fill = function() end, set = function() end, blit = function() end,
                rect = function(_, x, y, w, h) out.rects[#out.rects + 1] = {x = x, y = y, w = w, h = h} end,
                text = function(_, x, y, caption) out.texts[#out.texts + 1] = {x = x, y = y, text = caption}; return 0 end}
            local store: any = {take = function() return raster, true end}
            local placed, why = render.placement({id = "bars", state_revision = 1,
                content_state = {sdk = 1, revision = 1, ui = scene()}}, {x = 1, y = 1, cols = 36, rows = 21}, cell, {face = font}, store)
            assert(placed, tostring(why))
            return out
        end
        local function has_rect(list: any, want: any): boolean
            for _, r in ipairs(list) do
                if r.x == want.x and r.y == want.y and r.w == want.w and r.h == want.h then return true end
            end
            return false
        end
        local function pressed(x: any, y: any): any
            return {type = "mouse", action = "press", button = "left", x = x, y = y}
        end

        test.it("takes 16 px of whole cells in list, table, tree and icons", function()
            local font = face()
            for _, cw in ipairs({8, 10, 20}) do
                local cols = EXPECTED[cw]
                test.eq(widgets.scroll_cols(cw), cols, "the rule at a " .. cw .. " px cell")
                local plan = ui.plan(scene(), 36, 21, ui.interaction(), {scroll_cols = widgets.scroll_cols(cw)})
                local out = drawn({w = cw, h = 20}, font)
                for _, id in ipairs({"list", "table", "tree", "icons"}) do
                    local item = plan.by_id[id]
                    test.eq(item.bar_cols, cols, id .. ": the plan reserves the bar at " .. cw .. " px")
                    local r, header = item.rect, geometry.whole(item.header)
                    local ground = {x = (r.x - 1 + r.w - cols) * cw + 1, y = (r.y - 1 + header) * 20 + 1,
                        w = cols * cw, h = (r.h - header) * 20}
                    test.is_true(has_rect(out.rects, ground), id .. ": the bar is drawn " .. cols .. " cells wide at " .. cw .. " px")
                end
                local grid = plan.by_id.icons.rect
                for _, spot in ipairs(plan.by_id.icons.cells) do
                    test.is_true(spot.box.to < grid.x + grid.w - cols, "icon " .. spot.index .. " lies on the bar at " .. cw .. " px")
                end
                -- The table's right-aligned value ends one cell before its
                -- column's end, and the last column ends where the bar begins.
                local sheet = plan.by_id.table.rect
                local value: any = nil
                for _, entry in ipairs(out.texts) do if entry.text == "1" then value = entry end end
                test.not_nil(value, "the table draws its first row")
                test.eq(value.x + geometry.whole(font:measure("1")), (sheet.x - 1 + sheet.w - cols - 1) * cw + 1,
                    "the right-aligned value ends one cell before the bar at " .. cw .. " px")
            end
        end)

        test.it("a press on the bar's leftmost column scrolls; in cells the bar is one column", function()
            for _, id in ipairs({"list", "table", "tree", "icons"}) do
                local interaction = ui.interaction()
                local plan = ui.plan(scene(), 36, 21, interaction, {scroll_cols = 2})
                local r = plan.by_id[id].rect
                test.is_nil(ui.event(plan, interaction, pressed(r.x + r.w - 2, r.y + r.h - 1)),
                    id .. ": a press on the bar is not a selection")
                test.eq(interaction.offsets[id], 1, id .. ": the down arrow in the bar's leftmost column scrolls")
            end
            local interaction = ui.interaction()
            local plan = ui.plan(scene(), 36, 21, interaction, {scroll_cols = 2})
            local r = plan.by_id.list.rect
            local left = ui.event(plan, interaction, pressed(r.x + r.w - 3, r.y))
            test.eq(left and left.type, "select", "the column left of the bar is still a row")
            -- Cells: the bar is one column, so the same column is a row.
            local in_cells = ui.interaction()
            local cells_plan = ui.plan(scene(), 36, 21, in_cells)
            test.eq(cells_plan.by_id.list.bar_cols, 1, "cells: the bar is one column")
            local row = ui.event(cells_plan, in_cells, pressed(r.x + r.w - 2, r.y))
            test.eq(row and row.type, "select", "cells: the column left of the one-column bar is a row")
        end)

        test.it("a native window takes the bar width from the compositor's cell and follows a resize", function()
            test.eq(app.context({native = true, cell_w = 8}).scroll_cols, 2, "an 8 px cell")
            test.eq(app.context({native = true, cell_w = 20}).scroll_cols, 1, "a 20 px cell")
            test.eq(app.context({cell_w = 8}).scroll_cols, 1, "cells: one column whatever the cell")
            local context = app.context({native = true, cell_w = 20, width = 10, height = 5})
            app.resize(context, {type = "resize", width = 30, height = 12, cell_w = 10})
            test.eq(context.width .. "x" .. context.height .. ":" .. context.scroll_cols, "30x12:2")
        end)
    end)

    -- What the Connections window had to work around: a placeholder, a
    -- drop-down list, a Yes/No question and a label that wraps. Cells are read
    -- as row strings, pixels through a stub raster that records each caption,
    -- where it starts and its color.
    test.describe("Window SDK: placeholder, select, confirm and wrapped labels", function()
        local CELL = {w = 10, h = 20}
        local function face(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        local function rows_of(plan: any, interaction: any, cols: integer, rows: integer): any
            local out = {}
            for index, row in ipairs(cells.rows(plan, interaction, cols, rows)) do
                out[index] = (tostring(row):gsub("\27%[[%d;:]*m", ""))
            end
            return out
        end
        local function rows(tree: any, cols: integer, height: integer, interaction: any): any
            return rows_of(ui.plan(tree, cols, height, interaction), interaction, cols, height)
        end
        local function captions(tree: any, cols: integer, height: integer, interaction: any, font: any): any
            local drawn: any = {list = {}}
            local raster: any = {fill = function() end, rect = function() end, set = function() end, blit = function() end,
                text = function(_, x, y, caption, options)
                    drawn.list[#drawn.list + 1] = {x = x, y = y, text = caption,
                        color = type(options) == "table" and options.color or nil}
                    return 0
                end}
            local store: any = {take = function() return raster, true end}
            local placed, why = render.placement({id = "forms", state_revision = 1,
                content_state = {sdk = 1, revision = 1, ui = tree, interaction = interaction}},
                {x = 1, y = 1, cols = cols, rows = height}, CELL, {face = font}, store)
            assert(placed, tostring(why))
            return drawn.list
        end
        local function find(list: any, wanted: string): any
            for _, entry in ipairs(list) do if entry.text == wanted then return entry end end
            return nil
        end
        local function press(x: any, y: any): any
            return {type = "mouse", action = "press", button = "left", x = x, y = y}
        end
        local function key(name: string): any
            return {type = "key", action = "press", key_type = name, key = name}
        end
        local function trimmed(line: any): string
            return (tostring(line or ""):gsub("%s+$", ""))
        end

        test.it("an empty input shows its placeholder in grey until it is focused, and never sends it", function()
            local font = face()
            local function tree(value: any): any
                return {kind = "column", children = {
                    {kind = "button", id = "first", size = 2, text = "First"},
                    {kind = "input", id = "token", size = 2, text = value, placeholder = "e.g. 123:ABC"},
                }}
            end
            test.not_nil(table.concat(rows(tree(""), 30, 4, ui.interaction()), "\n"):find("e.g. 123:ABC", 1, true),
                "cells: an empty unfocused field shows the placeholder")
            test.is_nil(table.concat(rows(tree("abc"), 30, 4, ui.interaction()), "\n"):find("e.g.", 1, true),
                "cells: a value hides it")
            local focused = ui.interaction()
            focused.focus = "token"
            test.is_nil(table.concat(rows(tree(""), 30, 4, focused), "\n"):find("e.g.", 1, true),
                "cells: a focused field hides it")
            local hint = find(captions(tree(""), 30, 4, ui.interaction(), font), "e.g. 123:ABC")
            local value = find(captions(tree("abc"), 30, 4, ui.interaction(), font), "abc")
            test.not_nil(hint, "pixels: the placeholder is drawn")
            test.is_true(hint ~= nil and value ~= nil and hint.color ~= value.color, "pixels: in another color than a value")
            test.is_nil(find(captions(tree(""), 30, 4, focused, font), "e.g. 123:ABC"), "pixels: a focused field hides it")
            local plan = ui.plan(tree(""), 30, 4, focused)
            local typed = ui.event(plan, focused, {type = "key", action = "press", key_type = "runes", key = "x"})
            test.eq(typed and (typed.type .. ":" .. tostring(typed.value)), "change:x", "the typed text is the value, not the placeholder")
        end)

        test.it("a select opens under its field, chooses by a click or Enter, and steps with the arrows when closed", function()
            local font = face()
            local options = {{value = "a", label = "Alpha"}, {value = "b", label = "Beta"}, {value = "c", label = "Gamma"}}
            local function tree(value: any): any
                return {kind = "column", children = {
                    {kind = "select", id = "kind", size = 2, value = value, options = options},
                    {kind = "label", text = ""},
                }}
            end
            local interaction = ui.interaction()
            local plan = ui.plan(tree("b"), 30, 8, interaction)
            test.eq(table.concat(plan.focusable, ","), "kind", "a select takes focus")
            local field = plan.by_id.kind.rect
            local row = field.y + field.h // 2
            local shown = rows_of(plan, interaction, 30, 8)
            test.not_nil(shown[row]:find("Beta", 1, true), "cells: the field shows the chosen label")
            test.not_nil(shown[row]:find("▾", 1, true), "cells: the arrow button")
            test.not_nil(find(captions(tree("b"), 30, 8, ui.interaction(), font), "Beta"), "pixels: the chosen label")

            test.is_nil(ui.event(plan, interaction, press(field.x + 2, row)), "a click on the field opens, it is not a choice")
            plan = ui.plan(tree("b"), 30, 8, interaction)
            local popup = plan.by_id.kind.popup
            test.not_nil(popup, "the list is open")
            test.eq(popup.rect.y, row + 1, "the list starts straight under the field's row")
            test.eq(popup.cursor, 2, "the cursor stands on the chosen option")
            shown = rows_of(plan, interaction, 30, 8)
            test.not_nil(shown[row + 1]:find("Alpha", 1, true), "cells: the first option under the field")
            test.not_nil(shown[row + 3]:find("Gamma", 1, true), "cells: the third option")
            local drawn = captions(tree("b"), 30, 8, interaction, font)
            local gamma = find(drawn, "Gamma")
            test.eq(gamma and (gamma.y - 1) // CELL.h + 1, row + 3, "pixels: the third option on its row")

            local chosen = ui.event(plan, interaction, press(field.x + 2, row + 3))
            test.eq(chosen and (chosen.type .. ":" .. chosen.id .. ":" .. tostring(chosen.value)), "change:kind:c",
                "a click on a row chooses its value")
            test.is_nil(interaction.menus.kind, "a choice closes the list")

            plan = ui.plan(tree("b"), 30, 8, interaction)
            interaction.focus = "kind"
            local stepped = ui.event(plan, interaction, key("down"))
            test.eq(stepped and stepped.value, "c", "closed: Down steps to the next value")
            test.is_nil(ui.event(plan, interaction, key("enter")), "Enter opens")
            test.not_nil(interaction.menus.kind, "the list is open after Enter")
            plan = ui.plan(tree("b"), 30, 8, interaction)
            ui.event(plan, interaction, key("up"))
            plan = ui.plan(tree("b"), 30, 8, interaction)
            local picked = ui.event(plan, interaction, key("enter"))
            test.eq(picked and picked.value, "a", "open: Up and Enter choose Alpha")
            ui.event(plan, interaction, key("enter"))
            plan = ui.plan(tree("b"), 30, 8, interaction)
            test.is_nil(ui.event(plan, interaction, key("esc")), "Esc is not a choice")
            test.is_nil(interaction.menus.kind, "Esc closes the list")
            test.is_nil(ui.event(plan, interaction, press(field.x + 2, row)), "reopen")
            plan = ui.plan(tree("b"), 30, 8, interaction)
            test.is_nil(ui.event(plan, interaction, press(field.x + 2, 8)), "a click elsewhere is swallowed")
            test.is_nil(interaction.menus.kind, "and closes the list")
            test.not_nil(ui.problem({kind = "select", id = "bad", options = "a,b"}), "options must be a list")
        end)

        test.it("ui.message takes buttons, OK alone stays the default, and ui.confirm is Yes and No with No the default", function()
            local ok = ui.plan(ui.message({title = "About", lines = {"v1"}}), 40, 12, ui.interaction())
            test.is_true(ok.by_id.message_ok ~= nil and ok.by_id.message_ok.node.default == true, "one OK, the default")
            local plan = ui.plan(ui.message({title = "Delete?", buttons = {
                {id = "yes", text = "Yes"}, {id = "no", text = "No", default = true}}}), 40, 12, ui.interaction())
            test.is_nil(plan.by_id.message_ok, "the given buttons replace OK")
            test.is_false(plan.by_id.yes.node.default == true, "Yes is not the default")
            test.is_true(plan.by_id.no.node.default == true, "No is")
            test.is_true(plan.by_id.yes.rect.x < plan.by_id.no.rect.x, "in the given order")
            test.eq(plan.by_id.no.rect.x + plan.by_id.no.rect.w - 1, 39, "flush right inside the padding")
            local confirm = ui.plan(ui.confirm({title = "Delete the connection?", yes = "delete", no = "keep"}), 40, 12, ui.interaction())
            test.eq(confirm.by_id.delete.node.text .. "/" .. confirm.by_id.keep.node.text, "Yes/No")
            test.is_true(confirm.by_id.keep.node.default == true, "No is the default of a question")
            local save = ui.plan(ui.confirm({title = "Save?", default = "yes"}), 40, 12, ui.interaction())
            test.is_true(save.by_id.yes.node.default == true and save.by_id.no.node.default ~= true, "default = \"yes\" moves it")
        end)

        test.it("a wrapped label flows by words into its height and cuts only the last line", function()
            local text = "one two three four five six seven"
            local tree = {kind = "column", children = {{kind = "label", size = 3, wrap = true, text = text}}}
            local shown = rows(tree, 12, 3, ui.interaction())
            test.eq(trimmed(shown[1]) .. "|" .. trimmed(shown[2]) .. "|" .. trimmed(shown[3]), "one two|three four|five six se…",
                "cells: lines by words, the last one cut")
            local short = rows({kind = "column", children = {{kind = "label", size = 3, wrap = true, text = "one two"}}},
                12, 3, ui.interaction())
            test.eq(trimmed(short[1]), "one two", "cells: text that fits is whole, on the top row")
            local font = face()
            local long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda omicron sigma omega"
            local drawn = captions({kind = "column", children = {{kind = "label", size = 3, wrap = true, text = long}}},
                12, 3, ui.interaction(), font)
            test.eq(#drawn, 4, "pixels: as many 15 px lines as 60 px hold")
            for index, entry in ipairs(drawn) do
                test.is_true(font:measure(entry.text) <= 12 * CELL.w - 4, "pixels: line " .. index .. " fits the width")
                if index > 1 then test.eq(entry.y - drawn[index - 1].y, 15, "pixels: a 15 px step") end
                local cut = entry.text:sub(-3) == "…"
                test.eq(cut, index == #drawn, "pixels: only the last line is cut, line " .. index)
            end
        end)
    end)

    -- Pixel measures: a dialog named in Windows 95 pixels is laid out in the
    -- whole cells closest to them, and its buttons are drawn at their
    -- Windows 95 size inside their cells. Cells mode keeps the cell measures.
    test.describe("Window SDK: pixel measures", function()
        test.it("size_px, padding_px and gap_px round to whole cells in pixels; cells keep size, padding and gap", function()
            local tree = {kind = "column", padding = 2, padding_px = 7, gap = 2, gap_px = 11, children = {
                {kind = "label", size = 3, size_px = 45, text = "a"},
                {kind = "row", size = 2, gap = 2, gap_px = 11, children = {
                    {kind = "button", id = "left", size = 5, size_px = 38, text = "L"},
                    {kind = "button", id = "right", size = 5, size_px = 38, text = "R"},
                }},
            }}
            local in_pixels = ui.plan(tree, 40, 20, ui.interaction(), {cell = {w = 10, h = 20}})
            local in_cells = ui.plan(tree, 40, 20, ui.interaction())
            local label, plain = in_pixels.items[1].rect, in_cells.items[1].rect
            test.eq(label.x .. "," .. label.y .. " h" .. label.h, "2,1 h2", "pixels: 7 px is one column and no row, 45 px two rows")
            test.eq(plain.x .. "," .. plain.y .. " h" .. plain.h, "3,3 h3", "cells: padding 2, size 3")
            local l, r = in_pixels.by_id.left.rect, in_pixels.by_id.right.rect
            test.eq(l.w .. "+" .. (r.x - l.x - l.w) .. "+" .. r.w, "4+1+4", "pixels: 38 px is four columns, an 11 px gap one")
            test.eq(l.y - (label.y + label.h), 1, "pixels: an 11 px gap is one row at 20 px")
            local cl, cr = in_cells.by_id.left.rect, in_cells.by_id.right.rect
            test.eq(cl.w .. "+" .. (cr.x - cl.x - cl.w), "5+2", "cells: size 5, gap 2")
        end)
        test.it("a right-aligned row packs 75 px buttons 6 px apart from its right edge, each inside its own cells", function()
            local row = {kind = "row", size = 2, size_px = 30, align = "right", children = {
                {kind = "button", id = "a", size = 10, size_px = 81, width_px = 75, text = "A"},
                {kind = "button", id = "b", size = 10, size_px = 81, width_px = 75, text = "B"},
                {kind = "button", id = "c", size = 10, size_px = 81, width_px = 75, text = "C"},
            }}
            for _, cw in ipairs({8, 10}) do
                local plan = ui.plan(row, 40, 2, ui.interaction(), {cell = {w = cw, h = 20}})
                local a, b, c = plan.by_id.a, plan.by_id.b, plan.by_id.c
                for _, entry in ipairs({a, b, c}) do
                    local item: any = entry
                    test.eq(item.px and item.px.w, 75, cw .. " px: " .. item.node.id .. " is 75 px")
                    test.is_true(item.px.x >= (item.rect.x - 1) * cw + 1 and item.px.x + 74 <= (item.rect.x + item.rect.w - 1) * cw,
                        cw .. " px: " .. item.node.id .. " is drawn inside its own cells")
                end
                test.eq((b.px.x - a.px.x - 75) .. "," .. (c.px.x - b.px.x - 75), "6,6", cw .. " px: 6 px apart")
                test.eq(c.px.x + 74, 40 * cw, cw .. " px: flush with the row's right edge")
            end
            test.is_nil(ui.plan(row, 40, 2, ui.interaction()).by_id.a.px, "cells: nothing is packed")
        end)
        test.it("tabs are measured by their captions in pixels, so four Windows 95 tabs fit", function()
            local tabs = {kind = "tabs", id = "t", labels = {"Background", "Screen Saver", "Appearance", "Settings"}, children = {}}
            test.eq(#ui.plan(tabs, 42, 6, ui.interaction(), {cell = {w = 8, h = 16}}).by_id.t.spans, 4, "8 px cells: all four")
            test.eq(#ui.plan(tabs, 42, 6, ui.interaction()).by_id.t.spans, 2, "cells: a cell per character keeps two")
            local tight: any = {kind = "tabs", id = "t", pad = 1, labels = {"Background", "Saver", "Appearance", "Settings"}, children = {}}
            test.eq(#ui.plan(tight, 42, 6, ui.interaction()).by_id.t.spans, 4, "cells: pad = 1 and a short caption fit four")
        end)
        test.it("a native window plans with the compositor's cell and follows a resize", function()
            local context = app.context({native = true, cell_w = 8, cell_h = 16})
            test.eq(context.cell and (context.cell.w .. "x" .. context.cell.h), "8x16")
            test.is_nil(app.context({cell_w = 8, cell_h = 16}).cell, "cells: no pixel cell")
            app.resize(context, {type = "resize", width = 30, height = 12, cell_w = 10, cell_h = 20})
            test.eq(context.cell.w .. "x" .. context.cell.h, "10x20")
        end)
    end)

    -- The two Settings controls of "Display Properties": a Windows 95
    -- trackbar and the palette's spectrum bar.
    test.describe("Window SDK: slider and spectrum", function()
        local function row_of(plan: any, interaction: any, cols: integer): string
            return (tostring(cells.rows(plan, interaction, cols, 1)[1]):gsub("\27%[[%d;:]*m", ""))
        end
        test.it("a slider changes by keys and clicks within min..max; a disabled one takes nothing", function()
            local tree = {kind = "column", children = {{kind = "slider", id = "s", size = 1, value = 2, min = 0, max = 4}}}
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 21, 1, interaction)
            test.eq(table.concat(plan.focusable, ","), "s", "a slider takes focus")
            local function key(name: string): any
                return ui.event(plan, interaction, {type = "key", action = "press", key_type = name, key = name})
            end
            local function click(x: integer): any
                return ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = x, y = 1})
            end
            local steps = {}
            for _, name in ipairs({"right", "left", "home", "end", "pgup"}) do
                local action = key(name)
                steps[#steps + 1] = name .. "=" .. tostring(action and action.value)
            end
            test.eq(table.concat(steps, " "), "right=3 left=1 home=0 end=4 pgup=3", "keys step from the value")
            test.eq(click(21) and click(21).value, 4, "the right end is max")
            test.eq(click(1) and click(1).value, 0, "the left end is min")
            test.is_nil(click(11), "the thumb's own column is no change")
            local before = row_of(plan, interaction, 21):match("^(.-)█")
            test.eq(select(2, (before or ""):gsub("─", "")), ui.slider_position(tree.children[1], 21),
                "cells: the thumb stands in the column the hit test uses")
            test.eq(ui.slider_position(tree.children[1], 21), 10, "value 2 of 0..4 is the middle of 21 columns")
            local off = {kind = "column", children = {{kind = "slider", id = "s", size = 1, value = 2, min = 0, max = 4, disabled = true}}}
            local frozen = ui.interaction()
            local plan_off = ui.plan(off, 21, 1, frozen)
            test.eq(#plan_off.focusable, 0, "a disabled slider takes no focus")
            test.is_nil(ui.event(plan_off, frozen, {type = "mouse", action = "press", button = "left", x = 21, y = 1}),
                "and no clicks")
        end)
        test.it("the spectrum runs from magenta to red by one rule in both renderers", function()
            test.eq(ui.spectrum_color(0) .. " " .. ui.spectrum_color(0.5) .. " " .. ui.spectrum_color(1), "#ff00ff #00ff80 #ff0000")
            local tree = {kind = "column", children = {{kind = "spectrum", size = 1}}}
            test.is_nil(ui.problem(tree), "a spectrum needs no id")
            test.eq(#row_of(ui.plan(tree, 12, 1, ui.interaction()), ui.interaction(), 12), 12, "cells: one cell per step")
            local colors: any = {}
            local raster: any = {fill = function() end, set = function() end, blit = function() end, text = function() return 0 end,
                rect = function(_, x, y, w, h, color) colors[#colors + 1] = color end}
            local store: any = {take = function() return raster, true end}
            assert(render.placement({id = "spectrum", state_revision = 1, content_state = {sdk = 1, revision = 1, ui = tree}},
                {x = 1, y = 1, cols = 12, rows = 1}, {w = 10, h = 20}, {}, store))
            local seen = table.concat(colors, " ")
            test.not_nil(seen:find("#ff00ff", 1, true), "pixels: magenta at the left end")
            test.not_nil(seen:find("#ff0000", 1, true), "pixels: red at the right end")
        end)
    end)

    test.describe("Window SDK: radio", function()
        test.it("a radio button is chosen by a click, Space or Enter, and never unchosen by itself", function()
            local tree = {kind = "row", children = {
                {kind = "radio", id = "tile", size = 10, text = "Tile", checked = false},
                {kind = "radio", id = "center", size = 10, text = "Center", checked = true},
            }}
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 20, 1, interaction)
            test.eq(table.concat(plan.focusable, ","), "tile,center", "radio buttons take focus")
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 2, y = 1}))
            local clicked = ui.event(plan, interaction, {type = "mouse", action = "release", button = "left", x = 2, y = 1})
            test.eq(clicked and (clicked.type .. ":" .. clicked.id .. ":" .. tostring(clicked.value)), "change:tile:true", "a click chooses")
            interaction.focus = "center"
            test.is_nil(ui.event(plan, interaction, {type = "key", action = "press", key_type = "runes", key = " "}),
                "choosing the chosen one again changes nothing")
            interaction.focus = "tile"
            local spaced = ui.event(plan, interaction, {type = "key", action = "press", key_type = "space", key = "space"})
            test.eq(spaced and spaced.id, "tile", "Space chooses")
            local row = (tostring(cells.rows(plan, interaction, 20, 1)[1]):gsub("\27%[[%d;:]*m", ""))
            test.not_nil(row:find("( ) Tile", 1, true), "cells: an empty ring: " .. row)
            test.not_nil(row:find("(•) Center", 1, true), "cells: the dot in the chosen one: " .. row)
            local sets: any = {}
            local raster: any = {fill = function() end, rect = function() end, blit = function() end, text = function() return 0 end,
                set = function(_, x, y, color) sets[tostring(x) .. "," .. tostring(y)] = color end}
            local store: any = {take = function() return raster, true end}
            assert(render.placement({id = "radio", state_revision = 1, content_state = {sdk = 1, revision = 1, ui = tree}},
                {x = 1, y = 1, cols = 20, rows = 1}, {w = 10, h = 20}, {}, store))
            -- Each ring is 12×12, 4 px under the top of its 20 px row: the centre
            -- of the first is (6, 10), of the second (106, 10).
            test.eq(sets["106,10"], "#000000", "pixels: the chosen one has its black dot")
            test.is_true(sets["6,10"] ~= nil and sets["6,10"] ~= "#000000", "pixels: the other one's well is empty")
        end)
    end)

    -- The client by rows: a placement per row, an unchanged row keeps its
    -- raster and version, so the surface does not re-send it. The costs go to
    -- shots/sdk-rows-cost.txt.
    test.describe("Window SDK: a menu's drop-down", function()
        local function face(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        -- Integers on both sides: go-lua's `//` and math.max give floats, and
        -- "18" and "18.0" must not differ in a comparison of positions.
        local function int(value: any): string
            return tostring(math.tointeger(math.floor(tonumber(value) or 0)))
        end
        -- Minesweeper's shape: a bar, and the counter row right under it.
        local function tree(): any
            return {kind = "column", children = {
                {kind = "menu", id = "bar", size = 1, entries = {
                    {title = "Game", accel = 1, items = {
                        {id = "new", text = "New", accel = 1},
                        {separator = true},
                        {id = "exit", text = "Exit", accel = 2},
                    }},
                }},
                {kind = "label", text = "000"},
            }}
        end
        local function opened(): any
            local interaction = ui.interaction()
            interaction.menus = {bar = {index = 1, cursor = 0}}
            return interaction
        end

        test.it("touches the bar in pixels at 8x16 and 10x20: no frame row, the first item row is New", function()
            local font = face()
            for _, cell in ipairs({{w = 8, h = 16}, {w = 10, h = 20}}) do
                local label = cell.w .. "x" .. cell.h .. ": "
                local interaction = opened()
                local plan = ui.plan(tree(), 30, 10, interaction, {cell = cell})
                local bar = plan.by_id.bar
                local popup = bar.popup
                test.not_nil(popup, label .. "the menu is open")
                test.eq(popup.rect.y, bar.rect.y + bar.rect.h, label .. "the list starts in the row under the bar")
                test.eq(popup.rect.h, #popup.rows, label .. "the list is its items alone, no frame rows")
                local box = render.menu_box(popup, cell)
                test.eq(int(box.y), int((bar.rect.y + bar.rect.h - 1) * cell.h + 1),
                    label .. "the panel's top pixel row is the one under the bar")
                test.eq(int(box.first), int(box.y), label .. "the first item lies in the panel's first row")

                -- The painter draws exactly that panel, and underlines the N
                -- of New centred in its band: the row less the frame at the top.
                local rects: any = {}
                local raster: any = {fill = function() end, set = function() end, blit = function() end,
                    text = function() return 0 end,
                    rect = function(_, x, y, w, h)
                        rects[#rects + 1] = int(x) .. "," .. int(y) .. "," .. int(w) .. "," .. int(h)
                    end}
                local store: any = {take = function() return raster, true end}
                assert(render.placement({id = "mines", state_revision = 1, content_state = {sdk = 1, revision = 1,
                    interaction = opened(), ui = tree()}}, {x = 1, y = 1, cols = 30, rows = 10}, cell, {face = font}, store))
                local drawn = " " .. table.concat(rects, " ") .. " "
                local panel = int(box.x) .. "," .. int(box.y) .. "," .. int(box.w) .. "," .. int(box.h)
                test.not_nil(drawn:find(" " .. panel .. " ", 1, true), label .. "the panel is painted at " .. panel)
                local frame = render.MENU_FRAME
                local underline = int(box.x + 2 * cell.w) .. "," .. int(box.first + frame + (cell.h - frame - 15) // 2 + 13) .. ","
                    .. int(math.max(1, (font:measure("N")))) .. ",1"
                test.not_nil(drawn:find(" " .. underline .. " ", 1, true),
                    label .. "the accelerator of New is underlined at " .. underline)
                -- Exit, the last item, is centred in its band: the row less the
                -- frame at the bottom.
                local last = box.first + 2 * cell.h
                local exit_underline = int(box.x + 2 * cell.w + font:measure("E")) .. ","
                    .. int(last + (cell.h - frame - 15) // 2 + 13) .. "," .. int(math.max(1, (font:measure("x")))) .. ",1"
                test.not_nil(drawn:find(" " .. exit_underline .. " ", 1, true),
                    label .. "the accelerator of Exit is underlined at " .. exit_underline)

                local chosen = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                    x = popup.rect.x + 1, y = popup.rect.y})
                test.eq(chosen and chosen.id, "new", label .. "a click on the first item row is New")
                -- The frame took pixels, not rows: the last cell row is still Exit.
                local again = opened()
                local replanned = ui.plan(tree(), 30, 10, again, {cell = cell})
                local exit = ui.event(replanned, again, {type = "mouse", action = "press", button = "left",
                    x = popup.rect.x + 1, y = popup.rect.y + 2})
                test.eq(exit and exit.id, "exit", label .. "a click on the last item row is Exit")
            end
        end)

        test.it("keeps the frame rows in cells: the box's top row, then New", function()
            local interaction = opened()
            local plan = ui.plan(tree(), 30, 10, interaction)
            local popup = plan.by_id.bar.popup
            test.eq(popup.rect.y, 2)
            test.eq(popup.rect.h, #popup.rows + 2, "a frame row above and below the items")
            local rows: any = cells.rows(plan, interaction, 30, 10)
            local line = tostring(rows[3]):gsub("\27%[[%d;:]*m", "")
            test.not_nil(line:find("New", 1, true), "New is drawn under the frame row: " .. line)
            local chosen = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = popup.rect.x + 1, y = popup.rect.y + 1})
            test.eq(chosen and chosen.id, "new", "a click on New's row is New")
        end)

        -- Windows 95's popup menu: a 3 px frame (face, then white at the
        -- top-left; black, then dark gray at the bottom-right; a pixel of
        -- face) inside the whole cell rows the hits count. One pixel at a
        -- time, from the real raster.
        test.it("frames the list as Windows 95 inside its rows: the first band under the frame, the last over it", function()
            local fonts = {face = face()}
            local frame = render.MENU_FRAME
            local FACE, WHITE, DARK, BLACK, BLUE = "#c0c0c0", "#ffffff", "#808080", "#000000", "#000080"
            local function probe(raster: any, x: any, y: any): string
                local part = gfx.raster(1, 1)
                part:blit(raster, geometry.whole(2 - x), geometry.whole(2 - y))
                return assert(part:encode("png"))
            end
            local function filled(colour: string): string
                local part = gfx.raster(1, 1)
                part:fill(colour)
                return assert(part:encode("png"))
            end
            for _, cell in ipairs({{w = 10, h = 20}, {w = 8, h = 16}}) do
                -- New highlighted, then Exit: the first band's top, the last one's bottom.
                for _, cursor in ipairs({1, 3}) do
                    local label = cell.w .. "x" .. cell.h .. ", cursor " .. cursor .. ": "
                    local function interaction(): any
                        local made = opened()
                        made.menus.bar.cursor = cursor
                        return made
                    end
                    local popup = ui.plan(tree(), 30, 10, interaction(), {cell = cell}).by_id.bar.popup
                    local box = render.menu_box(popup, cell)
                    local store = rasters.store()
                    store.begin()
                    local placed = assert(render.placement({id = "mines", state_revision = 1, content_state = {sdk = 1,
                        revision = 1, interaction = interaction(), ui = tree()}}, {x = 1, y = 1, cols = 30, rows = 10},
                        cell, fonts, store))
                    local function sees(x: any, y: any, colour: string, what: string)
                        test.eq(probe(placed.raster, x, y), filled(colour), label .. what .. " at " .. int(x) .. "," .. int(y))
                    end
                    local left, top = box.x, box.y
                    local right, bottom = box.x + box.w - 1, box.y + box.h - 1
                    sees(left, top, FACE, "top-left: face outermost")
                    sees(left + 1, top + 1, WHITE, "then white")
                    sees(left + 2, top + 2, FACE, "then a pixel of face")
                    sees(right, top, BLACK, "top-right: black outermost")
                    sees(right - 1, top + 1, DARK, "then dark gray")
                    sees(left, bottom, BLACK, "bottom-left: black")
                    sees(left + 1, bottom - 1, DARK, "then dark gray")
                    sees(right, bottom, BLACK, "bottom-right: black")
                    sees(right - 1, bottom - 1, DARK, "then dark gray")
                    -- The separator: dark over light, 2 px in from the frame.
                    local line = box.first + cell.h + cell.h // 2 - 1
                    sees(left + frame + 2, line, DARK, "the separator's dark line starts 2 px in")
                    sees(left + frame + 1, line, FACE, "face before it")
                    sees(right - frame - 2, line, DARK, "and ends 2 px in")
                    sees(right - frame - 1, line, FACE, "face after it")
                    sees(left + frame + 2, line + 1, WHITE, "the light line under it")
                    if cursor == 1 then
                        sees(left + frame, top + frame, BLUE, "the first band's top, under the frame")
                        sees(left + frame, top + frame - 1, FACE, "the frame's face above it")
                        sees(left + frame - 1, top + frame, FACE, "and beside it")
                        sees(left + frame, box.first + cell.h - 1, BLUE, "the band reaches its row's end")
                        sees(left + frame, box.first + cell.h, FACE, "and stops there")
                    else
                        local row = box.first + 2 * cell.h
                        sees(left + frame, bottom - frame, BLUE, "the last band's bottom, over the frame")
                        sees(left + frame, bottom - frame + 1, FACE, "the frame's face under it")
                        sees(right - frame, row, BLUE, "the band's right end")
                        sees(right - frame + 1, row, FACE, "the frame beside it")
                        sees(left + frame, row - 1, FACE, "the band starts at its row")
                    end
                end
            end
        end)
    end)

    test.describe("Window SDK: the end of a list, and a read-only text", function()
        local function face(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        local function numbered(count: integer): any
            local items = {}
            for index = 1, count do items[index] = "item " .. index end
            return items
        end
        local function wheel(y: integer): any
            return {type = "mouse", action = "wheel", button = "wheel_down", x = 3, y = y}
        end
        local function key(name: string, key_type: string): any
            return {type = "key", key = name, key_type = key_type, action = "press"}
        end

        test.it("a list says end when the wheel pushes down with its last row on screen", function()
            local state = ui.interaction()
            local tree = {kind = "list", id = "items", items = numbered(30)}
            local plan = ui.plan(tree, 20, 10, state)
            test.is_nil(ui.event(plan, state, wheel(4)), "far from the end the wheel only scrolls")
            test.eq(state.offsets.items, 3)
            state.offsets.items = 17
            plan = ui.plan(tree, 20, 10, state)
            local action: any = ui.event(plan, state, wheel(4))
            test.not_nil(action)
            test.eq(action.type, "end")
            test.eq(action.id, "items")
            test.eq(action.offset, 20, "the offset the wheel reached: the last page")
            test.eq(action.total, 30)
            test.eq(ui.event(plan, state, wheel(4)).type, "end", "pushing again at the end says it again")
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "wheel", button = "wheel_up", x = 3, y = 4}),
                "the wheel up is not the end")
            local short_plan = ui.plan({kind = "list", id = "short", items = numbered(4)}, 20, 10, state)
            test.eq(ui.event(short_plan, state, wheel(2)).type, "end", "a list that fits is at its end")
            test.is_nil(ui.event(short_plan, state, {type = "mouse", action = "wheel", button = "wheel_up", x = 3, y = 2}),
                "the wheel up on a list that fits is still not the end")
            test.is_nil(ui.event(ui.plan({kind = "list", id = "empty", items = {}}, 20, 10, state), state, wheel(2)),
                "an empty list has no last row")
        end)

        test.it("a table counts its rows below the header", function()
            local rows = {}
            for index = 1, 12 do rows[index] = {id = "r" .. index, cells = {"row " .. index}} end
            local state = ui.interaction()
            local plan = ui.plan({kind = "table", id = "events", columns = {{title = "Name", weight = 1}}, rows = rows},
                20, 6, state)
            state.offsets.events = 6
            local action: any = ui.event(plan, state, wheel(3))
            test.eq(action.type, "end")
            test.eq(action.offset, 7, "five rows under the header: the last page starts at 7")
        end)

        test.it("keys past the last row say end; reaching it is still a select", function()
            local state = ui.interaction()
            local tree = {kind = "list", id = "items", items = numbered(30), selected = 29}
            local plan = ui.plan(tree, 20, 10, state)
            state.focus = "items"
            local reached: any = ui.event(plan, state, key("down", "down"))
            test.eq(reached.type, "select")
            test.eq(reached.index, 30)
            tree.selected = 30
            plan = ui.plan(tree, 20, 10, state)
            state.focus = "items"
            for _, pushed in ipairs({{"down", "down"}, {"page_down", "pgdown"}, {"end", "end"}}) do
                local action: any = ui.event(plan, state, key(pushed[1], pushed[2]))
                test.eq(action.type, "end", pushed[1] .. " at the last row")
                test.eq(action.total, 30)
            end
            test.eq(ui.event(plan, state, key("up", "up")).index, 29)
        end)

        test.it("end and scroll are drawn even when update ignores them", function()
            local definition = {update = function() return false end}
            local context = app.context({})
            test.is_true(app.dispatch(definition, {}, context, {type = "end", id = "items"}))
            test.is_true(app.dispatch(definition, {}, context, {type = "scroll", id = "payload"}))
            test.is_false(app.dispatch(definition, {}, context, {type = "select", id = "items"}),
                "any other action keeps update's verdict")
        end)

        test.it("a text wraps by characters after a space, keeping its lines and indents", function()
            local lines = ui.wrap_text("один два три", 8)
            test.eq(#lines, 2)
            test.eq(lines[1], "один ")
            test.eq(lines[2], "два три")
            test.eq(table.concat(ui.wrap_text("абвгдежз", 3), "|"), "абв|где|жз", "a word longer than the line is cut")
            test.eq(table.concat(ui.wrap_text("a\n\nb", 10), "|"), "a||b", "an empty line stays")
            test.eq(table.concat(ui.wrap_text("x\r\ny", 10), "|"), "x|y")
            test.eq(ui.wrap_text("    \"key\": 1", 40)[1], "    \"key\": 1", "an indent stays")
            test.eq(#ui.wrap_text(string.rep("w", 50), 10, false), 1, "wrap = false keeps a line whole")
            test.eq(#ui.wrap_text("", 10), 1)
        end)

        test.it("a text with an id scrolls by lines — wheel, bar and keys, each a scroll action", function()
            local rows = {}
            for index = 1, 40 do rows[index] = "line " .. index end
            local state = ui.interaction()
            local tree = {kind = "text", id = "payload", text = table.concat(rows, "\n")}
            local plan = ui.plan(tree, 30, 10, state)
            local item: any = plan.by_id.payload
            test.eq(#item.lines, 40)
            test.eq(item.page, 10)
            test.eq(item.bar.limit, 30, "forty lines on a page of ten")
            test.eq(plan.focusable[1], "payload", "with an id it takes the focus")
            local moved: any = ui.event(plan, state, wheel(3))
            test.eq(moved.type, "scroll")
            test.eq(moved.offset, 3)
            test.eq(moved.total, 40)
            test.eq(state.offsets.payload, 3)
            state.focus = "payload"
            test.eq(ui.event(plan, state, key("page_down", "pgdown")).offset, 13, "the keys count from the state, like the wheel")
            test.eq(ui.event(plan, state, key("down", "down")).offset, 14)
            test.eq(ui.event(plan, state, key("end", "end")).offset, 30)
            test.eq(ui.event(plan, state, key("up", "up")).offset, 29)
            test.eq(ui.event(plan, state, key("home", "home")).offset, 0)
            test.is_nil(ui.event(plan, state, {type = "key", key = "x", key_type = "runes", action = "press"}),
                "a letter is not the text's: it goes to the application")
            state.offsets.payload = 0
            plan = ui.plan(tree, 30, 10, state)
            local arrow: any = ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 30, y = 10})
            test.eq(arrow.type, "scroll", "the bar's down arrow")
            test.eq(arrow.offset, 1)
            test.is_nil(ui.event(plan, state, {type = "mouse", action = "press", button = "left", x = 5, y = 5}),
                "a press on the text itself only focuses it")
            local wide = ui.plan({kind = "text", id = "wide", text = string.rep("word ", 12)}, 30, 10, ui.interaction())
            test.eq(#wide.by_id.wide.lines, 3, "wrapped by the width minus the bar and the air: 28 characters")
            local edge = ui.plan({kind = "column", children = {
                {kind = "text", id = "fits", text = string.rep("a", 28), size = 5},
                {kind = "text", id = "over", text = string.rep("a", 29), size = 5},
            }}, 30, 10, ui.interaction())
            test.eq(#edge.by_id.fits.lines, 1, "28 characters are one line")
            test.eq(#edge.by_id.over.lines, 2, "29 are two: the bar's column and the air are not text")
        end)

        test.it("a text without an id is inert: no focus, no scroll, no problem", function()
            local state = ui.interaction()
            local tree = {kind = "column", children = {{kind = "text", text = "a\nb\nc\nd"}, {kind = "button", id = "ok", text = "OK"}}}
            test.is_nil(ui.problem(tree))
            local plan = ui.plan(tree, 20, 4, state)
            test.eq(#plan.focusable, 1, "only the button takes the focus")
            test.is_nil(ui.event(plan, state, wheel(1)))
            test.is_nil(next(state.offsets), "no offset is kept for it")
            test.not_nil(ui.problem({kind = "column", children = {{kind = "text", id = "t", text = ""},
                {kind = "text", id = "t", text = ""}}}), "an id, when given, is unique")
        end)

        test.it("both renderers draw the plan's lines from the offset", function()
            local rows = {}
            for index = 1, 20 do rows[index] = "line " .. index end
            local interaction = ui.interaction()
            interaction.offsets.payload = 3
            local tree = {kind = "text", id = "payload", text = table.concat(rows, "\n")}
            local plan = ui.plan(tree, 20, 4, interaction)
            local first = (tostring(cells.rows(plan, interaction, 20, 4)[1]):gsub("\27%[[%d;:]*m", ""))
            test.eq(first:sub(1, 7), " line 4", "cells: one cell in, from the offset")
            local texts: any = {}
            local raster: any = {fill = function() end, rect = function() end, set = function() end, blit = function() end,
                text = function(_, x, y, caption) texts[#texts + 1] = tostring(caption); return 0 end}
            local store: any = {take = function() return raster, true end}
            assert(render.placement({id = "text", state_revision = 1, content_state = {sdk = 1, revision = 1,
                interaction = interaction, ui = tree}}, {x = 1, y = 1, cols = 20, rows = 4}, {w = 10, h = 20},
                {face = face()}, store))
            test.eq(texts[1], "line 4", "pixels: the same lines from the same offset")
            test.eq(#texts, 4, "a line per row, nothing else written")
        end)
    end)

    test.describe("Window SDK: client rows", function()
        local function face(): any
            local files = assert(fs.get("app:system_fonts"))
            return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
        end
        local function list_window(selected: integer, revision: integer): any
            local items = {}
            for index = 1, 10 do items[index] = "item " .. index end
            return {id = "rows", state_revision = revision, content_state = {sdk = 1, revision = revision,
                interaction = ui.interaction(),
                ui = {kind = "column", children = {{kind = "list", id = "items", items = items, selected = selected}}}}}
        end
        local function ms(from: any, to: any): string
            return string.format("%.2f", (to - from) / 1000000.0)
        end
        test.it("only the rows whose content changed are repainted; the same revision repaints none; a resize all", function()
            local fonts = {face = face()}
            local store = rasters.store()
            local inner, cell = {x = 1, y = 1, cols = 50, rows = 15}, {w = 10, h = 20}
            store.begin()
            local t0 = time.now():unix_nano()
            local first = assert(render.rows(list_window(2, 1), inner, cell, fonts, store))
            local t1 = time.now():unix_nano()
            test.eq(#first, 15, "a placement per client row")
            test.eq(first[3].id .. " " .. first[3].y .. " " .. first[3].rows, "win:rows:sdk:row:3 3 1", "a row placement is one row")
            local before: any = {}
            for _, placed in ipairs(first) do before[placed.id] = {raster = placed.raster, version = placed.raster:version()} end

            store.begin()
            local t2 = time.now():unix_nano()
            local second = assert(render.rows(list_window(5, 2), inner, cell, fonts, store))
            local t3 = time.now():unix_nano()
            local dirty = {}
            for _, placed in ipairs(second) do
                local was: any = before[placed.id]
                test.eq(placed.raster, was.raster, "a row keeps its raster: " .. placed.id)
                if placed.raster:version() ~= was.version then dirty[#dirty + 1] = placed.id:match(":row:(%d+)$") end
            end
            test.eq(table.concat(dirty, ","), "2,5", "rows unchanged were re-sent: only the old and the new selection may be")

            local versions: any = {}
            for _, placed in ipairs(second) do versions[placed.id] = placed.raster:version() end
            store.begin()
            local calls: any = {count = 0}
            local plan = ui.plan
            ui.plan = function(...) calls.count = calls.count + 1; return plan(...) end
            local third = assert(render.rows(list_window(5, 2), inner, cell, fonts, store))
            ui.plan = plan
            test.eq(calls.count, 0, "the same revision is not laid out again")
            for _, placed in ipairs(third) do
                test.eq(placed.raster:version(), versions[placed.id], "the same revision repaints nothing: " .. placed.id)
            end

            store.begin()
            local wider = assert(render.rows(list_window(5, 2), {x = 1, y = 1, cols = 52, rows = 15}, cell, fonts, store))
            local repainted = 0
            for _, placed in ipairs(wider) do
                if placed.raster ~= before[placed.id].raster then repainted = repainted + 1 end
            end
            test.eq(repainted, 15, "a resize repaints every row")

            -- The cost, for the report: the whole client as one placement against the rows.
            local whole_store = rasters.store()
            whole_store.begin()
            local t4 = time.now():unix_nano()
            local single = assert(render.placement(list_window(2, 1), inner, cell, fonts, whole_store))
            local t5 = time.now():unix_nano()
            local png_whole = single.raster:encode("png")
            local t6 = time.now():unix_nano()
            for _, placed in ipairs(second) do
                if placed.id:match(":row:[25]$") then placed.raster:encode("png") end
            end
            local t7 = time.now():unix_nano()
            test.not_nil(png_whole)
            assert(assert(fs.get("app:shots")):writefile("sdk-rows-cost.txt", string.format(
                "50x15 client at 10x20 (500x300 px), a 10-item list, the selection moved from 2 to 5\n"
                .. "one raster: every revision re-sends 150000 px; paint %s ms, PNG encode of the whole %s ms\n"
                .. "rows, first frame: 15 placements, 150000 px; plan + keys + paint + 15 blits %s ms\n"
                .. "rows, next revision: 2 placements re-sent, 20000 px; plan + keys + paint + 2 blits %s ms; "
                .. "PNG encode of the 2 rows %s ms\n",
                ms(t4, t5), ms(t5, t6), ms(t0, t1), ms(t2, t3), ms(t6, t7))))
        end)
        test.it("a graph's integer ceiling is printed as digits", function()
            local texts: any = {}
            local raster: any = {fill = function() end, rect = function() end, set = function() end, blit = function() end,
                text = function(_, x, y, caption) texts[#texts + 1] = tostring(caption); return 0 end}
            local store: any = {take = function() return raster, true end}
            -- Both ways a ceiling reaches the caption: declared, and computed by
            -- charts.ceiling_of (all-zero values give its floor of 1).
            for _, case in ipairs({{ceiling = 40, values = {1, 2, 3}, caption = "40 MB"},
                                   {values = {0, 0, 0}, caption = "1 MB"}}) do
                local from = #texts + 1
                assert(render.placement({id = "graph", state_revision = 1, content_state = {sdk = 1, revision = 1,
                    ui = {kind = "graph", values = case.values, ceiling = case.ceiling, unit = " MB"}}},
                    {x = 1, y = 1, cols = 20, rows = 6}, {w = 10, h = 20}, {face = face()}, store))
                local seen = table.concat(texts, "|", from)
                test.not_nil(seen:find(case.caption, 1, true), "the ceiling reads " .. case.caption .. ": " .. seen)
            end
            -- Neither way passes an integer today (tonumber and math.max return
            -- floats), so the caption is checked on a real one directly: a Lua
            -- literal and math.tointeger are what reach %f as lua.LInteger.
            test.eq(render.ceiling_caption(math.tointeger(40) :: number, " MB"), "40 MB",
                "an integer ceiling must print as digits, not as %!f(lua.LInteger=40)")
        end)
    end)

    test.describe("Window SDK ergonomics", function()
        test.it("app.main wraps app.run, and a bare context has watch, unwatch, after and close", function()
            test.eq(type(app.main({})), "function")
            local context = app.context({width = 20, height = 5})
            test.eq(context.width .. "x" .. context.height, "20x5")
            for _, name in ipairs({"watch", "unwatch", "after", "close"}) do
                test.eq(type(context[name]), "function", "context." .. name)
            end
            local ch = time.after("1s")
            context.watch(ch)
            context.watch(ch)
            test.eq(#context.watched, 1, "a channel is watched once")
            context.unwatch(ch)
            test.eq(#context.watched, 0)
            context.close()
            test.is_true(context.closing)
        end)

        test.it("context.after delivers one timer action with its tag, once", function()
            local context = app.context({})
            local ch = context.after("1ms", "flash")
            local action = app.channel_action(context, channel.select({ch:case_receive()}))
            test.eq(action.type .. ":" .. tostring(action.tag), "timer:flash")
            test.eq(#context.timers, 0, "a one-shot timer is forgotten after it fires")
            local other = time.after("1ms")
            context.watch(other)
            test.eq(app.channel_action(context, channel.select({other:case_receive()})).type, "channel",
                "a watched channel stays a channel action")
        end)

        test.it("a row with align = right puts fixed children against its far end", function()
            local function row(align: any): any
                return ui.plan({kind = "row", align = align, gap = 1, children = {
                    {kind = "button", id = "ok", size = 6, text = "OK"},
                    {kind = "button", id = "cancel", size = 8, text = "Cancel"},
                }}, 30, 2, ui.interaction())
            end
            local right = row("right")
            test.eq(right.by_id.cancel.rect.x + right.by_id.cancel.rect.w - 1, 30, "the last button ends at the edge")
            test.eq(right.by_id.ok.rect.x, 30 - (6 + 1 + 8) + 1, "the gap stays between them")
            test.eq(row(nil).by_id.ok.rect.x, 1, "without align the row starts on the left")
        end)

        test.it("close_on_escape closes on an Esc update did not take, and not on one it did", function()
            local definition = {close_on_escape = true, update = function(model: any, action: any)
                if action.type == "key" and action.key_type == "esc" and model.sheet then model.sheet = false; return true end
                return false
            end}
            local model, context = {sheet = true}, app.context({})
            local esc = {type = "key", key = "esc", key_type = "esc"}
            app.dispatch(definition, model, context, esc)
            test.is_false(context.closing, "the first Esc closes the sheet")
            app.dispatch(definition, model, context, esc)
            test.is_true(context.closing, "the second closes the window")
            local plain = app.context({})
            app.dispatch({update = function() return false end}, {}, plain, esc)
            test.is_false(plain.closing, "without the flag Esc stays the window's business")
        end)

        test.it("a static table needs no id, takes no focus and no clicks", function()
            local tree = {kind = "column", children = {
                {kind = "table", size = 3, static = true, columns = {{title = "Name"}}, rows = {{cells = {"a"}}}},
                {kind = "button", id = "ok", size = 2, text = "OK"},
            }}
            test.is_nil(ui.problem(tree), "a static table without an id lays out")
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 20, 6, interaction)
            test.eq(table.concat(plan.focusable, ","), "ok", "only the button takes focus")
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = 2, y = 2}),
                "a click on the static table does nothing")
            test.eq(interaction.focus, "ok")
            test.not_nil(ui.problem({kind = "table", columns = {}, rows = {}}), "a table that is not static still needs an id")
        end)
    end)

    -- Tabs in pixels, the Windows 95 way: the active tab 2 px taller and 2 px
    -- higher, its bottom open into the page; the frame's top line runs under
    -- the inactive tabs only. The page frame's top row belongs to the tabs
    -- too: it holds the gap under the active tab, so it is repainted when the
    -- active tab changes.
    test.describe("Window SDK: tabs in pixels", function()
        local FACE, LIGHT = "#c0c0c0", "#ffffff"
        local function tabs(active: integer): any
            return {kind = "column", children = {{kind = "tabs", id = "pages", labels = {"General", "Profile"},
                active = active, pad = 1, children = {{kind = "label", text = "Page"}}}}}
        end
        -- The color the painter left at a pixel: the last rectangle over it.
        local function painted(rects: any, px: integer, py: integer): any
            local found: any = nil
            for _, r in ipairs(rects) do
                if px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then found = r.c end
            end
            return found
        end
        test.it("draws the active tab higher and open into the page, the frame line under the inactive one", function()
            for _, cell in ipairs({{w = 8, h = 16}, {w = 10, h = 20}}) do
                local label = cell.w .. "x" .. cell.h .. ": "
                local rects: any = {}
                local raster: any = {fill = function() end, set = function() end, blit = function() end,
                    text = function() return 0 end,
                    rect = function(_, x, y, w, h, c) rects[#rects + 1] = {x = x, y = y, w = w, h = h, c = tostring(c)} end}
                local store: any = {take = function() return raster, true end}
                assert(render.placement({id = "tabs-shape", state_revision = 1, content_state = {sdk = 1, revision = 1,
                    ui = tabs(2)}}, {x = 1, y = 1, cols = 30, rows = 8}, cell, {}, store))
                local item: any = ui.plan(tabs(2), 30, 8, ui.interaction(), {cell = cell}).by_id.pages
                local inactive, active = item.spans[1], item.spans[2]
                local mid_in = 1 + inactive.x * cell.w + (inactive.w * cell.w) // 2
                local mid_on = 1 + active.x * cell.w + (active.w * cell.w) // 2
                local frame_y = 1 + cell.h
                test.eq(painted(rects, mid_on, 1), LIGHT, label .. "the active tab's top edge is on the strip's first pixel row")
                test.is_nil(painted(rects, mid_in, 2), label .. "nothing above the inactive tab")
                test.eq(painted(rects, mid_in, 3), LIGHT, label .. "the inactive tab's top edge is 2 px lower")
                test.eq(painted(rects, mid_on, frame_y), FACE, label .. "no line at the active tab's bottom")
                test.eq(painted(rects, mid_in, frame_y), LIGHT, label .. "the frame's top line runs under the inactive tab")
                test.eq(painted(rects, mid_in, frame_y - 1), FACE, label .. "the inactive tab has no bottom edge of its own")
            end
        end)
        test.it("repaints the page frame's top row when the active tab changes", function()
            -- One font set for both frames: a row key names the set by identity
            -- on purpose (`use_fonts` makes a new set, and every row repaints).
            local fonts: any = {}
            local function keys(active: integer): any
                local out: any = {}
                local raster: any = {blit = function() end}
                local store: any = {take = function(id, _, _, _, key) out[id] = key; return raster, false end}
                assert(render.rows({id = "tabs-rows", state_revision = active, content_state = {sdk = 1, revision = active,
                    ui = tabs(active)}}, {x = 1, y = 1, cols = 30, rows = 8}, {w = 8, h = 16}, fonts, store))
                return out
            end
            local before, after = keys(1), keys(2)
            local function row(n: integer): string return "win:tabs-rows:sdk:row:" .. n end
            test.is_true(before[row(1)] ~= after[row(1)], "the strip")
            test.is_true(before[row(2)] ~= after[row(2)], "the frame's top row: the gap under the active tab moves with it")
            test.eq(before[row(6)], after[row(6)], "a page row the tabs do not change keeps its raster")
            render.forget("tabs-rows")
        end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
