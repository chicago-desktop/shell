-- What "My Computer" shows.
--
-- My Computer lists logical disks. C: (Wippy) contains the registry's
-- filesystems as folders and the Control Panel. Filesystem entry IDs remain
-- the stable internal addresses used by file viewers and saved shortcuts.
-- Programs, Desktop and Open Windows remain reachable by their own paths.
--
-- The split into a pure assembly and reading the sources is the same as in
-- the catalog: a rule that can be checked only against a live database gets
-- checked once, and then never.

local catalog = require("catalog")
local associations = require("associations")
local files = require("files")

local model = {}

model.ROOT = ""
model.WIPPY = "wippy"
-- The collection of filesystems the running modules declare. It is D:, not
-- C:, because C: is now a disk of its own — a single filesystem a module
-- declares as one, with its own letter (`model.disk_path`). The collection
-- is what it always was: the fonts, the wallpapers, the icon packs and the
-- declarations, each folder something the system really reads.
--
-- The caption follows the original's form — the label, then the letter in
-- brackets, "3½ Floppy (A:)" — and the picture is the CD-ROM's: D: was the
-- disc on those machines, and this one is the disc the software came on.
model.WIPPY_TITLE = "Wippy (D:)"
model.WIPPY_LETTER = "D"
model.WIPPY_IMAGE = "cdrom"

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

-- The folder window itself (FR-008 §3): opening a folder opens this entry with
-- the folder's path in `args`.
model.EXPLORER = "chicago.shell.explorer:window"

-- The Control Panel: a folder at the root holding the catalog's `Settings`
-- programs. Its picture is the pack's `control_panel`.
model.CONTROL = "control"
model.CONTROL_TITLE = "Control Panel"
model.CONTROL_IMAGE = "control_panel"
model.SETTINGS_GROUP = "Settings"

-- How folders open (View → Options…): a window per folder, as the original
-- did by default, or one window that changes. The first is the default.
model.BROWSE = {"separate", "single"}
model.BROWSE_KEY = "explorer_browse"

-- Arrange Icons: by name (the default), type, size, date.
model.SORT_KEYS = {"name", "type", "size", "date"}

-- A path is a string, and its whole grammar is here, because three parties
-- read it: the window (to know what to draw), the sources (to know what to
-- read) and the "Up" button (to know where to go back to). Were they to
-- diverge, "Up" would lead somewhere other than where a double click leads.
--
--   ""                    the root of "My Computer"
--   "wippy"               C: (Wippy), the filesystem collection
--   "programs"            the program catalog
--   "desktop"             the desktop, top level
--   "desktop/<id>"        a desktop folder
--   "windows"             open windows
--   "control"             the Control Panel
--   "drive/<entry>"       the root of a filesystem from the registry
--   "drive/<entry>/<path>"  a directory inside it
--   "disk/<letter>/<entry>"        a lettered disk of its own (C:)
--   "disk/<letter>/<entry>/<path>" a directory inside it
--
-- A lettered disk is one filesystem a module declares as a disk rather than
-- as a folder of the collection: it stands at the root beside D:, its
-- address reads `C:\...`, and "Up" from its root is My Computer.
--
-- A registry entry id is always `namespace:name`, and there can be no slash
-- in it; parsing the path inside a drive relies on exactly that.

-- disk_path(letter, entry, sub?) -> the path of a lettered disk.
--
-- Built in ONE place because three pure functions read it back — the address
-- bar, the window title and the "Up" button. A second formula would drift
-- from this one, and silently.
function model.disk_path(letter: any, entry: any, sub: any): string
    local text = "disk/" .. string.upper(tostring(letter or "")) .. "/" .. tostring(entry or "")
    if type(sub) == "string" and sub ~= "" then text = text .. "/" .. sub end
    return text
