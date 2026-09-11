-- The body of desktop requests — parsing and validation in ONE place for
-- POST and PATCH.
--
-- The endpoints accepted things that are then not drawn: the coordinate
-- `"1e999"` (tonumber gives inf, and `repo.cell` turned it into 0 — an icon
-- in the corner, and the pixel theme skipped it), a folder in a folder (a
-- nested folder is drawn nowhere, and two PATCHes produced a cycle A→B→A),
-- broken JSON as an empty successful PATCH, a name with no cap. There is
-- neither HTTP nor a database here — only what is in the body, so every
-- refusal is checked by a test without a server.

local json = require("json")
local repo = require("repo")

local body = {}

body.COORD_MIN = 1
body.COORD_MAX = 10000
body.ENTRY_MAX = 256
body.TITLE_MAX = 512

body.FOLDER_IN_FOLDER = "parent_id: a desktop folder cannot go into a folder — nested folders are not drawn"

-- Length in CHARACTERS, not in bytes: a cap that Cyrillic uses up twice as
-- fast as Latin is two different caps under one number.
local function chars(value: string): integer
    local count = 0
    for _ in value:gmatch("[^\128-\191]") do count = count + 1 end
    return count
end

-- decode(raw) -> table | nil, reason
--
-- A broken body is a refusal, not an empty object: `json.decode(...) or {}`
-- turned a typo into a successful PATCH that did nothing.
function body.decode(raw: any): (any, any)
    local value, err = json.decode(tostring(raw or ""))
    if err ~= nil then return nil, "body is not JSON: " .. tostring(err) end
    -- An array also arrives as a table; an object has no first element.
    if type(value) ~= "table" or value[1] ~= nil then return nil, "body: a JSON object" end
    return value, nil
end

-- A coordinate is a grid cell: a whole number from 1 to 10000. A string
-- holding a number is accepted, as before, but only if the number is finite
-- and whole. Infinity arrives as a number — JSON `1e999`, a call from Lua —
-- and not as a string: `tonumber("1e999")` in go-lua gives nil, not inf.
local function coordinate(value: any): (any, any)
    local number: any = type(value) == "number" and value or (type(value) == "string" and tonumber(value) or nil)
    if number == nil then return nil, "a number" end
    -- Before `math.tointeger`: in go-lua it returns an out-of-range integer
    -- for infinities, not nil (caught by a mutation), so without this line inf
    -- would pass as "whole".
    if number ~= number or number == math.huge or number == -math.huge then return nil, "a finite number" end
    local cell = math.tointeger(number)
    if cell == nil then return nil, "a whole number" end
    if cell < body.COORD_MIN or cell > body.COORD_MAX then
        return nil, string.format("between %d and %d", body.COORD_MIN, body.COORD_MAX)
    end
    return cell, nil
end
body.coordinate = coordinate

local function text(name: string, value: any, limit: integer): (any, any)
    if value == nil then return nil, nil end
    if type(value) ~= "string" then return nil, name .. ": a string" end
    if chars(value) > limit then return nil, string.format("%s: at most %d characters", name, limit) end
    return value, nil
end

-- names_null(raw, key) -> true if the TOP-level object has key `key` equal to null
--
-- A parsed table does not tell a sent null from an absent field — both are
-- nil — and the runtime json has no marker for null (`"null"` → nil). The
-- difference here is one of meaning: `parent_id: null` is "move out onto the
-- desktop", absence is "leave alone". Earlier null was searched for as a
-- substring over the whole body and fired on a nested object. Here — only a
-- top-level key: strings are skipped whole, with escaping, and nesting is
-- counted. It is called for a body that json has already parsed — this is a
-- search in valid JSON, not parsing.
function body.names_null(raw: any, key: string): boolean
    local source = tostring(raw or "")
    local depth, at, size = 0, 1, #source
    while at <= size do
        local char = source:sub(at, at)
        if char == '"' then
            local close = at + 1
            while close <= size do
                local inner = source:sub(close, close)
                if inner == "\\" then close = close + 2
                elseif inner == '"' then break
                else close = close + 1 end
            end
            local token = source:sub(at + 1, close - 1)
            at = close + 1
            if depth == 1 and token == key and source:match("^%s*:%s*null", at) then return true end
        elseif char == "{" or char == "[" then
            depth = depth + 1
            at = at + 1
        elseif char == "}" or char == "]" then
            depth = depth - 1
            at = at + 1
        else
            at = at + 1
        end
    end
    return false
