-- What "My Computer" shows.
--
-- Drives are the `fs.*` entries of the registry, and there is no need to
-- create them: almost every installed module brings its own filesystem, and
-- on the running system there are dozens of them. The window SHOWS them.
-- Hence both rules at once: a drive declared by an installed module appears
-- by itself, with no edit in the shell; and a drive that is not in the
-- registry will not be here — a painted `C:` would be an object that does
-- not exist, and the first question would be why it does not open.
--
-- The root shows only drives. For desktop folders opened directly and for
-- service paths separate source models remain; the shell reads them for
-- other purposes:
--
--   Programs       — the registry catalog, the same one that fills the "Start" menu
--   Desktop        — our own layout, desktop shortcuts and folders
--   Open Windows   — what is on screen right now, held by the base's compositor
--
-- What is deliberately NOT here: runs, bridge jobs, content-machine beats.
-- Reading other modules' tables directly would mean taking a dependency on
-- the schemas of modules the shell does not depend on — and breaking on
-- their first migration, silently and not in our own code. A module that
-- wants to show its own data declares a window as an entry with
-- `meta.type: tui_desktop.window`, and it appears in "Programs" by itself.
-- This is the same principle the whole module stands on: the registry
-- declares.
--
-- The split into a pure assembly and reading the sources is the same as in
-- the catalog: a rule that can be checked only against a live database gets
-- checked once, and then never.

local catalog = require("catalog")
local associations = require("associations")

local model = {}

model.ROOT = ""

-- Filesystem kinds supported by the installed runtime. Discovery and object
-- construction share this list, so non-filesystem registry entries stay out.
model.DRIVE_KINDS = {"fs.directory", "fs.embed"}
local drive_kinds = {}
for _, kind in ipairs(model.DRIVE_KINDS) do drive_kinds[kind] = true end

model.DEFAULT_ICON = "▢"
model.BROKEN_ICON = "▨"
model.DRIVE_ICON = "▦"
model.DIR_ICON = "▤"
model.FILE_ICON = "▫"

-- A path is a string, and its whole grammar is here, because three parties
-- read it: the window (to know what to draw), the sources (to know what to
-- read) and the "Up" button (to know where to go back to). Were they to
-- diverge, "Up" would lead somewhere other than where a double click leads.
--
--   ""                    the root of "My Computer"
--   "programs"            the program catalog
--   "desktop"             the desktop, top level
--   "desktop/<id>"        a desktop folder
--   "windows"             open windows
--   "drive/<entry>"       the root of a filesystem from the registry
--   "drive/<entry>/<path>"  a directory inside it
--
-- A registry entry id is always `namespace:name`, and there can be no slash
-- in it; parsing the path inside a drive relies on exactly that.
function model.parse(path: any)
    local text = type(path) == "string" and path or ""

    if text == model.ROOT then return {view = "root"} end
    if text == "programs" then return {view = "programs"} end
    if text == "desktop" then return {view = "desktop"} end
    if text == "windows" then return {view = "windows"} end

    local folder = string.match(text, "^desktop/(.+)$")
    if folder then return {view = "desktop_folder", id = folder} end

    local drive, rest = string.match(text, "^drive/([^/]+)(.*)$")
    if drive then
        local inside = string.match(tostring(rest), "^/(.+)$")
        return {view = "drive", id = drive, sub = inside}
    end

    -- An unknown path is not the root. A silent fallback to the root would
    -- turn a typo into a successful navigation, and a person would decide
    -- that the folder is empty.
    return {view = "unknown"}
end

