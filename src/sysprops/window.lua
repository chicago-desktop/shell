-- "System Properties" is the properties window of "My Computer", like
-- System Properties in Windows 95: what the system is, who it belongs to,
-- what the computer consists of. Three tabs: "General", "Device Manager",
-- "Performance".
--
-- The numbers are taken from `system` under the window's permissions, the
-- entries from the registry. The runtime version is not exposed to Lua, so
-- "System" names the node and the number of modules, not a build number: an
-- invented number would be worse than a missing one.
--
-- The window changes nothing: it has neither `registry.apply` nor process
-- spawning; "OK" and "Cancel" close it the same way.
local facts = require("facts")
local registry = require("registry")
local app = require("app")
local model = require("model")
local charts = require("charts")
local geometry = require("geometry")
local whole = geometry.whole

local definition: any = {interval = "2s"}

-- A value or a reason for every field: `butschster.windows.config:system`.
-- Previously the second value of `system.*` was discarded, and the reason
-- "hosts not read" was written into a field nobody read: the screen showed
-- "(none)".
local function snapshot(from: any?): any
    local snap: any = facts.read({"memory", "goroutines", "cpu_count", "max_procs", "pid", "hostname", "cwd",
        "node_id", "node_role", "hosts", "modules"}, from)
    local function text(value: any): any return value ~= nil and tostring(value) or nil end
    local out: any = {problems = snap.problems}
    out.memory = type(snap.memory) == "table" and snap.memory or {}
    out.goroutines = snap.goroutines ~= nil and whole(snap.goroutines) or nil
    out.cpu_count = snap.cpu_count ~= nil and whole(snap.cpu_count) or nil
    out.max_procs = snap.max_procs ~= nil and whole(snap.max_procs) or nil
    out.pid = text(snap.pid)
    out.hostname = text(snap.hostname)
    out.cwd = text(snap.cwd)
    out.node_id = text(snap.node_id)
    out.node_role = text(snap.node_role)
    out.hosts = type(snap.hosts) == "table" and snap.hosts or {}
    out.modules = type(snap.modules) == "table" and snap.modules or {}
    return out
end
-- For tests: the same snapshot over a substituted `system`.
definition.snapshot = snapshot

-- The field, or the reason why it is missing, or the fallback text.
local function shown(snap: any, field: string, fallback: string): string
    if snap[field] ~= nil then return tostring(snap[field]) end
    local problems: any = type(snap.problems) == "table" and snap.problems or {}
    return problems[field] and tostring(problems[field]) or fallback
end

