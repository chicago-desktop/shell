-- «Свойства: Система», чистая модель: дерево устройств стенда из снимка
-- рантайма и записей реестра, видимые строки дерева, подписи.
--
-- «Устройства» здесь — то, из чего рантайм состоит и что видно снаружи
-- без прав на запись: хосты процессов, файловые системы, базы, HTTP,
-- терминалы и модули Lua. Записи реестра раскладываются по ПРЕФИКСУ вида:
-- список видов у рантайма открытый, и перечислять их по одному значило бы
-- терять новые молча.
local geometry = require("geometry")
local whole = geometry.whole

local model = {}

model.TABS = {{text = "General"}, {text = "Device Manager"}, {text = "Performance"}}

-- Группы дерева в порядке показа: подпись, префикс вида записи реестра.
model.GROUPS = {
    {key = "hosts", label = "Process hosts"},
    {key = "fs", label = "File systems", prefix = "fs."},
    {key = "db", label = "Databases", prefix = "db."},
    {key = "http", label = "HTTP", prefix = "http."},
    {key = "terminal", label = "Terminals", prefix = "terminal."},
    {key = "modules", label = "Lua modules"},
}

local function node(key: any, label: any, kind: any): any
    return {key = tostring(key), label = tostring(label), kind = tostring(kind or "folder"), children = {}}
end

-- tree(snapshot, records) -> корень дерева
--
-- `snapshot` — то, что сняло окно с `system`; `records` — записи реестра
-- (`{id, kind}`). Пустая группа остаётся в дереве с пометкой «нет»: пропасть
-- она не может, иначе «баз нет» было бы неотличимо от «не прочитано».
function model.tree(snapshot: any, records: any): any
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local root = node("root", tostring(snap.hostname or "Computer"), "computer")
    for _, group in ipairs(model.GROUPS) do
        local branch = node(group.key, group.label, "folder")
        if group.key == "hosts" then
            for _, host in ipairs(type(snap.hosts) == "table" and snap.hosts or {}) do
                local record: any = host
                local leaf = node("host:" .. tostring(record.id), tostring(record.id), "device")
                leaf.detail = string.format("workers %d · processes %d · executed %d",
                    whole(record.workers), whole(record.processes), whole(record.executed))
                branch.children[#branch.children + 1] = leaf
            end
        elseif group.key == "modules" then
            for _, entry in ipairs(type(snap.modules) == "table" and snap.modules or {}) do
                local mod: any = entry
                local leaf = node("module:" .. tostring(mod.name), tostring(mod.name), "device")
                leaf.detail = tostring(mod.description or "")
                branch.children[#branch.children + 1] = leaf
            end
        else
            for _, entry in ipairs(type(records) == "table" and records or {}) do
                local record: any = entry
                local kind = tostring(record.kind or "")
                if group.prefix and kind:sub(1, #group.prefix) == group.prefix then
                    local leaf = node("entry:" .. tostring(record.id), tostring(record.id), "device")
                    leaf.detail = kind
                    branch.children[#branch.children + 1] = leaf
                end
            end
        end
        table.sort(branch.children, function(left, right) return left.label < right.label end)
        branch.count = #branch.children
        root.children[#root.children + 1] = branch
    end
    return root
end

-- flatten(root, expanded) -> видимые строки для компонента `tree`
function model.flatten(root: any, expanded: any): any
    local rows = {}
    local open: any = type(expanded) == "table" and expanded or {}
    local function walk(current: any, depth: any, trail: any)
        local is_open = open[current.key] == true
        local label = current.label
        if current.count ~= nil then
            label = label .. (current.count > 0 and string.format(" (%d)", current.count) or " (none)")
        end
        rows[#rows + 1] = {
            id = current.key, label = label, kind = current.kind == "folder" and "folder" or "device",
            image = current.kind == "computer" and "my_computer" or (current.kind == "device" and "system" or nil),
            depth = depth, has_children = #current.children > 0, expanded = is_open,
            trail = trail, detail = current.detail,
        }
        if is_open then
            for index, child in ipairs(current.children) do
                local next_trail = {}
                for i, v in ipairs(trail) do next_trail[i] = v end
                next_trail[#next_trail + 1] = index < #current.children
                walk(child, depth + 1, next_trail)
            end
        end
    end
    walk(root, 0, {})
    return rows
end

-- Раскрыть корень и все группы: так окно открывается с деревом, а не с
-- одной строкой, которую ещё надо догадаться раскрыть.
function model.expanded_all(root: any): any
    local out: any = {}
    out[root.key] = true
    for _, child in ipairs(root.children) do out[child.key] = true end
    return out
end

-- Строка дерева по идентификатору — для подписи под деревом.
function model.row(rows: any, id: any): any
    for _, row in ipairs(rows) do
        local line: any = row
        if line.id == id then return line end
    end
    return nil
end

function model.megabytes(bytes: any): string
    local value = (tonumber(bytes) or 0) / (1024 * 1024)
    if value >= 10 then return string.format("%.0f MB", value) end
    return string.format("%.1f MB", value)
end

return model
