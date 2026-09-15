-- Startup windows (`meta.type: chicago.startup`).
--
-- The rule is checked pure (the order, what is skipped and why), then on the
-- harness's real registry and real `funcs` (the fixtures in _index.yaml), then
-- the startup process itself against a stand-in desktop — the test answers
-- its `desktop.open` — and last against the real compositor of a shell
-- brought up on a viewport. The logon itself cannot be driven here (it would
-- need the application's logon function and token store for every shell the
-- harness boots), so `startup.begin` — the one call the logon wrapper makes —
-- is checked with a stand-in spawn, and the shell without logon is checked to
-- open nothing by itself.
local test = require("test")
local startup = require("startup")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")

local USER = "u-startup"
local DESKTOP_NAME = "chicago.shell.desktop"
-- What the fixtures open for USER, in order: `entry/args`.
local OPENED = "app:sdk_demo/first app:sdk_demo/also app:sdk_demo/later"

local function ids(list: any): string
    local out = {}
    for _, item in ipairs(type(list) == "table" and list or {}) do out[#out + 1] = tostring((item :: any).id) end
    return table.concat(out, ",")
end

local function reason_of(list: any, id: string): string
    for _, item in ipairs(type(list) == "table" and list or {}) do
        if (item :: any).id == id then return tostring((item :: any).reason) end
    end
    return "not skipped"
end

local function has(text: any, part: string): boolean
    return tostring(text):find(part, 1, true) ~= nil
end

local function body(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then value = value:data() end
    if type(value) == "table" and value[1] then value = value[1] end
    return value
end

local function next_message(stream: any, budget: string): any
    local deadline = time.after(budget)
    local picked = channel.select({stream:case_receive(), deadline:case_receive()})
    if picked.channel == deadline or not picked.ok then return nil end
    return picked.value
end

local function exited(lifecycle: any, pid: any, budget: string): boolean
    local deadline = time.after(budget)
    while true do
        local picked = channel.select({lifecycle:case_receive(), deadline:case_receive()})
        if picked.channel == deadline or not picked.ok then return false end
        local event: any = picked.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then return true end
    end
end

-- windows_of(shell, replies, budget) -> the compositor's window list, or nil.
-- Answers left from an earlier question are dropped first: read as fresh,
-- a list from before would answer this one.
local function windows_of(shell: string, replies: any, budget: string): any
    while true do
        local stale = channel.select({replies:case_receive()}, true)
        if stale.default or not stale.ok then break end
    end
    process.send(shell, "desktop.list", {reply_to = tostring(process.pid())})
    local deadline = time.after(budget)
    while true do
        local picked = channel.select({replies:case_receive(), deadline:case_receive()})
        if picked.channel == deadline or not picked.ok then return nil end
        local value: any = body(picked.value)
        if type(value) == "table" and value.command == "desktop.list" then return value.windows or {} end
    end
end

local function shown(windows: any): string
    local out = {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
        out[#out + 1] = tostring((window :: any).entry) .. "/" .. tostring((window :: any).args)
    end
    return table.concat(out, " ")
end

local function define_tests()
    test.describe("startup windows — the rule", function()
        test.it("orders by meta.order, then by the entry id; no order is 100", function()
            local items, skipped = startup.plan({
                {id = "app:c", meta = {order = 100}, data = {entry = "app:w"}},
                {id = "app:b", meta = {}, data = {entry = "app:w"}},
                {id = "app:a", meta = {order = 200}, data = {entry = "app:w"}},
                {id = "app:z", meta = {order = 5}, data = {entry = "app:w", args = "x"}},
                {id = "app:empty_args", meta = {order = 300}, data = {entry = "app:w", args = ""}},
            })
            test.eq(ids(items), "app:z,app:b,app:c,app:a,app:empty_args")
            test.eq(#skipped, 0)
            test.eq(items[1].args, "x")
            test.eq(items[2].order, startup.DEFAULT_ORDER)
            test.is_nil(items[5].args, "empty args are no args, as the compositor reads them")
        end)

        test.it("skips a declaration it cannot follow, with the reason", function()
            local items, skipped = startup.plan({
                {id = "app:no_entry", data = {}},
                {id = "app:table_args", data = {entry = "app:w", args = {a = 1}}},
                {id = "app:bad_when", data = {entry = "app:w", when = 7}},
                {id = "app:fine", data = {entry = "app:w", when = "app:f"}},
            })
            test.eq(ids(items), "app:fine")
            test.eq(items[1].when, "app:f")
            test.is_true(has(reason_of(skipped, "app:no_entry"), "names no window"), reason_of(skipped, "app:no_entry"))
            test.is_true(has(reason_of(skipped, "app:table_args"), "must be a string"), reason_of(skipped, "app:table_args"))
            test.is_true(has(reason_of(skipped, "app:bad_when"), "must name a function"), reason_of(skipped, "app:bad_when"))
        end)

        test.it("opens only on {show = true}; a failure, a refusal and another answer do not", function()
            test.is_true((startup.decide({id = "app:s"}, USER)), "no when opens the window")
            local seen: any = {}
            local show, why = startup.decide({id = "app:s", when = "app:f"}, USER, function(name: any, args: any): (any, any)
                seen.name, seen.args = name, args
                return {show = true}, nil
            end)
            test.is_true(show, tostring(why))
            test.eq(seen.name, "app:f")
            test.eq(seen.args.user_id, USER, "the when function is asked about the logged-on user")

            local declined: any
            show, why, declined = startup.decide({when = "app:f"}, USER, function(): (any, any) return {show = false}, nil end)
            test.is_false(show)
            test.is_true(declined, "show = false is an answer, not a fault")
            show, why = startup.decide({when = "app:f"}, USER, function(): (any, any) return "yes", nil end)
            test.is_false(show)
            test.is_true(has(why, "answered string"), tostring(why))
            show, why = startup.decide({when = "app:f"}, USER, function(): (any, any) return {show = "true"}, nil end)
            test.is_false(show)
            test.is_true(has(why, "without show = true"), tostring(why))
            show, why, declined = startup.decide({when = "app:f"}, USER, function(): (any, any) return nil, "permission denied" end)
            test.is_false(show)
            test.is_false(declined)
            test.is_true(has(why, "permission denied"), tostring(why))
            show, why = startup.decide({when = "app:f"}, USER, function(): (any, any) error("raised on purpose") end)
            test.is_false(show)
            test.is_true(has(why, "raised on purpose"), "a raised error is a reason, not a crash: " .. tostring(why))
        end)
    end)

    test.describe("startup windows — the registry and funcs", function()
        test.it("reads the chicago.startup entries in order", function()
            local read, err = startup.read()
            test.is_nil(err)
            test.eq(ids(read and read.items),
                "app:startup_first,app:startup_error,app:startup_missing,app:startup_also,app:startup_later,app:startup_default")
        end)

        test.it("calls the when function through funcs with the user id", function()
            local show, why = startup.decide({when = "app:startup_when_user"}, USER)
            test.is_true(show, tostring(why))
            local declined: any
            show, why, declined = startup.decide({when = "app:startup_when_user"}, "u-other")
            test.is_false(show)
            test.is_true(declined, tostring(why))
            show, why = startup.decide({when = "app:startup_when_error"}, USER)
            test.is_false(show)
            test.is_true(has(why, "fails on purpose"), tostring(why))
            show, why = startup.decide({when = "app:no_such_function"}, USER)
            test.is_false(show, "a function that is not there opens nothing")
            test.not_nil(why)
        end)

        test.it("chooses per person and names every skip", function()
            local picked, err = startup.choose(USER)
            test.is_nil(err)
            test.eq(ids(picked and picked.chosen), "app:startup_first,app:startup_also,app:startup_later")
            local skipped: any = picked and picked.skipped
            test.is_true(has(reason_of(skipped, "app:startup_missing"), "no window entry app:no_such_window"),
                reason_of(skipped, "app:startup_missing"))
            test.is_true(has(reason_of(skipped, "app:startup_error"), "fails on purpose"), reason_of(skipped, "app:startup_error"))
            test.is_true(has(reason_of(skipped, "app:startup_default"), "said no"), reason_of(skipped, "app:startup_default"))

            local other = startup.choose("u-other")
            test.eq(ids(other and other.chosen), "app:startup_also,app:startup_later")

            local foreign = startup.choose(USER, {
                find = function(): (any, any)
                    return {{id = "app:s", meta = {type = startup.TYPE}, data = {entry = "app:not_window"}}}, nil
                end,
                get = function(id: any): (any, any) return {id = id, meta = {type = "something.else"}}, nil end,
            })
            test.eq(ids(foreign and foreign.chosen), "")
            test.is_true(has(reason_of(foreign and foreign.skipped, "app:s"), "is not a window"),
                reason_of(foreign and foreign.skipped, "app:s"))

            local unread, why = startup.choose(USER, {find = function(): (any, any) return nil, "denied on purpose" end})
            test.is_nil(unread)
            test.is_true(has(why, "denied on purpose"), tostring(why))
        end)

        test.it("no logon, no startup windows; a logon starts the startup process once", function()
            local none, why = startup.choose(nil)
            test.is_nil(none)
            test.is_true(has(why, "no logon"), tostring(why))

            local spawned: any = {}
            local function spawn(id: any, host: any, desktop: any, user: any): (any, any)
                spawned[#spawned + 1] = {id = id, host = host, desktop = desktop, user = user}
                return "pid-startup", nil
            end
            local pid = startup.begin(nil, {spawn = spawn})
            test.is_nil(pid)
            pid = startup.begin({scope = "S", context = {user_id = USER}}, {spawn = spawn})
            test.is_nil(pid, "no actor: the base refuses this logon, so nothing starts")
            pid, why = startup.begin({actor = "A", scope = "S", context = {}}, {spawn = spawn})
            test.is_nil(pid)
            test.is_true(has(why, "no user id"), tostring(why))
            test.eq(#spawned, 0, "nothing was spawned without a person")

            local identity = {actor = "A", scope = "S", context = {user_id = USER, user_name = "Startup"}}
            pid, why = startup.begin(identity, {spawn = spawn, desktop = "pid-desktop"})
            test.eq(pid, "pid-startup", tostring(why))
            test.eq(#spawned, 1)
            test.eq(spawned[1].id, startup.PROCESS)
            test.eq(spawned[1].host, startup.HOST)
            test.eq(spawned[1].desktop, "pid-desktop")
            test.eq(spawned[1].user, USER)

            pid, why = startup.begin(identity, {spawn = spawn, find = function(): (any, any) return {}, nil end})
            test.is_nil(pid)
            test.is_nil(why, "nothing declared is no process and no complaint")
            test.eq(#spawned, 1)
        end)
    end)

    test.describe("startup windows — the startup process", function()
        test.it("asks the desktop for each chosen window in order, and a refusal does not stop the rest", function()
            local opens = process.listen(startup.OPEN, {message = true})
            test.not_nil(opens, "the test could not listen for desktop.open")
            local lifecycle = assert(process.events())
            local pid, err = process.spawn_monitored(startup.PROCESS, "app:processes", tostring(process.pid()), USER)
            test.not_nil(pid, "the startup process did not start: " .. tostring(err))
            local asked: any = {}
            for index = 1, 3 do
                local message = next_message(opens, "10s")
                test.not_nil(message, "command " .. index .. " did not arrive; asked: " .. table.concat(asked, " "))
                if not message then break end
                local value: any = body(message)
                asked[#asked + 1] = tostring(value.entry) .. "/" .. tostring(value.args)
                local answer: any = {ok = true, command = startup.OPEN, window = {id = "w" .. index}}
                if index == 2 then answer = {ok = false, command = startup.OPEN, error = "refused on purpose"} end
                process.send(tostring(value.reply_to), "desktop.reply", answer)
            end
            test.eq(table.concat(asked, " "), OPENED)
            test.is_true(exited(lifecycle, pid, "10s"), "the startup process ends once it has asked")
            test.is_nil(next_message(opens, "300ms"),
                "nothing else is asked: the missing window, the failing and the declining when stay shut")
        end)

        test.it("a shell without logon opens none itself, and the startup process opens them through its compositor", function()
            local view = assert(tty.viewport({width = 120, height = 40}))
            local grant = assert(view:grant())
            local replies = process.listen("desktop.reply", {message = true})
            test.not_nil(replies, "the test could not listen for the desktop's answers")
            local shell_pid, err = process.with_options({terminal = grant})
                :spawn_monitored("chicago.shell:shell", "app:processes", "test")
            test.not_nil(shell_pid, "the shell did not start: " .. tostring(err))
            local shell = tostring(shell_pid)

            local listed: any = nil
            local deadline = time.now():unix_nano() + 20000000000
            while listed == nil and time.now():unix_nano() < deadline do
                listed = windows_of(shell, replies, "2s")
            end
            test.not_nil(listed, "the shell did not answer desktop.list")
            -- Had the shell started the startup process without a logon, the
            -- windows would be arriving now.
            channel.select({time.after("1500ms"):case_receive()})
            listed = windows_of(shell, replies, "5s")
            test.eq(shown(listed), "", "a desktop without logon opens no startup window")

            local lifecycle = assert(process.events())
            local helper, herr = process.spawn_monitored(startup.PROCESS, "app:processes", shell, USER)
            test.not_nil(helper, "the startup process did not start: " .. tostring(herr))
            test.is_true(exited(lifecycle, helper, "40s"), "the startup process ends")
            listed = windows_of(shell, replies, "5s")
            test.eq(shown(listed), OPENED, "the chosen windows open through the compositor, in meta.order")

            process.terminate(shell)
            -- The next suite brings up a shell of its own under the same name.
            local freed = time.now():unix_nano() + 10000000000
            while time.now():unix_nano() < freed do
                local holder = process.registry.lookup(DESKTOP_NAME)
                if not holder or tostring(holder) ~= shell then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
