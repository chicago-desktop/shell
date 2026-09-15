-- Where "My Computer" gets its objects from.
--
-- Separated from assembling the objects on purpose: the assembly is a pure
-- rule and is checked without a live database, while here there is only
-- reading. A rule that can be checked only through the database gets checked
-- once, and then never.
--
-- Exactly four things are read, and all of them are either our own or
-- shared:
--
--   drives           the registry's `fs.*` entries, and their contents via the `fs` module
--   programs         the registry catalog, the same one that fills the "Start" menu
--   desktop          our own layout table
--   desktop folder   the same table, rows with this parent
--
-- There are no other modules' tables here and there will not be. Reading a
-- neighbouring module's table means taking a dependency on its schema — and
-- breaking on ITS migration, silently, not in our own code, and a week later.
--
-- Open windows are NOT here, and this is not an omission. The window list
-- lives with the compositor, and it can be asked only by a message with the
-- reply going to one's own inbox. Inside a window that cannot be done: a
-- waiting loop takes OTHER messages from the inbox too, and throwing away a
-- message addressed to the window means losing a compositor command without
-- a trace. So the window list is brought by the window process itself: its
-- loop owns the inbox and handles the reply along with everything else, and
-- `model.windows` turns what was brought into objects.

local fs = require("fs")
local registry = require("registry")

local catalog = require("catalog")
local model = require("model")
local repo = require("repo")

local sources = {}

-- The entry kinds the shell considers a drive. There are two of them, and
-- both are real: `fs.directory` is a directory on disk, `fs.embed` is files
-- frozen into the module at build time. We do not invent a third kind: a
-- drive that is not in the registry must not be drawn.
sources.DRIVE_KINDS = model.DRIVE_KINDS

-- The cap on a single directory read. A directory with ten thousand files
-- would build ten thousand objects for the sake of the three rows that fit
-- in the window. The cut is NOT silent: a truncated list says so itself,
-- otherwise "everything is shown" and "the beginning is shown" look the
-- same.
sources.FILE_LIMIT = 500

