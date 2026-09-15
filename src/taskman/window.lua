-- Task Manager: a window on the shell SDK that shows the runtime itself.
--
-- Four tabs: open windows (the compositor knows them), runtime processes
-- (`system.hosts.processes`), performance (memory and goroutines over time)
-- and the node (cluster, leader, hosts). The numbers are taken once a second
-- by the SDK tick; the history is held up to a cap.
--
-- There is no CPU load in percent here, and there will not be, on purpose:
-- the runtime does not compute it, and the window is not allowed to read
-- `/proc`. The honest "load" of the runtime is goroutines and the heap, and
-- it changes before your eyes when the content machine is working.
--
-- Everything visible is SDK components: `tabs`, `table`, `group`, `gauge`,
-- `graph`, `statusbar`, `button`. The window no longer has its own layout
-- and renderers, which means there is no second geometry by which a click
-- would land on the neighbouring row in one of the modes.
local os_clock = require("os")
local system = require("system")

local app = require("app")
local desktop = require("desktop")
local model = require("model")
local charts = require("charts")
local facts = require("facts")
local process = require("process")
local ui = require("ui")

local HISTORY_CAP = 240

local geometry = require("geometry")
local whole = geometry.whole

-- ─── Taking the numbers ──────────────────────────────────────────────────

-- A value or a reason for every field: `butschster.windows.config:system`.
-- Previously the second value of `system.*` was discarded, and a permission
-- denial turned into zero goroutines or "unavailable".
local function snapshot(from: any?): any
    local snap: any = facts.read({"memory", "goroutines", "cpu_count", "max_procs", "pid", "hostname", "hosts",
        "node_id", "node_role", "members", "leader", "raft_role"}, from)
    local function text(value: any): any return value ~= nil and tostring(value) or nil end
    local function count(value: any): any return value ~= nil and whole(value) or nil end
    local out: any = {taken = tonumber(os_clock.time()) or 0, problems = snap.problems}
    out.memory = type(snap.memory) == "table" and snap.memory or {}
    out.goroutines = count(snap.goroutines)
    out.cpu_count = count(snap.cpu_count)
    out.max_procs = count(snap.max_procs)
    out.pid = text(snap.pid)
    out.hostname = text(snap.hostname)
    out.hosts = type(snap.hosts) == "table" and snap.hosts or {}
    local all, perr = facts.processes(out.hosts, from)
    out.processes = model.processes(all)
    out.processes_error = snap.problems.hosts or perr
    out.node_id = text(snap.node_id)
    out.node_role = text(snap.node_role)
    out.members = type(snap.members) == "table" and snap.members or nil
    out.leader = text(snap.leader)
    out.raft_role = text(snap.raft_role)
    return out
end

local function sample(state: any)
    local snap = snapshot()
    state.snapshot = snap
    local mem: any = snap.memory or {}
    state.heap_history = model.push(state.heap_history, tonumber(mem.heap_in_use) or 0, HISTORY_CAP)
    state.goroutine_history = model.push(state.goroutine_history, snap.goroutines or 0, HISTORY_CAP)
    if state.tab == 1 then
        local answer, err = desktop.list({timeout = "300ms"})
        if answer then state.windows, state.windows_error = answer.windows or {}, nil
        else state.windows, state.windows_error = {}, tostring(err) end
    end
end

-- ─── Application ─────────────────────────────────────────────────────────

local definition: any = {}
definition.interval = "1s"
-- For tests: the same snapshot over a substituted `system`.
definition.snapshot = snapshot

-- The window's effects, replaceable in tests: closing a window through the
-- compositor, terminating a runtime process, and the processes that are the
-- shell itself — ending one of those from here would take the Task Manager
-- and every window down with it.
definition.deps = {
    close = function(id: any, opts: any?): (any, any)
        local ok, err = desktop.close(id, opts)
        return ok, err
    end,
    terminate = function(pid: any): (any, any)
        local ok, err = process.terminate(tostring(pid))
        return ok, err
    end,
    protected = function(): any
        local out: any = {}
        out[tostring(process.pid())] = "the Task Manager itself"
        -- Every desktop, not only this one: under a terminal.ssh host each
        -- connection has its own, and ending another person's desktop ends
        -- their session with every window in it.
        local name = desktop.service()
        for _, found in ipairs(desktop.desktops(name)) do
            out[tostring(found.pid)] = "a desktop"
        end
        local shell: any = name and process.registry.lookup(name) or nil
        if shell then out[tostring(shell)] = "the shell" end
        return out
    end,
}

