-- «Свойства: Система» — окно свойств «Моего компьютера», как System
-- Properties в Windows 95: что за система, кому принадлежит, из чего
-- состоит компьютер. Три вкладки: «Общие», «Устройства», «Быстродействие».
--
-- Цифры снимаются с `system` под правами окна, записи — из реестра. Версии
-- рантайма наружу в Lua нет, поэтому «Система» называет узел и число
-- модулей, а не номер сборки: выдуманный номер был бы хуже отсутствующего.
--
-- Окно ничего не меняет: у него нет ни `registry.apply`, ни порождения
-- процессов; «ОК» и «Отмена» закрывают его одинаково.
local system = require("system")
local registry = require("registry")
local app = require("app")
local model = require("model")
local charts = require("charts")
local geometry = require("geometry")
local whole = geometry.whole

local definition: any = {interval = "2s"}

local function snapshot(): any
    local out: any = {}
    local mem: any = system.memory.stats()
    out.memory = type(mem) == "table" and mem or {}
    out.goroutines = whole(system.runtime.goroutines())
    out.cpu_count = whole(system.runtime.cpu_count())
    out.max_procs = whole(system.runtime.max_procs())
    out.pid = tostring(system.process.pid())
    out.hostname = tostring(system.process.hostname())
    local ok_cwd, cwd = pcall(function() return system.process.cwd() end)
    out.cwd = ok_cwd and tostring(cwd) or nil
    local ok_node, node_id = pcall(function() return system.node.id() end)
    out.node_id = ok_node and tostring(node_id) or nil
    local ok_role, role = pcall(function() return system.node.role() end)
    out.node_role = ok_role and tostring(role) or nil
    local hosts, herr = system.hosts.list()
    out.hosts = type(hosts) == "table" and hosts or {}
    if herr then out.failure = "хосты не прочитаны: " .. tostring(herr) end
    local ok_modules, modules = pcall(function() return system.modules() end)
    out.modules = (ok_modules and type(modules) == "table") and modules or {}
    return out
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
    local node_line = snap.node_id and ("узел " .. tostring(snap.node_id)) or "узел не назван"
    if snap.node_role then node_line = node_line .. " · " .. tostring(snap.node_role) end
    return {kind = "row", gap = 1, children = {
        {kind = "column", size = 12, children = {
            line(""),
            {kind = "image", size = 3, image = "my_computer", size_px = 32},
            {kind = "label", text = ""},
        }},
        {kind = "column", children = {
            line("Система:"),
            line("    Wippy Runtime"),
            line("    " .. node_line),
            line(string.format("    модулей Lua: %d", #(snap.modules or {}))),
            line(""),
            line("Приложение:"),
            line("    " .. tostring(snap.hostname or "")),
            line("    PID " .. tostring(snap.pid or "") .. (snap.cwd and (" · " .. tostring(snap.cwd)) or "")),
            line(""),
            line("Компьютер:"),
            line(string.format("    %d процессоров, %d потоков", whole(snap.cpu_count), whole(snap.max_procs))),
            line("    " .. model.megabytes(mem.sys) .. " памяти у рантайма"),
            {kind = "label", text = ""},
        }},
    }}
end

local function devices(state: any): any
    local rows = model.flatten(state.tree, state.expanded)
    local chosen: any = model.row(rows, state.selected)
    local detail = chosen and chosen.detail or (state.records_error and ("реестр не прочитан: " .. tostring(state.records_error)) or "")
    return {kind = "column", gap = 0, children = {
        {kind = "tree", id = "devices", rows = rows, selected = state.selected},
        {kind = "label", size = 1, text = detail, alert = state.records_error ~= nil and chosen == nil},
    }}
end

local function pairs_table(rows: any): any
    local out = {}
    for _, pair in ipairs(rows) do out[#out + 1] = {cells = {tostring(pair[1]), tostring(pair[2])}} end
    return {kind = "table", id = "resources", header = false,
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
            {kind = "group", title = "Память", children = {
                {kind = "gauge", value = heap, ceiling = heap_top, caption = model.megabytes(heap)}}},
            {kind = "group", title = "Горутины", children = {
                {kind = "gauge", value = goroutines, ceiling = charts.round_ceiling(goroutines), caption = tostring(goroutines)}}},
        }},
        {kind = "group", title = "Ресурсы рантайма", children = {pairs_table({
            {"Занято", model.megabytes(mem.alloc)}, {"Куча в работе", model.megabytes(heap)},
            {"Куча у системы", model.megabytes(mem.heap_sys)}, {"Отдано системе", model.megabytes(mem.heap_released)},
            {"Сборок мусора", tostring(whole(mem.num_gc))}, {"Горутин", tostring(goroutines)},
            {"Хостов процессов", tostring(#(snap.hosts or {}))},
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
    return {kind = "column", padding = 1, gap = 0, children = {
        {kind = "tabs", id = "pages", labels = labels, active = state.tab, padding = 1, children = {page}},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "ok", size = 10, text = "ОК", default = true},
            {kind = "button", id = "cancel", size = 10, text = "Отмена"},
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
    elseif action.type == "key" and (action.key_type == "esc" or action.key_type == "enter") then context.close()
    else return false end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition, snapshot = snapshot}
