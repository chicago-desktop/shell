-- AntiBug (FR-009 §6): the pure model on a fake registry listing and fake
-- events, the window's update per menu item and button with a stand-in
-- world, the close gate, a live scan of one real harness test entry through
-- the real runner, and the shots test/shots/antibug.png (mid-scan, two
-- findings) and antibug-complete.png (the box). The targets of §4a are in
-- antibug_targets_test.lua.
local test = require("test")
local ui = require("ui")
local app = require("app")
local render = require("render")
local rasters = require("rasters")
local channel = require("channel")
local time = require("time")
local fs = require("fs")
local gfx = require("gfx")
local funcs = require("funcs")
local scan = require("scan")
local antibug_window = require("antibug_window")

local window = antibug_window.definition
local REAL_SYS = window.deps.sys
local CELL = {w = 10, h = 20}

local function entry(id: string, group: any, suite: any, extra: any?): any
    local meta: any = {type = "test", group = group, suite = suite}
    for key, value in pairs(extra or {}) do meta[key] = value end
    return {id = id, kind = "function.lua", meta = meta}
end

-- A registry listing: two groups, an entry without a group, one without a
-- suite, and entries that are not tests.
local function listing(): any
    return {
        entry("app:b_test", "Shell", "shell", {order = 2}),
        entry("app:a_test", "Shell", "shell", {order = 1, timeout = "5s"}),
        entry("app:menu_test", "Shell", "menus"),
        entry("app:db_test", "Data", "storage"),
        entry("app:loose_test", nil, "loose"),
        entry("app:plain_test", "Data", nil),
        {id = "app:helper", kind = "library.lua", meta = {type = "test"}},
        {id = "app:window", kind = "process.lua", meta = {type = "tui_desktop.window"}},
    }
end