-- The field, or the reason why it is missing, or the fallback text.
local function shown(snap: any, field: string, fallback: string): string
    if snap[field] ~= nil then return tostring(snap[field]) end
    local problems: any = type(snap.problems) == "table" and snap.problems or {}
    return problems[field] and tostring(problems[field]) or fallback
end

function definition.init(args: any, context: any): any
    local state: any = {tab = 3, selected_id = nil, snapshot = nil, heap_history = {}, goroutine_history = {},
        windows = {}, windows_error = nil, notice = nil, confirm = nil, ending = nil}
    if system and system.memory then sample(state) end
    return state
end

-- Rows of the current tab and the index of the selected one: the selection
-- holds on to the identifier, not the row number, since a new sample changes
-- the order.
local function rows_of(state: any): (any, any)
    local out = {}
    local selected = 0
    if state.tab == 1 then
        for index, window in ipairs(state.windows or {}) do
            local record: any = window
            local status = record.minimized and "Minimized" or (record.ready and "Running" or "Starting")
            out[#out + 1] = {id = record.id, cells = {tostring(record.title or ""), status}}
            if record.id == state.selected_id then selected = index end
        end
    elseif state.tab == 2 then
        local taken = tonumber((state.snapshot or {}).taken) or 0
        for index, proc in ipairs((state.snapshot or {}).processes or {}) do
            local record: any = proc
            -- How long it runs, from `started_at`: the runtime keeps no
            -- memory per process (one heap for all), so this and the actor
            -- are what a process row can tell.
            local started = tonumber(record.started)
            local uptime = started and model.uptime(taken - started) or ""
            out[#out + 1] = {id = record.pid, cells = {tostring(record.source or ""), model.short_pid(record.pid),
                tostring(record.actor or ""), tostring(record.state or ""), uptime, tostring(record.steps or 0)}}
            if record.pid == state.selected_id then selected = index end
        end
    end
    return out, selected
end

