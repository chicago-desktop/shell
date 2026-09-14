-- butschster.windows.antibug:target — runs ONE scan target as a child
-- (FR-009 §4a).
--
-- Spawned by the runner, never by the window: it inherits the runner's actor,
-- whose wide policy includes `exec`. The command comes from the target's
-- registry entry, which the runner already checked (`targets.command`). The
-- child's stdout is parsed line by line into the scan's case events and sent
-- to the window's pid on its topic as they come — a module's suite runs for
-- minutes, and the window watches a channel instead of waiting. stderr is kept
-- only as the reason of a bad exit. On `antibug.stop` from the window the
-- child is killed. The last message is always `antibug:exit`.
local channel = require("channel")
local exec = require("exec")
local process = require("process")
local targets = require("targets")

local EXECUTOR = "butschster.windows.antibug:exec"
local STOP = "antibug.stop"

local function main(args: any)
    local given: any = type(args) == "table" and args or {}
    local target: any = type(given.target) == "table" and given.target or {}
    local window = given.pid
    local topic = tostring(given.topic or "")
    local function send(kind: any, data: any)
        data.ref_id = target.id
        process.send(tostring(window), topic, {type = tostring(kind), data = data})
    end
    -- The stop subscription exists before the child does: a Stop pressed
    -- right away must not land in an inbox nobody reads.
    local stop = process.listen(STOP)

    local plan, why = targets.command(target)
    if not plan then
        send("antibug:exit", {error = "cannot start: " .. tostring(why)})
        return
    end
    local executor, exec_err = exec.get(EXECUTOR)
    if not executor then
        send("antibug:exit", {error = "cannot start: no executor (" .. tostring(exec_err) .. ")"})
        return
    end
    -- The environment is the declaration's own (`meta.env`): exec.native
    -- does not inherit the runtime's.
    -- An empty environment when none is declared: the child gets nothing
    -- either way.
    local env: {[string]: string} = {}
    if type(plan.env) == "table" then
        for key, value in pairs(plan.env) do env[tostring(key)] = tostring(value) end
    end
    local child, child_err = executor:exec(tostring(plan.cmd), {work_dir = tostring(plan.work_dir), env = env})
    if not child then
        executor:release()
        send("antibug:exit", {error = "cannot start " .. plan.cmd .. ": " .. tostring(child_err)})
        return
    end
    local started, start_err = child:start()
    if not started then
        executor:release()
        send("antibug:exit", {error = "cannot start " .. plan.cmd .. " in " .. plan.work_dir .. ": " .. tostring(start_err)})
        return
    end

    -- Both streams are read by their own coroutine into one channel; the
    -- loop selects on it and on Stop.
    local chunks = channel.new(64)
    local function pump(name: string, stream: any)
        coroutine.spawn(function()
            while stream do
                local chunk = stream:read()
                if chunk == nil then break end
                if chunk ~= "" then chunks:send({name = name, chunk = chunk}) end
            end
            chunks:send({name = name, eof = true})
        end)
    end
    local out_stream = child:stdout_stream()
    local err_stream = child:stderr_stream()
    pump("out", out_stream)
    pump("err", err_stream)

    local parser = targets.parser(target.kind)
    local state: any = {open = 2, stopped = false}
    while state.open > 0 do
        local picked = channel.select({chunks:case_receive(), stop:case_receive()})
        if picked.channel == stop then
            if not state.stopped then
                state.stopped = true
                child:close(true)
            end
        elseif picked.ok then
            local item: any = picked.value
            if item.eof then
                state.open = state.open - 1
            elseif item.name == "out" then
                for _, found in ipairs(targets.feed(parser, item.chunk)) do send(found.type, found.data) end
            else
                targets.stray(parser, item.chunk)
            end
        else
            break
        end
    end
    for _, found in ipairs(targets.flush(parser)) do send(found.type, found.data) end

    local code: any = nil
    if not state.stopped then
        local exit_code, wait_err = child:wait()
        code = exit_code
        if wait_err and code == nil then code = -1 end
    end
    local reason: any = nil
    if not state.stopped and tonumber(code) ~= 0 then reason = targets.reason(parser) end
    send("antibug:exit", {code = code, stopped = state.stopped, error = reason})
    executor:release()
    process.unlisten(stop)
end

return {main = main}
