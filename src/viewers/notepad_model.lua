-- windows.shell.viewers:notepad_model — Notepad as Windows 95 had it
-- (FR-007 §1, §6), pure.
--
-- The window's model and its `view`, `update` and `title`: the menus of §1,
-- the sheets (the file dialog, Find, the questions and the messages), the
-- clipboard, the "save changes?" gate. The document itself is the SDK
-- editor's (`context.editor(DOC)`); this model keeps what is not text.
--
-- Nothing here reads a drive, the registry or the clock. The window passes a
-- `sys` table of five functions and a test passes a stand-in:
--   read(drive, path)        -> text | nil, reason, kind ("missing" | "large" | "failed")
--   write(drive, path, text) -> true | nil, reason
--   exists(drive, path)      -> whether a file is there (Save As asks before replacing it)
--   drives()                 -> the explorer's drive objects | nil, reason
--   list(place)              -> objects | nil, notice   (a place is {drive, path})
--   now()                    -> the time and date to insert, "9:45 PM 9/13/2026"
-- `read_file` and `write_file` are those two for the window, over the `fs`
-- module's `get`, here so that the 64 KB rule is tested as it runs.
local ui = require("ui")
local editor = require("editor")
local filedialog = require("filedialog")
local files = require("files")

local notepad = {}

-- The editor's id in the window's tree.
notepad.DOC = "doc"
-- Windows 95 Notepad opened files up to 64 KB and refused larger ones.
notepad.LIMIT = 64 * 1024
notepad.NAME = "Notepad"
notepad.UNTITLED = "Untitled"
notepad.TOO_LARGE = "This file is too large for Notepad to open."
notepad.NO_HELP = "Help is not available."
-- The Time/Date the original inserted: the US short forms, "9:45 PM 9/13/2026".
notepad.TIME_LAYOUT = "3:04 PM 1/2/2006"

local SEP = {separator = true}
-- Ctrl with a letter: the editor leaves these to the window, and the
-- clipboard is the window's (§2).
local KEYS: {[string]: string} = {z = "undo", x = "cut", c = "copy", v = "paste"}
local YES_NO_CANCEL = function(prefix: string): any
    return {{id = prefix .. "_yes", text = "Yes", default = true}, {id = prefix .. "_no", text = "No"},
        {id = prefix .. "_cancel", text = "Cancel"}}
end

-- read_file(get, drive, path) -> text | nil, reason, kind
--
-- The file as Notepad opens it: a missing file is `missing` (the create
-- question), one over `LIMIT` is `large` — known from `stat` before a byte is
-- read — and anything else `failed` with the reason.
function notepad.read_file(get: any, drive: any, path: any): (any, any, any)
    local handle: any, err = get(tostring(drive))
    if err or not handle then
        return nil, "drive " .. tostring(drive) .. " not opened: " .. tostring(err or "no such entry"), "failed"
    end
    local info: any = handle:stat(tostring(path))
    if type(info) ~= "table" then return nil, "no such file: " .. tostring(path), "missing" end
    if (tonumber(info.size) or 0) > notepad.LIMIT then return nil, notepad.TOO_LARGE, "large" end
    local data: any, read_err = handle:readfile(tostring(path))
    if read_err or type(data) ~= "string" then
        return nil, "file " .. tostring(path) .. " not read: " .. tostring(read_err), "failed"
    end
    if #data > notepad.LIMIT then return nil, notepad.TOO_LARGE, "large" end
    return data, nil, nil
end

-- exists_file(get, drive, path) -> whether a file is at `path`, by the same
-- `stat` the size is read by; a drive that does not open has none.
function notepad.exists_file(get: any, drive: any, path: any): boolean
    local handle: any, err = get(tostring(drive))
    if err or not handle then return false end
    return type(handle:stat(tostring(path))) == "table"
end

-- write_file(get, drive, path, text) -> true | nil, reason
function notepad.write_file(get: any, drive: any, path: any, text: any): (any, any)
    local handle: any, err = get(tostring(drive))
    if err or not handle then
        return nil, "drive " .. tostring(drive) .. " not opened: " .. tostring(err or "no such entry")
    end
    local _, write_err = handle:writefile(tostring(path), tostring(text or ""))
    if write_err then return nil, "file " .. tostring(path) .. " not written: " .. tostring(write_err) end
    return true, nil
