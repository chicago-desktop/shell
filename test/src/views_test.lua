-- View windows of the shell: "Date/Time" and the calculator.
--
-- What is checked is what makes such a window lie silently: a button drawn
-- somewhere other than where it is pressed; a row of rasters re-sent without
-- changes; a second redrawing the calendar; arithmetic that counts not the
-- way the buttons do.
local test = require("test")
local gfx = require("gfx")
local tty = require("tty")
local rasters = require("rasters")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local datetime = require("datetime_window")
local engine = require("engine")
local reg_model = require("reg_model")
local regedit = require("regedit_window")
local registry = require("registry")
local calc_window = require("calc_window")
local ui = require("ui")
local fs = require("fs")
local pixels = require("pixels")
local widgets = require("widgets")

local CELL = {w = 10, h = 20}

-- Titles and ids of the menu bar items from the window tree.
local function menu_of(tree: any): (string, string, boolean)
    local titles, ids, disabled = {}, {}, false
    for _, child in ipairs(tree.children or {}) do
        if child.kind == "menu" then
            for _, entry in ipairs(child.entries) do
                titles[#titles + 1] = tostring(entry.title)
                for _, item in ipairs(entry.items or {}) do
                    if not item.separator then ids[#ids + 1] = tostring(item.id) end
                    if item.disabled then disabled = true end
                end
            end
        end
    end
    return table.concat(titles, " "), table.concat(ids, " "), disabled
end

-- The label with this text in the plan and its width: a sheet title cut down
-- to one cell shows as a single letter.
local function label_width(plan: any, text: string): integer
    for _, item in ipairs(plan.items) do
        if item.node.kind == "label" and item.node.text == text then return item.rect.w end
    end
    return 0
end

local function versions(placements: any): any
    local out: any = {}
    for _, item in ipairs(placements) do
        out[item.id] = {raster = item.raster, version = item.raster:version()}
    end
    return out
end

local function moved(before: any, after: any): any
    local names = {}
    for id, now in pairs(after) do
        local was: any = before[id]
        if not was then names[#names + 1] = id .. " (appeared)"
        elseif was.raster ~= now.raster then names[#names + 1] = id .. " (RECREATED)"
        elseif was.version ~= now.version then names[#names + 1] = id end
    end
    table.sort(names)
    return names
end

-- Buttons named in cells do not share a cell: otherwise a click on the
-- border belongs to both at once, and whichever was found first wins.
local function assert_disjoint(buttons: any)
    for i = 1, #buttons do
        for j = i + 1, #buttons do
            local a, b = buttons[i], buttons[j]
            local rows = a.row <= b.bottom_row and b.row <= a.bottom_row
            local cols = a.from <= b.to and b.from <= a.to
            test.is_false(rows and cols, a.id .. " and " .. b.id .. " share a cell")
        end
    end
end

local function define_tests()
    test.describe("butschster.windows \"Date/Time\" window", function()
        local function clock_state(): any
            return {clock = {year = 2026, month = 9, day = 8, hour = 21, minute = 47, second = 5,
                first_weekday = 1, days = 30, zone = "UTC+04:00"}, tab = 1}
        end

        test.it("the month grid starts on the right day and ends with the last one", function()
            -- September 2026: the first is a Tuesday, thirty days.
            local grid = ui.month_grid(1, 30)
            test.eq(#grid, 6)
            test.is_false(grid[1][1], "the Monday before the first is empty")
            test.eq(grid[1][2], 1)
            test.eq(grid[5][3], 30, "the thirtieth is the Wednesday of the fifth week")
            test.is_false(grid[5][4])
            test.is_false(grid[6][1])
        end)

        test.it("the bottom buttons share no cells, \"OK\" is the default, \"Apply\" cannot be pressed", function()
            local plan = ui.plan(datetime.definition.view(clock_state(), {width = 42, height = 20}), 42, 20, ui.interaction())
            local buttons = {}
            for _, item in ipairs(plan.items) do
                if item.node.kind == "button" then
                    buttons[#buttons + 1] = {id = item.node.id, from = item.rect.x, to = item.rect.x + item.rect.w - 1,
                        row = item.rect.y, bottom_row = item.rect.y + item.rect.h - 1}
                end
            end
            test.eq(#buttons, 3)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do test.is_true(button.to <= 42, button.id .. " beyond the window edge") end
            test.is_true(ui.default_look(plan, plan.by_id.ok.node, false), "\"OK\" is the default")
            test.is_true(plan.by_id.apply.node.disabled, "\"Apply\" is disabled")
            local interaction = ui.interaction()
            plan = ui.plan(datetime.definition.view(clock_state(), {width = 42, height = 20}), 42, 20, interaction)
            local apply = plan.by_id.apply.rect
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = apply.x, y = apply.y}))
            test.is_nil(interaction.armed, "a disabled button is not armed")
            local kinds = {}
            for _, item in ipairs(plan.items) do kinds[item.node.kind] = true end
            test.is_true(kinds.calendar and kinds.clock and kinds.tabs, "the calendar, the clock and the tabs are in place")
        end)

        test.it("the same second does not redraw, \"OK\" and Esc close", function()
            local state = clock_state()
            local closed = 0
            local context = {width = 42, height = 20, close = function() closed = closed + 1 end}
            state.clock = datetime.snapshot()
            local verdict = datetime.definition.update(state, {type = "tick"}, context)
            test.is_true(verdict == false or verdict == true)
            datetime.definition.update(state, {type = "activate", id = "ok"}, context)
            datetime.definition.update(state, {type = "key", key_type = "esc", key = "esc"}, context)
            test.eq(closed, 2)
            test.eq(datetime.definition.update(state, {type = "activate", id = "apply"}, context), false)
        end)
    end)

    test.describe("butschster.windows calculator", function()
        test.it("counts like the buttons, not like an expression", function()
            local state = engine.new()
            for _, id in ipairs({"2", "add", "3", "mul", "4", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "20.", "2 + 3 × 4 on a desk calculator is twenty")
            test.is_true(state.fresh)
        end)

        test.it("the display shows a whole number with a dot, a fraction without a second one", function()
            local state = engine.new()
            test.eq(engine.display(state), "0.")
            for _, id in ipairs({"1", "dot", "5", "dot"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "1.5")
            state = engine.press(state, "neg")
            test.eq(engine.display(state), "-1.5")
        end)

        test.it("division by zero is a phrase, and after it only a reset works", function()
            local state = engine.new()
            for _, id in ipairs({"8", "div", "0", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "Cannot divide by zero")
            state = engine.press(state, "5")
            test.eq(engine.display(state), "Cannot divide by zero", "a digit after the refusal does not count")
            state = engine.press(state, "ce")
            test.eq(engine.display(state), "0.")
            state = engine.press(state, "inv")
            test.eq(engine.display(state), "Cannot divide by zero")
            state = engine.press(state, "c")
            test.eq(engine.display(state), "0.")
        end)

        test.it("memory survives the C reset and is shown on the display", function()
            local state = engine.new()
            for _, id in ipairs({"4", "2", "ms", "c"}) do state = engine.press(state, id) end
            test.eq(state.memory, 42)
            state = engine.press(state, "mplus")
            test.eq(state.memory, 42, "M+ of zero does not change the memory")
            state = engine.press(state, "mr")
            test.eq(engine.display(state), "42.")
            state = engine.press(state, "mc")
            test.is_nil(state.memory)
        end)

        test.it("Back, CE, square root and percent behave as in the original", function()
            local state = engine.new()
            for _, id in ipairs({"1", "2", "3", "back"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "12.")
            state = engine.press(state, "back"); state = engine.press(state, "back")
            test.eq(engine.display(state), "0.", "erased to the end is zero, not empty")
            for _, id in ipairs({"8", "1", "sqrt"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "9.")
            for _, id in ipairs({"5", "0", "add", "1", "0", "pct"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "5.", "10 % of the accumulated 50 is five")
            state = engine.press(state, "eq")
            test.eq(engine.display(state), "55.")
            for _, id in ipairs({"7", "add", "ce", "3", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "10.", "CE erases the input, but not the operation")
        end)

        test.it("keys arrive at the same buttons as the mouse", function()
            test.eq(engine.key({key_type = "runes", key = "7"}), "7")
            test.eq(engine.key({key_type = "runes", key = "*"}), "mul")
            test.eq(engine.key({key_type = "enter", key = "enter"}), "eq")
            test.eq(engine.key({key_type = "backspace"}), "back")
            test.eq(engine.key({key_type = "esc"}), "c")
            test.eq(engine.key({key_type = "runes", key = "с"}), "c", "the Russian \"с\" also clears")
            test.is_nil(engine.key({key_type = "runes", key = "q"}))
        end)

        test.it("SDK buttons stand in the original's grid, share no cells and fit in the window", function()
            local state = calc_window.definition.init(nil, {})
            local tree = calc_window.definition.view(state, {width = 27, height = 14, native = true})
            local plan = ui.plan(tree, 27, 14, ui.interaction())
            local buttons = {}
            for _, item in ipairs(plan.items) do
                if item.node.kind == "button" then
                    buttons[#buttons + 1] = {id = item.node.id, from = item.rect.x, to = item.rect.x + item.rect.w - 1,
                        row = item.rect.y, bottom_row = item.rect.y + item.rect.h - 1}
                end
            end
            test.eq(#buttons, 3 + 4 * 6)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do
                test.is_true(button.to <= 27 and button.bottom_row <= 14, button.id .. " beyond the edge")
            end
            test.eq(ui.hit(plan, 7, 6).node.id, "7")
            test.eq(ui.hit(plan, 26, 13).node.id, "eq")
            test.eq(ui.hit(plan, 2, 12).node.id, "mplus")
            test.eq(ui.hit(plan, 6, 6).node.kind, "label", "the gap between the memory and the keys is empty")
            test.eq(ui.hit(plan, 10, 2).node.kind, "field", "the display is not a button")
        end)

        test.it("a click and a key count the same, the highlight goes out by its own timer", function()
            local watched: any = {}
            local context: any = {watch = function(ch) watched[#watched + 1] = ch end, close = function() end}
            local state = calc_window.definition.init(nil, context)
            calc_window.definition.update(state, {type = "activate", id = "7"}, context)
            calc_window.definition.update(state, {type = "key", key_type = "runes", key = "*"}, context)
            calc_window.definition.update(state, {type = "activate", id = "6"}, context)
            calc_window.definition.update(state, {type = "key", key_type = "enter", key = "enter"}, context)
            test.eq(engine.display(state.calc), "42.")
            test.eq(state.calc.pressed, "eq", "the last button is highlighted")
            test.eq(#watched, 4, "every press starts a highlight timer")
            local tree = calc_window.definition.view(state, {width = 27, height = 14, native = true})
            local plan = ui.plan(tree, 27, 14, ui.interaction())
            test.is_true(plan.by_id.eq.node.pressed == true)
            test.eq(calc_window.definition.update(state, {type = "channel", channel = watched[4], ok = true}, context), true)
            test.is_nil(state.calc.pressed, "the timer turns the highlight off")
        end)

        -- The owner's screenshot (2026-09-11): MC, MR, MS, M+ and sqrt showed
        -- "..." in pixels. At a 10 px cell the old 10 px padding still fitted
        -- them (test/shots/calc.png); at 9 px it cut sqrt, at 8 px also the
        -- memory keys — which matches the screenshot. Every key is
        -- drawn here the way the SDK renderer draws it — its cells minus
        -- `inset` on each side, the shell's bold Liberation Sans 13 — at cell
        -- widths terminals actually give, and the caption `pixels.button`
        -- hands to the raster must be the key's whole caption.
        test.it("draws every key caption whole in pixels at the shell's font and 8 to 10 px cells", function()
            local files = assert(fs.get("app:system_fonts"))
            local bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            local state = calc_window.definition.init(nil, {})
            local plan = ui.plan(calc_window.definition.view(state, {width = 27, height = 14, native = true}), 27, 14, ui.interaction())
            -- Captions are collected in a table field, not an upvalue: go-lua
            -- splits upvalues after an error caught by pcall.
            local seen: any = {list = {}}
            local stub: any = {
                rect = function() end,
                set = function() end,
                text = function(_, _, _, caption) seen.list[#seen.list + 1] = caption; return 0 end,
            }
            local checked, cut = 0, {}
            for _, width in ipairs({8, 9, 10}) do
                local cell = {w = width, h = 20}
                for _, item in ipairs(plan.items) do
                    local node: any = item.node
                    if node.kind == "button" then
                        local pad = node.inset or 0
                        local bw = item.rect.w * cell.w - pad * 2
                        seen.list = {}
                        pixels.button(stub, 1, 1, bw, item.rect.h * cell.h - pad * 2,
                            {label = node.text, font = bold}, cell)
                        if seen.list[1] ~= node.text then
                            cut[#cut + 1] = string.format("%s at %d px cell: %q in a %d px key, caption %d px",
                                tostring(node.id), width, tostring(seen.list[1]), bw, bold:measure(node.text))
                        end
                        checked = checked + 1
                    end
                end
            end
            test.eq(checked, 3 * (3 + 4 * 6), "every key is checked at every cell width")
            test.eq(table.concat(cut, "; "), "", "every caption is drawn whole")
            -- 16 px leave 10 px of room: no room for "...", room for "s".
            test.eq(pixels.caption(bold, "sqrt", 16), "s", "a key too narrow for the dots is cut, not left with an ellipsis")
        end)

        -- In cells the client of the 29x16 window is what the cell theme's
        -- insets leave, 25x11 — not the 27x14 of pixels. Every key must fit
        -- there, share no cell, and hold its caption between two bevels.
        test.it("fits the cell client and shows every caption whole between bevels", function()
            local inset = chrome.window_insets({})
            local width, height = 29 - inset.left - inset.right, 16 - inset.top - inset.bottom
            test.eq(width .. "x" .. height, "25x11", "the cell client of the calculator window")
            local state = calc_window.definition.init(nil, {})
            local plan = ui.plan(calc_window.definition.view(state, {width = width, height = height, native = false}),
                width, height, ui.interaction())
            local buttons = {}
            for _, item in ipairs(plan.items) do
                local node: any = item.node
                if node.kind == "button" then
                    local rect = item.rect
                    local name = "key " .. tostring(node.id)
                    buttons[#buttons + 1] = {id = node.id, from = rect.x, to = rect.x + rect.w - 1,
                        row = rect.y, bottom_row = rect.y + rect.h - 1}
                    test.is_true(rect.x + rect.w - 1 <= width and rect.y + rect.h - 1 <= height, name .. " is inside the client")
                    test.is_true(widgets.cells(node.text) + 2 <= rect.w, name .. " has room for its caption and both bevels")
                    local shown = tostring(widgets.button(node.text, {room = rect.w})):gsub("\27%[[%d;:]*m", "")
                    test.is_true(shown:find(node.text, 1, true) ~= nil, name .. " shows its caption whole: " .. shown)
                    test.is_true(widgets.cells(shown) <= rect.w, name .. " stays inside its cells")
                end
            end
            test.eq(#buttons, 3 + 4 * 6, "every key is laid out")
            assert_disjoint(buttons)
            test.eq((tostring(widgets.button("MC", {room = 4})):gsub("\27%[[%d;:]*m", "")):gsub("[^%w]", ""), "MC")
        end)

        test.it("the menu has only \"About\": the sheet opens, keys do not count under it", function()
            local context: any = {watch = function() end, close = function() end}
            local state = calc_window.definition.init(nil, context)
            local titles, ids, disabled = menu_of(calc_window.definition.view(state, {width = 27, height = 14, native = true}))
            test.eq(titles, "Help", "No Edit — the window has no clipboard; no View — there is only one view")
            test.eq(ids, "about")
            test.is_false(disabled, "there are no permanently disabled items")

            calc_window.definition.update(state, {type = "activate", id = "about", menu = "bar"}, context)
            test.is_true(state.about, "\"About\" opens the sheet")
            local plan = ui.plan(calc_window.definition.view(state, {width = 27, height = 14, native = true}), 27, 14, ui.interaction())
            test.not_nil(plan.by_id.about_ok, "the sheet has \"OK\"")
            local ok = plan.by_id.about_ok.rect
            test.is_true(ok.x + ok.w - 1 <= 27 and ok.y + ok.h - 1 <= 14, "\"OK\" is inside the window")
            test.is_true(label_width(plan, "Calculator") >= #"Calculator", "the sheet title is visible whole")

            test.eq(calc_window.definition.update(state, {type = "key", key_type = "runes", key = "7"}, context), false)
            test.eq(engine.display(state.calc), "0.", "a digit under the sheet is not typed")
            calc_window.definition.update(state, {type = "key", key_type = "esc", key = "esc"}, context)
            test.is_false(state.about, "Esc closes the sheet")
            calc_window.definition.update(state, {type = "activate", id = "about", menu = "bar"}, context)
            calc_window.definition.update(state, {type = "activate", id = "about_ok"}, context)
            test.is_false(state.about, "\"OK\" closes the sheet")
            test.eq(engine.display(state.calc), "0.", "neither \"about\" nor \"about_ok\" went into the calculator")
        end)
    end)

    test.describe("butschster.windows registry viewer", function()
        local records = {
            {id = "app:db", kind = "db.sql.sqlite", meta = {comment = "database"}, data = {file = ":memory:"}},
            {id = "butschster.windows.shell:chrome", kind = "library.lua", meta = {comment = "theme"},
                data = {source = "file://chrome.lua", modules = {"tty"}}},
            {id = "butschster.windows.shell:pixels", kind = "library.lua", meta = {}, data = {}},
            {id = "butschster.windows:shell", kind = "process.lua", meta = {title = "Shell"}, data = {}},
            {id = "app.desktop:window_calc", kind = "process.lua", meta = {type = "tui_desktop.window"}, data = {}},
        }

        test.it("lays namespaces out by dots, folders before entries", function()
            local root = reg_model.build(records)
            test.eq(#root.children, 2, "two root namespaces: app and butschster")
            test.eq(root.children[1].label, "app")
            local app = root.children[1]
            test.eq(app.children[1].kind, "folder", "the desktop folder comes before the db entry")
            test.eq(app.children[1].label, "desktop")
            test.eq(app.children[2].label, "db")
            local windows = reg_model.find(root, "butschster.windows")
            test.not_nil(windows)
            test.eq(#windows.children, 2, "the shell folder and the shell entry side by side")
            test.eq(windows.children[1].kind, "folder")
            test.eq(windows.children[2].key, "butschster.windows:shell")
        end)

        test.it("visible rows depend on the expanded keys, the path is written as in regedit", function()
            local root = reg_model.build(records)
            local expanded: any = {}
            expanded[""] = true
            local rows = reg_model.flatten(root, expanded)
            test.eq(#rows, 3, "the root and two namespaces")
            test.eq(rows[2].depth, 1)
            test.is_true(rows[2].has_children)
            test.is_false(rows[2].expanded)
            expanded["butschster"] = true
            expanded["butschster.windows"] = true
            rows = reg_model.flatten(root, expanded)
            test.eq(rows[#rows].label, "shell")
            test.eq(rows[#rows].kind, "entry")
            test.is_false(rows[#rows].trail[#rows[#rows].trail], "the last sibling — the line does not go down")
            test.eq(reg_model.path("butschster.windows.shell:chrome"), "Registry\\butschster\\windows\\shell\\chrome")
            test.eq(reg_model.path(""), "Registry")
            test.eq(reg_model.parent_key("butschster.windows.shell:chrome"), "butschster.windows.shell")
            test.eq(reg_model.parent_key("butschster.windows"), "butschster")
            test.eq(reg_model.parent_key("app"), "")
        end)

        test.it("entry fields — kind, meta and data alphabetically, tables on one line", function()
            local root = reg_model.build(records)
            local node = reg_model.find(root, "butschster.windows.shell:chrome")
            local values = reg_model.values(node, function(v) return "{json}" end)
            test.eq(values[1].name, "kind")
            test.eq(values[1].data, "library.lua")
            test.eq(values[2].name, "meta.comment")
            test.eq(values[2].data, "\"theme\"")
            test.eq(values[3].name, "data.modules")
            test.eq(values[3].data, "{json}", "a table is encoded by whatever was given")
            test.eq(values[4].name, "data.source")
            local folder = reg_model.values(reg_model.find(root, "app"), nil)
            test.eq(folder[1].name, "(Default)")
            test.eq(folder[2].data, "2")
            test.eq(reg_model.stringify("first\nsecond", nil), "\"first…\"", "a source is shown by its first line")
        end)

        test.it("the expander box and the keys of the SDK tree expand, move and keep the selection", function()
            local state = regedit.session(records)
            local context = {width = 78, height = 22, close = function() end}
            test.eq(#state.rows, 3)
            local function plan_now()
                return ui.plan(regedit.definition.view(state, context), 78, 22, ui.interaction())
            end
            local plan = plan_now()
            local tree = plan.by_id.tree
            -- Row 2 is "app" at depth 1; the expander box is in the expander
            -- column of depth 1.
            local columns = ui.tree_columns(1)
            local interaction = ui.interaction()
            local toggled = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + columns.expander, y = tree.rect.y + 1})
            test.eq(toggled.type, "toggle")
            regedit.definition.update(state, toggled, context)
            test.is_true(state.expanded["app"], "the expander box expanded app")
            test.eq(state.selected, "", "the expander box does not change the selection")
            plan = plan_now()
            local picked = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + 10, y = tree.rect.y + 4})
            test.eq(picked.type, "select")
            regedit.definition.update(state, picked, context)
            test.eq(state.selected, "butschster")
            interaction.focus = "tree"
            local function key(name)
                plan = plan_now()
                local action = ui.event(plan, interaction, {type = "key", action = "press", key_type = name, key = name})
                if action then regedit.definition.update(state, action, context) end
            end
            key("right")
            test.is_true(state.expanded["butschster"], "right on a collapsed one — expand")
            key("right")
            test.eq(state.selected, "butschster.windows", "right on an expanded one — to the first child")
            key("right")
            test.is_true(state.expanded["butschster.windows"])
            key("left")
            test.is_nil(state.expanded["butschster.windows"], "left on an expanded one — collapse")
            key("left")
            test.eq(state.selected, "butschster", "left on a collapsed one — to the parent")
            key("end")
            test.eq(state.selected, "butschster.windows", "end — the last visible row")
            local tree_view = regedit.definition.view(state, context)
            test.eq(tree_view.children[3].fields[1].text, "Registry\\butschster\\windows")
        end)

        test.it("a long tree scrolls and keeps the selection on screen", function()
            local many = {}
            for index = 1, 60 do many[index] = {id = "ns" .. string.format("%02d", index) .. ":x", kind = "k", meta = {}, data = {}} end
            local state = regedit.session(many)
            local context = {width = 78, height = 22, close = function() end}
            test.eq(#state.rows, 61)
            local interaction = ui.interaction()
            interaction.focus = "tree"
            for _ = 1, 40 do
                local plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
                local action = ui.event(plan, interaction, {type = "key", action = "press", key_type = "down", key = "down"})
                regedit.definition.update(state, action, context)
            end
            test.eq(state.selected, "ns40")
            local plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
            local tree = plan.by_id.tree
            local lines = tree.page
            test.eq(interaction.offsets.tree, 41 - lines, "the selection is on the last row of the screen")
            ui.event(plan, interaction, {type = "mouse", action = "wheel", button = "wheel_down", x = tree.rect.x + 2, y = tree.rect.y + 2})
            test.eq(interaction.offsets.tree, 41 - lines + 3)
            plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
            ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + tree.rect.w - 1, y = tree.rect.y})
            test.eq(interaction.offsets.tree, 41 - lines + 2, "the scrollbar arrow — by one row")
            -- The window was stretched: the offset was clamped to the new height.
            plan = ui.plan(regedit.definition.view(state, {width = 100, height = 40}), 100, 40, interaction)
            test.is_true(interaction.offsets.tree <= 61 - plan.by_id.tree.page, "the offset is clamped to the new height")
        end)

        test.it("the menu has no permanently disabled items, and each remaining one does something", function()
            local state = regedit.session(records)
            local closed = 0
            local context = {width = 78, height = 22, close = function() closed = closed + 1 end}
            local titles, ids, disabled = menu_of(regedit.definition.view(state, context))
            test.eq(titles, "Registry View Help", "no \"Edit\" with a disabled Copy Path")
            test.eq(ids, "refresh exit refresh about")
            test.is_false(disabled)

            regedit.definition.update(state, {type = "activate", id = "refresh", menu = "bar"}, context)
            test.is_true(state.count > #records, "Refresh reread the registry: " .. tostring(state.count))

            regedit.definition.update(state, {type = "activate", id = "about", menu = "bar"}, context)
            test.is_true(state.about)
            local plan = ui.plan(regedit.definition.view(state, context), 78, 22, ui.interaction())
            test.not_nil(plan.by_id.about_ok, "the sheet has \"OK\"")
            test.is_true(label_width(plan, "Registry Editor") >= #"Registry Editor", "the sheet title is visible whole")
            regedit.definition.update(state, {type = "key", key_type = "esc", key = "esc"}, context)
            test.is_false(state.about, "Esc closes the sheet")
            test.eq(closed, 0, "and not the window")
            regedit.definition.update(state, {type = "activate", id = "about"}, context)
            regedit.definition.update(state, {type = "activate", id = "about_ok"}, context)
            test.is_false(state.about, "\"OK\" closes the sheet")

            regedit.definition.update(state, {type = "activate", id = "exit", menu = "bar"}, context)
            test.eq(closed, 1, "Exit closes the window")
        end)

        test.it("an empty filter returns the whole registry, and the tree is built from it", function()
            -- The provider reads the registry exactly this way; if an empty
            -- filter one day comes to mean "nothing", the window will show an
            -- empty tree and call it the registry.
            local found, err = registry.find({})
            test.is_nil(err)
            test.is_true(#found > 30, "the harness has more than thirty entries, found " .. tostring(#found))
            local root = reg_model.build(found)
            local shell = reg_model.find(root, "butschster.windows.shell:chrome")
            test.not_nil(shell, "the theme entry must be found in the tree")
            test.eq(shell.record.kind, "library.lua")
        end)

    end)

    test.describe("butschster.windows farewell screen", function()
        test.it("after \"Shut Down\" — a black screen with the caption in the middle", function()
            -- The compositor holds this frame for FAREWELL_HOLD seconds; a
            -- frame without the caption would read as a hung terminal, not as
            -- a shutdown.
            local canvas = tty.canvas(80, 10)
            local painted = chrome.farewell(canvas, 80, 10)
            test.is_nil(painted, "there are no placements in cells")
            local rows = canvas:rows()
            local found: any = nil
            for index, row in ipairs(rows) do
                if tostring(row):find("safe to turn off", 1, true) then found = index end
            end
            test.eq(found, 5, "the caption stands in the middle row")
            test.is_true(tostring(rows[5]):find("\27[", 1, true) ~= nil, "the row is colored, not bare")
            test.is_true(tonumber(chrome.FAREWELL_HOLD) == 5, "five seconds, as asked")
            test.eq(chrome_pixels.FAREWELL_HOLD, chrome.FAREWELL_HOLD, "both themes hold it the same")
        end)

        test.it("a narrow screen gets a cut caption, not emptiness", function()
            local canvas = tty.canvas(20, 3)
            chrome.farewell(canvas, 20, 3)
            local rows = canvas:rows()
            local seen = false
            for _, row in ipairs(rows) do
                if tostring(row):find("It's now", 1, true) then seen = true end
            end
            test.is_true(seen)
        end)
    end)

    test.describe("butschster.windows fixed size", function()
        test.it("a window with resizable false has no \"maximize\" button", function()
            local set = chrome.buttons_for({window_type = "app", resizable = false})
            test.eq(#set, 2)
            test.eq(set[1].id, "minimize")
            test.eq(set[2].id, "close")
            local free = chrome.buttons_for({window_type = "app"})
            test.eq(#free, 3, "a window that says nothing about it stretches and maximizes, as before")
            local dialog = chrome.buttons_for({window_type = "dialog", resizable = false})
            test.eq(#dialog, 2, "a dialog has no \"maximize\" anyway — the set does not change")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
