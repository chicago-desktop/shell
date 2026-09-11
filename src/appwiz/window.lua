-- "Add/Remove Programs": a declarative window on the shell SDK.
--
-- The list of installed modules: `ns.dependency` declarations from the
-- registry are merged with the vendor cache (`hub.cache.list`: version and
-- size). Under the list: where the selected module comes from and what can
-- be done with it. "Remove" removes the declaration, "Install…" appends one
-- by the name `org/name`.
--
-- What the window does NOT do, and this is a boundary, not an omission: it
-- does not touch the registry and does not pull a module from the Hub. Both
-- actions are edits of the declarations file; they take effect after `wippy
-- update` and a restart, and the window says exactly that. There is nothing
-- here to install a module into the running runtime with, and pretending to
-- have installed it is the worst thing this panel could do.
--
-- The application names the declarations file through the environment:
-- BUTSCHSTER_WINDOWS_DEPS_FS is the identifier of an `fs.directory` entry over
-- the directory with the dependencies' `_index.yaml`. If it did not name one,
-- the window only shows and says why.

local fs = require("fs")
local hub = require("hub")
local registry = require("registry")
local time = require("time")

local app = require("app")
local model = require("model")
local environment = require("environment")

local DEPS_ENV = "BUTSCHSTER_WINDOWS_DEPS_FS"
local DEPS_FILE = "_index.yaml"
local NEXT_STEPS = "Next: wippy update, then a restart"

local geometry = require("geometry")
local whole = geometry.whole

-- Reading the environment is shared (`butschster.windows.config:environment`):
-- first the process environment, then the file store, and a permission
-- denial is called a permission denial. Only the words for the window's
-- status line are here.
local function read_env(name): (any, string)
    local value, _, denied = environment.read(name)
    if value ~= nil then return value, "" end
    if denied then return nil, "no env.get permission for " .. name end
    return nil, name .. " is not set — the application did not name the declarations folder"
end

-- ─── Data ────────────────────────────────────────────────────────────────

