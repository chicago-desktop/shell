-- The real Windows 95 icons — rasters from files, not primitives.
--
-- A 32×32 icon is a thousand pixels, and it cannot be drawn with primitives:
-- the silhouette is recognizable, the details are missing. Here the icons
-- arrive as PNG files from the folder `chicago.shell.theme:icon_files`
-- (assets/icons, see SOURCE.md in the same place), are decoded through
-- `gfx.image` and laid onto the theme's raster through `blit`.
--
-- Three rules it is built on:
--
--   * **The file arrives as BYTES through `fs`, not as a path inside
--     `gfx`.** The same decision as for the font: reading a file is governed
--     by the process's permissions, and a module that opened paths by itself
--     would be a road around them.
--   * **An icon has one name, and it is also the file name.** The table
--     `images.NAMES` is the only list of what is in the shell's own pack; the
--     test checks that every name decodes in both sizes. A name that is not
--     in the list is a refusal with a reason, not a silent skip: an icon that
--     "for some reason did not draw" gets looked for in the drawing, not in a
--     typo.
--   * **Pictures of other modules come in their own packs**, not in this
--     one: an `fs.*` entry that declares `meta.type: chicago.images`, and a
--     picture named `<entry id>/<file>` (see `images.PACK_TYPE`). The shell
--     does not list them — it finds the pack in the registry when a picture
--     is asked for.
--   * **A decoded raster lives as long as the process lives.** Rasters
--     outlive the frame (FR-005 §4): an icon decoded anew every frame would
--     be a new raster with the same version — and the surface would NOT
--     resend it. That is why the cache is here, not with the caller.
--
-- A failure to open the folder or a file is named and remembered: the theme
-- calls this every frame, and repeating `fs.get` sixty times a second for the
-- same "not allowed" is pointless. On a failure the caller draws primitives —
-- as it did before this file existed; the reason goes to the log here, once
-- per icon and size.

local fs = require("fs")
local gfx = require("gfx")
local registry = require("registry")
local time = require("time")
local logger = require("logger")
local log = logger:named("chicago.icons")

local images = {}

-- The registry entry with the icons' filesystem. The folder is declared in
-- the module (`base: module`), so the application does not need to set up
-- anything.
images.STORE = "chicago.shell.theme:icon_files"

-- The wallpapers — original pictures drawn by `tools/wallpapers.py`, in the
-- display module's folder (assets/wallpaper, original art, MIT). A
-- wallpaper has no sizes: the theme draws it at 1:1, tiled or centred.
images.WALLPAPER_STORE = "chicago.shell.display:wallpaper_files"

-- Packs of other modules and of the application: an `fs.*` entry that
-- declares this meta.type. Its pictures lie as `<size>/<file>.png`, and a
-- picture is named `<entry id>/<file>` — `app.workshop:images/mine`. The pack
-- is looked up in the registry when a picture is asked for, not when this
-- library loads, so a pack applied to the live registry, and a file added to
-- its folder, are drawn without touching the shell.
images.PACK_TYPE = "chicago.images"
-- How often a pack picture is looked at again: a refused one is asked again,
-- a read one is compared with its file. The same bytes keep the same raster
-- (the surface resends nothing); other bytes are decoded into a new one, so a
-- picture REPLACED in a pack's folder shows without a restart too.
images.PACK_RECHECK_SECONDS = 5
-- A pack's sizes are the folders its author drew; the largest one read.
images.PACK_MAX_SIZE = 256

-- The sizes the pack is built in. There are no other files in the folder,
-- and asking for another size is the caller's mistake, not a reason to
-- scale: `gfx` has no scaling on purpose, and a 16-color icon stretched by
-- one and a half times stops being that icon.
images.SIZES = {32, 16}

-- Everything in the pack. The order is as in SOURCE.md.
images.NAMES = {
    "calculator", "clock", "my_computer", "folder", "folder_open", "recycle_bin", "recycle_bin_full",
    "programs", "settings", "documents", "find", "help", "run", "shutdown",
    "program", "document", "text_document",
    "drive", "floppy", "cdrom", "network_drive", "printer",
    "control_panel", "fonts", "desktop", "windows", "shortcut_overlay",
    "network", "network_neighborhood", "documents_stack", "program_settings", "system",
    "regedit", "regedit_string", "regedit_binary",
    "key",
    "appwizard", "taskmgr", "console", "user", "display_properties", "notepad", "dialup",
}

-- pack_of(name) -> pack entry id, file | nil
--
-- `app.workshop:images/mine` → `app.workshop:images`, `mine`. The file is one
-- path segment of letters, digits, `_` and `-`: a name is not a path, and
-- `..` never reaches the filesystem.
function images.pack_of(name: any): (any, any)
    if type(name) ~= "string" then return nil, nil end
    local id, file = name:match("^([%w_%.%-]+:[%w_%.%-]+)/([%w_%-]+)$")
    return id, file
