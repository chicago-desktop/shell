-- The registry viewer model, pure: a tree from entries, visible rows, entry
-- fields. Not a single call to the registry: entries arrive as a list, and
-- what is built here is checked by a test without the runtime.
--
-- The tree is `namespace:name`. The namespace `butschster.windows.shell` is
-- laid out by dots into folders, and the entry becomes a leaf inside the
-- last one. Exactly regedit: keys on the left, values on the right, only the
-- contents are real.

local model = {}

model.ROOT_LABEL = "Registry"

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

-- build(records) -> the tree root
--
-- Folders come before entries, and within each, alphabetically. An entry
-- without a colon in its id is put into the root as is: that should not
-- happen, but it has no right to vanish silently.
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

-- flatten(root, expanded) -> the list of visible rows
--
-- A row knows its depth, whether it has children, whether it is expanded and
-- whether it is the last among its siblings; the tree lines are drawn from
-- the last one.
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

-- find(root, key) -> node or nil
function model.find(root: any, key: any): any
    if root.key == key then return root end
    for _, child in ipairs(root.children) do
        local found = model.find(child, key)
        if found then return found end
    end
    return nil
end

-- parent_key(key) -> the parent's key
function model.parent_key(key: any): any
    local id = tostring(key or "")
    if id == "" then return nil end
    local namespace = id:match("^(.-):") 
    if namespace then return namespace end
    local upper = id:match("^(.*)%.[^%.]+$")
    return upper or ""
end

-- path(key, kind) -> the status line, as in regedit: "Registry\a\b\c"
function model.path(key: any): string
    local id = tostring(key or "")
    if id == "" then return model.ROOT_LABEL end
    local namespace, name = id:match("^(.-):(.+)$")
    local parts = {model.ROOT_LABEL}
    for _, piece in ipairs(split(namespace or id)) do parts[#parts + 1] = piece end
    if name then parts[#parts + 1] = name end
    return table.concat(parts, "\\")
end

-- A value on one line. A multi-line source is shown as its first line with
-- an ellipsis: the "Data" field is not an editor.
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
    if kind == "nil" then return "(none)" end
    if kind == "table" then
        local ok, encoded = pcall(function()
            if type(encode) == "function" then return encode(value) end
            return nil
        end)
        if ok and type(encoded) == "string" then return one_line(encoded, 160) end
        local count = 0
        for _ in pairs(value) do count = count + 1 end
        return "{…} " .. count .. " fields"
    end
    return "(" .. kind .. ")"
end

-- values(node, encode) -> rows of the right pane {name, data, icon}
--
-- For an entry: the kind, then meta alphabetically, then data
-- alphabetically. For a folder: "(Default)" with no value, as regedit shows
-- for a key without values.
function model.values(node: any, encode: any): any
    if type(node) ~= "table" or node.kind ~= "entry" then
        local count = type(node) == "table" and #node.children or 0
        return {
            {name = "(Default)", data = "(value not set)", icon = "text"},
            {name = "(items)", data = tostring(count), icon = "number"},
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
