-- The shell's notifications: the SDK library against stand-in desktops of
-- the shell's family, the rights a caller that is not a window needs, and
-- the message window through `app.dispatch`.
--
-- The stand-ins answer to a family of this suite's own, not the shell's:
-- suites run side by side, and a stand-in under `chicago.shell.desktop.N`
-- answered another suite's `desktop.refresh` with its refusal. `notify.FAMILY`
-- is the one name the library looks desktops up by, so pointing it here
-- (in this process, and in the caller's through its args) is the whole seam.
local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local security = require("security")
local registry = require("registry")
local tty = require("tty")
local notify = require("notify")
local app = require("app")
local ui = require("ui")
local message = require("message")

local SHELL_FAMILY = notify.FAMILY
local FAMILY = "app.notify_test.desktop"
notify.FAMILY = FAMILY
local U1_A, U1_B, U2, U3 = FAMILY, FAMILY .. ".2", FAMILY .. ".3", FAMILY .. ".4"
local STANDINS: any = {
    {name = U1_A, user = "u1"},
    {name = U1_B, user = "u1"},
    {name = U2, user = "u2"},
    {name = U3, user = "u3", mode = "refuse"},
}

local function body_of(message_value: any): any
    local body: any = message_value:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- Messages from the stand-ins and the caller arrive interleaved: the wanted
-- topic is taken, the rest held for later. A field of a table, not a local
-- list: the harness runs the cases under pcall.
local held: any = {list = {}}

local function take(topic: string, budget: string?): any
    local kept: any = {}
    local found: any = nil
    for _, waiting in ipairs(held.list) do
        if found == nil and waiting:topic() == topic then found = body_of(waiting) else kept[#kept + 1] = waiting end
    end
    held.list = kept
    if found ~= nil then return found end
    local inbox = process.inbox()
    local expiry = time.after(budget or "5s")
    while true do
        local picked = channel.select({inbox:case_receive(), expiry:case_receive()})
        if picked.channel == expiry or not picked.ok then return nil end
        if picked.value:topic() == topic then return body_of(picked.value) end
        held.list[#held.list + 1] = picked.value
    end
end

-- Every "standin.got" for this many desktops, by desktop name.
local function gathered(count: integer): any
    local by: any = {}
    for _ = 1, count do
        local got: any = take("standin.got")
        test.not_nil(got, "a desktop did not report what it got")
        if got then by[tostring(got.desktop)] = got end
    end
    return by
end

-- A terminate is asynchronous: the name is free only when the process is
-- gone. Without the wait, a case after a failed one (which never reached its
-- own stop) met "name already registered" and hid the first failure.
local function stop_standins()
    for _, spec in ipairs(STANDINS) do
        local pid = process.registry.lookup(spec.name)
        if pid then process.terminate(tostring(pid)) end
    end
    local deadline = time.now():unix_nano() + 3000000000
    while time.now():unix_nano() < deadline do
        local taken = false
        for _, spec in ipairs(STANDINS) do
            if process.registry.lookup(spec.name) then taken = true end
        end
        if not taken then break end
        channel.select({time.after("50ms"):case_receive()})
    end
    held.list = {}
end

local function start_standins()
    stop_standins()
    local me = tostring(process.pid())
    for _, spec in ipairs(STANDINS) do
        local pid, err = process.spawn("app:desktop_standin", "app:processes",
            json.encode({name = spec.name, user = spec.user, mode = spec.mode, watcher = me}))
        test.not_nil(pid, "a stand-in did not start: " .. tostring(err))
    end
    for _ = 1, #STANDINS do
        local ready: any = take("standin.ready", "8s")
        test.not_nil(ready, "a stand-in did not report")
        test.is_nil(ready and ready.error, "a stand-in could not take its name: " .. tostring(ready and ready.error))
    end
end

-- Every node of a tree, depth first.
local function nodes(tree: any, out: any): any
    out = out or {}
    if type(tree) ~= "table" then return out end
    out[#out + 1] = tree
    for _, child in ipairs(type(tree.children) == "table" and tree.children or {}) do nodes(child, out) end
    return out
end

local function define_tests()
    test.describe("chicago.shell notify targeting", function()
        test.it("a person with two desktops gets two, another person's desktop gets none, and nobody gets nothing", function()
            start_standins()
            local reached, why = notify.balloon({user = "u1", title = "aICQ", text = "Anna: hi", icon = "info",
                entry = "chicago.aicq:window", timeout = 10})
            test.eq(reached, 2, "both of u1's desktops: " .. tostring(why))
            local by = gathered(2)
            test.not_nil(by[U1_A], "the first desktop of u1 got nothing")
            test.not_nil(by[U1_B], "the second desktop of u1 got nothing")
            test.is_nil(by[U2], "u2's desktop must not get u1's balloon")
            local got: any = by[U1_A] or {body = {}}
            test.eq(got.topic, "desktop.balloon")
            test.eq(got.body.title, "aICQ")
            test.eq(got.body.text, "Anna: hi")
            test.eq(got.body.icon, "info")
            test.eq(got.body.entry, "chicago.aicq:window")
            test.eq(got.body.timeout, 10)
            test.is_nil(take("standin.got", "300ms"), "a third desktop got the balloon")

            local none, nobody = notify.balloon({user = "u404", title = "t", text = "x"})
            test.is_nil(none, "a person with no open desktop gets nothing")
            test.eq(nobody, notify.NOBODY)
            test.is_nil(take("standin.got", "300ms"), "nobody's balloon reached a desktop")
            stop_standins()
        end)

        test.it("desktop names one desktop, one that is not running is nobody, a refusal comes back with its reason", function()
            start_standins()
            local reached, why = notify.notice({desktop = U2, text = "Backup finished", ttl = 5})
            test.eq(reached, 1, tostring(why))
            local got: any = take("standin.got") or {body = {}}
            test.eq(got.desktop, U2)
            test.eq(got.topic, "desktop.notice")
            test.eq(got.body.text, "Backup finished")
            test.eq(got.body.ttl, 5)

            local gone, gone_why = notify.notice({desktop = FAMILY .. ".12", text = "x"})
            test.is_nil(gone)
            test.eq(gone_why, notify.NOBODY, "a desktop that is not running is nobody to show it to")

            local refused, refused_why = notify.balloon({user = "u3", title = "t", text = "x"})
            test.is_nil(refused, "the only desktop refused, so nothing was reached")
            test.eq(refused_why, "the desktop already holds 8 balloons", "the desktop's own reason comes back")
            take("standin.got")

            local checks: any = {
                {call = function() return notify.balloon({desktop = 5, title = "t", text = "x"}) end, why = "desktop names"},
                {call = function() return notify.balloon("x") end, why = "a balloon is a table"},
                {call = function() return notify.balloon({title = "t", text = "x"}) end, why = "name the user or the desktop"},
                {call = function() return notify.notice({text = "x"}) end, why = "name the user or the desktop"},
            }
            for _, case in ipairs(checks) do
                local answer, reason = case.call()
                test.is_nil(answer, "must be refused: " .. case.why)
                test.is_true(tostring(reason):find(case.why, 1, true) ~= nil,
                    "the reason is not named (" .. case.why .. "): " .. tostring(reason))
            end
            stop_standins()
        end)

        test.it("a message opens one centred window per desktop, its args JSON", function()
            start_standins()
            local reached, why = notify.message({user = "u2", title = "ScanDisk", text = "Errors were found on drive C.",
                icon = "warning", button = "Close"})
            test.eq(reached, 1, tostring(why))
            local got: any = take("standin.got") or {body = {}}
            test.eq(got.desktop, U2)
            test.eq(got.topic, "desktop.open")
            test.eq(got.body.entry, notify.MESSAGE)
            test.eq(got.body.x, (100 - notify.MESSAGE_W) // 2 + 1, "centred on the screen the desktop reports")
            test.eq(got.body.y, (30 - notify.MESSAGE_H) // 2 + 1)
            local args: any = json.decode(tostring(got.body.args)) or {}
            test.eq(args.title, "ScanDisk")
            test.eq(args.text, "Errors were found on drive C.")
            test.eq(args.icon, "warning")
            test.eq(args.button, "Close")
            stop_standins()
        end)

        test.it("flash reaches an entry's windows on the person's desktops; a window id belongs to one desktop", function()
            start_standins()
            local reached, why = notify.flash({entry = "app:flash_target", user = "u1", count = 3})
            test.eq(reached, 2, tostring(why))
            local by = gathered(2)
            for _, name in ipairs({U1_A, U1_B}) do
                local got: any = by[name] or {body = {}}
                test.eq(got.topic, "desktop.flash", name)
                test.eq(got.body.id, "w1", "the window of that entry, by the id its desktop listed")
                test.eq(got.body.count, 3)
            end

            local nothing, nothing_why = notify.flash({entry = "app:nowhere", user = "u1"})
            test.is_nil(nothing)
            test.is_true(tostring(nothing_why):find("no window of app:nowhere", 1, true) ~= nil, tostring(nothing_why))

            local mixed, mixed_why = notify.flash({id = "w1", user = "u1"})
            test.is_nil(mixed)
            test.is_true(tostring(mixed_why):find("belongs to one desktop", 1, true) ~= nil, tostring(mixed_why))

            local stopped, stopped_why = notify.flash({id = "w1", desktop = U2, stop = true})
            test.eq(stopped, 1, tostring(stopped_why))
            local got: any = take("standin.got") or {body = {}}
            test.eq(got.body.id, "w1")
            test.is_true(got.body.stop == true)

            local own, own_why = notify.flash("w1")
            test.is_nil(own, "a process that is not a window has no own desktop")
            test.is_true(tostring(own_why):find("name the user or the desktop", 1, true) ~= nil, tostring(own_why))
            stop_standins()
        end)

        test.it("process.send is the right a caller needs: the notify policy reaches, a scope without it hears why", function()
            start_standins()
            local events = assert(process.events())
            -- The caller under exactly these policies; its answer is its result.
            local function call_under(policies: any): any
                local scoped: any = {}
                for _, id in ipairs(policies) do
                    local policy, perr = security.policy(id)
                    test.not_nil(policy, "policy " .. id .. ": " .. tostring(perr))
                    scoped[#scoped + 1] = policy
                end
                local pid, err = process.with_context({})
                    :with_actor(security.new_actor("test:notify-caller"))
                    :with_scope(security.new_scope(scoped))
                    :spawn_monitored("app:notify_caller", "app:processes", json.encode({user = "u1", family = FAMILY}))
                test.not_nil(pid, "the caller did not start: " .. tostring(err))
                local deadline = time.after("10s")
                while true do
                    local picked = channel.select({events:case_receive(), deadline:case_receive()})
                    if picked.channel == deadline or not picked.ok then
                        test.is_true(false, "the caller did not end")
                        return {}
                    end
                    local event: any = picked.value
                    if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
                        -- Measured: `result = {value = <what main returned>}`.
                        local result: any = event.result
                        local answer: any = type(result) == "table" and result.value or nil
                        if type(answer) == "table" then return answer end
                        return {why = "the caller ended without an answer: " .. tostring(event.error)}
                    end
                end
            end

            local granted = call_under({"chicago.shell.security:notify"})
            test.eq(granted.reached, 2, "under the notify policy alone: " .. tostring(granted.why))
            gathered(2)
            -- `process.send` alone is enough: the runtime checks it on every
            -- desktop's pid, and looking a name up checks nothing.
            local send_only = call_under({"app:send_only"})
            test.eq(send_only.reached, 2, "under process.send alone: " .. tostring(send_only.why))
            gathered(2)
            -- The control, without which the cases above would be green under
            -- any scope: no send, and the call says so — not "nobody".
            local no_send = call_under({"app:no_send"})
            test.is_nil(no_send.reached, "a caller that may not send reaches nothing")
            test.is_true(tostring(no_send.why):find("no desktop could be asked", 1, true) ~= nil,
                "and hears why, not \"nobody\": " .. tostring(no_send.why))
            test.is_nil(take("standin.got", "300ms"), "nothing reached a desktop")
            stop_standins()
        end)
    end)

    test.describe("chicago.shell notify message window", function()
        local definition: any = message.definition

        test.it("reads its JSON args, shows the title, the text and one button, and closes on OK or Esc", function()
            local args = json.encode({title = "ScanDisk", text = "Errors were found on drive C.", icon = "warning",
                button = "Close", bell = true})
            local model = definition.init(args, app.context({args = args, width = 52, height = 13}))
            test.eq(model.title, "ScanDisk")
            test.eq(model.icon, "warning")
            test.eq(model.button, "Close")
            test.is_true(model.bell == true, "the bell request is kept")
            test.eq(definition.title(model), "ScanDisk", "the caption is the message's title")

            local tree = definition.view(model, app.context({width = 52, height = 13}))
            test.is_nil(ui.problem(tree), "the tree lays out")
            local labels, image, buttons = {}, nil, {}
            for _, node in ipairs(nodes(tree)) do
                if node.kind == "label" then labels[#labels + 1] = tostring(node.text) end
                if node.kind == "image" then image = node end
                if node.kind == "button" then buttons[#buttons + 1] = node end
            end
            local text = table.concat(labels, "|")
            test.is_true(text:find("ScanDisk", 1, true) ~= nil, "the title is shown: " .. text)
            test.is_true(text:find("Errors were found on drive C.", 1, true) ~= nil, "the text is shown: " .. text)
            test.eq(image and image.image, "warning", "the pack picture in pixels")
            test.eq(image and image.icon, "!", "the letter in cells")
            test.eq(#buttons, 1, "one button")
            test.eq(buttons[1].id, "message_ok")
            test.eq(buttons[1].text, "Close")
            test.is_true(buttons[1].default == true)

            local ok_context = app.context({width = 52, height = 13})
            test.is_true(app.dispatch(definition, model, ok_context, {type = "activate", id = "message_ok"}))
            test.is_true(ok_context.closing, "OK closes the window")
            local esc_context = app.context({width = 52, height = 13})
            app.dispatch(definition, model, esc_context, {type = "key", key = "esc", key_type = "esc"})
            test.is_true(esc_context.closing, "Esc closes the window")
            local other_context = app.context({width = 52, height = 13})
            test.is_false(app.dispatch(definition, model, other_context, {type = "key", key = "a", key_type = "runes"}))
            test.is_false(other_context.closing, "any other key leaves it open")
        end)

        test.it("wraps a long text to the window and ellipsizes it; args that do not read say what was wrong", function()
            local model = definition.init(json.encode({title = "Long", text = string.rep("word ", 200)}), {})
            local function shown_lines(width: integer, height: integer): any
                local lines = {}
                for _, node in ipairs(nodes(definition.view(model, app.context({width = width, height = height})))) do
                    if node.kind == "label" and node.size == 1 then lines[#lines + 1] = tostring(node.text) end
                end
                return lines
            end
            local cells_lines = shown_lines(52, 13)
            test.eq(#cells_lines, 4, "the cell client of 52 by 13 holds four lines")
            for _, line in ipairs(cells_lines) do
                local runes = 0
                for _ in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do runes = runes + 1 end
                test.is_true(runes <= 50, "a line wider than the window: " .. line)
            end
            test.is_true(cells_lines[#cells_lines]:sub(-3) == "…", "the cut text ends in an ellipsis")
            test.eq(#shown_lines(54, 16), 7, "the pixel client holds more")
            test.eq(table.concat(definition.lines("one\ntwo", 10, 5), "|"), "one|two", "a line break starts a line")
            test.eq(table.concat(definition.lines("short", 10, 5), "|"), "short")

            local bad = definition.init("{not json", {})
            test.eq(bad.icon, "error")
            test.is_true(tostring(bad.text):find("could not be read", 1, true) ~= nil, tostring(bad.text))
            local empty = definition.init(nil, {})
            test.is_true(tostring(empty.text):find("without its text", 1, true) ~= nil, tostring(empty.text))
            local unknown = definition.init(json.encode({title = "t", text = "x", icon = "question"}), {})
            test.is_nil(unknown.icon, "an unknown icon draws none")
            test.eq(unknown.button, "OK", "the default caption")
        end)

        test.it("is a fixed-size dialog outside the menu, the size notify centres by, on the SDK renderer", function()
            local entry: any = registry.get(notify.MESSAGE)
            test.not_nil(entry, notify.MESSAGE .. " is missing")
            local meta: any = entry and entry.meta or {}
            test.eq(meta.type, "tui_desktop.window")
            test.eq(meta.width, notify.MESSAGE_W, "notify centres the window by this width")
            test.eq(meta.height, notify.MESSAGE_H, "and this height")
            test.is_true(meta.resizable == false, "the size is fixed")
            test.is_true(meta.in_menu == false, "not in the Start menu")
            test.eq(meta.window_type, "dialog")
            test.eq(meta.pixel_render, "chicago.shell.sdk:render")
            test.eq(meta.pixel_state, notify.MESSAGE)
        end)

        test.it("runs in a viewport and draws its first frame", function()
            local view = assert(tty.viewport({width = 52, height = 13}))
            local grant = assert(view:grant())
            local pid, err = process.with_options({terminal = grant})
                :with_context({["tui_desktop.service"] = "chicago.shell.test.notify_nowhere"})
                :spawn(notify.MESSAGE, "app:processes", json.encode({title = "Hello", text = "World", icon = "info"}))
            test.not_nil(pid, "the window did not start: " .. tostring(err))
            local drawn = ""
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                local snap: any = view:snapshot(-1)
                drawn = table.concat(snap and snap.rows or {}, "\n")
                if drawn:find("World", 1, true) then break end
                channel.select({time.after("50ms"):case_receive()})
            end
            test.is_true(drawn:find("Hello", 1, true) ~= nil, "the title is on its first frame")
            test.is_true(drawn:find("World", 1, true) ~= nil, "the text is on its first frame")
            test.is_true(drawn:find("OK", 1, true) ~= nil, "the button is on its first frame")
            process.terminate(tostring(pid))
            view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
