-- Startup windows: what opens by itself once a person has logged on.
--
-- A module or the application declares a registry entry
--
--   kind: registry.entry
--   meta: {type: chicago.startup, order: 10}
--   data: {entry: <window entry>, args: "<string>", when: <function.lua entry>}
--
-- and the shell opens that window right after a successful logon — by
-- password or by SSH key — once per desktop, under the logged-on person, in
-- `meta.order` (lower first, 100 by default, ties by the entry id). `when`
-- names a function the shell calls through `funcs` with `{user_id}`, under
-- the function's own actor, as the logon provider calls the application's
-- functions; only the answer `{show = true}` opens the window. A desktop
-- without logon runs under the service actor and opens none.
--
-- Nothing here may stop the desktop: a startup entry that names a missing
-- window, a `when` that fails, refuses or answers anything else, a window the
-- compositor does not open — each is skipped and logged with its reason.
--
-- WHY A PROCESS OF ITS OWN. The windows are opened by the base's compositor
-- on `desktop.open`, the command every window and the command channel use,
-- so a startup window opens exactly as one the person opens: under the
-- identity the compositor holds, placed and raised by the same code. The
-- logon wrapper runs INSIDE the compositor, before its loop, so it cannot
-- send that command to itself: the compositor answers a refusal to the
-- sender, and an answer sent to itself is an unknown command it refuses
-- again, to itself, for ever. So the wrapper spawns `startup_run`, which asks
-- the way any other process asks and waits for each answer. Its commands wait
-- in the compositor's inbox until the loop starts — after the identity is
-- taken — and the `when` calls do not hold up the first frame.

local registry = require("registry")
local funcs = require("funcs")
local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local catalog = require("catalog")
local window_api = require("window_api")

local startup = {}

startup.TYPE = "chicago.startup"
startup.DEFAULT_ORDER = 100
-- The process that opens them, and the host it runs on — the one the
-- compositor spawns its windows on.
startup.PROCESS = "chicago.shell.programs:startup_run"
startup.HOST = "chicago.tui_desktop:workers"
startup.OPEN = "desktop.open"
-- How long to wait for the compositor's answer about one window. The first
-- answer waits for the compositor's loop, which starts after logon.
startup.BUDGET = "15s"