local function ids(list: any): string
    local out = {}
    for _, item in ipairs(list) do out[#out + 1] = tostring(item.id) end
    return table.concat(out, ",")
end

local function message(kind: string, data: any): any
    return {type = kind, data = data}
end

local function plan(ref: string, count: integer): any
    local tests = {}
    for index = 1, count do tests[index] = {name = "case " .. index} end
    return message("test:plan", {ref_id = ref, suites = {{name = "s", tests = tests}}})
end

local function labels(tree: any, out: any): any
    local found: any = out or {}
    if type(tree) ~= "table" then return found end
    if tree.kind == "label" then found[#found + 1] = tostring(tree.text) end
    for _, child in ipairs(type(tree.children) == "table" and tree.children or {}) do labels(child, found) end
    return found
end

local function node(tree: any, id: string): any
    if type(tree) ~= "table" then return nil end
    if tree.id == id then return tree end
    for _, child in ipairs(type(tree.children) == "table" and tree.children or {}) do
        local found = node(child, id)
        if found then return found end
    end
    return nil
end

local function has(list: any, needle: string): boolean
    for _, text in ipairs(list) do
        if tostring(text):find(needle, 1, true) then return true end
    end
    return false
end

-- A stand-in world for the window: launches are recorded; each command has
-- its own response channel the test fires; the clock is a number.
local function world(found: any): any
    local seen: any = {launched = {}, commands = {}, writes = {}, stopped = {}, now = 100, inbox = channel.new(16)}
    local function command(): any
        local made: any = {ch = channel.new(1), answer = {returned = nil}}
        function made:response(): any return self.ch end
        function made:result(): (any, any)
            return {returned = self.answer.returned, error = self.answer.error, child = self.answer.child}, nil
        end
        seen.commands[#seen.commands + 1] = made
        return made
    end
    seen.sys = {
        find = function(): (any, any) return found or listing(), nil end,
        find_targets = function(): (any, any) return seen.targets or {}, nil end,
        listen = function(): any return seen.inbox end,
        launch = function(id: string): (any, any)
            seen.launched[#seen.launched + 1] = id
            if seen.refuse then return nil, seen.refuse end
            return command(), nil
        end,
        launch_target = function(id: string): (any, any)
            seen.launched[#seen.launched + 1] = "target " .. id
            return command(), nil
        end,
        stop = function(child: any): boolean
            seen.stopped[#seen.stopped + 1] = child
            return true
        end,
        now = function(): number return seen.now end,
        drives = function(): (any, any) return {{id = "app:docs", title = "docs"}}, nil end,
        list = function(place: any): (any, any) return {}, nil end,
        exists = function(drive: any, path: any): boolean return seen.exists == true end,
        write = function(drive: any, path: any, text: any): (any, any)
            seen.writes[#seen.writes + 1] = {drive = drive, path = path, text = text}
            return true, nil
        end,
    }
    return seen
end

local function opened(found: any): (any, any, any)
    local seen = world(found)
    window.deps.sys = seen.sys
    local context = app.context({width = 62, height = 19})
    local model = window.init(nil, context)
    return model, context, seen
end

local function act(model: any, context: any, action: any): boolean
    return app.dispatch(window, model, context, action)
end

local function menu(model: any, context: any, id: string): boolean
    return act(model, context, {type = "activate", id = id, menu = "menu"})
end

local function press(model: any, context: any, id: string): boolean
    return act(model, context, {type = "activate", id = id})
end

-- The answer of the current command, then the channel action the loop makes.
local function answer(model: any, context: any, seen: any, returned: any)
    local made = seen.commands[#seen.commands]
    made.answer.returned = returned
    act(model, context, {type = "channel", channel = made.ch, value = true, ok = true})
end

local function event(model: any, context: any, seen: any, value: any)
    act(model, context, {type = "channel", channel = seen.inbox, value = value, ok = true})
end

local function fonts(): any
    local dir = assert(fs.get("app:system_fonts"))
    return {face = assert(gfx.font(assert(dir:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
        mono = assert(gfx.font(assert(dir:readfile("LiberationMono-Regular.ttf")), {size = 13, smooth = true}))}
end

local function shot(model: any, context: any, name: string)
    local tree = window.view(model, context)
    test.is_nil(ui.problem(tree), tostring(ui.problem(tree)))
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = name, state_revision = 1, content_state = {sdk = 1, revision = 1,
        ui = tree, interaction = context.interaction}}, {x = 1, y = 1, cols = 62, rows = 19}, CELL, fonts(), store))
    local raster = gfx.raster(62 * CELL.w, 19 * CELL.h)
    raster:fill("#808080")
    raster:blit(placed.raster, 1, 1)
    assert(assert(fs.get("app:shots")):writefile(name, assert(raster:encode("png"))))
end

local function define_tests()
    test.describe("AntiBug model", function()
        test.it("takes only function test entries, sorted by group, suite and order; no suite is 'other'", function()
            local entries = scan.entries(listing())
            test.eq(ids(entries), "app:loose_test,app:plain_test,app:db_test,app:menu_test,app:a_test,app:b_test")
            test.eq(entries[2].suite, "other", "an entry without a suite")
            test.eq(entries[5].timeout, "5s")
            test.eq(entries[6].timeout, "30s", "the default timeout")
        end)

        test.it("builds the group → suite → entry tree with counts and the expander state", function()
            local state = scan.new(scan.entries(listing()))
            local rows = scan.tree(state)
            local shown = {}
            for _, row in ipairs(rows) do shown[#shown + 1] = row.label end
            test.eq(table.concat(shown, "|"), "(no group) (1)|loose (1)|Data (2)|other (1)|storage (1)|Shell (3)|menus (1)|shell (2)")
            scan.toggle(state, "s:Shell/shell")
            rows = scan.tree(state)
            test.eq(rows[#rows].label, "b_test", "the suite opened")
            test.eq(rows[#rows].depth, 2)
            test.eq(rows[#rows].kind, "entry")
            test.is_true(rows[#rows].trail[1] == false, "the last group has no sibling below")
            state.include_other = false
            test.eq(scan.tree(state)[1].id, "g:Data", "without the box the ungrouped entries leave the tree")
        end)

        test.it("chooses the entries of every selection shape and filter", function()
            local state = scan.new(scan.entries(listing()))
            test.eq(#scan.chosen(state), 6, "nothing selected: everything")
            state.selected = "g:Shell"
            test.eq(ids(scan.chosen(state)), "app:menu_test,app:a_test,app:b_test")
            state.selected = "s:Shell/shell"
            test.eq(ids(scan.chosen(state)), "app:a_test,app:b_test")
            state.selected = "e:app:db_test"
            test.eq(ids(scan.chosen(state)), "app:db_test")
            state.selected = nil
            state.include_other = false
            test.eq(#scan.chosen(state), 5, "the ungrouped entry is left out")
            state.include_other, state.only_failed = true, true
            test.eq(#scan.chosen(state), 0, "nothing failed last time")
            state.last["app:b_test"] = "failed"
            test.eq(ids(scan.chosen(state)), "app:b_test")
        end)

        test.it("runs a scan through plan, cases, answer and completion, in either order", function()
            local state = scan.new(scan.entries({entry("app:one", "G", "s"), entry("app:two", "G", "s")}))
            test.eq(scan.start(state, 10), "app:one")
            test.is_false(scan.event(state, plan("app:two", 9)), "another entry's event is dropped")
            test.is_true(scan.event(state, plan("app:one", 3)))
            local value, ceiling = scan.progress(state)
            test.eq(ceiling, 3, "the plan is the denominator")
            scan.event(state, message("test:case:start", {ref_id = "app:one", suite = "s", test = "a"}))
            local _, _, caption = scan.progress(state)
            test.eq(caption, "Scanning: s/a")
            scan.event(state, message("test:case:pass", {ref_id = "app:one", suite = "s", test = "a", duration = 0.012}))
            scan.event(state, message("test:case:fail", {ref_id = "app:one", suite = "s", test = "b", duration = 0.003,
                error = "expected 1, got 2\nstack"}))
            scan.event(state, message("test:case:skip", {ref_id = "app:one", suite = "s", test = "c"}))
            value = scan.progress(state)
            test.eq(value, 3)
            -- The answer first: not settled until the complete (or the grace).
            test.is_false(scan.answered(state, {returned = {status = "failed"}}))
            test.is_false(scan.settled(state))
            scan.event(state, message("test:complete", {ref_id = "app:one"}))
            test.is_true(scan.settled(state))
            test.eq(scan.finish(state, 11), "app:two")
            -- The complete first, then the answer settles at once.
            scan.event(state, message("test:complete", {ref_id = "app:two"}))
            test.is_true(scan.answered(state, {returned = nil}), "complete before the answer")
            test.is_nil(scan.finish(state, 12.5), "the last entry: the scan ends")
            test.eq(state.phase, "complete")
            test.eq(state.counts.scanned, 3, "two cases and a plain function test")
            test.eq(state.counts.infected, 1)
            test.eq(state.counts.skipped, 1)
            test.eq(state.last["app:one"], "failed")
            test.eq(state.last["app:two"], "passed")
            local counts, phase = scan.status(state, 99)
            test.eq(counts, "Scanned: 3   Infected: 1   Skipped: 1   Time: 2.5 s")
            test.eq(phase, "Complete")
            test.eq(state.box.lines[1], "Scan complete.")
            test.eq(state.box.lines[2], "1 infected test found.")
        end)

        test.it("judges a plain function test by its answer; times out; stops between entries", function()
            local state = scan.new(scan.entries({entry("app:f", "G", "s"), entry("app:g", "G", "s"), entry("app:h", "G", "s")}))
            scan.start(state, 0)
            scan.answered(state, {returned = false})
            test.eq(scan.finish(state, 1), "app:g", "the grace ran out, the next starts")
            test.eq(state.findings[1].error, "test returned false")
            scan.stop(state)
            test.eq(state.phase, "stopping")
            test.is_nil(scan.timed_out(state, 31), "stopped: no other entry starts")
            test.eq(state.findings[2].error, "timeout after 30s")
            test.eq(state.phase, "stopped")
            test.eq(state.box.lines[1], "Scan stopped.")
            test.eq(state.box.lines[2], "2 infected tests found.")
            test.is_nil(state.last["app:h"], "the third never ran")
        end)

        test.it("shows failures and skips, passes only with Show all; logs every case", function()
            local state = scan.new(scan.entries({entry("app:one", "G", "s")}))
            scan.start(state, 0)
            scan.event(state, message("test:case:pass", {ref_id = "app:one", suite = "s", test = "a", duration = 0.012}))
            scan.event(state, message("test:case:fail", {ref_id = "app:one", suite = "s", test = "b", error = "boom\nline 2"}))
            local rows = scan.rows(state)
            test.eq(#rows, 1, "the pass is hidden")
            test.eq(rows[1].cells[1], "s/b")
            test.eq(rows[1].cells[2], "boom", "the first line of the error")
            test.eq(rows[1].cells[3], "Failed")
            state.show_all = true
            rows = scan.rows(state)
            test.eq(#rows, 2)
            test.eq(rows[1].cells[4], "12 ms")
            test.eq(scan.finding_of(state, rows[2].id).error, "boom\nline 2")
            local text = scan.log_text(state)
            test.is_true(text:find("PASS s/a 12 ms", 1, true) ~= nil, text)
            test.is_true(text:find("FAIL s/b: boom", 1, true) ~= nil, text)
            local info = scan.info(scan.finding_of(state, rows[2].id))
            test.eq(info[1], "boom")
            test.eq(info[2], "line 2")
            test.eq(info[#info - 1], "Entry: app:one")
        end)
    end)

    test.describe("AntiBug window", function()
        test.it("lays out at 62×19 without overlaps in cells and pixels, on both tabs", function()
            local model, context = opened()
            for _, tab in ipairs({1, 2}) do
                model.tab = tab
                local tree = window.view(model, context)
                test.is_nil(ui.problem(tree), tostring(ui.problem(tree)))
                for _, cell in ipairs({false, {w = 10, h = 20}, {w = 8, h = 16}}) do
                    local where = "tab " .. tab .. (cell and ("@" .. cell.w .. "x" .. cell.h) or " cells")
                    local planned = ui.plan(tree, 62, 19, ui.interaction(), cell and {cell = cell} or nil)
                    for index, item in ipairs(planned.items) do
                        local r = item.rect
                        test.is_true(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= 62 and r.y + r.h - 1 <= 19,
                            where .. ": " .. tostring(item.node.kind) .. " outside")
                        for other = index + 1, #planned.items do
                            local b = planned.items[other].rect
                            test.is_true(r.x + r.w <= b.x or b.x + b.w <= r.x or r.y + r.h <= b.y or b.y + b.h <= r.y,
                                where .. ": overlap " .. tostring(item.node.kind) .. "/" .. tostring(planned.items[other].node.kind))
                        end
                    end
                    local at = planned.by_id
                    test.is_true(at.findings.rect.h >= 4, where .. ": the findings keep rows")
                    if tab == 1 then
                        test.is_true(at.tree.rect.h >= 2, where .. ": the tree keeps rows: " .. at.tree.rect.h)
                        test.is_true(at.scan_now.rect.x > at.tree.rect.x + at.tree.rect.w - 1, where .. ": buttons at the right")
                        test.is_true(at.stop.rect.y > at.scan_now.rect.y and at.new_scan.rect.y > at.stop.rect.y,
                            where .. ": one under another")
                    end
                end
            end
            window.deps.sys = REAL_SYS
        end)

        test.it("Scan Now runs the chosen entries one at a time through channels and ends with the box", function()
            local model, context, seen = opened({entry("app:one", "G", "s"), entry("app:two", "G", "s")})
            test.is_true(context.watched[1] == seen.inbox, "the events are watched from the start")
            press(model, context, "scan_now")
            test.eq(ids({{id = seen.launched[1]}}), "app:one")
            test.eq(#seen.launched, 1, "one at a time")
            test.is_true(context.watched[2] == seen.commands[1].ch, "the runner's answer is watched")
            test.eq(context.timers[1] and context.timers[1].tag.kind, "timeout", "the entry's timeout is set")
            local tree = window.view(model, context)
            test.is_true(node(tree, "scan_now").disabled, "Scan Now while scanning")
            test.eq(node(tree, "stop").text, "Stop after current")
            event(model, context, seen, plan("app:one", 2))
            event(model, context, seen, message("test:case:pass", {ref_id = "app:one", suite = "s", test = "a"}))
            event(model, context, seen, message("test:case:fail", {ref_id = "app:one", suite = "s", test = "b", error = "boom"}))
            answer(model, context, seen, {status = "failed"})
            test.eq(#seen.launched, 1, "answered before complete: the grace, not the next")
            test.eq(context.timers[#context.timers].tag.kind, "grace")
            event(model, context, seen, message("test:complete", {ref_id = "app:one"}))
            test.eq(seen.launched[2], "app:two", "complete within the grace: the next one")
            answer(model, context, seen, false)
            test.eq(#seen.launched, 2)
            act(model, context, {type = "timer", tag = {kind = "grace", seq = 2}})
            test.eq(model.sheet and model.sheet.kind, "box", "the scan ended with the box")
            test.is_true(has(labels(window.view(model, context)), "2 infected tests found."))
            press(model, context, "message_ok")
            test.is_nil(model.sheet)
            test.eq(#scan.rows(model.scan), 2, "a failed case and a plain test that returned false")
            window.deps.sys = REAL_SYS
        end)

        test.it("a stale timer and a timeout; Stop after current; a refused start is a finding", function()
            -- Entries run in the tree's order: group, suite, order, id.
            local model, context, seen = opened({entry("app:e1", "G", "s"), entry("app:e2", "G", "s"), entry("app:e3", "G", "s")})
            press(model, context, "scan_now")
            test.is_false(act(model, context, {type = "timer", tag = {kind = "timeout", seq = 9}}), "another entry's timer")
            act(model, context, {type = "timer", tag = {kind = "timeout", seq = 1}})
            test.eq(seen.launched[2], "app:e2", "the timeout finishes the entry")
            test.eq(model.scan.findings[1].error, "timeout after 30s")
            menu(model, context, "stop")
            test.eq(model.scan.phase, "stopping")
            event(model, context, seen, message("test:complete", {ref_id = "app:e2"}))
            answer(model, context, seen, nil)
            test.eq(#seen.launched, 2, "stopped: the third never starts")
            test.eq(model.scan.phase, "stopped")

            local refused, refused_context, refused_seen = opened({entry("app:one", "G", "s")})
            refused_seen.refuse = "not allowed"
            press(refused, refused_context, "scan_now")
            test.eq(refused.scan.findings[1].error, "not started: not allowed")
            test.eq(refused.sheet and refused.sheet.kind, "box")
            window.deps.sys = REAL_SYS
        end)

        test.it("the menu items: Show all, Reports, Refresh list, New Scan, About, Exit", function()
            local model, context, seen = opened({entry("app:one", "G", "s")})
            menu(model, context, "show_all")
            test.is_true(model.scan.show_all)
            menu(model, context, "reports")
            test.eq(model.tab, 2)
            test.is_true(node(window.view(model, context), "save").disabled, "nothing to save before a scan")
            menu(model, context, "about")
            test.eq(model.sheet.title, "About AntiBug")
            press(model, context, "message_ok")
            model.scan.findings[1] = {status = "failed", name = "x", error = "e"}
            model.scan.log[1] = "line"
            press(model, context, "new_scan")
            test.eq(#model.scan.findings, 0, "New Scan clears the findings")
            test.eq(#model.scan.log, 0, "and the log")
            seen.sys.find = function(): (any, any) return {entry("app:one", "G", "s"), entry("app:zeta", "G", "s")}, nil end
            menu(model, context, "refresh")
            test.eq(#model.scan.entries, 2, "Refresh list re-reads the registry")
            act(model, context, {type = "key", key_type = "f5"})
            test.eq(seen.launched[1], "app:one", "F5 scans")
            menu(model, context, "exit")
            test.eq(model.sheet and model.sheet.kind, "quit", "Exit while scanning asks")
            test.is_false(context.closing)
            press(model, context, "quit_yes")
            test.is_true(context.closing, "Yes exits")
            window.deps.sys = REAL_SYS
        end)

        test.it("the close gate: a scan running asks and stays on No; idle closes", function()
            local model, context = opened({entry("app:one", "G", "s")})
            test.is_false(app.refuses_close(window, model, context), "idle: the close goes through")
            press(model, context, "scan_now")
            test.is_true(app.refuses_close(window, model, context), "scanning: stay() and ask")
            test.eq(model.sheet.kind, "quit")
            press(model, context, "quit_no")
            test.is_nil(model.sheet)
            test.is_false(context.closing, "No keeps the window and the scan")
            test.is_true(model.scan.phase == "scanning")
            window.deps.sys = REAL_SYS
        end)

        test.it("the tree and the options choose the scan; a findings row opens Virus Info", function()
            local model, context, seen = opened()
            act(model, context, {type = "change", id = "target", value = "registry"})
            act(model, context, {type = "toggle", id = "tree", value = {id = "s:Data/storage"}})
            act(model, context, {type = "select", id = "tree", value = {id = "e:app:db_test"}})
            act(model, context, {type = "change", id = "failed", value = true})
            test.is_true(model.scan.only_failed)
            act(model, context, {type = "change", id = "all", value = true})
            act(model, context, {type = "change", id = "other", value = false})
            test.is_false(model.scan.include_other)
            press(model, context, "scan_now")
            test.eq(seen.launched[1], "app:db_test", "the selected entry only")
            event(model, context, seen, message("test:case:fail", {ref_id = "app:db_test", suite = "s", test = "t",
                error = "expected the row to be written"}))
            act(model, context, {type = "activate", id = "findings", value = {id = "f1"}})
            test.eq(model.sheet.title, "Virus Info")
            test.eq(model.sheet.lines[1], "expected the row to be written")
            window.deps.sys = REAL_SYS
        end)

        test.it("Save… writes the log through the file dialog as antibug.log, asking before a replace", function()
            local model, context, seen = opened({entry("app:one", "G", "s")})
            model.scan.log = {"AntiBug: scanning 1 test entry", "PASS s/a 1 ms"}
            model.tab = 2
            press(model, context, "save")
            test.eq(model.sheet.kind, "save")
            test.eq(window.title(model), "Save As")
            act(model, context, {type = "activate", id = "fd_accept"})
            test.eq(#seen.writes, 1)
            test.eq(seen.writes[1].path, "/antibug.log")
            test.eq(seen.writes[1].text, "AntiBug: scanning 1 test entry\nPASS s/a 1 ms")
            seen.exists = true
            press(model, context, "save")
            act(model, context, {type = "activate", id = "fd_accept"})
            test.eq(model.sheet.kind, "replace", "an existing file is replaced only on Yes")
            press(model, context, "replace_yes")
            test.eq(#seen.writes, 2)
            window.deps.sys = REAL_SYS
        end)

        test.it("shots: mid-scan with two findings, and the Scan complete box", function()
            local model, context, seen = opened()
            model.scan.show_all = false
            press(model, context, "scan_now")
            event(model, context, seen, plan("app:loose_test", 4))
            event(model, context, seen, message("test:case:fail", {ref_id = "app:loose_test", suite = "loose",
                test = "reads the row back", error = "expected 3 rows, got 2", duration = 0.041}))
            event(model, context, seen, message("test:case:skip", {ref_id = "app:loose_test", suite = "loose", test = "postgres only"}))
            event(model, context, seen, message("test:case:start", {ref_id = "app:loose_test", suite = "loose", test = "migrates"}))
            shot(model, context, "antibug.png")
            model.sheet = {kind = "box"}
            model.scan.box = {title = "AntiBug", lines = {"Scan complete.", "No infected tests found."}}
            shot(model, context, "antibug-complete.png")
            window.deps.sys = REAL_SYS
        end)

        test.it("the runner runs only test entries: anything else is refused by name", function()
            local refused, err = funcs.new():call("butschster.windows.antibug:runner", {entry = "app:antibug_actor_probe"})
            test.is_nil(err, tostring(err))
            test.eq(refused and refused.error, "app:antibug_actor_probe is not a test entry")
            local missing = funcs.new():call("butschster.windows.antibug:runner", {entry = "app:no_such_test"})
            test.is_true(tostring(missing and missing.error):find("no such entry: app:no_such_test", 1, true) ~= nil,
                tostring(missing and missing.error))
        end)

        test.it("live: scans one real harness test entry through the real runner and sees its cases arrive", function()
            local target = "app:glyphs_test"
            local found = {entry(target, "Windows Shell", "butschster_windows")}
            window.deps.sys = setmetatable({find = function(): (any, any) return found, nil end}, {__index = REAL_SYS})
            local context = app.context({width = 62, height = 19})
            local model = window.init(nil, context)
            press(model, context, "scan_now")
            local current = scan.current(model.scan)
            test.not_nil(current, "the scan started")
            -- The SDK loop, by hand: the watched channels and the timers.
            local deadline = time.after("20s")
            while scan.scanning(model.scan) do
                local cases: any = {deadline:case_receive()}
                for _, ch in ipairs(context.watched) do cases[#cases + 1] = ch:case_receive() end
                for _, pending in ipairs(context.timers) do cases[#cases + 1] = pending.channel:case_receive() end
                local picked = channel.select(cases)
                if picked.channel == deadline then break end
                act(model, context, app.channel_action(context, picked))
            end
            test.is_false(scan.scanning(model.scan), "the scan ended within 20 s")
            local planned = current.planned
            test.is_true(planned > 0, "the plan arrived: " .. tostring(planned))
            test.eq(current.done, planned, "every planned case arrived")
            test.eq(model.scan.counts.scanned, planned)
            test.eq(model.scan.counts.infected, 0, "glyphs_test is clean: " .. scan.log_text(model.scan))
            test.eq(model.scan.last[target], "passed")
            test.is_true(has(model.scan.log, "PASS "), "the log has the passes")
            window.deps.sys = REAL_SYS
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