end
function model.parse(path: any)
    local text = type(path) == "string" and path or ""

    if text == model.ROOT then return {view = "root"} end
    if text == model.WIPPY then return {view = "wippy"} end
    if text == "programs" then return {view = "programs"} end
    if text == "desktop" then return {view = "desktop"} end
    if text == "windows" then return {view = "windows"} end
    if text == model.CONTROL then return {view = "control"} end

    local folder = string.match(text, "^desktop/(.+)$")
    if folder then return {view = "desktop_folder", id = folder} end

    -- A lettered disk carries its letter IN the path, before the entry id.
    -- The alternative was to look the letter up in the registry, and then
    -- the address bar, the window title and the "Up" button — three pure
    -- functions of a path — would each need the registry to say where they
    -- are. A path that cannot be read on its own is not a path.
    local letter, disk, tail = string.match(text, "^disk/(%a)/([^/]+)(.*)$")
    if letter and disk then
        local inside = string.match(tostring(tail), "^/(.+)$")
        return {view = "disk", letter = letter, id = disk, sub = inside}
    end

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
-- address(path) -> the display address; internal filesystem IDs stay stable.
function model.address(path: any): string
    local where: any = model.parse(path)
    if where.view == "root" then return "My Computer" end
    if where.view == "wippy" then return model.WIPPY_LETTER .. ":\\" end
    if where.view == "programs" then return "My Computer\\Programs" end
    if where.view == "desktop" then return "My Computer\\Desktop" end
    if where.view == "desktop_folder" then return "My Computer\\Desktop\\" .. tostring(where.id) end
    if where.view == "windows" then return "My Computer\\Open Windows" end
    -- The Control Panel is not on a disk: it stands in My Computer beside the
    -- disks, as it did in the original.
    if where.view == "control" then return "My Computer\\" .. model.CONTROL_TITLE end
    if where.view == "drive" then
        local text = "D:\\" .. tostring(where.id)
        if where.sub then text = text .. "\\" .. tostring(where.sub):gsub("/", "\\") end
        return text
    end
    -- A lettered disk reads as a disk: `C:\PROGRAMS\CHICAGO`. The entry id
    -- is not in the address — the letter is what the person was given, and
    -- the id is in the status line, as it is for the collection's folders.
    if where.view == "disk" then
        local text = string.upper(tostring(where.letter)) .. ":\\"
        if where.sub then text = text .. tostring(where.sub):gsub("/", "\\") end
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
    if where.view == "control" then return model.ROOT end

    if where.view == "drive" then
        if not where.sub then return model.WIPPY end
        local up = string.match(tostring(where.sub), "^(.+)/[^/]+$")
        if up then return "drive/" .. tostring(where.id) .. "/" .. up end
        return "drive/" .. tostring(where.id)
    end

    -- A lettered disk stands at the root, beside the collection: above C:
    -- is "My Computer", not D:. Sending it up into the collection would put
    -- a person somewhere they have never been.
    if where.view == "disk" then
        if not where.sub then return model.ROOT end
        local up = string.match(tostring(where.sub), "^(.+)/[^/]+$")
        return model.disk_path(where.letter, where.id, up)
    end

    return model.ROOT
end

-- An object: what is visible (title, icon, detail) and what happens on a
-- double click (open). Double, not single: a program that starts on one
-- click is a trap, and the original does not have it either.
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
        -- A disk's letter: My Computer lists its disks by letter, A: before C:,
        -- not by caption, where "(C:)" would sort before "3½ Floppy (A:)".
        letter = fields.letter,
        detail = fields.detail,
        open = fields.open,
        -- The Details columns (FR-008 §4): bytes, Unix seconds, the Type
        -- text and the Control Panel's comment. Named at assembly, where the
        -- file type registry is at hand, so `details` stays a pure format.
        size = fields.size, modified = fields.modified,
        type_name = fields.type_name, comment = fields.comment,
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

            -- A caption and a picture of the module's own, the same way the
            -- Control Panel has them: `meta.title` is what the person is
            -- meant to read ("Program Files"), while the entry name stays the
            -- address. Without them the name IS the caption, as before.
            local meta: any = type(record.meta) == "table" and record.meta or {}
            local caption: any = nil
            if type(meta.title) == "string" and meta.title ~= "" then caption = meta.title end
            local picture: any = nil
            if type(meta.image) == "string" and meta.image ~= "" then picture = meta.image end

            -- Only unnamed folders count towards a collision: a named one is
            -- no longer told apart by its entry name, and lengthening the
            -- neighbour because of it would explain nothing.
            if not caption then seen[name] = (seen[name] or 0) + 1 end
            drives[#drives + 1] = {
                id = record.id, name = name, space = space, kind = record.kind,
                caption = caption, image = picture,
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
            title = drive.caption or (ambiguous and (drive.space .. " " .. drive.name) or drive.name),
            icon = model.DRIVE_ICON,
            image = drive.image,
            -- The entry kind is the answer to "why doesn't it open": `fs.embed`
            -- is frozen into the module and is read-only, `fs.directory` is a
            -- real directory on disk.
            detail = drive.id .. " · " .. tostring(drive.kind or "fs"),
            type_name = drive.kind == "fs.embed" and "Read-only Disk" or "Local Disk",
            open = {action = "folder", path = "drive/" .. drive.id},
        })
    end
    return out