end

local known = {}
for _, name in ipairs(images.NAMES) do known[name] = true end

-- A shortcut to the explorer window is "My Computer", not a program with an
-- arrow. The same special entry as in `pixels.icon`.
local EXPLORER = "chicago.shell.explorer:window"

-- Item kind → icon name. One table for all the places where an icon is
-- needed (the desktop, the "Start" menu, the explorer list): each has its
-- own painter, but the name is decided here, otherwise a folder on the
-- desktop and a folder in the explorer will one day turn out to be
-- different folders.
local BY_KIND = {
    folder = "folder",
    directory = "folder",
    group = "folder",
    drive = "drive",
    program = "program",
    window = "program",
    item = "document",
    file = "document",
}

-- name_for(item) -> icon name, overlay name or nil
--
-- An explicit `item.image` beats the kind: a registry entry that declared
-- `meta.image: printer` gets a printer. An unknown name is not replaced with
-- "something similar" — it is returned as is, and `get` will refuse with a
-- reason.
function images.name_for(item: any): (any, any)
    if type(item) ~= "table" or item.broken then return nil, nil end
    local explicit: any = item.image
    if type(explicit) == "string" and explicit ~= "" then
        return explicit, nil
    end
    if item.entry == EXPLORER then return "my_computer", nil end
    local kind: any = item.kind
    if kind == "shortcut" then
        return "program", "shortcut_overlay"
    end
    return BY_KIND[kind], nil
end

-- One opened folder (or its remembered failure) per store id.
local stores: any = {}
local store_failures: any = {}
local cache: any = {}

local function open_store(id: string): (any, any)
    if stores[id] then return stores[id], nil end
    if store_failures[id] then return nil, store_failures[id] end
    local opened, err = fs.get(id)
    if err or not opened then
        store_failures[id] = "icon folder not opened (" .. id .. "): " .. tostring(err)
        return nil, store_failures[id]
    end
    stores[id] = opened
    return opened, nil
end

