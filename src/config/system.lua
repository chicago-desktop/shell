-- Runtime figures for three windows — "Task Manager", "System Properties",
-- "Network Neighborhood" — in one read: for each field a value OR a reason.
--
-- There were three copies of `snapshot()`, and all three lost the second
-- value of `system.*`: a permission denial became zero, "unnamed",
-- "unavailable" or "(none)" — that is, a statement about the runtime that is
-- untrue. Here the error goes into `snap.problems[field]` in words for a
-- person, and a permission denial is called a permission denial.
--
-- `system.*` does not throw, it returns nil and an error, so there is no
-- `pcall` around the calls here and none is needed. It would even be
-- dangerous: a caught error in go-lua tears the upvalues of the whole stack
-- below it (sdk_test, "go-lua: an error under pcall…").

local system = require("system")

local facts = {}

-- Field name → {`system` section, function, what to call it for a person}.
-- An empty section is a function at the root of the module.
local FIELDS: any = {
    memory = {"memory", "stats", "memory"},
    goroutines = {"runtime", "goroutines", "goroutines"},
    cpu_count = {"runtime", "cpu_count", "processors"},
    max_procs = {"runtime", "max_procs", "threads"},
    pid = {"process", "pid", "process id"},
    hostname = {"process", "hostname", "host name"},
    cwd = {"process", "cwd", "working directory"},
    node_id = {"node", "id", "node name"},
    node_addr = {"node", "addr", "node address"},
    node_role = {"node", "role", "node role"},
    members = {"cluster", "members", "cluster members"},
    leader = {"cluster", "leader", "leader"},
    raft_role = {"raft", "role", "Raft role"},
    hosts = {"hosts", "list", "process hosts"},
    modules = {"", "modules", "Lua modules"},
}

-- Kind and text of a runtime error. An error is userdata with methods;
-- anything else (a string, a table) has no kind and does not get as far as
-- `pcall`.
local function kind_and_text(err: any): (any, string)
    if type(err) ~= "userdata" then return nil, tostring(err) end
    local ok_kind, kind = pcall(function() return err:kind() end)
    local ok_text, message = pcall(function() return err:message() end)
    return ok_kind and kind or nil, ok_text and tostring(message) or tostring(err)
end

-- denied(err) -> whether this is a permission denial
--
-- The runtime's `system` module marks a permission denial NOT with the kind
-- PermissionDenied but with Invalid and the text "permission denied:
-- system.read on …" (runtime/lua/modules/system: module.go, cluster.go,
-- hosts.go, raft.go); PermissionDenied there is set only by lock.go. So both
-- the kind and the start of the text are read — until the runtime is fixed.
-- The kind alone is not enough: Invalid also means "empty host identifier".
function facts.denied(err: any): boolean
    local kind, message = kind_and_text(err)
    if kind == "PermissionDenied" then return true end
    return kind == "Invalid" and message:sub(1, 17) == "permission denied"
end

-- reason(what, err) -> the reason in words
function facts.reason(what: string, err: any): string
    local _, message = kind_and_text(err)
    if facts.denied(err) then
        if message:sub(1, 17) == "permission denied" then return what .. ": " .. message end
        return what .. ": permission denied (" .. message .. ")"
    end
    return what .. ": unavailable (" .. message .. ")"
end

-- read(names, from?) -> snapshot: snap[field] = value, snap.problems[field] = reason
--
-- `from` is a stand-in `system` with the same sections, for tests. nil
-- without an error is a value, not a refusal: "no leader elected yet" is a
-- legitimate state.
function facts.read(names: any, from: any?): any
    local source: any = from or system
    local snap: any = {problems = {}}
    for _, name in ipairs(type(names) == "table" and names or {}) do
        local spec: any = FIELDS[name]
        if not spec then
            snap.problems[name] = tostring(name) .. ": unknown fact"
        else
            local section: any = spec[1] == "" and source or (type(source) == "table" and source[spec[1]] or nil)
            local call: any = type(section) == "table" and section[spec[2]] or nil
            if type(call) ~= "function" then
                snap.problems[name] = spec[3] .. ": not in this runtime"
            else
                local value, err = call()
                if err ~= nil then snap.problems[name] = facts.reason(tostring(spec[3]), err)
                else snap[name] = value end
            end
        end
    end
    return snap
end

-- processes(hosts, from?) -> all processes, reason | nil
--
-- Per host separately: an empty host identifier answers with an empty list,
-- not with "all". A host whose processes could not be read is named in the
-- reason.
function facts.processes(hosts: any, from: any?): (any, any)
    local source: any = from or system
    local all: any = {}
    local failures = {}
    local section: any = type(source) == "table" and source.hosts or nil
    local call: any = type(section) == "table" and section.processes or nil
    for _, host in ipairs(type(hosts) == "table" and hosts or {}) do
        local record: any = host
        local what = "processes of " .. tostring(record.id)
        if type(call) ~= "function" then
            failures[#failures + 1] = what .. ": not in this runtime"
        else
            local list, err = call(tostring(record.id or ""))
            if err ~= nil then failures[#failures + 1] = facts.reason(what, err)
            elseif type(list) == "table" then
                for _, proc in ipairs(list) do all[#all + 1] = proc end
            end
        end
    end
    return all, #failures > 0 and table.concat(failures, "; ") or nil
end

return facts
