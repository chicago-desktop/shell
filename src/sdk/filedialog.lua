-- chicago.shell.sdk:filedialog — the Windows 95 common file dialog,
-- Open and Save As, as a sheet inside the window (FR-007 §5).
--
-- Pure, like the rest of the SDK: `sheet` builds the tree from the dialog's
-- state and `update` answers the sheet's own actions. Reading a folder is NOT
-- here. The library holds no permissions: when the sheet needs another place
-- it answers `{read = {drive, path}}`, the application reads that place with
-- the explorer's `sources` under the window's own `fs.get` and
-- `process.registry`, and hands the objects back with `filedialog.arrive`.
--
-- The state is the spec itself; the application keeps it in its model while
-- the sheet is open:
--
--   title     "Open" | "Save As" — the window's caption while the sheet is up
--   button    "Open" | "Save" — the default button
--   place     {drive, path}: a registry drive and a path inside it, "/" or "/a/b"
--   objects   what the explorer read for the place (`model.files` objects), or nil
--   notice    why `objects` is nil
--   drives    the explorer's drive objects (`{id, title}`)
--   name      the File name field
--   types     {{id, label, ext?}, …}, `filedialog.TYPES` by default; `type` is the active id
--   selected  the id of the selected row

local files = require("files")

local filedialog = {}

-- 426×264 px in the original; here in cells.
filedialog.W, filedialog.H = 44, 16

-- The control ids. One table, so the sheet and `update` cannot name one
-- control two ways.
filedialog.IDS = {
    look = "fd_look", up = "fd_up", list = "fd_list", name = "fd_name",
    type = "fd_type", accept = "fd_accept", cancel = "fd_cancel",
}

-- The filters of Notepad's dialog. `ext` is compared with `files.ext`, the
-- one extension rule of the shell; a type without `ext` shows every file.
filedialog.TYPES = {
    {id = "txt", label = "Text Documents (*.txt)", ext = "txt"},
    {id = "all", label = "All Files (*.*)"},
}

-- The picture on Up One Level. The original's is a folder with an arrow; the
-- icon catalog has no such picture, so the folder stands in until one is
-- drawn (then: `folder_up`).
filedialog.UP_IMAGE = "folder"

local IDS = filedialog.IDS
local LABEL = 14   -- "Files of type:" and "Save as type:", the longest caption
local BUTTON = 10  -- the dialog buttons, as wide as `ui.message`'s