-- open_pack(id) -> filesystem or nil, reason
--
-- The pack is checked in the registry, not trusted by its name: a window
-- names the picture, and an `fs` entry that did not declare itself a pack (a
-- drive of the stand, someone's data) is not read as one. Only an opened
-- pack is kept; a refusal is kept by `fail`, with a retry.
local function open_pack(id: string): (any, any)
    if stores[id] then return stores[id], nil end
    local entry, err = registry.get(id)
    if not entry then
        return nil, "no image pack " .. id .. ": " .. tostring(err or "not in the registry")
    end
    local meta: any = type(entry.meta) == "table" and entry.meta or {}
    if meta.type ~= images.PACK_TYPE then
        return nil, "entry " .. id .. " is not an image pack: it does not declare meta.type " .. images.PACK_TYPE
    end
    local opened, ferr = fs.get(id)
    if ferr or not opened then
        return nil, "image pack " .. id .. " not opened: " .. tostring(ferr)
    end
    stores[id] = opened
    return opened, nil
end

-- fail(key, pack, why) -> nil, why
--
-- A refusal is remembered: the theme asks every frame. A picture of the
-- shell's own pack stays refused until `forget` — its files do not change
-- while the shell runs. A pack picture is asked again after
-- `PACK_RECHECK_SECONDS`: the pack may be applied to the registry, or the file
-- added to its folder, a minute later, and it must show up then.
local function fail(key: string, pack: any, why: string): (any, any)
    if pack then
        cache[key] = {check_at = time.now():unix() + images.PACK_RECHECK_SECONDS, why = why}
    else
        cache[key] = false
    end
    return nil, why
end

-- get(name, size) -> raster or nil, reason
--
-- The raster is shared by all callers and must not change: `blit` reads from
-- it, and that is enough. Whoever draws into it spoils the icon for
-- everyone.
function images.get(name: any, size: any): (any, any)
    local pack, file = images.pack_of(name)
    if not pack and (type(name) ~= "string" or not known[name]) then
        return nil, "no such icon: " .. tostring(name)
    end
    local px = math.tointeger(tonumber(size) or 0) or 0
    local sized = false
    if pack then
        sized = px >= 1 and px <= images.PACK_MAX_SIZE
    else
        for _, allowed in ipairs(images.SIZES) do
            if allowed == px then sized = true end
        end
    end
    if not sized then
        return nil, "no icons of size " .. tostring(size) .. " in the package"
    end

    local key = tostring(name) .. "@" .. tostring(px)
    local cached: any = cache[key]
    if cached == false then return nil, "icon " .. key .. " not read (see the first failure)" end
    if type(cached) == "table" then
        -- A pack picture, read or refused, until it is looked at again.
        if time.now():unix() < cached.check_at then
            if cached.raster then return cached.raster, nil end
            return nil, cached.why
        end
    elseif cached ~= nil then
        return cached, nil
    end

    local opened: any, why: any = nil, nil
    if pack then
        opened, why = open_pack(tostring(pack))
        if not opened then return fail(key, pack, tostring(why)) end
    else
        opened, why = open_store(images.STORE)
        if not opened then return nil, why end
    end

    local path = tostring(px) .. "/" .. tostring(file or name) .. ".png"
    local where = pack and (" from " .. pack) or ""
    local data, read_err = opened:readfile(path)
    if read_err or not data then
        return fail(key, pack, "icon " .. path .. " not read" .. where .. ": " .. tostring(read_err))
    end
    -- A pack picture whose file has not changed keeps its raster.
    if pack and type(cached) == "table" and cached.raster and cached.bytes == data then
        cached.check_at = time.now():unix() + images.PACK_RECHECK_SECONDS
        return cached.raster, nil
    end
    -- `opened` is typed as any, and readfile returns any; the linter is right
    -- that a string has to be named a string rather than guessed.
    local raster, decode_err = gfx.image(data :: string)
    if not raster then
        return fail(key, pack, "icon " .. path .. where .. " not decoded: " .. tostring(decode_err))
    end
    local w, h = raster:size()
    if w ~= px or h ~= px then
        return fail(key, pack, string.format("icon %s%s is %dx%d, expected %dx%d", path, where, w, h, px, px))
    end
    if pack then
        cache[key] = {raster = raster, bytes = data, check_at = time.now():unix() + images.PACK_RECHECK_SECONDS}
    else
        cache[key] = raster
    end
    return raster, nil
end

-- wallpaper(file) -> raster or nil, reason
--
-- `wallpaper_*.png` from the wallpaper folder, decoded once and shared like an
-- icon: whoever draws into it spoils it for everyone.
function images.wallpaper(file: any): (any, any)
    if type(file) ~= "string" or not file:match("^wallpaper_[%w_]+$") then
        return nil, "no such wallpaper: " .. tostring(file)
    end
    local key = "wallpaper:" .. file
    local cached: any = cache[key]
    if cached ~= nil then
        if cached == false then return nil, "wallpaper " .. file .. " not read (see the first failure)" end
        return cached, nil
    end
    local opened, why = open_store(images.WALLPAPER_STORE)
    if not opened then return nil, why end
    local data, read_err = opened:readfile(file .. ".png")
    if read_err or not data then
        cache[key] = false
        return nil, "wallpaper " .. file .. " not read: " .. tostring(read_err)
    end
    local raster, decode_err = gfx.image(data :: string)
    if not raster then
        cache[key] = false
        return nil, "wallpaper " .. file .. " not decoded: " .. tostring(decode_err)
    end
    cache[key] = raster
    return raster, nil
end

-- Failures already told to the log: the theme calls `icon` every frame, and
-- the same reason sixty times a second would drown the log.
local reported = {}

-- icon(raster, x, y, item, size) -> true or nil, reason
--
-- Puts the item's icon (and the shortcut overlay, when due) into the theme's
-- raster. The coordinate is the top left corner, as everywhere in `gfx`. A
-- failure is a reason to draw primitives, not emptiness; the reason goes to
-- the log once.
function images.icon(raster: any, x: any, y: any, item: any, size: any): (any, any)
    local name, overlay = images.name_for(item)
    if not name then return nil, "the item has no icon in the package" end
    local px = math.tointeger(tonumber(size) or 32) or 32
    local picture, why = images.get(name, px)
    if not picture then
        local key = tostring(name) .. "@" .. tostring(px)
        if not reported[key] then
            reported[key] = true
            log:warn("icon not loaded", {icon = key, error = tostring(why)})
        end
        return nil, why
    end
    raster:blit(picture, x, y)
    if overlay then
        -- In Windows 95 the shortcut arrow sits in the bottom left corner of
        -- the icon.
        local arrow = images.get(overlay, 16)
        if arrow then
            local ax = math.tointeger(tonumber(x) or 1) or 1
            local ay = (math.tointeger(tonumber(y) or 1) or 1) + px - 16
            raster:blit(arrow, ax, ay)
        end
    end
    return true, nil
end

-- forget() — reset the cache; needed by tests and by a change of folder,
-- by no one else.
function images.forget()
    stores, store_failures, cache, reported = {}, {}, {}, {}
end

return images