end

-- nest(kind, parent) -> reason | nil
--
-- What may be put into a folder. A folder — no: a nested folder is drawn
-- nowhere, and allowed nesting produced a cycle with two PATCHes. Checked
-- first, before looking up the folder: the answer does not depend on which
-- one was named.
function body.nest(kind: any, parent: any): any
    if kind == repo.KIND_FOLDER then return body.FOLDER_IN_FOLDER end
    if parent == nil then return "parent_id: no such folder" end
    -- A shortcut inside a shortcut has nothing to open it with: the desktop
    -- has a folder window, and a shortcut window does not exist.
    if parent.kind ~= repo.KIND_FOLDER then return "parent_id: only a desktop folder can hold items" end
    return nil
end

-- create(raw) -> {kind, entry, title, x, y, parent_id} | nil, reason
function body.create(raw: any): (any, any)
    local value, err = body.decode(raw)
    if not value then return nil, err end

    local kind = type(value.kind) == "string" and value.kind or ""
    if kind ~= repo.KIND_SHORTCUT and kind ~= repo.KIND_FOLDER then
        return nil, "kind: only " .. repo.KIND_SHORTCUT .. " or " .. repo.KIND_FOLDER
    end

    local entry, eerr = text("entry", value.entry, body.ENTRY_MAX)
    if eerr then return nil, eerr end
    entry = entry or ""
    if kind == repo.KIND_SHORTCUT and entry == "" then
        return nil, "entry: a shortcut must reference a registry entry"
    end
    -- A folder with an entry is a shortcut that was called a folder.
    if kind == repo.KIND_FOLDER and entry ~= "" then
        return nil, "entry: a desktop folder has no registry entry"
    end

    local title, terr = text("title", value.title, body.TITLE_MAX)
    if terr then return nil, terr end

    -- Coordinates are optional: without them the compositor places the icon
    -- once it learns the screen width. But if given, BOTH must be — one
    -- coordinate does not define a place.
    local has_x, has_y = value.x ~= nil, value.y ~= nil
    if has_x ~= has_y then return nil, "x and y: given together or not at all" end
    local x: any, y: any = nil, nil
    if has_x then
        local xerr: any, yerr: any
        x, xerr = coordinate(value.x)
        if xerr then return nil, "x: " .. tostring(xerr) end
        y, yerr = coordinate(value.y)
        if yerr then return nil, "y: " .. tostring(yerr) end
    end

    local parent_id: any = type(value.parent_id) == "string" and value.parent_id ~= "" and value.parent_id or nil
    if value.parent_id ~= nil and parent_id == nil then return nil, "parent_id: a folder id" end
    if parent_id and kind == repo.KIND_FOLDER then return nil, body.FOLDER_IN_FOLDER end

    return {kind = kind, entry = entry ~= "" and entry or nil, title = title or "",
        x = x, y = y, parent_id = parent_id}, nil
end

-- update(raw) -> patch | nil, reason
--
-- The patch holds only the named fields; `parent_id = false` is "move out
-- onto the desktop".
function body.update(raw: any): (any, any)
    local value, err = body.decode(raw)
    if not value then return nil, err end

    if value.entry ~= nil or value.kind ~= nil then
        return nil, "entry and kind do not change: swapping the entry under the same icon launches something other than what is shown"
    end

    local patch: any = {}
    if value.title ~= nil then
        if type(value.title) ~= "string" or value.title == "" then return nil, "title: a non-empty string" end
        local title, terr = text("title", value.title, body.TITLE_MAX)
        if terr then return nil, terr end
        patch.title = title
    end
    for _, axis in ipairs({"x", "y"}) do
        if value[axis] ~= nil then
            local cell, why = coordinate(value[axis])
            if why then return nil, axis .. ": " .. tostring(why) end
            patch[axis] = cell
        end
    end
    if value.parent_id ~= nil then
        if type(value.parent_id) ~= "string" or value.parent_id == "" then
            return nil, "parent_id: a folder id or null"
        end
        patch.parent_id = value.parent_id
    elseif body.names_null(raw, "parent_id") then
        patch.parent_id = false
    end
    return patch, nil
end

return body
