-- Диспетчер задач — окно на SDK оболочки, показывающее сам рантайм.
--
-- Четыре вкладки: открытые окна (их знает композитор), процессы рантайма
-- (`system.hosts.processes`), быстродействие (память и горутины во времени)
-- и узел (кластер, лидер, хосты). Цифры снимаются раз в секунду тиком SDK;
-- история держится на потолок.
--
-- Загрузки процессора в процентах здесь нет и не будет нарочно: рантайм её
-- не считает, а читать `/proc` окну нельзя. Честная «нагрузка» рантайма —
-- горутины и куча, и она меняется на глазах, когда работает контент-машина.
--
-- Всё, что видно, — компоненты SDK: `tabs`, `table`, `group`, `gauge`,
-- `graph`, `statusbar`, `button`. Своих раскладки и отрисовщиков у окна
-- больше нет — а значит, нет и второй геометрии, по которой щелчок попадал бы
-- на соседнюю строку в одном из режимов.
local os_clock = require("os")
local system = require("system")

local app = require("app")
local desktop = require("desktop")
local model = require("model")
local charts = require("charts")

local HISTORY_CAP = 240

local geometry = require("geometry")
local whole = geometry.whole

-- ─── Снятие цифр ─────────────────────────────────────────────────────────

local function snapshot(): any
    local out: any = {taken = tonumber(os_clock.time()) or 0}
    local mem: any = system.memory.stats()
    if type(mem) == "table" then out.memory = mem else out.memory = {} end
    out.goroutines = whole(system.runtime.goroutines())
    out.cpu_count = whole(system.runtime.cpu_count())
    out.max_procs = whole(system.runtime.max_procs())
    out.pid = tostring(system.process.pid())
    out.hostname = tostring(system.process.hostname())
    -- Процессы спрашиваются по каждому хосту: пустой идентификатор хоста
    -- отвечает пустым списком, а не «всеми».
    local hosts, herr = system.hosts.list()
    if type(hosts) == "table" then out.hosts = hosts else out.hosts, out.hosts_error = {}, tostring(herr) end
    local all: any = {}
    local failures = {}
    for _, host in ipairs(out.hosts) do
        local record: any = host
        local procs, perr = system.hosts.processes(tostring(record.id or ""))
        if type(procs) == "table" then
            for _, proc in ipairs(procs) do all[#all + 1] = proc end
        else
            failures[#failures + 1] = tostring(record.id) .. ": " .. tostring(perr)
        end
    end
    out.processes = model.processes(all)
    if #failures > 0 then out.processes_error = "не прочитано: " .. table.concat(failures, "; ") end
    local ok_node, node_id = pcall(function() return system.node.id() end)
    out.node_id = ok_node and tostring(node_id) or nil
    local ok_role, role = pcall(function() return system.node.role() end)
    out.node_role = ok_role and tostring(role) or nil
    local ok_members, members = pcall(function() return system.cluster.members() end)
    out.members = ok_members and type(members) == "table" and members or nil
    local ok_leader, leader = pcall(function() return system.cluster.leader() end)
    out.leader = ok_leader and tostring(leader) or nil
    local ok_raft, raft_role = pcall(function() return system.raft.role() end)
    out.raft_role = ok_raft and tostring(raft_role) or nil
    return out
end

local function sample(state: any)
    local snap = snapshot()
    state.snapshot = snap
    local mem: any = snap.memory or {}
    state.heap_history = model.push(state.heap_history, tonumber(mem.heap_in_use) or 0, HISTORY_CAP)
    state.goroutine_history = model.push(state.goroutine_history, snap.goroutines, HISTORY_CAP)
    if state.tab == 1 then
        local answer, err = desktop.list({timeout = "300ms"})
        if answer then state.windows, state.windows_error = answer.windows or {}, nil
        else state.windows, state.windows_error = {}, tostring(err) end
    end
end

-- ─── Приложение ──────────────────────────────────────────────────────────

local definition: any = {}
definition.interval = "1s"

function definition.init(args: any, context: any): any
    local state: any = {tab = 3, selected_id = nil, snapshot = nil, heap_history = {}, goroutine_history = {},
        windows = {}, windows_error = nil}
    if system and system.memory then sample(state) end
    return state
end

-- Строки текущей вкладки и номер выделенной: выбор держится за
-- идентификатор, а не за номер строки, — новый замер меняет порядок.
local function rows_of(state: any): (any, any)
    local out = {}
    local selected = 0
    if state.tab == 1 then
        for index, window in ipairs(state.windows or {}) do
            local record: any = window
            local status = record.minimized and "Свёрнуто" or (record.ready and "Работает" or "Запускается")
            out[#out + 1] = {id = record.id, cells = {tostring(record.title or ""), status}}
            if record.id == state.selected_id then selected = index end
        end
    elseif state.tab == 2 then
        for index, proc in ipairs((state.snapshot or {}).processes or {}) do
            local record: any = proc
            out[#out + 1] = {id = record.pid, cells = {tostring(record.source or ""), model.short_pid(record.pid),
                tostring(record.state or ""), tostring(record.steps or 0)}}
            if record.pid == state.selected_id then selected = index end
        end
    end
    return out, selected
end

local function pairs_table(rows: any): any
    local out = {}
    for _, pair in ipairs(rows) do out[#out + 1] = {cells = {tostring(pair[1]), tostring(pair[2])}} end
    return {kind = "table", id = "pairs_" .. tostring(#out) .. tostring(rows[1] and rows[1][1] or ""), header = false,
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
            and {{title = "Задача", weight = 3}, {title = "Состояние", width = 14}}
            or {{title = "Запись", weight = 3}, {title = "PID", width = 14}, {title = "Состояние", width = 11}, {title = "Шагов", width = 8, align = "right"}}
        local children: any = {{kind = "table", id = tab == 1 and "apps" or "procs", columns = columns, rows = rows, selected = selected}}
        if failure then children[#children + 1] = {kind = "label", size = 1, text = tostring(failure), alert = true}
        elseif #rows == 0 then children[#children + 1] = {kind = "label", size = 1, text = tab == 1 and "Нет открытых задач" or "Процессов нет"} end
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
            return {kind = "label", text = "Увеличьте окно для просмотра графиков."}
        end
        return {kind = "column", gap = 0, children = {
            {kind = "row", gap = 1, children = {
                {kind = "group", size = 16, title = "Горутины", children = {{kind = "gauge", value = snap.goroutines, ceiling = go_top, caption = tostring(snap.goroutines or 0)}}},
                {kind = "group", title = "История горутин", children = {{kind = "graph", values = state.goroutine_history, ceiling = go_top}}},
            }},
            {kind = "row", gap = 1, children = {
                {kind = "group", size = 16, title = "Память", children = {{kind = "gauge", value = heap, ceiling = heap_top, caption = model.megabytes(heap)}}},
                {kind = "group", title = "История памяти", children = {{kind = "graph", values = heap_mb, ceiling = heap_top / (1024 * 1024), unit = " МБ"}}},
            }},
            {kind = "row", size = 7, gap = 1, children = {
                {kind = "group", title = "Память", children = {pairs_table({
                    {"Занято", model.megabytes(mem.alloc)}, {"Куча в работе", model.megabytes(mem.heap_in_use)},
                    {"Куча у системы", model.megabytes(mem.heap_sys)}, {"Отдано системе", model.megabytes(mem.heap_released)},
                    {"Сборок мусора", tostring(whole(mem.num_gc))}})}},
                {kind = "group", title = "Система", children = {pairs_table({
                    {"Процессов", tostring(#(snap.processes or {}))}, {"Хостов", tostring(#(snap.hosts or {}))},
                    {"Горутин", tostring(snap.goroutines or 0)}, {"Ядер / потоков", tostring(snap.cpu_count or 0) .. " / " .. tostring(snap.max_procs or 0)},
                    {"Работает", uptime}})}},
            }},
        }}
    end
    local hosts = {}
    for _, host in ipairs(snap.hosts or {}) do
        local record: any = host
        hosts[#hosts + 1] = {id = record.id, cells = {tostring(record.id or ""), tostring(whole(record.workers)),
            tostring(whole(record.processes)), tostring(whole(record.executed))}}
    end
    return {kind = "column", gap = 0, children = {
        {kind = "group", size = 9, title = "Узел рантайма", children = {pairs_table({
            {"Узел", snap.node_id or "недоступно"}, {"Роль", snap.node_role or "недоступно"},
            {"Лидер", snap.leader or "—"}, {"Raft", snap.raft_role or "—"},
            {"Участников", snap.members and tostring(#snap.members) or "—"},
            {"Хост", tostring(snap.hostname or "")}, {"PID рантайма", tostring(snap.pid or "")}})}},
        {kind = "group", title = "Хосты процессов", children = {
            {kind = "table", id = "hosts", columns = {{title = "Хост", weight = 3}, {title = "Раб.", width = 6, align = "right"},
                {title = "Проц.", width = 7, align = "right"}, {title = "Вып.", width = 9, align = "right"}}, rows = hosts},
        }},
    }}
end

function definition.view(state: any, context: any): any
    local snap: any = state.snapshot or {}
    local mem: any = snap.memory or {}
    local labels = {}
    for index, tab in ipairs(model.TABS) do labels[index] = tab.text end
    return {kind = "column", gap = 0, children = {
        {kind = "tabs", id = "pages", labels = labels, active = state.tab, padding = 1, children = {page(state, context)}},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "refresh", size = 12, text = "Обновить"},
        }},
        {kind = "statusbar", size = 1, fields = {
            {text = string.format("Процессов: %d", #(snap.processes or {})), width = 16},
            {text = string.format("Горутин: %d", snap.goroutines or 0), width = 14},
            {text = "Память: " .. model.megabytes(mem.alloc)},
        }},
    }}
end

function definition.update(state: any, action: any, context: any)
    if action.type == "tick" or action.id == "refresh" then sample(state)
    elseif action.id == "pages" and action.type == "select" then
        state.tab = whole(action.index)
        state.selected_id = nil
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

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