local function records(): any
    local found, err = registry.find({})
    if err or type(found) ~= "table" then return {}, err and tostring(err) or nil end
    local out = {}
    for _, entry in ipairs(found) do
        local record: any = entry
        out[#out + 1] = {id = tostring(record.id or ""), kind = tostring(record.kind or "")}
    end
    return out, nil
end

function definition.init(args: any, context: any): any
    local snap = snapshot()
    local found, err = records()
    local tree = model.tree(snap, found)
    return {tab = 1, snapshot = snap, records = found, records_error = err,
        tree = tree, expanded = model.expanded_all(tree), selected = nil}
end

local function line(text: any): any
    return {kind = "label", size = 1, text = tostring(text)}
end

local function general(state: any): any
    local snap: any = state.snapshot or {}
    local mem: any = snap.memory or {}
    local problems: any = type(snap.problems) == "table" and snap.problems or {}
    local node_line = snap.node_id and ("node " .. tostring(snap.node_id)) or (problems.node_id or "node not named")
    if snap.node_role then node_line = node_line .. " · " .. tostring(snap.node_role) end
    local modules_line = problems.modules and tostring(problems.modules)
        or string.format("Lua modules: %d", #(snap.modules or {}))
    local cpu_line = (problems.cpu_count or problems.max_procs)
        and tostring(problems.cpu_count or problems.max_procs)
        or string.format("%d processors, %d threads", whole(snap.cpu_count), whole(snap.max_procs))
    return {kind = "row", gap = 1, children = {
        {kind = "column", size = 12, children = {
            line(""),
            {kind = "image", size = 3, image = "my_computer", size_px = 32},
            {kind = "label", text = ""},
        }},
        {kind = "column", children = {
            line("System:"),
            line("    Wippy Runtime"),
            line("    " .. node_line),
            line("    " .. modules_line),
            line(""),
            line("Application:"),
            line("    " .. shown(snap, "hostname", "")),
            line("    PID " .. shown(snap, "pid", "") .. (snap.cwd and (" · " .. tostring(snap.cwd)) or "")),
            line(""),
            line("Computer:"),
            line("    " .. cpu_line),
            line("    " .. model.megabytes(mem.sys) .. " of runtime memory"),
            {kind = "label", text = ""},
        }},
    }}
end

local function devices(state: any): any
    local rows = model.flatten(state.tree, state.expanded)
    local chosen: any = model.row(rows, state.selected)
    local detail = chosen and chosen.detail or (state.records_error and ("registry not read: " .. tostring(state.records_error)) or "")
    return {kind = "column", gap = 0, children = {
        {kind = "tree", id = "devices", rows = rows, selected = state.selected},
        {kind = "label", size = 1, text = detail, alert = state.records_error ~= nil and chosen == nil},
    }}
end

local function pairs_table(rows: any): any
    local out = {}
    for _, pair in ipairs(rows) do out[#out + 1] = {cells = {tostring(pair[1]), tostring(pair[2])}} end
    -- Name — value pairs that nobody selects: a static table takes no focus
    -- and no clicks, so it needs no id.
    return {kind = "table", static = true, header = false,
        columns = {{title = "", weight = 3}, {title = "", weight = 2, align = "right"}}, rows = out}
end

local function performance(state: any): any
    local snap: any = state.snapshot or {}
    local mem: any = snap.memory or {}
    local heap = tonumber(mem.heap_in_use) or 0
    local heap_top = math.max(1, tonumber(mem.heap_sys) or 0)
    local goroutines = whole(snap.goroutines)
    return {kind = "column", gap = 0, children = {
        {kind = "row", size = 6, gap = 1, children = {
            {kind = "group", title = "Memory", children = {
                {kind = "gauge", value = heap, ceiling = heap_top, caption = model.megabytes(heap)}}},
            {kind = "group", title = "Goroutines", children = {
                {kind = "gauge", value = goroutines, ceiling = charts.round_ceiling(goroutines), caption = tostring(goroutines)}}},
        }},
        {kind = "group", title = "Runtime resources", children = {pairs_table({
            {"In use", model.megabytes(mem.alloc)}, {"Heap in use", model.megabytes(heap)},
            {"Heap from system", model.megabytes(mem.heap_sys)}, {"Released to system", model.megabytes(mem.heap_released)},
            {"GC cycles", tostring(whole(mem.num_gc))}, {"Goroutines", tostring(goroutines)},
            {"Process hosts", shown({hosts = nil, problems = snap.problems}, "hosts", tostring(#(snap.hosts or {})))},
        })}},
    }}
end

function definition.view(state: any, context: any): any
    local labels = {}
    for index, tab in ipairs(model.TABS) do labels[index] = tab.text end
    local page: any
    if state.tab == 2 then page = devices(state)
    elseif state.tab == 3 then page = performance(state)
    else page = general(state) end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "tabs", id = "pages", labels = labels, active = state.tab, padding = 1, children = {page}},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "ok", size = 10, text = "OK", default = true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }},
    }}
end

function definition.update(state: any, action: any, context: any)
    if action.type == "tick" then
        if state.tab ~= 3 then return false end
        state.snapshot = snapshot()
    elseif action.id == "pages" and action.type == "select" then state.tab = whole(action.index)
    elseif action.id == "devices" and action.type == "toggle" then
        local row: any = action.value
        if type(row) == "table" and row.id then state.expanded[row.id] = not state.expanded[row.id] end
    elseif action.id == "devices" and (action.type == "select" or action.type == "activate") then
        local row: any = action.value
        if type(row) == "table" then
            state.selected = row.id
            if action.type == "activate" and row.has_children then state.expanded[row.id] = not state.expanded[row.id] end
        end
    elseif action.id == "ok" or action.id == "cancel" then context.close()
    elseif action.type == "key" and action.key_type == "enter" then context.close()
    else return false end
end

-- Esc closes the window: the loop does it for an Esc `update` did not take.
definition.close_on_escape = true

return {main = app.main(definition), definition = definition, snapshot = snapshot}
