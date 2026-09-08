-- Просмотрщик реестра — окно на SDK оболочки, вид regedit Windows 95.
--
-- Единственное место, где просмотрщик читает реестр, — и читает только:
-- в его политике нет `registry.apply`, и это не забывчивость (FR-004 §3.4):
-- правка записи — это правка работающего приложения, ей место в панели
-- управления под своим актором.
--
-- Реестр читается один раз при открытии; F5 перечитывает. Дерево, панель
-- значений, строка меню и статус — компоненты SDK; собственных раскладки,
-- контроллера и красок больше нет. Дерево строит и сплющивает `model`.
local json = require("json")
local registry = require("registry")

local app = require("app")
local model = require("model")

local function encode(value: any): any
    local ok, text = pcall(function() return json.encode(value) end)
    if ok and type(text) == "string" then return text end
    return nil
end

local function read_all(): (any, any)
    local found, err = registry.find({})
    if err then return nil, tostring(err) end
    if type(found) ~= "table" then return nil, "реестр ответил не списком" end
    return found, nil
end

local window: any = {}

-- Сеанс из готового списка записей — тот же, что строит `init`, но без
-- реестра: так его собирают тесты и снимки.
function window.session(records: any, failure: any): any
    local root = model.build(records or {})
    local expanded: any = {}
    expanded[root.key] = true
    return {root = root, expanded = expanded, selected = root.key,
        rows = model.flatten(root, expanded), count = #(records or {}), failure = failure}
end

local function reflow(state: any)
    state.rows = model.flatten(state.root, state.expanded)
end

local function selected_index(state: any): integer
    for index, row in ipairs(state.rows) do
        if row.key == state.selected then return index end
    end
    return 0
end

local definition: any = {}

function definition.init(args: any, context: any): any
    local records, err = read_all()
    return window.session(records or {}, not records and ("реестр не прочитан: " .. tostring(err)) or nil)
end

function definition.view(state: any, context: any): any
    local rows = {}
    for _, row in ipairs(state.rows) do
        rows[#rows + 1] = {id = row.key, label = row.label, kind = row.kind, depth = row.depth,
            has_children = row.has_children, expanded = row.expanded, trail = row.trail}
    end
    local node = model.find(state.root, state.selected)
    local values = {}
    for _, value in ipairs(model.values(node, encode)) do
        values[#values + 1] = {id = value.name, cells = {tostring(value.name), tostring(value.data)}}
    end
    local right: any = {kind = "column", gap = 0, children = {
        {kind = "table", id = "values", columns = {{title = "Имя", weight = 2}, {title = "Данные", weight = 3}}, rows = values},
    }}
    if state.failure then
        right.children[#right.children + 1] = {kind = "label", size = 1, text = tostring(state.failure), alert = true}
    end
    return {kind = "column", gap = 0, children = {
        {kind = "menu", id = "bar", size = 1, entries = {
            {title = "Реестр", accel = 1, items = {{id = "refresh", text = "Обновить"}, {separator = true}, {id = "exit", text = "Выход"}}},
            {title = "Правка", accel = 1, items = {{id = "copy_path", text = "Копировать путь", disabled = true}}},
            {title = "Вид", accel = 1, items = {{id = "refresh", text = "Обновить"}}},
            {title = "Справка", accel = 1, items = {{id = "about", text = "О программе"}}},
        }},
        {kind = "split", gap = 1, children = {
            {kind = "tree", id = "tree", weight = 2, rows = rows, selected = selected_index(state)},
            right,
        }},
        {kind = "statusbar", size = 1, fields = {{text = model.path(state.selected)}}},
    }}
end

function definition.update(state: any, action: any, context: any)
    if action.id == "tree" and action.type == "select" then
        local picked: any = action.value
        state.selected = picked and picked.id or state.selected
    elseif action.id == "tree" and action.type == "toggle" then
        local picked: any = action.value
        if picked and picked.has_children then
            if state.expanded[picked.id] then state.expanded[picked.id] = nil else state.expanded[picked.id] = true end
            reflow(state)
        end
    elseif action.id == "refresh" or (action.type == "key" and action.key_type == "f5") then
        local records, err = read_all()
        local fresh = window.session(records or {}, not records and ("реестр не прочитан: " .. tostring(err)) or nil)
        fresh.expanded = state.expanded
        fresh.selected = state.selected
        fresh.rows = model.flatten(fresh.root, fresh.expanded)
        for key, value in pairs(fresh) do state[key] = value end
        if not model.find(state.root, state.selected) then state.selected = state.root.key end
    elseif action.id == "exit" or (action.type == "key" and action.key_type == "esc") then
        context.close()
    else return false end
end

window.definition = definition

function window.main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return window