end

-- The contents of a directory inside a drive. `entries` is what `readdir`
-- returned — a name and a kind — plus the `size` (bytes) and `modified`
-- (Unix seconds) the sources took with a `stat` per row for the Details view
-- (FR-008 §4). A row whose `stat` failed has neither, and Details shows empty
-- cells for it rather than a zero.
--
-- file_type(programs, name) -> the Type column of a file: the handling
-- program's document name (`meta.file_type`, "Text Document"), else its title
-- with `Document`; `<EXT> File` for an unknown type; `File` without an
-- extension.
function model.file_type(programs: any, name: any): string
    local program: any = associations.find(programs, name)
    if program then
        if type(program.file_type) == "string" and program.file_type ~= "" then return program.file_type end
        return tostring(program.title) .. " Document"
    end
    local ext = files.ext(name)
    if ext ~= "" then return ext:upper() .. " File" end
    return "File"
end

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
            rows[#rows + 1] = {name = record.name, dir = record.type == "directory",
                size = tonumber(record.size), modified = tonumber(record.modified)}
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
                modified = row.modified,
                type_name = "File Folder",
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
                size = row.size, modified = row.modified,
                type_name = model.file_type(programs, row.name),
                open = open,
            })
        end
    end
    return out
end

-- The Control Panel folder object of the root.
function model.control_folder(): any
    return object({
        id = model.CONTROL,
        kind = "folder",
        title = model.CONTROL_TITLE,
        icon = model.DIR_ICON,
        image = model.CONTROL_IMAGE,
        detail = model.CONTROL_TITLE,
        type_name = "System Folder",
        open = {action = "folder", path = model.CONTROL},
    })
end

-- Keep drives() as the filesystem descriptor API used by file dialogs.
-- Explorer presents these same resources as folders inside the Wippy disk.
function model.wippy(records: any)
    local out = model.drives(records)
    for _, item in ipairs(out) do
        item.kind = "folder"
        item.icon = model.DIR_ICON
        -- A picture the entry asked for stays: `meta.image` is how a module
        -- says "this folder is not a plain one". The rest get the plain
        -- folder, as they did.
        item.image = item.image or "folder"
        item.type_name = "File Folder"
    end
    return out
end

-- letter_of(caption) -> "A" for "3½ Floppy (A:)" | nil
--
-- The letter a caption already carries, for a disk that does not name one
-- in `data.letter`. A disk with no letter anywhere is not given one: an
-- invented letter would be a path that points at nothing.
local function letter_of(caption: any): any
    local found = string.match(tostring(caption or ""), "%((%a):%)")
    if found then return string.upper(found) end
    return nil
end

