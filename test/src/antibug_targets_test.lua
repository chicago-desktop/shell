-- AntiBug FR-009 §4a: scan targets beyond the registry. The two parsers
-- against output captured from the real tools (test/fixtures/antibug:
-- wippy.txt — a whole run of this harness through the wippy test runner, which
-- cannot be filtered to one entry from the CLI; go.jsonl — `go test -json` of
-- a scratch module with a pass, a failure, a skip, subtests and a package that
-- does not build), the declarations and their commands, the target's state
-- machine in the scan model and in the window, and a live scan of a Go target
-- (test/fixtures/antibug/gomod) through the real runner, target process and exec.
local test = require("test")
local fs = require("fs")
local app = require("app")
local channel = require("channel")
local time = require("time")
local scan = require("scan")
local targets = require("targets")
local antibug_window = require("antibug_window")

local window = antibug_window.definition
local REAL_SYS = window.deps.sys

local function fixture(name: string): string
    local dir = assert(fs.get("app:antibug_fixtures"))
    return assert(dir:readfile(name))
end

-- The events of `text` fed in chunks of `size` bytes, then flushed.
local function parsed(kind: string, text: string, size: integer): any
    local parser = targets.parser(kind)
    local events: any = {}
    local at = 1
    while at <= #text do
        for _, found in ipairs(targets.feed(parser, text:sub(at, at + size - 1))) do events[#events + 1] = found end
        at = at + size
    end
    for _, found in ipairs(targets.flush(parser)) do events[#events + 1] = found end
    return events
end

local function count(events: any, kind: string): integer
    local total = 0
    for _, found in ipairs(events) do if found.type == kind then total = total + 1 end end
    return total
end

local function first(events: any, kind: string, test_name: string): any
    for _, found in ipairs(events) do
        if found.type == kind and found.data.test == test_name then return found.data end
    end
    return nil
end

local function kinds(events: any): string
    local out = {}
    for _, found in ipairs(events) do out[#out + 1] = found.type end
    return table.concat(out, ",")
end

local function declared(id: string, meta: any): any
    local full: any = {type = targets.TYPE}
    for key, value in pairs(meta) do full[key] = value end
    return {id = id, kind = "registry.entry", meta = full}
end

local function message(kind: string, data: any): any
    return {type = kind, data = data}
end

local function define_tests()
    test.describe("AntiBug targets: the parsers", function()
        test.it("the wippy runner's text: every case of a real run, the counts its own summary prints, the failures' text", function()
            local text = fixture("wippy.txt")
            -- The run's own verdict, read from its last lines.
            local plain = targets.plain(text)
            local passed, failed = plain:match("\n  (%d+) passed  (%d+) failed")
            test.not_nil(passed, "the fixture ends with the runner's counts")
            local events = parsed("wippy", text, 4096)
            test.eq(count(events, "test:case:pass"), tonumber(passed), "every pass the runner counted")
            test.eq(count(events, "test:case:fail"), tonumber(failed), "every failure")
            test.eq(events[1].type, "antibug:progress")
            test.eq(events[1].data.known, 41, "the runner's \"41 tests in 1 suites\"")
            local fail = first(events, "test:case:fail", "chooses the entries of every selection shape and filter")
            test.not_nil(fail, "a failed case by its name")
            test.eq(fail.suite, "antibug_test", "the entry the progress line named")
            test.eq(count(events, "antibug:detail"), tonumber(failed), "a text for every failure")
            local detail = first(events, "antibug:detail", "chooses the entries of every selection shape and filter")
            test.eq(detail.error, "wippy.test:test:477: nothing selected: everything: expected 6, got 7")
            local pass = first(events, "test:case:pass", "lays out at 62×19 without overlaps in cells and pixels, on both tabs")
            test.eq(pass.duration, 0.005, "\"5ms\"")
            -- Chunks split lines, escapes and characters anywhere.
            test.eq(kinds(parsed("wippy", text, 7)), kinds(events), "the same events in 7-byte chunks")
        end)

        test.it("go test -json: tests and subtests, a failure's last output, a package that does not build", function()
            local events = parsed("go", fixture("go.jsonl"), 97)
            test.eq(count(events, "test:case:pass"), 2, "TestPasses and TestTable/first")
            test.eq(count(events, "test:case:skip"), 1)
            test.eq(count(events, "test:case:fail"), 4, "TestFails, TestTable/second, TestTable and the build")
            local fails = first(events, "test:case:fail", "TestFails")
            test.eq(fails.suite, "example.com/antibugfix")
            test.eq(fails.error, "preparing the row\n    fix_test.go:12: expected 3 rows, got 2", "the test's own output")
            test.eq(first(events, "test:case:fail", "TestTable/second").error, "    fix_test.go:19: broken")
            test.eq(first(events, "test:case:fail", "TestTable").error, "failed (a subtest failed)")
            local build = first(events, "test:case:fail", "[build failed]")
            test.eq(build.suite, "antibugfix/broken")
            test.is_true(build.error:find("cannot use \"x\"", 1, true) ~= nil, build.error)
            test.is_nil(first(events, "test:case:fail", "[package failed]"), "a package with failed tests is not one more finding")
            test.eq(first(events, "test:case:start", "TestFails").suite, "example.com/antibugfix")
        end)

        test.it("the declarations: a kind and a directory or a reason; commands without a shell", function()
            local list = targets.entries({
                declared("app:shell", {title = "Shell", kind = "wippy", dir = "/w/shell", order = 2}),
                declared("app:runtime", {title = "Runtime", kind = "go", dir = "/w/runtime", order = 1}),
                declared("app:odd", {title = "Odd", kind = "make", dir = "/w/odd", order = 3}),
                declared("app:quoted", {title = "Quoted", kind = "wippy", dir = "/w/\"x", order = 4}),
                {id = "app:other", kind = "registry.entry", meta = {type = "windows.images"}},
            })
            test.eq(#list, 4, "only the declarations")
            test.eq(list[1].id, "app:runtime", "by order")
            test.is_nil(list[1].problem)
            test.eq(list[3].problem, "unknown kind 'make' (wippy or go)")
            test.eq(list[4].problem, "a quote or a line break in the declaration")
            local go = targets.command(list[1])
            test.eq(go.cmd, "go test -json ./...")
            test.eq(go.work_dir, "/w/runtime")
            local wippy = targets.command(list[2])
            test.eq(wippy.cmd, "\"wippy\" test --host \"wippy.terminal:host\"", "the defaults")
            test.eq(wippy.work_dir, "/w/shell/test")
            local own = targets.command({kind = "wippy", dir = "/m", wippy = "/r/dist/wippy-linux-amd64", host = "app:host"})
            test.eq(own.cmd, "\"/r/dist/wippy-linux-amd64\" test --host \"app:host\"")
            local none, why = targets.command(list[3])
            test.is_nil(none)
            test.eq(why, "unknown kind 'make' (wippy or go)")
            test.is_nil(go.env, "no declared environment, none passed")
            local with_env = targets.entries({declared("app:e", {kind = "go", dir = "/w", env = {HOME = "/h", PATH = "/p:/q"}})})[1]
            test.eq(targets.command(with_env).env.PATH, "/p:/q", "the declaration's environment goes to the child")
            local bad = targets.entries({declared("app:b", {kind = "go", dir = "/w", env = {["NOT A NAME"] = "x"}})})[1]
            test.eq(bad.problem, "a bad environment name 'NOT A NAME'")
        end)
    end)

    test.describe("AntiBug targets: the scan", function()
        local function target_state(): any
            return scan.new({}, targets.entries({declared("app:mod", {title = "Module", kind = "wippy", dir = "/m"})}))
        end

        test.it("a first scan counts entries, a late failure text finds its case, the exit settles; the next counts cases", function()
            local state = target_state()
            test.eq(scan.options(state)[2].label, "Module")
            test.eq(scan.options(state)[3].value, "all")
            state.target = "t:app:mod"
            test.eq(scan.start(state, 0), "app:mod")
            test.is_false(scan.answered(state, {child = "<pid 7>"}), "a target waits for its exit, not a grace")
            test.eq(scan.current(state).child, "<pid 7>")
            scan.event(state, message("antibug:progress", {ref_id = "app:mod", known = 2}))
            scan.event(state, message("antibug:progress", {ref_id = "app:mod", entry = "a_test"}))
            local value, ceiling, caption = scan.progress(state)
            test.eq(value, 1)
            test.eq(ceiling, 2, "entries done of entries known")
            test.eq(caption, "first scan: a_test")
            scan.event(state, message("test:case:pass", {ref_id = "app:mod", suite = "a_test", test = "one"}))
            scan.event(state, message("test:case:fail", {ref_id = "app:mod", suite = "a_test", test = "two", error = ""}))
            test.is_nil(state.findings[2].error, "the runner names a failure first")
            scan.event(state, message("antibug:detail", {ref_id = "app:mod", test = "two", error = "expected 1, got 2"}))
            test.eq(state.findings[2].error, "expected 1, got 2", "and gives its text at the end")
            test.is_false(scan.settled(state))
            scan.event(state, message("antibug:exit", {ref_id = "app:mod", code = 1}))
            test.is_true(scan.settled(state), "the exit settles")
            test.is_nil(scan.finish(state, 3))
            test.eq(#state.findings, 2, "a bad exit with a failed case is not one more finding")
            test.eq(state.totals["app:mod"], 2)
            test.eq(state.last["app:mod"], "failed")
            scan.start(state, 10)
            scan.event(state, message("test:case:pass", {ref_id = "app:mod", suite = "a_test", test = "one"}))
            value, ceiling, caption = scan.progress(state)
            test.eq(value, 1)
            test.eq(ceiling, 2, "cases against the previous scan's total")
            test.eq(caption, "Scanning: a_test/one")
        end)

        test.it("a target that cannot start, a bad exit with no failed test, a clean exit, and Stop", function()
            local state = target_state()
            state.target = "t:app:mod"
            scan.start(state, 0)
            test.is_true(scan.answered(state, {error = "no such target: app:mod"}), "nothing to wait for")
            scan.finish(state, 1)
            test.eq(state.findings[1].name, "Module")
            test.eq(state.findings[1].error, "not started: no such target: app:mod")

            scan.start(state, 2)
            scan.answered(state, {child = "c"})
            scan.event(state, message("antibug:exit", {ref_id = "app:mod", code = 2, error = "Error: the boot failed"}))
            scan.finish(state, 3)
            test.eq(state.findings[1].error, "Error: the boot failed", "the child's own words")

            scan.start(state, 4)
            scan.answered(state, {child = "c"})
            scan.event(state, message("antibug:exit", {ref_id = "app:mod", code = 3}))
            scan.finish(state, 5)
            test.eq(state.findings[1].error, "exited with code 3 and no failed test")

            scan.start(state, 6)
            scan.answered(state, {child = "c"})
            scan.event(state, message("antibug:exit", {ref_id = "app:mod", code = 0}))
            scan.finish(state, 7)
            test.eq(state.findings[1].status, "passed", "a clean exit with no case is one pass")

            scan.start(state, 8)
            scan.answered(state, {child = "c"})
            scan.stop(state)
            scan.event(state, message("antibug:exit", {ref_id = "app:mod", stopped = true}))
            scan.finish(state, 9)
            test.eq(state.phase, "stopped", "the last item killed is a stopped scan")
            test.eq(#state.findings, 0, "a stopped target is neither clean nor infected")
        end)

        test.it("All targets queues this computer's tests, then every target; a target row picks one", function()
            local state = scan.new(scan.entries({{id = "app:t", kind = "function.lua", meta = {type = "test", group = "G", suite = "s"}}}),
                targets.entries({declared("app:a", {title = "A", kind = "go", dir = "/a", order = 1}),
                    declared("app:b", {title = "B", kind = "go", dir = "/b", order = 2})}))
            state.target = "all"
            local queue = scan.queue(state)
            test.eq(#queue, 3)
            test.eq(queue[1].id, "app:t")
            test.eq(queue[3].title, "B")
            state.selected = "t:app:b"
            queue = scan.queue(state)
            test.eq(#queue, 1)
            test.eq(queue[1].id, "app:b")
            local rows = scan.tree(state)
            test.eq(rows[#rows].label, "B (go)")
        end)
    end)

    test.describe("AntiBug targets: the window", function()
        test.it("runs a target through the runner, and Stop asks its process to kill the child", function()
            local seen: any = {launched = {}, stopped = {}}
            local inbox = channel.new(8)
            local command: any = {ch = channel.new(1)}
            function command:response(): any return self.ch end
            function command:result(): (any, any) return {child = "<pid 42>"}, nil end
            window.deps.sys = {
                find = function(): (any, any) return {}, nil end,
                find_targets = function(): (any, any) return {declared("app:mod", {title = "Module", kind = "wippy", dir = "/m"})}, nil end,
                listen = function(): any return inbox end,
                launch = function(id: string): (any, any) error("not a test entry") end,
                launch_target = function(id: string): (any, any)
                    seen.launched[#seen.launched + 1] = id
                    return command, nil
                end,
                stop = function(child: any): boolean seen.stopped[#seen.stopped + 1] = child; return true end,
                now = function(): number return 0 end,
            }
            local context = app.context({width = 62, height = 19})
            local model = window.init(nil, context)
            app.dispatch(window, model, context, {type = "change", id = "target", value = "t:app:mod"})
            app.dispatch(window, model, context, {type = "activate", id = "scan_now"})
            test.eq(seen.launched[1], "app:mod")
            test.eq(#context.timers, 0, "a target has no timeout")
            app.dispatch(window, model, context, {type = "channel", channel = command.ch, value = true, ok = true})
            test.eq(#context.timers, 0, "and no grace: it waits for the exit")
            app.dispatch(window, model, context, {type = "channel", channel = inbox, ok = true,
                value = message("test:case:fail", {ref_id = "app:mod", suite = "a", test = "b", error = "boom"})})
            app.dispatch(window, model, context, {type = "activate", id = "stop"})
            test.eq(seen.stopped[1], "<pid 42>", "Stop goes to the target's process")
            test.eq(context.timers[1].tag.kind, "stopwait")
            -- The process never answered: the wait ends the scan as stopped.
            app.dispatch(window, model, context, {type = "timer", tag = context.timers[1].tag})
            test.eq(model.scan.phase, "stopped")
            test.eq(model.sheet and model.sheet.kind, "box")
            test.eq(model.scan.box.lines[1], "Scan stopped.")
            window.deps.sys = REAL_SYS
        end)

        test.it("live: a Go target through the real runner, target process and exec; its cases arrive", function()
            window.deps.sys = setmetatable({find = function(): (any, any) return {}, nil end}, {__index = REAL_SYS})
            local context = app.context({width = 62, height = 19})
            local model = window.init(nil, context)
            app.dispatch(window, model, context, {type = "change", id = "target", value = "t:app:antibug_go_target"})
            app.dispatch(window, model, context, {type = "activate", id = "scan_now"})
            test.not_nil(scan.current(model.scan), "the scan started")
            local deadline = time.after("25s")
            while scan.scanning(model.scan) do
                local cases: any = {deadline:case_receive()}
                for _, ch in ipairs(context.watched) do cases[#cases + 1] = ch:case_receive() end
                for _, pending in ipairs(context.timers) do cases[#cases + 1] = pending.channel:case_receive() end
                local picked = channel.select(cases)
                if picked.channel == deadline then break end
                app.dispatch(window, model, context, app.channel_action(context, picked))
            end
            local log = scan.log_text(model.scan)
            test.is_false(scan.scanning(model.scan), "the target ended within 25 s: " .. log)
            test.eq(model.scan.counts.passed, 1, log)
            test.eq(model.scan.counts.infected, 1, log)
            test.eq(model.scan.counts.skipped, 1, log)
            local failed = model.scan.findings[2]
            test.eq(failed and failed.name, "example.com/antibugfixture/TestFails", log)
            test.is_true(tostring(failed and failed.error):find("expected 3 rows, got 2", 1, true) ~= nil, log)
            test.eq(model.scan.totals["app:antibug_go_target"], 3, "the next scan counts against three cases")
            window.deps.sys = REAL_SYS
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
