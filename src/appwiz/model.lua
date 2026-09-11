-- "Add/Remove Programs": the pure model.
--
-- A program here is a wippy module. It is installed by being declared with an
-- `ns.dependency` entry in the application sources and lying in the vendor
-- cache; it cannot be removed or installed in the running runtime: that is
-- done by `wippy update` from the declarations, and it takes effect after a
-- restart. That is why the window edits the DECLARATION, not the registry:
-- what it wrote, `wippy update` will read exactly the same way as what was
-- written by hand.
--
-- Everything that can be checked without the runtime lives here: merging
-- declarations with the cache, editing the `_index.yaml` text, the name for
-- a new entry. The window only reads, draws and writes.

local model = {}

local geometry = require("geometry")
local whole = geometry.whole

-- Size, the way Windows writes it: "3.19 MB", "412 KB".
function model.human_size(bytes: any): string
    local n = tonumber(bytes) or 0
    if n <= 0 then return "—" end
    if n < 1024 then return string.format("%d bytes", n) end
    if n < 1024 * 1024 then return string.format("%d KB", n // 1024) end
    return string.format("%.2f MB", n / (1024 * 1024))
end

-- A module is named `org/name`, in lowercase; `wippy update` will not
-- resolve anything else, and it resolves later and stays silent about the
-- reason.
function model.valid_component(text: any): boolean
    if type(text) ~= "string" then return false end
    return text:match("^[a-z0-9][a-z0-9_%-%.]*/[a-z0-9][a-z0-9_%-%.]*$") ~= nil
end

-- The name of the `ns.dependency` entry for module `org/name` is `name`. A
-- taken name REPLACES the previous entry without a real warning (the runtime
-- writes `will use last definition` and takes the last one), and other
-- modules' `ns.requirement` break; that is why a taken name gives way to the
-- form `org-name`.
function model.dep_name(component: any, taken: any): string
    local text = tostring(component or "")
    local org, name = text:match("^([^/]+)/(.+)$")
    if not name then name, org = text, "" end
    local used: any = type(taken) == "table" and taken or {}
    if used[name] then return org .. "-" .. name end
    return name
end

-- Merging registry declarations with the vendor cache into window rows.
--
--   declared  {{id = "app.deps:bridge", component = "org/m", version = ">=…"}, …}
--   cached    {{module = "org/m", version = "1.2.3", size = N, pinned = bool}, …}
--   app_ns    namespace of the application's declarations ("app.deps")
--
-- A row: component, name (the entry name, if the application declared it),
-- owner: "app" (declared by the application), "module" (declared by another
-- module, its dependency), "cache" (only in the cache), declared_by (the
-- namespace), constraint, version, size, pinned. The version is the one
-- pinned by the lock; a working copy (a replacement in .wippy.yaml) has no
-- cache, version = nil.
function model.merge(declared: any, cached: any, app_ns: any): any
    local by_component: any = {}
    local order = {}
    local function row(component: any)
        local key = tostring(component)
        if not by_component[key] then
            by_component[key] = {component = key, size = 0}
            order[#order + 1] = key
        end
        return by_component[key]
    end
    local prefix = tostring(app_ns or "") .. ":"
    for _, entry in ipairs(type(declared) == "table" and declared or {}) do
        local record: any = entry
        if type(record.component) == "string" and record.component ~= "" then
            local line: any = row(record.component)
            local id = tostring(record.id or "")
            local ns = id:match("^(.-):") or ""
            local mine = prefix ~= ":" and id:sub(1, #prefix) == prefix
            -- The application's declaration outranks another's: that is the
            -- one the window edits.
            if mine or line.owner == nil or line.owner == "cache" then
                line.owner = mine and "app" or "module"
                line.declared_by = ns
                line.name = mine and id:sub(#prefix + 1) or line.name
                line.constraint = tostring(record.version or "")
                line.entry = id
            end
        end
    end
    for _, item in ipairs(type(cached) == "table" and cached or {}) do
        local record: any = item
        if type(record.module) == "string" and record.module ~= "" then
            local line: any = row(record.module)
            line.owner = line.owner or "cache"
            -- The version pinned by the lock is the one that runs; the others
            -- merely lie in the cache. Without a pinned one, the last named is
            -- taken.
            if record.pinned or line.version == nil or not line.pinned then
                line.version = tostring(record.version or "")
                line.size = tonumber(record.size) or 0
                line.pinned = record.pinned and true or false
            end
        end
    end
    table.sort(order)
    local out = {}
    for _, key in ipairs(order) do out[#out + 1] = by_component[key] end
    return out
end

-- Who installed it, as one line for a person.
function model.owner_text(line: any): string
    if line.owner == "app" then return "declared by the application (" .. tostring(line.entry) .. ")" end
    if line.owner == "module" then return "required by module " .. tostring(line.declared_by) end
    return "cache only — declared by no one"
end

-- ─── Editing the declarations `_index.yaml` ──────────────────────────────
--
-- The file is edited AS TEXT, not by parsing and rebuilding the YAML: the
-- person has comments there, and a rebuilt file would lose them. A list item
-- starts with a `- ` line at the indent the items in this file have
-- (`item_indent`).

local function lines_of(text: any): any
    local out = {}
    local source = tostring(text or "") .. "\n"
    for line in source:gmatch("(.-)\n") do out[#out + 1] = line end
    -- gmatch with an appended newline gives an extra empty line at the end
    -- exactly when the text already ended with a newline.
    if #out > 0 and out[#out] == "" and tostring(text or ""):sub(-1) == "\n" then out[#out] = nil end
    return out
end

function model.namespace_of(text: any): any
    return tostring(text or ""):match("\n%s*namespace:%s*([%w_%.%-]+)")
        or tostring(text or ""):match("^%s*namespace:%s*([%w_%.%-]+)")
end

local function is_toplevel(line: any): boolean
    local text = tostring(line)
    return text:match("^%S") ~= nil and text:match("^#") == nil
end

-- The indent of items under `entries:` is the one in the file. Two spaces
-- only if there are no items yet: YAML will read an item with a foreign
-- indent as nested in the previous one or not read it at all, and it is
-- `wippy update` that will say so, not the window.
local function item_indent(lines: any): string
    local inside = false
    for _, line in ipairs(lines) do
        local text = tostring(line)
        if text:match("^entries:%s*$") then
            inside = true
        elseif inside then
            local indent = text:match("^( *)%- ")
            if indent then return indent end
            if is_toplevel(text) then break end
        end
    end
    return "  "
end

local function is_item_start(line: any, indent: string): boolean
    return tostring(line):sub(1, #indent + 2) == indent .. "- "
end

-- List items are line ranges from a line with "- " to the next item or
-- top-level key. There is one parse: search, counting and the edit check see
-- one and the same list.
local function items_of(lines: any): any
    local indent = item_indent(lines)
    local out = {}
    local start: any = nil
    for index, line in ipairs(lines) do
        local opens = is_item_start(line, indent)
        if opens or is_toplevel(line) then
            if start ~= nil then out[#out + 1] = {from = start, to = index - 1} end
            start = opens and index or nil
        end
    end
    if start ~= nil then out[#out + 1] = {from = start, to = #lines} end
    return out
end

-- A newline on both sides: `name:` can be the first line of an item.
local function body_of(lines: any, item: any): string
    return "\n" .. table.concat(lines, "\n", item.from, item.to) .. "\n"
end

local function is_dependency(body: string): boolean
    return body:match("kind:%s*ns%.dependency") ~= nil
end

-- Find the item with `name: <name>` and `kind: ns.dependency`.
-- Returns the first and last line of the item (without the comments above
-- it).
local function find_item(lines: any, name: any): (any, any)
    local escaped = (tostring(name):gsub("%p", "%%%0"))
    for _, item in ipairs(items_of(lines)) do
        local body = body_of(lines, item)
        -- `name:` can be the first line of the item; then "- " precedes it.
        if body:match("\n%s*%-?%s*name:%s*" .. escaped .. "%s*\n") ~= nil and is_dependency(body) then
            return item.from, item.to
        end
    end
    return nil, nil
end

-- How many declarations the file has, in ITEMS, not `- name:` lines: an
-- item with parameters has several `- name:` lines, and removing one such
-- item would look like removing three by the line count.
local function count_dependencies(lines: any): integer
    local count = 0
    for _, item in ipairs(items_of(lines)) do
        if is_dependency(body_of(lines, item)) then count = count + 1 end
    end
    return count
end

-- remove_declaration(text, name) -> new text | nil, reason
--
-- What is removed is the item itself, the comments right above it and one
-- empty line above them: what the person wrote about this entry. Empty
-- lines at the end of the item stay: they belong to the next one.
function model.remove_declaration(text: any, name: any): (any, any)
    local lines = lines_of(text)
    local first, last = find_item(lines, name)
    if not first then
        return nil, "declaration " .. tostring(name) .. " not found in the file"
    end
    local from: integer = math.tointeger(first) or 1
    while from > 1 and tostring(lines[from - 1]):match("^%s*#") do from = from - 1 end
    if from > 1 and tostring(lines[from - 1]):match("^%s*$") then from = from - 1 end
    -- The item's tail up to the next one (empty lines and comments) is not
    -- its own: a comment above the next item belongs to the next item.
    local to: integer = math.tointeger(last) or from
    while to > first and (tostring(lines[to]):match("^%s*$") or tostring(lines[to]):match("^%s*#")) do
        to = to - 1
    end
    local out = {}
    for index = 1, from - 1 do out[#out + 1] = lines[index] end
    for index = to + 1, #lines do out[#out + 1] = lines[index] end
    return table.concat(out, "\n") .. "\n", nil
end

-- The failure without a namespace. One wording for two places, appending
-- and the edit check: two different ones would read as two different
-- failures.
function model.no_namespace(file: any): string
    return "namespace not declared in " .. tostring(file or "the declarations file")
end

-- append_declaration(text, component, name, namespace, stamp, file) -> new text | nil, reason
--
-- The entry is as a person would write it: a comment with the identifier,
-- where from and when, version "any". Parameters are not written: the window
-- does not know what the module requires, and `wippy update` and the boot
-- will say so themselves and by name.
--
-- There is no default namespace ON PURPOSE. It used to be `app.deps`, and a
-- file without a `namespace:` line got an entry about which the status said
-- "declaration nil:npc written".
function model.append_declaration(text: any, component: any, name: any, namespace: any, stamp: any, file: any): (any, any)
    if type(namespace) ~= "string" or namespace == "" then return nil, model.no_namespace(file) end
    local body = tostring(text or "")
    if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
    local indent = item_indent(lines_of(body))
    local field = indent .. "  "
    return body .. table.concat({
        "",
        indent .. "# " .. namespace .. ":" .. tostring(name),
        indent .. "# Installed from Add/Remove Programs " .. tostring(stamp or "") .. ".",
        indent .. "- version: '>=v0.0.0'",
        field .. "name: " .. tostring(name),
        field .. "kind: ns.dependency",
        field .. "meta: {}",
        field .. "component: " .. tostring(component),
        "",
    }, "\n"), nil
end

-- check_edit(before, after, name, delta, file) -> true | nil, reason
--
-- The edit is checked BEFORE writing, with the same parse the file is read
-- with: the namespace is in place and has not changed, there are exactly
-- `delta` more declarations (+1 appended, -1 removed), and the named item is
-- found or not found as promised. Without this, the file without which the
-- stand does not come up would learn about a botched edit only on the next
-- boot.
function model.check_edit(before: any, after: any, name: any, delta: integer, file: any): (any, any)
    local where = tostring(file or "the declarations file")
    local ns = model.namespace_of(after)
    if not ns then return nil, model.no_namespace(file) end
    if ns ~= model.namespace_of(before) then
        return nil, "the edit would change the namespace of " .. where .. "; nothing written"
    end
    local now = lines_of(after)
    local grown = count_dependencies(now) - count_dependencies(lines_of(before))
    if grown ~= delta then
        return nil, string.format("the edit would change %d declarations in %s instead of %d; nothing written",
            grown, where, delta)
    end
    local present = find_item(now, name) ~= nil
    if present ~= (delta > 0) then
        return nil, "declaration " .. tostring(name) .. (present and " is still" or " is not")
            .. " found in the edited " .. where .. "; nothing written"
    end
    return true, nil
end

-- write_file(handle, file, before, after) -> true | false, reason
--
-- The runtime's `fs` has no rename (the handle has readfile, writefile,
-- remove, stat, exists…), so the file cannot be swapped for a ready temporary
-- one in one step. Instead there are three steps, and every failure names
-- where the previous text is:
--   1. the file on disk is compared with the one the edit was made from,
--      otherwise the edit would overwrite someone else's, made by hand while
--      the window was open;
--   2. the previous text goes into `<file>.bak` next to it (the runtime
--      loader reads `_index.yaml` by name, the copy is invisible to it);
--   3. write and read back: if they do not match, it says so.
function model.write_file(handle: any, file: string, before: string, after: string): (boolean, any)
    local backup = file .. ".bak"
    local current, rerr = handle:readfile(file)
    if type(current) ~= "string" then
        return false, file .. " not re-read before writing: " .. tostring(rerr)
    end
    if current ~= before then
        return false, file .. " changed on disk since it was read; nothing written, refresh and try again"
    end
    local _, berr = handle:writefile(backup, before)
    if berr then
        return false, "backup " .. backup .. " not written, " .. file .. " left as is: " .. tostring(berr)
    end
    local _, werr = handle:writefile(file, after)
    if werr then
        return false, file .. " not written: " .. tostring(werr) .. "; the previous text is in " .. backup
    end
    local back, verr = handle:readfile(file)
    if back ~= after then
        return false, file .. " reads back different from what was written ("
            .. tostring(verr or "content differs") .. "); the previous text is in " .. backup
    end
    return true, nil
end

return model
