-- butschster.windows.antibug:runner — runs a scan item for AntiBug's window
-- (FR-009 §3, shape 1; §4a).
--
-- The window is a program under the logged-on user and keeps a narrow scope;
-- tests need more than a user has (the database, `fs`, `gfx`, `exec`). So
-- this entry declares its own actor and a wide policy, and the window calls
-- it with `funcs.async`. Measured in the module's harness
-- (`antibug_actor_test`): a `funcs` call runs the callee under the actor its
-- entry declares, with its declared policies added to the caller's scope —
-- and a test entry, which declares none, then runs under this runner. The
-- same trust anchor as the CLI runner's wildcard; the window's own policy is
-- what may call it.
--
-- Two items:
--   {entry = <id>, pid, topic} — a `meta.type: test` function entry, run
--     here; the test library streams its events straight to the window.
--   {target = <id>, pid, topic} — a `meta.type: windows.antibug_target`
--     entry (§4a): the target process is spawned under this runner's actor
--     (it runs the child through `exec`), and its pid is returned so the
--     window can ask it to stop. The command is built from the registry
--     entry here, never from the window's arguments.
-- Nothing else is run: this is not a way to call an arbitrary function or
-- program with a wide scope.
local funcs = require("funcs")
local registry = require("registry")
local process = require("process")
local targets = require("targets")

local TARGET_PROCESS = "butschster.windows.antibug:target"
local DEFAULT_PROCESS_HOST = "app:processes"

local function run_entry(given: any): any
    local id = type(given.entry) == "string" and given.entry or ""
    local entry, err = registry.get(id)
    if not entry then return {error = "no such entry: " .. id .. (err and (" (" .. tostring(err) .. ")") or "")} end
    local meta: any = type(entry.meta) == "table" and entry.meta or {}
    if meta.type ~= "test" or entry.kind ~= "function.lua" then
        return {error = id .. " is not a test entry"}
    end
    local returned, call_err = funcs.new():call(id, {pid = given.pid, topic = given.topic, ref_id = id})
    if call_err then return {error = tostring(call_err)} end
    return {returned = returned}
end

local function run_target(given: any): any
    local id = type(given.target) == "string" and given.target or ""
    local entry, err = registry.get(id)
    if not entry then return {error = "no such target: " .. id .. (err and (" (" .. tostring(err) .. ")") or "")} end
    local found = targets.entries({entry})
    local target: any = found[1]
    if not target then return {error = id .. " is not a scan target"} end
    if target.problem then return {error = target.problem} end
    -- The host comes from the module's `process_host` requirement, written
    -- into the target process's own entry.
    local process_entry: any = registry.get(TARGET_PROCESS)
    local process_meta: any = process_entry and type(process_entry.meta) == "table" and process_entry.meta or {}
    local host = type(process_meta.process_host) == "string" and process_meta.process_host ~= ""
        and process_meta.process_host or DEFAULT_PROCESS_HOST
    local pid, spawn_err = process.spawn(TARGET_PROCESS, host, {target = target, pid = given.pid, topic = given.topic})
    -- The scan says "not started:" itself; this says why.
    if spawn_err or not pid then return {error = "spawn failed: " .. tostring(spawn_err or "no pid")} end
    return {child = tostring(pid)}
end

local function run(args: any): any
    local given: any = type(args) == "table" and args or {}
    if given.target ~= nil then return run_target(given) end
    return run_entry(given)
end

return {run = run}