local function skip(list: any, id: any, reason: any, declined: boolean?)
    list[#list + 1] = {id = tostring(id), reason = tostring(reason), declined = declined == true}
end

-- plan(records) -> items, skipped
--
-- Pure, like `catalog.build`: the order is a rule, and a rule checked only
-- through the registry is checked once. `items` are `{id, entry, args, when,
-- order}` in `meta.order`, then the entry id; `skipped` are `{id, reason}` —
-- a declaration that cannot be followed is named, not dropped.
function startup.plan(records: any): (any, any)
    local items: any, skipped: any = {}, {}
    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record: any = entry
        if type(record) == "table" and type(record.id) == "string" and record.id ~= "" then
            local meta: any = type(record.meta) == "table" and record.meta or {}
            local data: any = type(record.data) == "table" and record.data or {}
            if type(data.entry) ~= "string" or data.entry == "" then
                skip(skipped, record.id, "names no window (data.entry)")
            elseif data.args ~= nil and type(data.args) ~= "string" then
                skip(skipped, record.id, "data.args must be a string: the compositor carries a window's args only as one")
            elseif data.when ~= nil and (type(data.when) ~= "string" or data.when == "") then
                skip(skipped, record.id, "data.when must name a function entry")
            else
                items[#items + 1] = {
                    id = record.id,
                    entry = data.entry,
                    -- An empty string is no args: the compositor reads it so too.
                    args = type(data.args) == "string" and data.args ~= "" and data.args or nil,
                    when = data.when,
                    order = tonumber(meta.order) or startup.DEFAULT_ORDER,
                }
            end
        end
    end
    table.sort(items, function(a: any, b: any): boolean
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return items, skipped
end

-- read(find?) -> {items, skipped} | nil, reason
--
-- The registry's `chicago.startup` entries, read the way the catalog reads
-- the taskbar clock. `find` stands in for `registry.find` in tests.
function startup.read(find: any?): (any, any)
    local look: any = find or registry.find
    local found, err = look({[".kind"] = "registry.entry", ["meta.type"] = startup.TYPE})
    if err then return nil, "startup windows not read: " .. tostring(err) end
    if type(found) ~= "table" then
        return nil, "startup windows not read: the registry answered with something other than a list"
    end
    local items, skipped = startup.plan(found)
    return {items = items, skipped = skipped}, nil
end

-- window_problem(entry, get?) -> reason | nil
--
-- The named entry must be a window. Asked before `when`: a function is not
-- called for a window that cannot open anyway.
function startup.window_problem(entry: any, get: any?): any
    local id = tostring(entry)
    local look: any = get or registry.get
    local record, err = look(id)
    if type(record) ~= "table" then
        return "no window entry " .. id .. (err ~= nil and (" (" .. tostring(err) .. ")") or "")
    end
    local meta: any = type(record.meta) == "table" and record.meta or {}
    if meta.type ~= catalog.WINDOW_TYPE then
        return "entry " .. id .. " is not a window: it does not declare meta.type " .. catalog.WINDOW_TYPE
    end
    return nil
end

-- decide(item, user_id, call?) -> show, reason, declined
--
-- No `when` opens the window. Otherwise only `{show = true}` does; an error,
-- a refusal (the error of a denied call) and any other answer do not, and
-- say why. `declined` marks the plain "no" (`show = false`), which is an
-- answer, not a fault. The call is guarded: this runs in the startup
-- process, never in the compositor's frame, and a raised error must not take
-- the windows after it along.
function startup.decide(item: any, user_id: any, call: any?): (boolean, any, boolean)
    if item.when == nil then return true, nil, false end
    local when = tostring(item.when)
    local invoke: any = call or function(name: any, args: any): (any, any)
        local answer, err = funcs.new():call(tostring(name), args)
        return answer, err
    end
    -- In a table, not in locals: under go-lua an error caught by pcall can
    -- split a closure's upvalue from its owner.
    local outcome: any = {}
    local ran, raised = pcall(function()
        outcome.answer, outcome.err = invoke(when, {user_id = user_id})
    end)
    if not ran then return false, "the when function " .. when .. " failed: " .. tostring(raised), false end
    if outcome.err ~= nil then
        return false, "the when function " .. when .. " failed: " .. tostring(outcome.err), false
    end
    local answer: any = outcome.answer
    if type(answer) ~= "table" then
        return false, "the when function " .. when .. " answered " .. type(answer) .. ", not {show = true}", false
    end
    if answer.show == true then return true, nil, false end
    if answer.show == false then return false, "the when function " .. when .. " said no", true end
    return false, "the when function " .. when .. " answered without show = true", false
end

-- choose(user_id, options?) -> {chosen, skipped} | nil, reason
--
-- What opens for this person, in order. `options.find`, `options.get` and
-- `options.call` stand in for the registry and `funcs` in tests. No person —
-- a desktop without logon — is no startup windows at all.
function startup.choose(user_id: any, options: any?): (any, any)
    local given: any = type(options) == "table" and options or {}
    if type(user_id) ~= "string" or user_id == "" then
        return nil, "no logon: a desktop without a person opens no startup windows"
    end
    local read, err = startup.read(given.find)
    if not read then return nil, err end
    local chosen: any, skipped: any = {}, {}
    for _, item in ipairs(read.skipped) do skipped[#skipped + 1] = item end
    for _, entry in ipairs(read.items) do
        local item: any = entry
        local missing = startup.window_problem(item.entry, given.get)
        if missing then
            skip(skipped, item.id, missing)
        else
            local show, why, declined = startup.decide(item, user_id, given.call)
            if show then chosen[#chosen + 1] = item else skip(skipped, item.id, tostring(why), declined) end
        end
    end
    return {chosen = chosen, skipped = skipped}, nil
end

-- The compositor's answer arrives wrapped: the payload is userdata, and
-- inside there is sometimes a one-element array.
local function answer_of(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then value = value:data() end
    if type(value) == "table" and value[1] ~= nil then value = value[1] end
    return type(value) == "table" and value or {}
end

local function await(replies: any, budget: string): (any, any)
    local deadline = time.after(budget)
    while true do
        local picked = channel.select({replies:case_receive(), deadline:case_receive()})
        if picked.channel == deadline then return nil, "the desktop did not answer within " .. budget end
        if not picked.ok then return nil, "the desktop's answers stopped" end
        local answer = answer_of(picked.value)
        if answer.command == startup.OPEN then return answer, nil end
    end
end

-- open(desktop, chosen, budget?) -> {{id, entry, ok, window?, reason?}, …}
--
-- One `desktop.open` per window, each answer awaited before the next command:
-- the compositor raises every window it opens, so the order of the commands
-- is the order on the screen, and an answer is never taken for another
-- window's. After a command the desktop did not answer in time, the rest are
-- not sent — a late answer would be read as the next window's.
function startup.open(desktop: string, chosen: any, budget: any?): any
    local results: any = {}
    local wait = type(budget) == "string" and budget or startup.BUDGET
    -- Subscribed BEFORE the first command: a quick answer is not missed.
    local replies: any = process.listen(window_api.REPLY_TOPIC, {message = true})
    local silent: any = nil
    for _, entry in ipairs(type(chosen) == "table" and chosen or {}) do
        local item: any = entry
        local result: any = {id = item.id, entry = item.entry, ok = false}
        if not replies then
            result.reason = "could not subscribe to the desktop's answers"
        elseif silent then
            result.reason = "not asked: " .. silent
        else
            local sent, serr = process.send(desktop, startup.OPEN,
                {entry = item.entry, args = item.args, reply_to = tostring(process.pid())})
            if not sent then
                result.reason = "the command did not reach the desktop: " .. tostring(serr)
            else
                local answer, why = await(replies, wait)
                if not answer then
                    result.reason = tostring(why)
                    silent = tostring(why)
                elseif answer.ok == true then
                    result.ok = true
                    result.window = type(answer.window) == "table" and answer.window.id or nil
                else
                    result.reason = tostring(answer.error or "refused without a reason")
                end
            end
        end
        results[#results + 1] = result
    end
    return results
end

-- run(desktop, user_id) -> {opened, results, skipped} — the startup process:
-- choose, open, and say what became of every entry. The log is the only
-- reader here, so every skip and every refusal is named.
function startup.run(desktop: any, user_id: any): any
    local log = logger:named("chicago.shell.startup")
    local picked, why = startup.choose(user_id)
    if not picked then
        log:warn("startup windows not opened", {reason = tostring(why)})
        return {opened = 0, results = {}, skipped = {}, error = why}
    end
    for _, entry in ipairs(picked.skipped) do
        local skipped: any = entry
        if skipped.declined then
            log:info("startup window not shown", {startup = skipped.id, reason = skipped.reason})
        else
            log:warn("startup window skipped", {startup = skipped.id, reason = skipped.reason})
        end
    end
    local results = startup.open(tostring(desktop), picked.chosen)
    local opened = 0
    for _, entry in ipairs(results) do
        local result: any = entry
        if result.ok then
            opened = opened + 1
            log:info("startup window opened", {startup = result.id, entry = result.entry, window = tostring(result.window)})
        else
            log:warn("startup window did not open", {startup = result.id, entry = result.entry, reason = tostring(result.reason)})
        end
    end
    return {opened = opened, results = results, skipped = picked.skipped}
end

-- begin(identity, options?) -> pid | nil, reason
--
-- Called by the shell's logon wrapper with the identity it is about to hand
-- to the compositor — the one place that runs once per desktop, right after a
-- successful logon, by password or by key. It runs inside the compositor,
-- under the base's pcall around the logon dialog: it must not raise, or the
-- logon would read as a crashed dialog. The identity is checked the way the
-- base checks it (an actor and a scope), so no process is spawned for a
-- logon the base is about to refuse. Nothing declared is no process and no
-- reason. `options.find`, `options.spawn` and `options.desktop` stand in for
-- the registry, `process.spawn` and the compositor's pid in tests.
function startup.begin(identity: any, options: any?): (any, any)
    local given: any = type(options) == "table" and options or {}
    if type(identity) ~= "table" or identity.actor == nil or identity.scope == nil then
        return nil, "no logon: no startup windows"
    end
    local context: any = type(identity.context) == "table" and identity.context or {}
    local user_id: any = context.user_id
    if type(user_id) ~= "string" or user_id == "" then
        return nil, "the logged-on identity carries no user id"
    end
    local read, err = startup.read(given.find)
    if not read then return nil, err end
    if #read.items == 0 and #read.skipped == 0 then return nil, nil end
    local desktop: any = given.desktop or tostring(process.pid())
    local spawn: any = given.spawn or function(id: any, host: any, first: any, second: any): (any, any)
        local pid, serr = process.spawn(tostring(id), tostring(host), first, second)
        return pid, serr
    end
    local pid, serr = spawn(startup.PROCESS, startup.HOST, desktop, user_id)
    if not pid then return nil, "the startup process did not start: " .. tostring(serr) end
    return pid, nil
end

return startup