local function pairs_table(rows: any): any
    local out = {}
    for _, pair in ipairs(rows) do out[#out + 1] = {cells = {tostring(pair[1]), tostring(pair[2])}} end
    -- Name — value pairs that nobody selects: a static table takes no focus
    -- and no clicks, so it needs no id, not even a made-up one.
    return {kind = "table", static = true, header = false,
        columns = {{title = "", weight = 3}, {title = "", weight = 2, align = "right"}}, rows = out}
end

local function page(state: any, context: any): any
    local snap: any = state.snapshot or {}
    local mem: any = snap.memory or {}
    local tab = state.tab
    if tab == 1 or tab == 2 then
        local rows, selected = rows_of(state)
        local failure = tab == 1 and state.windows_error or snap.processes_error
        local columns = tab == 1
            and {{title = "Task", weight = 3}, {title = "Status", width = 14}}
            or {{title = "Entry", weight = 3}, {title = "PID", width = 12}, {title = "Actor", width = 14},
                {title = "Status", width = 9}, {title = "Uptime", width = 8}, {title = "Steps", width = 7, align = "right"}}
        local children: any = {{kind = "table", id = tab == 1 and "apps" or "procs", columns = columns, rows = rows, selected = selected}}
        if failure then children[#children + 1] = {kind = "label", size = 1, text = tostring(failure), alert = true}
        elseif #rows == 0 then children[#children + 1] = {kind = "label", size = 1, text = tab == 1 and "No tasks running" or "No processes"} end
        return {kind = "column", gap = 0, children = children}
    elseif tab == 3 then
        local heap = tonumber(mem.heap_in_use) or 0
        local heap_top = charts.ceiling_of(state.heap_history)
        local go_top = charts.ceiling_of(state.goroutine_history)
        local heap_mb = {}
        for _, value in ipairs(state.heap_history) do heap_mb[#heap_mb + 1] = value / (1024 * 1024) end
        local started = model.oldest_start(snap.processes)
        local uptime = started and model.uptime((tonumber(snap.taken) or 0) - started) or "—"
        if context.width < 40 or context.height < 14 then
            return {kind = "label", text = "Enlarge the window to see the graphs."}
        end
        local charts_page: any = {kind = "column", gap = 0, children = {
            {kind = "row", gap = 1, children = {
                {kind = "group", size = 16, title = "Goroutines", children = {{kind = "gauge", value = snap.goroutines, ceiling = go_top, caption = tostring(snap.goroutines or 0)}}},
                {kind = "group", title = "Goroutine history", children = {{kind = "graph", values = state.goroutine_history, ceiling = go_top}}},
            }},
            {kind = "row", gap = 1, children = {
                {kind = "group", size = 16, title = "Memory", children = {{kind = "gauge", value = heap, ceiling = heap_top, caption = model.megabytes(heap)}}},
                {kind = "group", title = "Memory history", children = {{kind = "graph", values = heap_mb, ceiling = heap_top / (1024 * 1024), unit = " MB"}}},
            }},
            {kind = "row", size = 7, gap = 1, children = {
                {kind = "group", title = "Memory", children = {pairs_table({
                    {"In use", model.megabytes(mem.alloc)}, {"Heap in use", model.megabytes(mem.heap_in_use)},
                    {"Heap from system", model.megabytes(mem.heap_sys)}, {"Released to system", model.megabytes(mem.heap_released)},
                    {"GC cycles", tostring(whole(mem.num_gc))}})}},
                {kind = "group", title = "System", children = {pairs_table({
                    {"Processes", tostring(#(snap.processes or {}))}, {"Hosts", tostring(#(snap.hosts or {}))},
                    {"Goroutines", tostring(snap.goroutines or 0)}, {"Cores / threads", tostring(snap.cpu_count or 0) .. " / " .. tostring(snap.max_procs or 0)},
                    {"Running", uptime}})}},
            }},
        }}
        -- Not read is not zero: the reason as a line above the graphs,
        -- otherwise an empty gauge reads as "there are no goroutines".
        local problems: any = type(snap.problems) == "table" and snap.problems or {}
        local missing = problems.memory or problems.goroutines
        if missing then
            table.insert(charts_page.children, 1, {kind = "label", size = 1, text = tostring(missing), alert = true})
        end
        return charts_page
    end
    local hosts = {}
    for _, host in ipairs(snap.hosts or {}) do
        local record: any = host
        hosts[#hosts + 1] = {id = record.id, cells = {tostring(record.id or ""), tostring(whole(record.workers)),
            tostring(whole(record.processes)), tostring(whole(record.executed))}}
    end
    return {kind = "column", gap = 0, children = {
        {kind = "group", size = 9, title = "Runtime node", children = {pairs_table({
            {"Node", shown(snap, "node_id", "unavailable")}, {"Role", shown(snap, "node_role", "unavailable")},
            {"Leader", shown(snap, "leader", "—")}, {"Raft", shown(snap, "raft_role", "—")},
            {"Members", snap.members and tostring(#snap.members) or shown(snap, "members", "—")},
            {"Host", shown(snap, "hostname", "")}, {"Runtime PID", shown(snap, "pid", "")}})}},
        {kind = "group", title = "Process hosts", children = {
            {kind = "table", id = "hosts", columns = {{title = "Host", weight = 3}, {title = "Wrk", width = 6, align = "right"},
                {title = "Proc", width = 7, align = "right"}, {title = "Done", width = 9, align = "right"}}, rows = hosts},
        }},
    }}
end

function definition.view(state: any, context: any): any
    -- Ending a process is asked first, in Windows NT's words: it gets no
    -- chance to save anything.
    if state.confirm then
        return ui.confirm({title = "Task Manager Warning", yes = "end_yes", no = "end_no", lines = {
            "WARNING: Terminating a process can cause undesired",
            "results including loss of data and system instability.",
            "The process will not be given the chance to save its",
            "state or data before it is terminated.",
            "",
            "Are you sure you want to terminate " .. tostring(state.confirm.source) .. "?",
        }})
    end
    local snap: any = state.snapshot or {}
    local mem: any = snap.memory or {}
    local labels = {}
    for index, tab in ipairs(model.TABS) do labels[index] = tab.text end
    local actions: any = {}
    if state.tab == 1 then
        actions[#actions + 1] = {kind = "button", id = "end_task", size = 12, text = "End Task", disabled = state.selected_id == nil}
    elseif state.tab == 2 then
        actions[#actions + 1] = {kind = "button", id = "end_process", size = 14, text = "End Process", disabled = state.selected_id == nil}
    end
    actions[#actions + 1] = {kind = "button", id = "refresh", size = 12, text = "Refresh"}
    local children: any = {
        {kind = "tabs", id = "pages", labels = labels, active = state.tab, padding = 1, children = {page(state, context)}},
    }
    if state.notice then children[#children + 1] = {kind = "label", size = 1, text = tostring(state.notice)} end
    children[#children + 1] = {kind = "row", size = 2, gap = 1, align = "right", children = actions}
    children[#children + 1] = {kind = "statusbar", size = 1, fields = {
        {text = string.format("Processes: %d", #(snap.processes or {})), width = 16},
        {text = string.format("Goroutines: %d", snap.goroutines or 0), width = 14},
        {text = "Memory: " .. model.megabytes(mem.alloc)},
    }}
    return {kind = "column", gap = 0, children = children}
end

-- End Task, as in Windows 95: the first press asks the window to close (it
-- may ask to save a document first); a window that refused or hangs is ended
-- by the second press on the same task.
local function end_task(state: any)
    local id = state.selected_id
    if id == nil then return end
    local title = tostring(id)
    for _, window in ipairs(state.windows or {}) do
        if window.id == id then title = tostring(window.title or id) end
    end
    local force = state.ending == id
    local ok, err = definition.deps.close(id, force and {force = true} or nil)
    state.ending = (not force) and id or nil
    if not ok then state.notice = "Not ended: " .. tostring(err)
    elseif force then state.notice = "Ended " .. title .. "."
    else state.notice = "Asked " .. title .. " to close; End Task again ends it." end
end

-- End Process: a warning first; the shell and the Task Manager itself are not
-- offered at all.
local function end_process(state: any)
    local pid = state.selected_id
    if pid == nil then return end
    local source = tostring(pid)
    for _, proc in ipairs((state.snapshot or {}).processes or {}) do
        if proc.pid == pid then source = tostring(proc.source) end
    end
    local why = definition.deps.protected()[tostring(pid)]
    if why then
        state.notice = "Not ended: " .. source .. " is " .. tostring(why) .. "."
        return
    end
    state.confirm = {pid = pid, source = source}
end

function definition.update(state: any, action: any, context: any)
    if state.confirm then
        if action.type == "activate" and action.id == "end_yes" then
            local target: any = state.confirm
            state.confirm = nil
            local ok, err = definition.deps.terminate(target.pid)
            if ok then state.notice = "Ended " .. tostring(target.source) .. "."
            else state.notice = "Not ended: " .. tostring(err) end
        elseif (action.type == "activate" and action.id == "end_no") or (action.type == "key" and action.key_type == "esc") then
            state.confirm = nil
        elseif action.type == "tick" then sample(state)
        else return false end
        return
    end
    if action.type == "activate" and action.id == "end_task" then end_task(state)
    elseif action.type == "activate" and action.id == "end_process" then end_process(state)
    elseif action.type == "tick" or action.id == "refresh" then sample(state)
    elseif action.id == "pages" and action.type == "select" then
        state.tab = whole(action.index)
        state.selected_id, state.notice, state.ending = nil, nil, nil
        sample(state)
    elseif (action.id == "apps" or action.id == "procs") and (action.type == "select" or action.type == "activate") then
        local picked: any = action.value
        state.selected_id = type(picked) == "table" and picked.id or nil
    elseif action.type == "key" then
        local key = tostring(action.key_type == "runes" and action.key or action.key_type or "")
        if key == "r" or key == "f5" then sample(state)
        elseif key:match("^[1-4]$") then state.tab = whole(key); state.selected_id = nil; sample(state)
        else return false end
    else return false end
end

return {main = app.main(definition), definition = definition}