-- parent(path) -> the path one level up | nil if there is nowhere higher
--
-- By the same parsing as `parse`: an "Up" button that computes the path by
-- its own formula will drift apart from the double click, and they will
-- drift apart silently.
-- address(path) -> the address string as Windows would show it: `My Computer`,
-- `My Computer\Programs`, `app:app_fs\src\app`. A drive is named by its
-- registry entry — it has no other name, and an invented letter would
-- promise something that does not exist.
function model.address(path: any): string
    local where: any = model.parse(path)
    if where.view == "root" then return "My Computer" end
    if where.view == "programs" then return "My Computer\\Programs" end
    if where.view == "desktop" then return "My Computer\\Desktop" end
    if where.view == "desktop_folder" then return "My Computer\\Desktop\\" .. tostring(where.id) end
    if where.view == "windows" then return "My Computer\\Open Windows" end
    if where.view == "drive" then
        local text = tostring(where.id)
        if where.sub then text = text .. "\\" .. tostring(where.sub):gsub("/", "\\") end
        return text
    end
    return tostring(path or "")
end

-- ancestors(path) -> a list of {title, path} from the root to the current folder.
--
-- These are the contents of the address bar's dropdown list: each line is a
-- place you can go to with one click. The last one is the folder itself.
function model.ancestors(path: any): any
    local chain: any = {}
    local at: any = path
    local guard = 0
    while at ~= nil and guard < 64 do
        guard = guard + 1
        table.insert(chain, 1, {title = model.address(at), path = at})
        if at == model.ROOT then break end
        at = model.parent(at)
        if at == nil then break end
    end
    if #chain == 0 or chain[1].path ~= model.ROOT then
        table.insert(chain, 1, {title = "My Computer", path = model.ROOT})
    end
    return chain
end

function model.parent(path: any)
    local where = model.parse(path)

    if where.view == "root" then return nil end
    if where.view == "desktop_folder" then return "desktop" end

    if where.view == "drive" then
        if not where.sub then return model.ROOT end
        local up = string.match(tostring(where.sub), "^(.+)/[^/]+$")
        if up then return "drive/" .. tostring(where.id) .. "/" .. up end
        return "drive/" .. tostring(where.id)
    end

    return model.ROOT
end

-- An object: what is visible (title, icon, detail) and what happens on a
-- double click (open). Double, not single: a program that starts on one
-- click is a trap, and real Windows does not have it either.
--
-- `open` describes an INTENT, it does not carry it out: the window does not
-- spawn processes and does not open its neighbours by itself, it asks the
-- compositor to do it. Interpreting the intent lives in one place, and the
-- window does not decide along the way what "open" means.
local function object(fields: any)
    return {
        id = fields.id,
        kind = fields.kind,
        title = fields.title,
        icon = fields.icon,
        image = fields.image, entry = fields.entry, broken = fields.broken,
        detail = fields.detail,
        open = fields.open,
    }
end

-- Drives: the registry's `fs.directory` and `fs.embed` entries as they are.
--
-- There is no table of drives of our own and there cannot be — it would mean
-- that a module that brought a filesystem does not appear here until someone
-- writes it in by hand. So the list is exactly what the registry returned.
--
-- The caption is the entry name, not the full id: `wippy.facade:public_files`
-- does not fit into a twelve-cell caption and gets cut exactly where the
-- difference begins.
--
-- But the name does not always tell them apart: `ui_static_fs` is brought by
-- several modules at once, and two identical icons side by side are not a
-- caption but a riddle. Then the namespace is added to the name, and it is
-- added with a SPACE, not a colon: the caption wraps at spaces, and
-- `keeper ui_static_fs` lays out as two lines where at least the first reads
-- in full, while `keeper:ui_static_fs` is cut to `keeper:ui_st` — that is,
-- exactly where the difference begins, the very difference it was lengthened
-- for.
--
-- BOTH matching names are lengthened, not just the second: a caption that
-- depends on the order the registry is read in changes by itself.
--
-- The full id is not lost in the process: it is in `detail`, and the window
-- shows the `detail` of the selected object in the status bar.
function model.drives(records: any)
    local seen: any = {}
    local drives: any = {}

    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record: any = entry
        if type(record.id) == "string" and record.id ~= "" and drive_kinds[record.kind] then
            local space, name = string.match(record.id, "^([^:]*):(.+)$")
            if not name then space, name = "", record.id end
            seen[name] = (seen[name] or 0) + 1
            drives[#drives + 1] = {
                id = record.id, name = name, space = space, kind = record.kind,
            }
        end
    end

    -- The order is set here and not inherited from the registry: a list whose
    -- order is decided by someone else's output rearranges the icons by
    -- itself, and a person used to a place searches anew every time.
    table.sort(drives, function(left, right) return left.id < right.id end)

    local out = {}
    for _, drive in ipairs(drives) do
        local ambiguous = (seen[drive.name] or 0) > 1 and drive.space ~= ""
        out[#out + 1] = object({
            id = drive.id,
            kind = "drive",
            title = ambiguous and (drive.space .. " " .. drive.name) or drive.name,
            icon = model.DRIVE_ICON,
            -- The entry kind is the answer to "why doesn't it open": `fs.embed`
            -- is frozen into the module and is read-only, `fs.directory` is a
            -- real directory on disk.
            detail = drive.id .. " · " .. tostring(drive.kind or "fs"),
            open = {action = "folder", path = "drive/" .. drive.id},
        })
    end
    return out