-- drives() -> (entries, nil) | (nil, reason)
--
-- A registry failure and "there are no drives" are different outcomes, as
-- everywhere here. An empty list on failure would say "no filesystems are
-- declared on the running system", that is, a claim we did not make.
function sources.drives()
    local out = {}
    for _, kind in ipairs(sources.DRIVE_KINDS) do
        local found, err = registry.find({[".kind"] = kind})
        if err then return nil, "registry not read: " .. tostring(err) end
        if type(found) ~= "table" then
            return nil, "registry not read: the answer is not a list"
        end
        for _, record in ipairs(found) do out[#out + 1] = record end
    end
    return out, nil
end

-- The contents of a directory inside a drive.
--
-- Read with the `fs` module under the window's own permissions: the window
-- has no access to the machine's filesystem, it has access to the registry
-- entry named as a drive. A drive that is declared but inaccessible answers
-- with a REASON, not with emptiness: an empty directory and a closed door are
-- different things, and a person must see the second one in words.
local function read_drive(id: any, sub: any)
    local handle, err = fs.get(tostring(id))
    if err or not handle then
        return nil, "drive not opened: " .. tostring(err or "no such entry")
    end

    local path = "/"
    if type(sub) == "string" and sub ~= "" then path = "/" .. sub end

    local iterator, state = handle:readdir(path)
    if type(iterator) ~= "function" then
        return nil, "catalog not read: " .. tostring(state)
    end

    local entries, cut = {}, false
    for entry in iterator, state do
        if #entries >= sources.FILE_LIMIT then
            cut = true
            break
        end
        entries[#entries + 1] = entry
    end

    -- Size and date for the Details view (FR-008 §4): `readdir` gives only a
    -- name and a kind, so each row costs one `stat` — at most FILE_LIMIT of
    -- them. A row whose `stat` failed keeps neither, and Details leaves its
    -- cells empty rather than showing a zero.
    local base = path == "/" and "" or path
    local rows = {}
    for _, entry in ipairs(entries) do
        local record: any = entry
        local row: any = {name = record.name, type = record.type}
        local info: any = handle:stat(base .. "/" .. tostring(record.name))
        if type(info) == "table" then
            row.size = tonumber(info.size)
            row.modified = tonumber(info.modified)
        end
        rows[#rows + 1] = row
    end

    return rows, nil, cut
end

-- browse() -> mode, reason
--
-- How folders open (FR-008 §3): `separate` (the default) or `single`, from
-- the shell's settings under `explorer_browse`. An unreadable setting is the
-- default AND a reason: the window still opens folders, and says why it did
-- not honour a choice.
function sources.browse(): (string, any)
    local value, err = repo.of(repo.person()).setting(model.BROWSE_KEY)
    if err then return model.BROWSE[1], "browse mode not read: " .. tostring(err) end
    return model.browse_mode(value), nil
end

-- set_browse(mode) -> true | nil, reason. An unknown mode is refused, not
-- stored: a stray value would read back as the default and look like a save
-- that did not happen.
function sources.set_browse(mode: any): (any, any)
    if not model.is_browse(mode) then return nil, "unknown browse mode: " .. tostring(mode) end
    local ok, err = repo.of(repo.person()).set_setting(model.BROWSE_KEY, mode)
    if not ok then return nil, "browse mode not saved: " .. tostring(err) end
    return true, nil
end

-- list(path, context) -> (view, nil) | (nil, reason)
--
-- View: { objects = list, title = title, notice = notice | nil }.
--
-- A failure and an empty folder differ in the FIRST value: an empty folder
-- is a view with an empty list, an unreadable source is nil and a reason.
-- Made identical, they send a person looking for a loss where nothing was
-- lost.
--
-- `notice` is a third state between them: read, but not everything. A notice
-- does not hide objects and does not pass itself off as a failure.
--
function sources.list(path, context: any)
    local where = model.parse(path)

    if where.view == "root" then
        local records, err = sources.drives()
        if err or not records then return nil, err or "drives not read" end
        return {objects = model.root(records), title = "My Computer"}, nil
    end

    if where.view == "programs" then
        local found, err = catalog.list()
        if err or not found then return nil, err or "catalog not read" end
        -- The same folder as the "Start" menu, just in a different view:
        -- here a person CHOOSES a program rather than looking it up by a
        -- link. A program that asked not to be shown in the menu is hidden
        -- here too — otherwise the flag means nothing but "I am missing from
        -- one of the two lists".
        return {objects = model.programs(catalog.listed(found.programs)),
                title = "Programs"}, nil
    end

    if where.view == "control" then
        local found, err = catalog.list()
        if err or not found then return nil, err or "catalog not read" end
        -- The programs the Start menu shows: a program hidden from the menu
        -- is hidden here too, as in the Programs view.
        return {objects = model.control(catalog.listed(found.programs)),
                title = model.CONTROL_TITLE}, nil
    end

    if where.view == "desktop" then
        -- The logged-on person's desktop, as their shell shows it.
        local items, err = repo.of(repo.person()).list()
        if err then return nil, "layout not read: " .. tostring(err) end
        -- The catalog is needed to tell a broken shortcut from a working
        -- one. Its failure does NOT hide the desktop: the objects are
        -- returned, just all without the broken flag — accusing a working
        -- program is worse than staying silent.
        local found = catalog.list()
        -- The top level is only what lies ON the desktop. Folder contents
        -- come back from the same read, and showing them here would mean
        -- showing every nested icon twice: in the folder and next to it.
        local top = {}
        for _, item in ipairs(items or {}) do
            if not (item :: any).parent_id then top[#top + 1] = item end
        end
        return {
            objects = model.desktop(top, found and found.programs or nil),
            title = "Desktop",
        }, nil
    end

    if where.view == "desktop_folder" then
        -- The logged-on person's desktop, as their shell shows it.
        local items, err = repo.of(repo.person()).list()
        if err then return nil, "layout not read: " .. tostring(err) end

        local folder: any = nil
        local inside = {}
        for _, entry in ipairs(items or {}) do
            local item: any = entry
            if item.id == where.id then folder = item end
            if item.parent_id == where.id then inside[#inside + 1] = item end
        end

        -- No folder is a failure, not an empty folder: silence would turn a
        -- typo in the path into a successfully opened emptiness.
        if not folder then return nil, "no such folder: " .. tostring(where.id) end
        if folder.kind ~= "folder" then
            return nil, "not a folder: " .. tostring(where.id)
        end

        local found = catalog.list()
        return {
            objects = model.desktop(inside, found and found.programs or nil),
            title = tostring(folder.title or "Folder"),
        }, nil
    end

    if where.view == "drive" then
        local entries, err, cut = read_drive(where.id, where.sub)
        if err or not entries then return nil, err or "drive not read" end

        local title = tostring(where.id)
        if where.sub then title = title .. "/" .. tostring(where.sub) end

        -- The catalog is needed by the files: the program for an extension
        -- and its icon come from the file type registry. A catalog failure
        -- does not hide the files — they remain "nothing to open it with",
        -- as they should without programs.
        local found = catalog.list()

        return {
            objects = model.files(entries, path, where.id, where.sub, found and found.programs or nil),
            title = title,
            notice = cut and ("showing the first " .. tostring(sources.FILE_LIMIT)) or nil,
        }, nil
    end

    return nil, "unknown folder: " .. tostring(path)
end

return sources