-- clean(path) -> "/" or "/a/b"
--
-- A path inside a drive: `\` is read as `/` (a person from Windows types it),
-- `.` is dropped and `..` goes one level up but never above the drive's root.
function filedialog.clean(path: any): string
    local parts: {string} = {}
    for part in tostring(path or ""):gsub("\\", "/"):gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif part ~= "." then
            parts[#parts + 1] = part
        end
    end
    return "/" .. table.concat(parts, "/")
end

-- join(path, name) -> the path of `name` seen from the folder `path`; a name
-- starting with `/` is already a path from the drive's root.
function filedialog.join(path: any, name: any): string
    local text = tostring(name or ""):gsub("\\", "/")
    if text:sub(1, 1) == "/" then return filedialog.clean(text) end
    return filedialog.clean(tostring(path or "/") .. "/" .. text)
end

-- parent(path) -> the folder above, nil at the drive's root.
function filedialog.parent(path: any): string?
    local at = filedialog.clean(path)
    if at == "/" then return nil end
    return filedialog.clean(at:match("^(.*)/[^/]+$"))
end

-- address(place) -> the explorer's path of a place, what `sources.list` reads:
-- `drive/<entry>` or `drive/<entry>/a/b`.
function filedialog.address(place: any): string
    local at = filedialog.clean(place and place.path)
    return "drive/" .. tostring(place and place.drive) .. (at == "/" and "" or at)
end

-- title(state) -> the caption the window shows while the sheet is open.
function filedialog.title(state: any): string
    if type(state.title) == "string" and state.title ~= "" then return state.title end
    return state.button == "Save" and "Save As" or "Open"
end

local function saving(state: any): boolean
    return state.button == "Save"
end

local function types_of(state: any): any
    if type(state.types) == "table" and #state.types > 0 then return state.types end
    return filedialog.TYPES
end

local function active_type(state: any): any
    local list: any = types_of(state)
    for _, entry in ipairs(list) do
        if (entry :: any).id == state.type then return entry end
    end
    return list[1]
end

-- visible(state) -> the rows of the list: the folders first, then the files of
-- the active type, each group in the order the explorer read it (by name).
function filedialog.visible(state: any): any
    local wanted: any = active_type(state).ext
    local folders, found = {}, {}
    for _, entry in ipairs(type(state.objects) == "table" and state.objects or {}) do
        local object: any = entry
        if object.kind == "directory" then
            folders[#folders + 1] = object
        elseif object.kind == "file" and (wanted == nil
            or files.ext(object.title or object.id) == tostring(wanted):lower()) then
            found[#found + 1] = object
        end
    end
    for _, object in ipairs(found) do folders[#folders + 1] = object end
    return folders
end

-- places(state) -> {{drive, path, label}, …}: what Look in offers. Every
-- drive, and under the current one the folders on the way to the place,
-- indented by depth, as the original's list did.
function filedialog.places(state: any): any
    local place: any = state.place or {}
    local drives: any = {}
    local present = false
    for _, entry in ipairs(type(state.drives) == "table" and state.drives or {}) do
        local drive: any = entry
        drives[#drives + 1] = drive
        if drive.id == place.drive then present = true end
    end
    -- A place on a drive the list did not bring still has to be chosen:
    -- otherwise Look in would show some other drive as the current one.
    if not present and place.drive ~= nil then
        table.insert(drives, 1, {id = place.drive, title = tostring(place.drive)})
    end
    local out: any = {}
    for _, entry in ipairs(drives) do
        local drive: any = entry
        out[#out + 1] = {drive = drive.id, path = "/", label = tostring(drive.title or drive.id)}
        if drive.id == place.drive then
            local walked, depth = "", 0
            for part in filedialog.clean(place.path):gmatch("[^/]+") do
                depth = depth + 1
                walked = walked .. "/" .. part
                out[#out + 1] = {drive = drive.id, path = walked, label = string.rep("  ", depth) .. part}
            end
        end
    end
    return out
end

-- arrive(state, place, objects, notice) -> state
--
-- What the application calls with the place it read for `{read = …}`. The
-- selection goes (it named a row of the old folder); the File name stays, as
-- in Windows 95. `objects == nil` shows `notice` where the list was: a folder
-- that could not be read is not an empty folder.
function filedialog.arrive(state: any, place: any, objects: any, notice: any): any
    state.place = {drive = place and place.drive, path = filedialog.clean(place and place.path)}
    state.objects = objects
    state.notice = objects == nil and tostring(notice or "the folder was not read") or nil
    state.selected = nil
    return state
end

local function rows_of(state: any): any
    local rows = {}
    for _, entry in ipairs(filedialog.visible(state)) do
        local object: any = entry
        local folder = object.kind == "directory"
        -- A tree of depth 0 is a list with 16-px icons, the one component that
        -- draws them today. When the `icons` view gains its small icons, the
        -- list moves there (and gets `pointer` on its clicks for free).
        rows[#rows + 1] = {
            id = tostring(object.id), label = tostring(object.title or object.id), depth = 0,
            has_children = false, kind = folder and "folder" or "entry",
            image = (not folder) and (object.image or "document") or nil,
        }
    end
    return rows
end

-- sheet(state) -> tree
--
-- Laid out as the original, 44×16: Look in with Up One Level on top, the
-- list, then File name and Files of type with the two buttons at their right.
function filedialog.sheet(state: any): any
    local place: any = state.place or {}
    local here = filedialog.clean(place.path)
    local options, current = {}, nil
    for index, entry in ipairs(filedialog.places(state)) do
        local spot: any = entry
        options[#options + 1] = {value = tostring(index), label = spot.label}
        if spot.drive == place.drive and spot.path == here then current = tostring(index) end
    end
    local kinds = {}
    for _, entry in ipairs(types_of(state)) do
        local kind: any = entry
        kinds[#kinds + 1] = {value = tostring(kind.id), label = tostring(kind.label)}
    end
    local body: any
    if state.objects == nil and state.notice ~= nil then
        body = {kind = "label", alert = true, wrap = true, text = tostring(state.notice)}
    else
        body = {kind = "tree", id = IDS.list, rows = rows_of(state), selected = state.selected}
    end
    local save = saving(state)
    return {kind = "column", padding_top = 1, padding_left = 1, padding_right = 1, padding_bottom = 0,
        gap = 1, children = {
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = LABEL, text = save and "Save in:" or "Look in:"},
            {kind = "select", id = IDS.look, value = current, options = options},
            {kind = "button", id = IDS.up, size = 4, text = "Up", image = filedialog.UP_IMAGE,
                disabled = filedialog.parent(here) == nil},
        }},
        body,
        {kind = "column", size = 4, gap = 0, children = {
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = LABEL, text = "File name:"},
                {kind = "input", id = IDS.name, text = tostring(state.name or "")},
                {kind = "button", id = IDS.accept, size = BUTTON, text = save and "Save" or "Open", default = true},
            }},
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = LABEL, text = save and "Save as type:" or "Files of type:"},
                {kind = "select", id = IDS.type, value = tostring(active_type(state).id), options = kinds},
                {kind = "button", id = IDS.cancel, size = BUTTON, text = "Cancel"},
            }},
        }},
    }}
end

local function shown(state: any, id: any): any
    if id == nil then return nil end
    for _, entry in ipairs(filedialog.visible(state)) do
        local object: any = entry
        if tostring(object.id) == tostring(id) then return object end
    end
    return nil
end

local function here(state: any): any
    local place: any = state.place or {}
    return place.drive, filedialog.clean(place.path)
end

-- A folder is entered, a file is the answer.
local function open(state: any, object: any): (any, any)
    local drive, path = here(state)
    local target = filedialog.join(path, object.id)
    if object.kind == "directory" then return state, {read = {drive = drive, path = target}} end
    return state, {accept = {drive = drive, path = target}}
end

-- The default button: the File name resolved against the place. A bare name
-- of a folder in the list enters it, as the original did; an empty field
-- answers nothing.
local function accept(state: any): (any, any)
    local name = tostring(state.name or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then return state, nil end
    local drive, path = here(state)
    if not name:find("[/\\]") then
        for _, entry in ipairs(type(state.objects) == "table" and state.objects or {}) do
            local object: any = entry
            if object.kind == "directory" and tostring(object.title or object.id) == name then
                return open(state, object)
            end
        end
    end
    return state, {accept = {drive = drive, path = filedialog.join(path, name)}}
end

-- update(state, action) -> state, result | nil
--
-- `result` is what the application acts on: `{read = {drive, path}}` — read
-- this place and call `arrive`; `{accept = {drive, path}}` — the file chosen,
-- the form `files.encode` takes; `{cancel = true}`. Anything else only
-- changed the state (redraw).
function filedialog.update(state: any, action: any): (any, any)
    if type(action) ~= "table" then return state, nil end
    local id, kind = action.id, action.type
    if (kind == "key" and action.key_type == "esc") or (id == IDS.cancel and kind == "activate") then
        return state, {cancel = true}
    end
    if id == IDS.name and kind == "change" then
        state.name = tostring(action.value or "")
        return state, nil
    end
    -- Enter in the field is the default button.
    if (id == IDS.accept or id == IDS.name) and kind == "activate" then return accept(state) end
    if id == IDS.up and kind == "activate" then
        local drive, path = here(state)
        local up = filedialog.parent(path)
        if up == nil then return state, nil end
        return state, {read = {drive = drive, path = up}}
    end
    if id == IDS.look and kind == "change" then
        local spot: any = filedialog.places(state)[tonumber(action.value) or 0]
        if spot == nil then return state, nil end
        return state, {read = {drive = spot.drive, path = spot.path}}
    end
    if id == IDS.type and kind == "change" then
        state.type = action.value
        -- A selection the filter hid is no selection.
        if shown(state, state.selected) == nil then state.selected = nil end
        return state, nil
    end
    if id == IDS.list and (kind == "select" or kind == "activate") then
        local value: any = action.value
        local object: any = shown(state, type(value) == "table" and value.id or nil)
        if object == nil then return state, nil end
        -- A double click is a second click on the selected row. Only a CLICK:
        -- ↑ or Home on the first row selects it again too, and must not open it.
        if kind == "activate" or (action.pointer == true and state.selected == tostring(object.id)) then
            return open(state, object)
        end
        state.selected = tostring(object.id)
        -- A click on a file names it; a folder is only selected, as in Windows 95.
        if object.kind ~= "directory" then state.name = tostring(object.title or object.id) end
        return state, nil
    end
    return state, nil
end

return filedialog