end

-- The contents of a directory inside a drive. `entries` is what `readdir`
-- returned: a name and a kind, and nothing more. There is deliberately no
-- size here — it would require a `stat` on every row, that is, a hundred disk
-- accesses for the sake of a column that icons do not have anyway.
--
-- A file is opened by a program from the file type registry
-- (`associations.open`). A file that has nothing to open it with has no
-- intent: it would be a promise that nobody can keep. The reason lies in
-- `detail`, and on a double click the window tells it the same way as it
-- tells any other refusal.
function model.files(entries: any, path: any, drive: any, sub: any, programs: any)
    local rows = {}
    for _, entry in ipairs(type(entries) == "table" and entries or {}) do
        local record: any = entry
        if type(record.name) == "string" and record.name ~= "" then
            rows[#rows + 1] = {name = record.name, dir = record.type == "directory"}
        end
    end

    -- Folders before files, then by name — as in Explorer. An order taken
    -- from the filesystem is different for each one.
    table.sort(rows, function(left, right)
        if left.dir ~= right.dir then return left.dir end
        return left.name < right.name
    end)

    local base = type(path) == "string" and path or ""
    -- The path INSIDE the drive is what the program will get; `path` is the
    -- folder's address in Explorer, it has a different form.
    local inside = (type(sub) == "string" and sub ~= "") and ("/" .. sub) or ""
    local out = {}
    for _, row in ipairs(rows) do
        if row.dir then
            out[#out + 1] = object({
                id = row.name,
                kind = "directory",
                title = row.name,
                icon = model.DIR_ICON,
                detail = "folder",
                open = {action = "folder", path = base .. "/" .. row.name},
            })
        else
            -- A file is opened by a program from the file type registry, and
            -- that program also gives it its icon. A file that has nothing to
            -- open it with says so in its details and does not open — instead
            -- of silence on a double click.
            local file_path = inside .. "/" .. row.name
            local open, why = associations.open(programs, drive, file_path)
            out[#out + 1] = object({
                id = row.name,
                kind = "file",
                title = row.name,
                icon = model.FILE_ICON,
                image = associations.image_for(programs, row.name),
                detail = open and "file" or tostring(why),
                open = open,
            })
        end
    end
    return out
end

-- My Computer contains filesystem entries only; other shell objects are
-- reached through their own menu or desktop folder.
function model.root(records: any)
    return model.drives(records)
end

-- The catalog's programs. Flat, without menu folders: in an Explorer window
-- menu folders would be a second tree next to the "My Computer" tree, and a
-- person would not understand which of them they are in.
function model.programs(programs: any)
    local out = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        out[#out + 1] = object({
            id = program.entry,
            kind = "program",
            title = program.title,
            icon = program.icon or model.DEFAULT_ICON,
            image = program.image, entry = program.entry,
            detail = program.entry,
            open = {
                action = "open_window",
                entry = program.entry,
                title = program.title,
                w = program.width,
                h = program.height,
                args = program.args,
            },
        })
    end
    return out
