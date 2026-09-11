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
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