end

function notepad.new(sys: any): any
    return {sys = sys, file = nil, wrap = false, clipboard = "", sheet = nil, pending = nil, search = nil}
end

local function document_of(context: any): any
    return context.editor(notepad.DOC)
end

local function file_of(place: any): any
    local path = filedialog.clean(place.path)
    return {drive = tostring(place.drive), path = path, name = files.name_of(path)}
end

-- A message sheet: the window's title, OK closes it.
local function message(state: any, lines: any, extra: any?): boolean
    local sheet: any = {kind = "message", title = notepad.NAME, lines = lines, image = "notepad", icon = "▤"}
    for key, value in pairs(extra or {}) do sheet[key] = value end
    state.sheet = sheet
    return true
end

local function read_place(state: any, dialog: any, place: any)
    local objects, notice = state.sys.list(place)
    filedialog.arrive(dialog, place, objects, notice)
end

-- The Open or Save As sheet, at the current file's folder or the first
-- drive's root.
local function open_dialog(state: any, mode: string): boolean
    local saving = mode == "save"
    local drives: any = state.sys.drives() or {}
    local place: any = nil
    if state.file ~= nil then
        place = {drive = state.file.drive, path = filedialog.parent(state.file.path) or "/"}
    elseif drives[1] ~= nil then
        place = {drive = drives[1].id, path = "/"}
    end
    local dialog: any = {title = saving and "Save As" or "Open", button = saving and "Save" or "Open", type = "txt",
        name = (saving and state.file ~= nil) and state.file.name or "", drives = drives, place = place}
    if place ~= nil then read_place(state, dialog, place) else dialog.notice = "there is no drive to keep files on" end
    state.sheet = {kind = "dialog", mode = mode, dialog = dialog}
    return true
end

-- open_path(state, context, place, dialog) — the file into the editor, or the
-- reason it is not: too large, missing (the create question, whose No goes
-- back to `dialog`), unreadable.
local function open_path(state: any, context: any, place: any, dialog: any): boolean
    local path = filedialog.clean(place.path)
    local text, why, kind = state.sys.read(place.drive, path)
    if text ~= nil then
        editor.set(document_of(context), text)
        state.file = file_of(place)
        state.sheet = nil
        return true
    end
    if kind == "large" then return message(state, {notepad.TOO_LARGE}) end
    if kind == "missing" then
        state.sheet = {kind = "create", title = notepad.NAME, image = "notepad", icon = "▤",
            place = {drive = place.drive, path = path}, back = dialog,
            lines = {"Cannot find the " .. files.name_of(path) .. " file.", "", "Do you want to create a new file?"},
            buttons = YES_NO_CANCEL("create")}
        return true
    end
    return message(state, {tostring(why or "the file was not read")})
end

-- proceed(state, context, what) — what a question held back: New, Open, Exit.
local function proceed(state: any, context: any, what: any): boolean
    state.pending = nil
    if what == "new" then
        editor.set(document_of(context), "")
        state.file = nil
    elseif what == "open" then
        return open_dialog(state, "open")
    elseif what == "exit" then
        context.close()
    end
    return true
end

-- save_to(state, context, place) — the document into the file; then what a
-- "save changes?" Yes was waiting for.
local function save_to(state: any, context: any, place: any): boolean
    local document = document_of(context)
    local ok, why = state.sys.write(place.drive, filedialog.clean(place.path), editor.text(document))
    if not ok then
        state.pending = nil
        return message(state, {tostring(why or "the file was not written")})
    end
    state.file = file_of(place)
    editor.mark(document)
    state.sheet = nil
    if state.pending ~= nil then return proceed(state, context, state.pending) end
    return true
end

-- Save: an untitled document is Save As.
local function save(state: any, context: any): boolean
    if state.file == nil then return open_dialog(state, "save") end
    return save_to(state, context, state.file)
end