end

-- Desktop shortcuts and folders. A broken shortcut is visible here too, and
-- for the same reason: a missing row reads as "I deleted it by accident", a
-- broken one as "the program is gone".
function model.desktop(items: any, programs: any)
    local out = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if item.kind == "folder" then
            out[#out + 1] = object({
                id = item.id,
                kind = "folder",
                title = item.title,
                icon = "▤",
                detail = "desktop folder",
                -- A desktop folder is opened in its own window, not in this
                -- one: it has its own contents and its own layout.
                open = {action = "folder", path = "desktop/" .. tostring(item.id)},
            })
        else
            local program = catalog.find(programs, item.entry)
            out[#out + 1] = object({
                id = item.id,
                kind = "shortcut",
                title = item.title,
                icon = program and (program.icon or model.DEFAULT_ICON) or model.BROKEN_ICON,
                image = program and program.image, entry = item.entry,
                broken = programs ~= nil and program == nil or nil,
                detail = program and item.entry or ("no program: " .. tostring(item.entry)),
                open = program and {
                    action = "open_window",
                    entry = item.entry,
                    title = item.title,
                    w = program.width,
                    h = program.height,
                    args = program.args,
                } or nil,
            })
        end
    end
    return out
end

-- Open windows. A double click raises the window rather than opening a second
-- one of the same kind: the list shows what is already on screen, and "open"
-- here means "show".
function model.windows(windows: any)
    local out = {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
        out[#out + 1] = object({
            id = window.id,
            kind = "window",
            title = window.title or window.id,
            icon = "◫",
            detail = window.minimized and "minimized" or "on screen",
            open = {action = "raise", id = window.id},
        })
    end
    return out
end

-- ─── compositor replies ──────────────────────────────────────────────────
--
-- The window has one reply channel, and it receives more than the reply to
-- `desktop.list`. Commands without waiting — `desktop.open`, `desktop.focus`,
-- `desktop.state` — are refused by the compositor over the same channel,
-- marked `unsolicited` (the base, `refuse`). A window that read everything as
-- a list took a refusal to open a program for "the window list was not
-- read": the reason went into a folder nobody was looking at, and there was
-- nothing on screen.

local NO_REASON = "the compositor refused without a reason"

-- How a refusal is named in the status bar. One table both for a refusal that
-- arrives immediately (compositor not found) and for one that arrives later
-- over the channel: two wordings of one refusal would read as two different
-- ones.
local REFUSED: any = {["desktop.open"] = "did not open", ["desktop.focus"] = "did not start"}

function model.refusal(command: any, reason: any): string
    local prefix = REFUSED[tostring(command)]
        or (type(command) == "string" and command .. " refused" or "refused")
    return prefix .. ": " .. tostring(reason or NO_REASON)
end

-- take_reply(state, body) -> "list" | "notice" | nil
--
-- "list" — the window list or a refusal to give it arrived, the folder must
-- be re-read; "notice" — a refusal for another command: it went into the
-- status bar, the list is untouched; nil — the reply is not to this window's
-- question, there is nowhere to put it.
function model.take_reply(state: any, body: any): any
    if type(body) ~= "table" then return nil end
    if body.unsolicited or (body.ok == false and body.command ~= "desktop.list") then
        state.notice = model.refusal(body.command, body.error)
        return "notice"
    end
    if body.command ~= "desktop.list" then return nil end
    if body.ok == false then
        state.windows_error = tostring(body.error or NO_REASON)
        state.windows = nil
    else
        state.windows = type(body.windows) == "table" and body.windows or {}
        state.windows_error = nil
    end
    return "list"
end

return model
