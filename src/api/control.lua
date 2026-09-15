-- Command channel to the shell.
--
-- The shell is an ordinary process registered under a name. A handler finds
-- it by name, sends a message and waits for the answer on its own inbox.
--
-- Why the layout handlers need this: the compositor reads the layout not
-- every frame but on command. A handler that changed a row and did not say
-- so looks as if it did not work — the icon would appear only after a
-- restart.
--
-- Hence an important consequence for whoever reads the answer: "the shell
-- does not answer" and "the shell is not running" are different things. The
-- second is normal: the layout can be edited with the shell shut down too,
-- and that must not be called a refusal.
--
-- There may be several shells at once: a terminal.ssh host gives every
-- connection its own desktop, under `name`, `name.2` … (window_api's rule).
-- A question goes to the first one running; a refresh goes to every one.

local channel = require("channel")
local process = require("process")
local time = require("time")
local desktop = require("desktop")

local control = {}

control.SERVICE_NAME = "butschster.windows.shell"

local REPLY_TOPIC = "desktop.reply"
-- Shorter than the base's: the shell is on the same machine, and a handler
-- that moves an icon must not hang for five seconds because of a busy
-- compositor.
local BUDGET = "2s"

-- The message arrives wrapped: payload is userdata, and inside there is
-- sometimes also an array of one element. A field read directly turns out
-- nil without any error.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

control.unwrap = unwrap

local function await(budget)
    local inbox = process.inbox()
    local expiry = time.after(budget)

    while true do
        local result = channel.select({inbox:case_receive(), expiry:case_receive()})
        if result.channel == expiry then
            return nil, "the shell did not answer within " .. budget
        end
        if not result.ok then
            return nil, "the call inbox closed while waiting for the shell"
        end
        local message = result.value
        if message:topic() == REPLY_TOPIC then
            return unwrap(message:payload()), nil
        end
        -- We do not swallow someone else's message: it is not addressed to us.
    end
end

-- desktops() -> {{name, pid}, …}: the shell desktops running now.
function control.desktops()
    return desktop.desktops(control.SERVICE_NAME)
end

local function ask(pid, topic, body)
    local payload = {}
    for key, value in pairs(type(body) == "table" and body or {}) do payload[key] = value end
    payload.reply_to = process.pid()

    local sent, serr = process.send(pid, topic, payload)
    if not sent then
        return nil, "could not deliver the command to the shell: " .. tostring(serr)
    end
    local answer, aerr = await(BUDGET)
    if not answer then return nil, aerr end
    if answer.ok == false then
        return nil, tostring(answer.error or "the shell refused without a reason")
    end
    return answer, nil
end

-- call(topic, body) -> (answer, nil, running) | (nil, reason, running)
--
-- The third value is whether a shell was running at all. The layout
-- handler needs it so as not to pass off a shut-down shell as a refusal.
function control.call(topic, body)
    local first = control.desktops()[1]
    if not first then
        return nil, "the shell is not running: run `wippy run --host butschster.windows:terminal windows`", false
    end
    local answer, err = ask(tostring(first.pid), topic, body)
    return answer, err, true
end

-- refresh() -> {refreshed, desktops, reason}
--
-- Neither a refusal nor an exception: the layout is already written, and a
-- failed re-read is a separate fact that the handler must name without
-- passing off the write as failed. A shut-down shell is not an error at all.
-- Every desktop re-reads: one that did not would show the old layout.
function control.refresh()
    local running = control.desktops()
    if #running == 0 then return {refreshed = false, reason = "the shell is not running"} end
    local failed = {}
    for _, found in ipairs(running) do
        local answer, err = ask(tostring(found.pid), "desktop.refresh", {})
        if not answer then failed[#failed + 1] = found.name .. ": " .. tostring(err) end
    end
    if #failed > 0 then
        return {refreshed = false, desktops = #running, reason = table.concat(failed, "; ")}
    end
    return {refreshed = true, desktops = #running}
end

return control