-- gate(state, context, what) — New, Open and Exit of a changed document ask
-- first, as §1 says.
local function gate(state: any, context: any, what: string): boolean
    if not editor.dirty(document_of(context)) then return proceed(state, context, what) end
    local name = state.file ~= nil and state.file.name or notepad.UNTITLED
    state.pending = what
    state.sheet = {kind = "ask", title = notepad.NAME, image = "notepad", icon = "▤",
        lines = {"The text in the " .. name .. " file has changed.", "", "Do you want to save the changes?"},
        buttons = YES_NO_CANCEL("ask")}
    return true
end

local function find_sheet(state: any): boolean
    local search: any = state.search or {}
    state.sheet = {kind = "find", needle = tostring(search.needle or ""), match_case = search.match_case == true,
        direction = search.direction == "up" and "up" or "down"}
    return true
end

-- Find Next (F3): the last search from the caret; with none, the Find sheet.
local function find_next(state: any, context: any): boolean
    local search: any = state.search
    if search == nil or search.needle == "" then return find_sheet(state) end
    if editor.find(document_of(context), search.needle, {match_case = search.match_case, direction = search.direction}) then
        return true
    end
    return message(state, {"Cannot find \"" .. search.needle .. "\""})
end

local function command(state: any, context: any, id: any): boolean
    local document = document_of(context)
    if id == "new" or id == "open" or id == "exit" then return gate(state, context, id)
    elseif id == "save" then return save(state, context)
    elseif id == "save_as" then return open_dialog(state, "save")
    elseif id == "undo" then editor.undo(document)
    elseif id == "cut" then
        local text = editor.selection(document)
        if text ~= nil then
            state.clipboard = text
            editor.delete_selection(document)
        end
    elseif id == "copy" then
        local text = editor.selection(document)
        if text ~= nil then state.clipboard = text end
    elseif id == "paste" then
        if state.clipboard ~= "" then editor.replace_selection(document, state.clipboard) end
    elseif id == "delete" then editor.delete_selection(document)
    elseif id == "select_all" then editor.select_all(document)
    elseif id == "time_date" then editor.insert(document, state.sys.now())
    elseif id == "wrap" then state.wrap = not state.wrap
    elseif id == "find" then return find_sheet(state)
    elseif id == "find_next" then return find_next(state, context)
    elseif id == "help" then return message(state, {notepad.NO_HELP}, {image = "help", icon = "?"})
    elseif id == "about" then
        return message(state, {"Notepad", "The Windows 95 shell for Wippy (windows/shell).",
            "Icons: Microsoft artwork from shell32.dll, not under the module's MIT licence."}, {title = "About Notepad"})
    else
        return false
    end
    return true
end