-- My Computer: the disks, then the Control Panel.
--
-- D: is the collection of the registry's filesystems. The other disks are
-- declared by modules (`meta.type: chicago.drive`). The Control Panel stands
-- here, beside the disks, as it did in the original — it is not a folder on
-- any disk.
function model.root(records: any)
    local out = {object({
        id = model.WIPPY, kind = "drive", title = model.WIPPY_TITLE, letter = model.WIPPY_LETTER,
        icon = model.DRIVE_ICON, image = model.WIPPY_IMAGE,
        detail = "Wippy filesystems — what the installed modules brought",
        type_name = "CD-ROM Disc", open = {action = "folder", path = model.WIPPY},
    })}
    for _, record in ipairs(type(records) == "table" and records or {}) do
        local meta, data = record.meta or {}, record.data or {}
        local letter = type(data.letter) == "string" and data.letter ~= "" and string.upper(data.letter)
            or letter_of(meta.title)
        if meta.type == "chicago.drive" and type(data.entry) == "string" and data.entry ~= "" then
            out[#out + 1] = object({
                id = record.id, kind = "drive", title = tostring(meta.title or record.id), letter = letter,
                icon = model.DRIVE_ICON, image = meta.image or "drive", detail = tostring(meta.comment or meta.title or record.id),
                type_name = "Removable Disk", open = {action = "open_window", entry = data.entry, args = data.args},
            })
        -- The other kind of disk: a filesystem shown as a disk of its own,
        -- browsed by the same folder window as everything else. `data.fs`
        -- names the filesystem entry; the letter is `data.letter` or the one
        -- the caption carries. Without a letter it has no path, and it is not
        -- shown rather than shown under a letter nobody gave it.
        elseif meta.type == "chicago.drive" and type(data.fs) == "string" and data.fs ~= "" and letter then
            out[#out + 1] = object({
                id = record.id, kind = "drive", title = tostring(meta.title or record.id), letter = letter,
                icon = model.DRIVE_ICON, image = meta.image or "drive",
                detail = tostring(meta.comment or data.fs),
                type_name = "Local Disk",
                open = {action = "folder", path = model.disk_path(letter, data.fs)},
            })
        end
    end
    out[#out + 1] = model.control_folder()
    return out
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

-- control(programs) -> the Control Panel's objects: the programs of the
-- catalog's `Settings` group, each opening its own window, sorted by title.
-- The catalog carries each entry's `meta.comment` (the Details Comment
-- column); an entry without one shows its id instead.
function model.control(programs: any)
    local out: any = {}
    for _, item in ipairs(type(programs) == "table" and programs or {}) do
        local program: any = item
        local group: any = program.group
        if type(group) == "table" and group[1] == model.SETTINGS_GROUP then
            local comment: any = type(program.comment) == "string" and program.comment ~= "" and program.comment or nil
            out[#out + 1] = object({
                id = program.entry,
                kind = "program",
                title = program.title,
                icon = program.icon or model.DEFAULT_ICON,
                image = program.image, entry = program.entry,
                detail = comment or program.entry,
                comment = comment,
                type_name = "Control Panel item",
                open = {
                    action = "open_window",
                    entry = program.entry,
                    title = program.title,
                    w = program.width,
                    h = program.height,
                },
            })
        end
    end
    table.sort(out, function(left: any, right: any)
        local a, b = tostring(left.title):lower(), tostring(right.title):lower()
        if a ~= b then return a < b end
        return tostring(left.id) < tostring(right.id)
    end)
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

-- ─── folder windows (FR-008 §3) ───────────────────────────────────────────

-- start(args) -> path, notice
--
-- Where a folder window starts: `args` is the path it was opened for. None →
-- the root. A path the grammar does not know → the root AND a notice saying
-- so: a silent fallback would turn a bad argument into My Computer, and the
-- person would take it for the folder they asked for.
function model.start(args: any): (string, any)
    if args == nil or args == "" then return model.ROOT, nil end
    if type(args) ~= "string" then return model.ROOT, "not a folder path: " .. tostring(args) end
    if model.parse(args).view == "unknown" then return model.ROOT, "unknown folder: " .. args end
    return args, nil
end

