-- Модель просмотрщика реестра — чистая: дерево из записей, видимые строки,
-- поля записи. Ни одного обращения в реестр: записи приходят списком, и
-- то, что здесь построено, проверяется тестом без рантайма.
--
-- Дерево — это `namespace:name`. Пространство `butschster.windows.shell`
-- раскладывается по точкам в папки, запись становится листом внутри
-- последней. Ровно regedit: слева ключи, справа значения, только содержимое
-- настоящее.

local model = {}

model.ROOT_LABEL = "Реестр"

local geometry = require("geometry")
local whole = geometry.whole

local function new_folder(key, label)
    return {key = key, label = label, kind = "folder", children = {}, index = {}}
end

local function split(namespace)
    local parts = {}
    for piece in tostring(namespace):gmatch("[^%.]+") do parts[#parts + 1] = piece end
    return parts
end

-- build(records) -> корень дерева
--
-- Папки идут раньше записей, внутри — по алфавиту. Запись без двоеточия в
-- id кладётся в корень как есть: такого быть не должно, но пропасть молча
-- она не имеет права.
function model.build(records: any): any
    local root = new_folder("", model.ROOT_LABEL)
    for _, record in ipairs(type(records) == "table" and records or {}) do
        local id = tostring((record :: any).id or "")
        local namespace, name = id:match("^(.-):(.+)$")
        if not namespace then namespace, name = "", id end
        local node: any = root
        local path = ""
        for _, piece in ipairs(split(namespace)) do
            path = path == "" and piece or (path .. "." .. piece)
            local child: any = node.index[piece]
            if not child then
                child = new_folder(path, piece)
                node.index[piece] = child
                node.children[#node.children + 1] = child
            end
            node = child
        end
        node.children[#node.children + 1] = {
            key = id, label = tostring(name), kind = "entry", record = record,
            children = {}, index = {},
        }
    end

    local function sort(node: any)
        table.sort(node.children, function(a: any, b: any)
            if a.kind ~= b.kind then return a.kind == "folder" end
            return tostring(a.label) < tostring(b.label)
        end)
        for _, child in ipairs(node.children) do
            if child.kind == "folder" then sort(child) end
        end
    end
    sort(root)
    return root
end

-- flatten(root, expanded) -> список видимых строк
--
-- Строка знает глубину, есть ли у неё дети, раскрыта ли она и последняя ли
-- она среди братьев — по последнему рисуются линии дерева.
function model.flatten(root: any, expanded: any): any
    local rows = {}
    local open: any = type(expanded) == "table" and expanded or {}
    local function walk(node: any, depth: any, trail: any)
        local is_open = open[node.key] == true
        rows[#rows + 1] = {
            key = node.key, label = node.label, kind = node.kind, depth = depth,
            has_children = #node.children > 0, expanded = is_open,
            trail = trail, record = node.record,
        }
        if is_open then
            for index, child in ipairs(node.children) do
                local next_trail = {}
                for i, v in ipairs(trail) do next_trail[i] = v end
                next_trail[#next_trail + 1] = index < #node.children
                walk(child, depth + 1, next_trail)
            end
        end
    end
    walk(root, 0, {})
    return rows
end

-- find(root, key) -> узел или nil
function model.find(root: any, key: any): any
    if root.key == key then return root end
    for _, child in ipairs(root.children) do
        local found = model.find(child, key)
        if found then return found end
    end
    return nil
end

-- parent_key(key) -> ключ родителя
function model.parent_key(key: any): any
    local id = tostring(key or "")
    if id == "" then return nil end
    local namespace = id:match("^(.-):") 
    if namespace then return namespace end
    local upper = id:match("^(.*)%.[^%.]+$")
    return upper or ""
end

-- path(key, kind) -> строка статуса, как в regedit: «Реестр\a\b\c»
function model.path(key: any): string
    local id = tostring(key or "")
    if id == "" then return model.ROOT_LABEL end
    local namespace, name = id:match("^(.-):(.+)$")
    local parts = {model.ROOT_LABEL}
    for _, piece in ipairs(split(namespace or id)) do parts[#parts + 1] = piece end
    if name then parts[#parts + 1] = name end
    return table.concat(parts, "\\")
end

-- Значение в одну строку. Многострочный исходник показывается первой
-- строкой с многоточием: поле «Данные» — не редактор.
local function one_line(text: any, limit: any): string
    local s = tostring(text)
    local first = s:match("^([^\n]*)")
    local cut = first or s
    local max = whole(limit)
    if max > 0 and #cut > max then cut = cut:sub(1, max) .. "…"
    elseif cut ~= s then cut = cut .. "…" end
    return cut
end

function model.stringify(value: any, encode: any): string
    local kind = type(value)
    if kind == "string" then return "\"" .. one_line(value, 160) .. "\"" end
    if kind == "number" or kind == "boolean" then return tostring(value) end
    if kind == "nil" then return "(нет)" end
    if kind == "table" then
        local ok, encoded = pcall(function()
            if type(encode) == "function" then return encode(value) end
            return nil
        end)
        if ok and type(encoded) == "string" then return one_line(encoded, 160) end
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "{…} " .. count .. " полей"
    end
    return "(" .. kind .. ")"
end

-- values(node, encode) -> строки правой панели {name, data, icon}
--
-- У записи: вид, затем meta по алфавиту, затем data по алфавиту. У папки —
-- «(По умолчанию)» без значения, как в regedit у ключа без значений.
function model.values(node: any, encode: any): any
    if type(node) ~= "table" or node.kind ~= "entry" then
        local count = type(node) == "table" and #node.children or 0
        return {
            {name = "(По умолчанию)", data = "(значение не присвоено)", icon = "text"},
            {name = "(объектов)", data = tostring(count), icon = "number"},
        }
    end
    local record: any = node.record or {}
    local out = {{name = "kind", data = tostring(record.kind or "?"), icon = "text"}}
    local function section(prefix, table_value: any)
        if type(table_value) ~= "table" then
            if table_value ~= nil then
                out[#out + 1] = {name = prefix, data = model.stringify(table_value, encode),
                    icon = type(table_value) == "string" and "text" or "number"}
            end
            return
        end
        local keys = {}
        for key in pairs(table_value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        for _, key in ipairs(keys) do
            local value: any = table_value[key]
            if value == nil then value = table_value[tonumber(key)] end
            out[#out + 1] = {name = prefix .. "." .. key, data = model.stringify(value, encode),
                icon = type(value) == "string" and "text" or "number"}
        end
    end
    section("meta", record.meta)
    section("data", record.data)
    return out
end

return model