local function sheet_update(state: any, context: any, action: any): boolean
    local sheet: any = state.sheet
    local escape = action.type == "key" and action.key_type == "esc"
    local pressed = action.type == "activate" and action.id or nil
    if sheet.kind == "dialog" then
        local _, result = filedialog.update(sheet.dialog, action)
        if result == nil then return true end
        if result.read then
            read_place(state, sheet.dialog, result.read)
            return true
        end
        if result.cancel then
            state.sheet, state.pending = nil, nil
            return true
        end
        if result.accept then
            if sheet.mode == "open" then return open_path(state, context, result.accept, sheet.dialog) end
            -- A name without an extension under Text Documents is a .txt, as
            -- Windows saved it.
            local place: any = {drive = result.accept.drive, path = result.accept.path}
            if files.ext(place.path) == "" and tostring(sheet.dialog.type or "txt") == "txt" then place.path = place.path .. ".txt" end
            -- A file already there is replaced only when the person says so,
            -- as Windows 95 asked; No is the default, the question deletes.
            if state.sys.exists(place.drive, filedialog.clean(place.path)) then
                state.sheet = {kind = "replace", title = "Save As", image = "notepad", icon = "▤",
                    place = place, back = sheet.dialog,
                    lines = {files.name_of(place.path) .. " already exists.", "Do you want to replace it?"},
                    buttons = {{id = "replace_yes", text = "Yes"}, {id = "replace_no", text = "No", default = true}}}
                return true
            end
            return save_to(state, context, place)
        end
        return true
    end
    if sheet.kind == "replace" then
        if pressed == "replace_yes" then return save_to(state, context, sheet.place)
        elseif pressed == "replace_no" or escape then
            -- No goes back to the dialog to pick another name.
            state.sheet = {kind = "dialog", mode = "save", dialog = sheet.back}
            return true
        end
        return false
    end
    if sheet.kind == "find" then
        if escape or pressed == "find_cancel" then
            state.sheet = nil
            return true
        end
        if action.type == "change" and action.id == "find_what" then sheet.needle = tostring(action.value or "")
        elseif action.type == "change" and action.id == "find_case" then sheet.match_case = action.value == true
        elseif action.type == "change" and action.id == "find_up" then sheet.direction = "up"
        elseif action.type == "change" and action.id == "find_down" then sheet.direction = "down"
        elseif pressed == "find_next" or pressed == "find_what" then
            if sheet.needle == "" then return false end
            state.search = {needle = sheet.needle, match_case = sheet.match_case, direction = sheet.direction}
            -- The sheet covers the text, so Find Next closes it to show the
            -- match; F3 goes on from there.
            state.sheet = nil
            return find_next(state, context)
        else
            return false
        end
        return true
    end
    if sheet.kind == "ask" then
        if pressed == "ask_yes" then
            state.sheet = nil
            return save(state, context)
        elseif pressed == "ask_no" then
            state.sheet = nil
            return proceed(state, context, state.pending)
        elseif pressed == "ask_cancel" or escape then
            state.sheet, state.pending = nil, nil
            return true
        end
        return false
    end
    if sheet.kind == "create" then
        if pressed == "create_yes" then
            local ok, why = state.sys.write(sheet.place.drive, sheet.place.path, "")
            if not ok then return message(state, {tostring(why or "the file was not created")}) end
            editor.set(document_of(context), "")
            state.file = file_of(sheet.place)
            state.sheet = nil
            return true
        elseif pressed == "create_no" then
            state.sheet = sheet.back ~= nil and {kind = "dialog", mode = "open", dialog = sheet.back} or nil
            return true
        elseif pressed == "create_cancel" or escape then
            state.sheet = nil
            return true
        end
        return false
    end
    if pressed == "msg_ok" or escape then
        state.sheet = nil
        return true
    end
    return false
end

-- init(sys, args, context) -> the model: an untitled document, or the file
-- the explorer's argument names (`files.encode`).
function notepad.init(sys: any, args: any, context: any): any
    local state = notepad.new(sys)
    if type(args) == "string" and args ~= "" then
        local file, why = files.parse(args)
        if file then open_path(state, context, {drive = file.drive, path = file.path}, nil)
        else message(state, {tostring(why)}) end
    end
    return state
end

-- title(state) -> "Untitled - Notepad", "<name> - Notepad" with the plain
-- hyphen of the original; while a sheet is up, the sheet's title.
function notepad.title(state: any): string
    local sheet: any = state.sheet
    if sheet ~= nil then
        if sheet.kind == "dialog" then return filedialog.title(sheet.dialog) end
        if sheet.kind == "find" then return "Find" end
        return tostring(sheet.title or notepad.NAME)
    end
    return (state.file ~= nil and state.file.name or notepad.UNTITLED) .. " - " .. notepad.NAME
end