-- title(path) -> the window's title: `My Computer`, the drive's caption (the
-- entry name, as `model.drives` shows an unambiguous one), the last segment
-- of a folder, `Control Panel`.
function model.folder_title(path: any): string
    local where: any = model.parse(path)
    if where.view == "root" then return "My Computer" end
    if where.view == "wippy" then return model.WIPPY_TITLE end
    if where.view == "control" then return model.CONTROL_TITLE end
    if where.view == "programs" then return "Programs" end
    if where.view == "desktop" then return "Desktop" end
    if where.view == "windows" then return "Open Windows" end
    if where.view == "desktop_folder" then return tostring(where.id) end
    if where.view == "drive" then
        if where.sub then return tostring(where.sub):match("([^/]+)$") or tostring(where.sub) end
        return tostring(where.id):match(":(.+)$") or tostring(where.id)
    end
    -- A lettered disk is titled by its letter at the root and by the folder
    -- name inside it — `C:\` and then `PROGRAMS`, as the original titled them.
    if where.view == "disk" then
        if where.sub then return tostring(where.sub):match("([^/]+)$") or tostring(where.sub) end
        return string.upper(tostring(where.letter)) .. ":\\"
    end
    return tostring(path or "")
end

-- image(path) -> the title bar's picture: `my_computer` at the root, `drive`
-- for a drive, the Control Panel's own, `folder_open` for any folder.
function model.folder_image(path: any): string
    local where: any = model.parse(path)
    if where.view == "root" then return "my_computer" end
    if where.view == "control" then return model.CONTROL_IMAGE end
    if where.view == "wippy" then return model.WIPPY_IMAGE end
    -- The root of a lettered disk is a disk; a folder inside it is a folder.
    if where.view == "disk" and not where.sub then return "drive" end
    return "folder_open"
end

-- open_folder(path, listing, title?) -> intent
--
-- Opening a folder in the separate-window mode. `listing` is the windows of
-- `desktop.list`: a folder window already open for the same path is focused
-- instead of opening a second one, as the original raised it. `title`
-- overrides the caption the path alone gives (an ambiguous drive's caption,
-- a desktop folder's title). A window opened without args is the root.
function model.open_folder(path: any, listing: any, title: any): any
    local target = type(path) == "string" and path or model.ROOT
    for _, item in ipairs(type(listing) == "table" and listing or {}) do
        local window: any = item
        if window.entry == model.EXPLORER and (window.args or model.ROOT) == target then
            return {action = "focus", id = window.id}
        end
    end
    return {
        action = "open_window",
        entry = model.EXPLORER,
        title = type(title) == "string" and title ~= "" and title or model.folder_title(target),
        image = model.folder_image(target),
        args = target,
    }
end

-- ─── browse mode ─────────────────────────────────────────────────────────

function model.is_browse(mode: any): boolean
    for _, known in ipairs(model.BROWSE) do
        if mode == known then return true end
    end
    return false
end

-- browse_mode(value) -> a known mode; anything else (never set, a stray
-- value) is the default, `separate`.
function model.browse_mode(value: any): string
    if model.is_browse(value) then return tostring(value) end
    return model.BROWSE[1]
end

-- ─── Details (FR-008 §4) ──────────────────────────────────────────────────

local function is_folder(item: any): boolean
    return item.kind == "directory" or item.kind == "folder" or item.kind == "drive"
end

local function grouped(digits: string): string
    local out, count = digits, 0
    repeat
        out, count = out:gsub("^(%d+)(%d%d%d)", "%1,%2")
    until count == 0
    return out
end

-- size_text(bytes) -> `133KB`: whole kilobytes rounded up, as the original's
-- Details did (`0KB` for an empty file, `1KB` for a few bytes), thousands
-- grouped with a comma. nil → "".
function model.size_text(bytes: any): string
    local number = tonumber(bytes)
    if number == nil then return "" end
    local kb = math.tointeger(math.ceil(math.max(0, number) / 1024)) or 0
    return grouped(tostring(kb)) .. "KB"
end

local function two(value: any): string
    local text = tostring(math.tointeger(value) or value)
    if #text < 2 then return "0" .. text end
    return text
end

-- date_text(when) -> `7/11/95 9:50 AM`, the US short form. `when` is Unix
-- seconds (local time) or a date table {year, month, day, hour, min}.
function model.date_text(when: any): string
    local t: any = when
    if type(when) == "number" then t = os.date("*t", math.tointeger(when) or math.floor(when)) end
    if type(t) ~= "table" or t.year == nil then return "" end
    local hour = math.tointeger(t.hour or 0) or 0
    local shown = hour % 12
    if shown == 0 then shown = 12 end
    return tostring(math.tointeger(t.month)) .. "/" .. tostring(math.tointeger(t.day)) .. "/"
        .. two((math.tointeger(t.year) or 0) % 100) .. " " .. tostring(shown) .. ":" .. two(t.min or 0)
        .. (hour < 12 and " AM" or " PM")
end

local function type_of(item: any): string
    if type(item.type_name) == "string" and item.type_name ~= "" then return item.type_name end
    if is_folder(item) then return "File Folder" end
    if item.kind == "shortcut" then return "Shortcut" end
    if item.kind == "program" then return "Application" end
    return "File"
end

-- details(object) -> {name, size, type, modified, comment}: the cells of a
-- Details row. A folder has no size; a cell the reader could not fill is
-- empty, never a zero.
function model.details(item: any): any
    local folder = is_folder(item)
    return {
        name = tostring(item.title or item.id or ""),
        size = folder and "" or model.size_text(item.size),
        type = type_of(item),
        modified = item.modified ~= nil and model.date_text(item.modified) or "",
        comment = type(item.comment) == "string" and item.comment or "",
    }
end

-- sort(objects, key) -> a new list: drives first, then folders, then files —
-- My Computer listed its drives before the Control Panel — then by the key —
-- `name` (the default), `type`, `size`, `date` — then by name; stable for rows
-- the rule does not tell apart.
function model.sort(objects: any, key: any): any
    local rows: any = {}
    for index, item in ipairs(type(objects) == "table" and objects or {}) do
        rows[#rows + 1] = {item = item, index = index}
    end
    local by = key
    if by ~= "type" and by ~= "size" and by ~= "date" then by = "name" end
    local function name_of(item: any): string return tostring(item.title or item.id or ""):lower() end
    local function rank(item: any): integer
        if item.kind == "drive" then return 0 end
        if is_folder(item) then return 1 end
        return 2
    end
    table.sort(rows, function(left: any, right: any)
        local a, b = left.item, right.item
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        -- Disks go by letter whatever the key, as the original listed them:
        -- A:, C:, D:. A disk without a letter goes after the lettered ones.
        if ra == 0 and (a.letter or b.letter) and a.letter ~= b.letter then
            if not a.letter then return false end
            if not b.letter then return true end
            return tostring(a.letter) < tostring(b.letter)
        end
        if by == "type" then
            local ta, tb = type_of(a):lower(), type_of(b):lower()
            if ta ~= tb then return ta < tb end
        elseif by == "size" then
            local sa, sb = tonumber(a.size) or 0, tonumber(b.size) or 0
            if sa ~= sb then return sa < sb end
        elseif by == "date" then
            local da, db = tonumber(a.modified) or 0, tonumber(b.modified) or 0
            if da ~= db then return da < db end
        end
        local na, nb = name_of(a), name_of(b)
        if na ~= nb then return na < nb end
        return left.index < right.index
    end)
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = row.item end
    return out
end

-- ─── selection (FR-008 §4) ────────────────────────────────────────────────
--
-- A selection is a set `{[id] = true}` over the objects in VIEW order. The
-- anchor is the index a Shift range starts from.

local function key_of(item: any): string
    return tostring(item.id)
end

local function copy_set(selection: any): any
    local out = {}
    for id, on in pairs(type(selection) == "table" and selection or {}) do
        if on then out[id] = true end
    end
    return out
end

-- select(selection, objects, index, {ctrl, shift, anchor}) -> selection, anchor
--
-- A click selects one; Ctrl+click toggles one; Shift+click selects the range
-- from the anchor (Ctrl+Shift adds it to what is selected); a click on the
-- empty field (no object at `index`) clears, unless Ctrl is held.
function model.select(selection: any, objects: any, index: any, mods: any): (any, any)
    local list: any = type(objects) == "table" and objects or {}
    local keys: any = type(mods) == "table" and mods or {}
    local at = math.tointeger(tonumber(index) or 0) or 0
    local item: any = list[at]
    if item == nil then
        if keys.ctrl then return copy_set(selection), keys.anchor end
        return {}, nil
    end
    local anchor = math.tointeger(tonumber(keys.anchor) or 0) or 0
    if keys.shift and list[anchor] ~= nil then
        local out: any = keys.ctrl and copy_set(selection) or {}
        for step = math.min(anchor, at), math.max(anchor, at) do out[key_of(list[step])] = true end
        return out, anchor
    end
    if keys.ctrl then
        local out: any = copy_set(selection)
        local id = key_of(item)
        if out[id] then out[id] = nil else out[id] = true end
        return out, at
    end
    return {[key_of(item)] = true}, at
end

function model.select_all(objects: any): any
    local out = {}
    for _, item in ipairs(type(objects) == "table" and objects or {}) do out[key_of(item)] = true end
    return out
end

function model.invert(selection: any, objects: any): any
    local set: any = type(selection) == "table" and selection or {}
    local out = {}
    for _, item in ipairs(type(objects) == "table" and objects or {}) do
        local id = key_of(item)
        if not set[id] then out[id] = true end
    end
    return out
end

-- selected_summary(selection, objects) -> the status bar's right field: the
-- single object's detail; `N object(s) selected` with the selected files'
-- size when there are more; "" for none.
function model.selected_summary(selection: any, objects: any): string
    local set: any = type(selection) == "table" and selection or {}
    local count, bytes, sized, single = 0, 0, false, nil
    for _, entry in ipairs(type(objects) == "table" and objects or {}) do
        local item: any = entry
        if set[key_of(item)] then
            count = count + 1
            single = item
            local size = tonumber(item.size)
            if not is_folder(item) and size ~= nil then
                bytes = bytes + size
                sized = true
            end
        end
    end
    if count == 0 then return "" end
    if count == 1 then return tostring(single.detail or "") end
    local text = tostring(count) .. " object(s) selected"
    if sized then text = text .. ", " .. model.size_text(bytes) end
    return text
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