local function declared_dependencies(): (any, any)
    local entries, err = registry.find({kind = "ns.dependency"})
    if err or type(entries) ~= "table" then return {}, tostring(err or "the registry did not answer") end
    local out = {}
    for _, entry in ipairs(entries) do
        local record: any = entry
        local data: any = type(record.data) == "table" and record.data or record
        out[#out + 1] = {id = tostring(record.id or ""), component = data.component, version = data.version}
    end
    return out, nil
end

local function cached_modules(): (any, any)
    local ok, list, err = pcall(function() return hub.cache.list() end)
    if not ok then return {}, tostring(list) end
    if err or type(list) ~= "table" then return {}, tostring(err or "cache not read") end
    -- The cache lists everything that lies in the vendor directory,
    -- including `org/name-1.2.3.sha256` sidecars with the file name in the
    -- module field. A module is `org/name` without dots and without a
    -- version; the rest are not modules.
    local out = {}
    for _, item in ipairs(list) do
        local record: any = item
        local name = tostring(record.module or "")
        if name:match("^[^/%.]+/[^/%.]+$") and tostring(record.version or "") ~= "" then
            out[#out + 1] = record
        end
    end
    return out, nil
end

local function read_declarations(state: any): (any, any)
    if not state.drive then return nil, state.drive_failure end
    local handle, err = fs.get(tostring(state.drive))
    if err or not handle then return nil, "declarations folder not opened: " .. tostring(err) end
    local text, rerr = handle:readfile(DEPS_FILE)
    if rerr or type(text) ~= "string" then return nil, DEPS_FILE .. " not read: " .. tostring(rerr) end
    return text, nil
end

-- The stand does not come up without this file, so an edit is first
-- checked by parsing (`model.check_edit`), and written with a backup and a
-- read-back (`model.write_file`).
local function write_declarations(state: any, before: any, after: any, name: any, delta: integer): (boolean, any)
    local fine, why = model.check_edit(before, after, name, delta, DEPS_FILE)
    if not fine then return false, why end
    local handle, err = fs.get(tostring(state.drive))
    if err or not handle then return false, "declarations folder not opened: " .. tostring(err) end
    return model.write_file(handle, DEPS_FILE, tostring(before), tostring(after))
end

local function load(state: any)
    local declared, derr = declared_dependencies()
    local cached, cerr = cached_modules()
    local text, terr = read_declarations(state)
    state.namespace = text and model.namespace_of(text) or nil
    state.rows = model.merge(declared, cached, state.namespace)
    state.taken = {}
    for _, line in ipairs(state.rows) do
        if line.owner == "app" and line.name then state.taken[line.name] = true end
    end
    local notes = {}
    if derr then notes[#notes + 1] = "registry: " .. derr end
    if cerr then notes[#notes + 1] = "cache: " .. cerr end
    if terr then notes[#notes + 1] = tostring(terr) end
    state.load_note = #notes > 0 and table.concat(notes, "; ") or nil
    state.readonly = text == nil
    -- The selection holds on to the module, not the row number: after an
    -- edit the list is different, but the person is looking at the same
    -- module.
    state.selected = 0
    for index, line in ipairs(state.rows) do
        if line.component == state.selected_id then state.selected = index end
    end
    if state.selected == 0 and #state.rows > 0 then
        state.selected = 1
        state.selected_id = state.rows[1].component
    end
end

local function current(state: any): any
    return state.rows[whole(state.selected)]
end

-- ─── Actions ─────────────────────────────────────────────────────────────

local function remove_current(state: any): string
    local line: any = current(state)
    if not line then return "nothing selected" end
    if line.owner ~= "app" then
        return "only what the application declared can be removed; this is " .. model.owner_text(line)
    end
    local text, err = read_declarations(state)
    if not text then return tostring(err) end
    local edited, rerr = model.remove_declaration(text, line.name)
    if not edited then return tostring(rerr) end
    local ok, werr = write_declarations(state, text, tostring(edited), line.name, -1)
    if not ok then return tostring(werr) end
    state.pending[line.component] = "removed from the declarations"
    return "declaration " .. tostring(line.entry) .. " removed. " .. NEXT_STEPS
end

local function install(state: any, component: any): string
    if not model.valid_component(component) then
        return "a module is named org/name in lowercase: " .. tostring(component)
    end
    for _, line in ipairs(state.rows) do
        if line.component == component and line.owner == "app" then
            return tostring(component) .. " is already declared by the application (" .. tostring(line.entry) .. ")"
        end
    end
    local text, err = read_declarations(state)
    if not text then return tostring(err) end
    local name = model.dep_name(component, state.taken)
    local stamp = time.now():format("2006-01-02")
    -- The namespace comes from the text being edited, not from the one read
    -- when the window opened: the file could have changed in between.
    local namespace = model.namespace_of(text)
    local edited, aerr = model.append_declaration(text, component, name, namespace, stamp, DEPS_FILE)
    if not edited then return tostring(aerr) end
    local ok, werr = write_declarations(state, text, edited, name, 1)
    if not ok then return tostring(werr) end
    state.pending[component] = "declared, not installed yet"
    state.selected_id = component
    return "declaration " .. tostring(namespace) .. ":" .. name .. " written. " .. NEXT_STEPS
end

-- ─── Application ─────────────────────────────────────────────────────────

local definition: any = {}

function definition.init(args: any, context: any): any
    local state: any = {rows = {}, selected = 0, selected_id = nil, mode = "list",
        input = "", pending = {}, status = nil, taken = {}}
    state.drive, state.drive_failure = read_env(DEPS_ENV)
    load(state)
    return state
end

-- A table row: module, version, size (right-aligned), who declared it.
-- The columns are one SDK layout, as in the Windows "Explorer".
local COLUMNS = {
    {title = "Module", weight = 3},
    {title = "Version", width = 10},
    {title = "Size", width = 11, align = "right"},
    {title = "Source", weight = 2},
}

local function owner_short(line: any): string
    if line.owner == "app" then return "application" end
    if line.owner == "module" then return tostring(line.declared_by) end
    return "cache"
end

local function row_of(line: any, pending: any): any
    local mark = line.owner == "app" and "▢ " or "  "
    local title = mark .. tostring(line.component)
    if pending then title = title .. "  (" .. tostring(pending) .. ")" end
    return {id = line.component, cells = {
        title,
        line.version or "working copy",
        line.size > 0 and model.human_size(line.size) or "",
        owner_short(line),
    }}
end

function definition.view(state: any, context: any): any
    local rows = {}
    for _, line in ipairs(state.rows) do
        rows[#rows + 1] = row_of(line, state.pending[line.component])
    end
    local line: any = current(state)
    local detail, hint = "", ""
    if line then
        local version = line.version and ("version " .. line.version) or "working copy — not in the cache"
        detail = tostring(line.component) .. ": " .. version .. " · " .. model.owner_text(line)
        hint = line.owner == "app"
            and "To drop this module from the declarations, click Remove."
            or "Only what the application declared can be removed."
    elseif state.load_note then
        detail = state.load_note
    else
        detail = "no modules"
    end

    local controls: any
    if state.mode == "install" then
        controls = {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = 20, text = "Module (org/name):"},
            {kind = "input", id = "component", text = state.input},
            {kind = "button", id = "write", size = 12, text = "Write", default = true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
        }}
    elseif state.mode == "confirm" then
        controls = {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = "Remove " .. tostring(line and line.component or "") .. " from the declarations?"},
            {kind = "button", id = "yes", size = 8, text = "Yes", default = true},
            {kind = "button", id = "no", size = 8, text = "No"},
        }}
    else
        local can_remove = line ~= nil and line.owner == "app" and not state.readonly
        controls = {kind = "row", size = 2, gap = 1, children = {
            {kind = "button", id = "install", size = 16, text = "Install…", disabled = state.readonly},
            {kind = "button", id = "remove", size = 12, text = "Remove", disabled = not can_remove},
            {kind = "button", id = "refresh", size = 12, text = "Refresh"},
            {kind = "label", text = ""},
            {kind = "button", id = "close", size = 12, text = "Close", default = true},
        }}
    end

    local status = state.status
    if not status or status == "" then
        if state.readonly then status = "read-only: " .. tostring(state.drive_failure ~= "" and state.drive_failure or state.load_note)
        else status = state.load_note or ("Changes take effect after wippy update and a restart") end
    end

    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = string.format("Installed programs:  (modules: %d)", #state.rows)},
        {kind = "table", id = "modules", columns = COLUMNS, rows = rows, selected = state.selected},
        {kind = "label", size = 1, text = ""},
        {kind = "label", size = 1, text = detail},
        {kind = "label", size = 1, text = hint},
        controls,
        {kind = "label", size = 1, text = status},
    }}
end

function definition.update(state: any, action: any, context: any)
    if action.type == "resize" or action.type == "tick" then return end
    if action.id == "modules" and (action.type == "select" or action.type == "activate") then
        state.selected = action.index
        local picked: any = action.value
        state.selected_id = type(picked) == "table" and picked.id or nil
        return
    end
    if action.type ~= "activate" and action.type ~= "change" then return end
    state.status = nil
    if action.id == "component" and action.type == "change" then
        state.input = tostring(action.value or "")
    elseif action.id == "component" or action.id == "write" then
        state.status = install(state, action.id == "component" and tostring(action.value or state.input) or state.input)
        state.mode, state.input = "list", ""
        load(state)
    elseif action.id == "install" then
        state.mode, state.input = "install", ""
    elseif action.id == "cancel" or action.id == "no" then
        state.mode = "list"
    elseif action.id == "remove" then
        local line: any = current(state)
        if line and line.owner == "app" and not state.readonly then state.mode = "confirm"
        elseif line then state.status = "only what the application declared can be removed; this is " .. model.owner_text(line) end
    elseif action.id == "yes" then
        state.status = remove_current(state)
        state.mode = "list"
        load(state)
    elseif action.id == "refresh" then
        load(state)
    elseif action.id == "close" then
        context.close()
    end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