-- menus(state, document) -> the bar of §1: the shortcut column, the Word
-- Wrap checkmark, Page Setup and Print disabled (there is no printer), Undo,
-- Cut, Copy, Delete and Paste greyed as the original greyed them.
function notepad.menus(state: any, document: any): any
    local selected = editor.selected(document)
    return {
        {title = "File", accel = 1, items = {
            {id = "new", text = "New", accel = 1},
            {id = "open", text = "Open...", accel = 1},
            {id = "save", text = "Save", accel = 1},
            {id = "save_as", text = "Save As...", accel = 6},
            SEP,
            {id = "page_setup", text = "Page Setup...", accel = 9, disabled = true},
            {id = "print", text = "Print", accel = 1, disabled = true},
            SEP,
            {id = "exit", text = "Exit", accel = 2},
        }},
        {title = "Edit", accel = 1, items = {
            {id = "undo", text = "Undo", accel = 1, shortcut = "Ctrl+Z", disabled = document.undo == nil},
            SEP,
            {id = "cut", text = "Cut", accel = 3, shortcut = "Ctrl+X", disabled = not selected},
            {id = "copy", text = "Copy", accel = 1, shortcut = "Ctrl+C", disabled = not selected},
            {id = "paste", text = "Paste", accel = 1, shortcut = "Ctrl+V", disabled = state.clipboard == ""},
            {id = "delete", text = "Delete", accel = 3, shortcut = "Del", disabled = not selected},
            SEP,
            {id = "select_all", text = "Select All", accel = 8},
            {id = "time_date", text = "Time/Date", accel = 6, shortcut = "F5"},
            SEP,
            {id = "wrap", text = "Word Wrap", accel = 1, checked = state.wrap == true},
        }},
        {title = "Search", accel = 1, items = {
            {id = "find", text = "Find...", accel = 1},
            {id = "find_next", text = "Find Next", accel = 6, shortcut = "F3"},
        }},
        {title = "Help", accel = 1, items = {
            {id = "help", text = "Help Topics", accel = 1},
            SEP,
            {id = "about", text = "About Notepad", accel = 1},
        }},
    }
end

-- The Find sheet of §1: Find what, Match case, Direction, Find Next and Cancel.
local function find_tree(sheet: any): any
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = 11, text = "Find what:"},
            {kind = "input", id = "find_what", text = sheet.needle},
            {kind = "button", id = "find_next", size = 12, text = "Find Next", default = true, disabled = sheet.needle == ""},
        }},
        {kind = "row", size = 4, gap = 1, children = {
            {kind = "column", gap = 0, children = {
                {kind = "label", size = 1, text = ""},
                {kind = "checkbox", id = "find_case", size = 1, text = "Match case", checked = sheet.match_case == true},
            }},
            {kind = "group", title = "Direction", size = 18, children = {
                {kind = "row", size = 1, gap = 1, children = {
                    {kind = "radio", id = "find_up", size = 6, text = "Up", checked = sheet.direction == "up"},
                    {kind = "radio", id = "find_down", size = 8, text = "Down", checked = sheet.direction ~= "up"},
                }},
            }},
            {kind = "button", id = "find_cancel", size = 12, text = "Cancel"},
        }},
    }}
end

function notepad.view(state: any, context: any): any
    local sheet: any = state.sheet
    if sheet ~= nil then
        if sheet.kind == "dialog" then return filedialog.sheet(sheet.dialog) end
        if sheet.kind == "find" then return find_tree(sheet) end
        return ui.message({title = sheet.title, lines = sheet.lines, image = sheet.image, icon = sheet.icon,
            ok = "msg_ok", buttons = sheet.buttons})
    end
    local document = document_of(context)
    return {kind = "column", gap = 0, children = {
        {kind = "menu", id = "bar", size = 1, entries = notepad.menus(state, document)},
        {kind = "editor", id = notepad.DOC, font = "mono", wrap = state.wrap == true},
    }}
end

-- update(state, action, context) -> whether to redraw; a `close` is refused
-- with `context.stay()` (C1).
function notepad.update(state: any, action: any, context: any): boolean
    if type(action) ~= "table" then return false end
    -- The title bar's ×, Close or another window's `desktop.close`: a changed
    -- document stays and asks, as Exit does, and the answer closes the window
    -- with `context.close()`; an unchanged one closes at once.
    if action.type == "close" then
        if editor.dirty(document_of(context)) then
            context.stay()
            return gate(state, context, "exit")
        end
        return true
    end
    if state.sheet ~= nil then return sheet_update(state, context, action) end
    if action.type == "activate" and action.menu == "bar" then return command(state, context, action.id) end
    if action.type == "key" then
        if action.ctrl and action.key_type == "runes" then
            local id = KEYS[tostring(action.key or ""):lower()]
            if id ~= nil then return command(state, context, id) end
        end
        if action.key_type == "f3" then return command(state, context, "find_next") end
        if action.key_type == "f5" then return command(state, context, "time_date") end
    end
    return false
end

return notepad
