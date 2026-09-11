-- The real Windows 95 icons — rasters from files, not primitives.
--
-- A 32×32 icon is a thousand pixels, and it cannot be drawn with primitives:
-- the silhouette is recognizable, the details are missing. Here the icons
-- arrive as PNG files from the folder `butschster.windows.shell:icon_files`
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
--     `images.NAMES` is the only list of what is in the pack; the test checks
--     that every name decodes in both sizes. A name that is not in the list
--     is a refusal with a reason, not a silent skip: an icon that "for some
--     reason did not draw" gets looked for in the drawing, not in a typo.
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
local logger = require("logger")
local log = logger:named("windows.icons")

local images = {}

-- The registry entry with the icons' filesystem. The folder is declared in
-- the module (`base: module`), so the application does not need to set up
-- anything.
images.STORE = "butschster.windows.shell:icon_files"

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
    "appwizard", "taskmgr", "console", "user", "display_properties", "notepad",
}

local known = {}
for _, name in ipairs(images.NAMES) do known[name] = true end

-- A shortcut to the explorer window is "My Computer", not a program with an
-- arrow. The same special entry as in `pixels.icon`.
local EXPLORER = "butschster.windows.explorer:window"

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

local store: any = nil
local store_failure: any = nil
local cache = {}

local function open_store(): (any, any)
    if store then return store, nil end
    if store_failure then return nil, store_failure end
    local opened, err = fs.get(images.STORE)
    if err or not opened then
        store_failure = "icon folder not opened (" .. images.STORE .. "): " .. tostring(err)
        return nil, store_failure
    end
    store = opened
    return store, nil
end

-- get(name, size) -> raster or nil, reason
--
-- The raster is shared by all callers and must not change: `blit` reads from
-- it, and that is enough. Whoever draws into it spoils the icon for
-- everyone.
function images.get(name: any, size: any): (any, any)
    if type(name) ~= "string" or not known[name] then
        return nil, "no such icon: " .. tostring(name)
    end
    local px = math.tointeger(tonumber(size) or 0) or 0
    local sized = false
    for _, allowed in ipairs(images.SIZES) do
        if allowed == px then sized = true end
    end
    if not sized then
        return nil, "no icons of size " .. tostring(size) .. " in the package"
    end

    local key = name .. "@" .. tostring(px)
    local cached: any = cache[key]
    if cached ~= nil then
        if cached == false then return nil, "icon " .. key .. " not read (see the first failure)" end
        return cached, nil
    end

    local opened, why = open_store()
    if not opened then return nil, why end

    local path = tostring(px) .. "/" .. name .. ".png"
    local data, read_err = opened:readfile(path)
    if read_err or not data then
        cache[key] = false
        return nil, "icon " .. path .. " not read: " .. tostring(read_err)
    end
    -- `opened` is typed as any, and readfile returns any; the linter is right
    -- that a string has to be named a string rather than guessed.
    local raster, decode_err = gfx.image(data :: string)
    if not raster then
        cache[key] = false
        return nil, "icon " .. path .. " not decoded: " .. tostring(decode_err)
    end
    local w, h = raster:size()
    if w ~= px or h ~= px then
        cache[key] = false
        return nil, string.format("icon %s is %dx%d, expected %dx%d", path, w, h, px, px)
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
    store, store_failure, cache, reported = nil, nil, {}, {}
end

return images
