-- The program catalog: what can be launched.
--
-- There is one source — the registry: entries with `meta.type:
-- tui_desktop.window`, the same type the base reads, so that one entry works
-- in both shells. The shell deliberately keeps no copy of the list of its own
-- — a copy would mean that an installed module does not appear in the menu
-- until someone presses "refresh".
--
-- What gets into the MENU is not decided by this file: the rules for
-- `meta.in_menu` and `meta.window_type` live in the base's library, because
-- the base builds its own menu by them too. Two readings of the same meta
-- drift apart silently.
--
-- The main thing here is the shape of a failure. `list` returns DIFFERENT
-- values for "the registry was not read" (nil, reason) and for "there are no
-- programs" (an empty catalog, nil). Merged into one, they send the person to
-- look for the error in their own application, where there is none.

local registry = require("registry")
local programs_meta = require("programs_meta")

local catalog = {}

catalog.WINDOW_TYPE = "tui_desktop.window"
catalog.DEFAULT_ICON = "▢"

-- A menu deeper than three levels is not readable in a terminal: at the
-- fourth, the submenu runs off the right edge of the screen. Extra segments
-- do not drop the program but collapse it to the third level — losing a
-- program is worse than losing a folder.
catalog.MAX_DEPTH = 3

-- A program without `order` goes after the programs that have one, and among
-- themselves they are sorted alphabetically. The number is chosen to be
-- certainly larger than any reasonable order, but not infinity: with it, a
-- comparison of two orderless programs would give inf < inf = false in both
-- directions, and the order would depend on the form in which the registry
-- returned the list.
local NO_ORDER = 1e9

-- The folder for a program that did not name a folder. The root of "Start"
-- is as in the original: two folders, "Run…" and "Shut Down…"; a program that
-- wants to sit on the root says so explicitly — `group: ""`. Otherwise every
-- window built by the workshop over HTTP (it has no `meta.group` and nowhere
-- to get one from) would land on the root, and the root would grow with every
-- such window.
catalog.DEFAULT_GROUP = "Programs"

-- "System Tools/Network" -> {"System Tools", "Network"}. Empty segments are
-- thrown away: "System Tools//Network" is a typo, not a nameless folder in
-- the middle. `nil` — the folder was not named, and that is `DEFAULT_GROUP`;
-- an empty string — it was named empty, that is, the root. The distinction
-- is deliberate: "did not say" and "said: none" are different answers.
local function parse_group(value: any)
    local out = {}
    if type(value) == "table" then
        for _, segment in ipairs(value) do
            if type(segment) == "string" and segment ~= "" and #out < catalog.MAX_DEPTH then out[#out + 1] = segment end
        end
        return out
    end
    if value == nil then return {catalog.DEFAULT_GROUP} end
    if type(value) ~= "string" then return out end
    for segment in string.gmatch(value, "[^/]+") do
        local trimmed = string.match(segment, "^%s*(.-)%s*$")
        if trimmed ~= "" and #out < catalog.MAX_DEPTH then out[#out + 1] = trimmed end
    end
    return out
end

local function compare(left: any, right: any)
    if left.order ~= right.order then return left.order < right.order end
    return left.title < right.title
end

local function new_node(title: any, path: any)
    return { title = title, path = path, folders = {}, programs = {} }
end

-- A folder comes into being by something being put into it. There is no
-- separate entry for a menu folder: a folder without programs is
-- meaningless, and one declared separately drifts apart from its contents
-- when a module is removed.
local function ensure_folder(node: any, name: any)
    for _, folder in ipairs(node.folders) do
        if folder.title == name then return folder end
    end
    local path = node.path == "" and name or (node.path .. "/" .. name)
    local folder = new_node(name, path)
    -- A folder needs an order of its own to be sorted next to programs; it
    -- gets the order of the earliest program inside — otherwise the
    -- "System Tools" group would drift to the end just because it has no
    -- order.
    folder.order = NO_ORDER
    node.folders[#node.folders + 1] = folder
    return folder
end

local function sort_node(node: any)
    table.sort(node.programs, compare)
    for _, folder in ipairs(node.folders) do sort_node(folder) end
    table.sort(node.folders, compare)
end

local function to_program(record: any)
    local meta = type(record.meta) == "table" and record.meta or {}
    local order = tonumber(meta.order)
    -- The window type and the "show in menu" flag are read by the BASE's
    -- library, not by this file. The rule is one for two shells, and a second
    -- reading of it here would silently diverge from the first — the default
    -- would be computed differently in the menu and on opening, and one and
    -- the same window would look like a dialog from "Start" and like an
    -- ordinary window from the desktop.
    --
    -- A trap people have already fallen into: `meta.in_menu` via `x and x.f
    -- or nil` gives EXACTLY THE OPPOSITE answer — `false` goes into the "no
    -- value" branch and turns into the default `true`, that is, a window that
    -- asked to be hidden is shown.
    local window_type, unknown = programs_meta.window_type(meta)
    return {
        entry = record.id,
        window_type = window_type,
        unknown_type = unknown,
        in_menu = programs_meta.in_menu(meta),
        title = type(meta.title) == "string" and meta.title ~= "" and meta.title or record.id,
        group = parse_group(meta.group),
        order = order or NO_ORDER,
        icon = type(meta.icon) == "string" and meta.icon ~= "" and meta.icon or catalog.DEFAULT_ICON,
        image = type(meta.image) == "string" and meta.image ~= "" and meta.image or nil,
        -- The icon for the program's FILES, if it is not the program's own
        -- (Notepad is a notepad, its files are a text document). Read by
        -- associations.
        file_image = type(meta.file_image) == "string" and meta.file_image ~= "" and meta.file_image or nil,
        -- The name of the program's documents for the explorer's Type column
        -- ("Text Document"). Read by associations.
        file_type = type(meta.file_type) == "string" and meta.file_type ~= "" and meta.file_type or nil,
        -- What the entry says about itself: the Control Panel's Comment column.
        comment = type(meta.comment) == "string" and meta.comment ~= "" and meta.comment or nil,
        width = tonumber(meta.width),
        height = tonumber(meta.height),
        args = type(meta.args) == "string" and meta.args or nil,
        -- What the program opens — the file type registry is assembled from
        -- this field by the explorer; the table as is, associations parses it.
        opens = type(meta.opens) == "table" and meta.opens or nil,
        -- A menu separator after this line: this is how "My Computer" on the
        -- root is separated from the folders below it, as in the original.
        separator_after = meta.separator_after == true or nil,
        -- `desktop` in the registry is a request to PUT a shortcut on the
        -- desktop on first appearance, not a statement that the shortcut is
        -- there. Whether it is there or not, only the layout knows.
        desktop = meta.desktop == true or meta.desktop == "true",
        -- The program's properties window: the "Properties" item in the
        -- context menu of its icon. An entry identifier, like `entry`; none
        -- means no item.
        properties = type(meta.properties) == "string" and meta.properties ~= "" and meta.properties or nil,
    }
end

-- build(records) -> catalog
--
-- Separated from reading the registry on purpose: the menu layout is a pure
-- rule ("folders from meta.group, order from meta.order"), and it has to be
-- checked without a live registry. A rule checked only through the registry
-- is checked once, and then never.
--
-- Catalog: { programs = EVERYTHING declared, tree = the menu root, warnings = … }.
--
-- Two lists, not one, and the difference between them matters.
--
-- `programs` is the whole catalog, including hidden ones. A shortcut finds
-- its entry by it: a shortcut to a hidden window must work, the `in_menu`
-- flag is about the menu, not about launching. Were we to filter here, the
-- shortcut on the desktop would become broken, and the person would read
-- that as "the program is gone".
--
-- `tree` is the menu, and there are no hidden ones in it.
--
-- A FOLDER WHOSE CHILDREN ARE ALL HIDDEN DOES NOT APPEAR IN THE MENU AT ALL.
-- A folder comes into being by something being put into it, and we do not
-- put a hidden program in — so no folder arises either. That is how it
-- should be: an empty folder in "Start" is an item that opens into nothing,
-- and the first question will be where its contents went. There is no
-- separate entry for a menu folder, so a "declared, but emptied" folder is
-- impossible here by design.
function catalog.build(records: any)
    local programs = {}
    local warnings = {}
    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record = entry :: any
        if type(record.id) == "string" then
            local program = to_program(record)
            programs[#programs + 1] = program
            -- An unknown window type does not prevent showing the program,
            -- but it must be named: otherwise a typo in the declaration lives
            -- forever.
            if program.unknown_type then
                warnings[#warnings + 1] = {
                    entry = program.entry, window_type = program.unknown_type,
                }
            end
        end
    end
    table.sort(programs, compare)

    local root = new_node(nil, "")
    root.order = NO_ORDER
    for _, program in ipairs(programs) do
        if program.in_menu then
            local node = root
            for _, name in ipairs(program.group) do
                local folder = ensure_folder(node, name)
                if program.order < folder.order then folder.order = program.order end
                node = folder
            end
            node.programs[#node.programs + 1] = program
        end
    end
    sort_node(root)

    return { programs = programs, tree = root, warnings = warnings }
end

-- Programs that belong in the menu. A separate function, not a catalog
-- field: the list is needed exactly where the person CHOOSES a program — in
-- the "Start" menu and in the "Programs" folder of the "My Computer" window.
-- Everywhere a program is looked up by reference, the full list is needed,
-- and were we to substitute it, a shortcut to a hidden window would stop
-- opening.
function catalog.listed(programs: any)
    local out = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        if (program :: any).in_menu then out[#out + 1] = program end
    end
    return out
end

-- The shell consumes this adapter directly: preserve metadata when translating
-- width/height to the compositor's w/h names, including future image fields.
function catalog.menu_items(programs: any)
    local out = {}
    for _, program in ipairs(catalog.listed(programs)) do
        local item: any = {}
        for key, value in pairs(program) do item[key] = value end
        item.w, item.h = program.width, program.height
        out[#out + 1] = item
    end
    out[#out + 1] = {action = "quit", title = "Shut Down…", image = "shutdown",
        icon = "■", order = 1e12, group = {}, separator_before = true}
    return out
end

-- Host-owned decoration for runtime-created windows which have no image field
-- in their persistence schema. Keys are exact entry IDs, never display titles.
catalog.IMAGES_TYPE = "chicago.program_images"
function catalog.assign_images(programs: any, declarations: any): (any, any)
    local chosen: any = {}
    for _, record in ipairs(declarations or {}) do
        local data: any = record.data or {}
        for entry, name in pairs(data.images or {}) do
            if type(entry) ~= "string" or type(name) ~= "string" or name == "" then
                return nil, "invalid icon declaration: " .. tostring(record.id)
            end
            if chosen[entry] and chosen[entry] ~= name then
                return nil, "two icons for one program: " .. entry
            end
            chosen[entry] = name
        end
    end
    for _, program in ipairs(programs) do
        -- The program's own declaration remains authoritative.
        if not program.image then program.image = chosen[program.entry] end
    end
    return true, nil
end

-- The host names the clock window; the theme never guesses an entry ID.
catalog.CLOCK_TYPE = "chicago.taskbar_clock"
function catalog.taskbar_clock(): (any, any)
    local found, err = registry.find({[".kind"] = "registry.entry", ["meta.type"] = catalog.CLOCK_TYPE})
    if err then return nil, "taskbar clock not read: " .. tostring(err) end
    if #found == 0 then return nil, nil end
    if #found ~= 1 then return nil, "more than one taskbar clock declared" end
    local record: any = found[1]
    local data: any = record.data or {}
    if type(data.entry) ~= "string" or data.entry == "" then
        return nil, "clock window not set: " .. tostring(record.id)
    end
    return data.entry, nil
end

-- Desktop widgets (FR-006 §3): registry entries with `meta.type =
-- "chicago.widget"`, each a state provider the compositor spawns under the
-- logged-on user. The shell reads them and hands the list to the base
-- (`options.widgets`), as it hands over the desktop items: the base does not
-- read the registry itself.
catalog.WIDGET_TYPE = "chicago.widget"
-- The defaults of an entry that names no size or order. The limits
-- (10..40 × 2..16) are the base's to check and to name: a size clamped here
-- would be a tree laid out for another widget.
catalog.WIDGET_DEFAULTS = {w = 20, h = 5, order = 100}

-- widget_list(records) -> {{entry, title, w, h, order, opens}, …} in the
-- order of `meta.order`, then the entry id. Pure, like `build`: checked
-- without a registry.
function catalog.widget_list(records: any): any
    local out: any = {}
    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record: any = entry
        if type(record.id) == "string" and record.id ~= "" then
            local meta: any = type(record.meta) == "table" and record.meta or {}
            out[#out + 1] = {
                entry = record.id,
                title = type(meta.title) == "string" and meta.title ~= "" and meta.title or nil,
                -- A declared size goes as declared, and only a missing one is
                -- the default: "wide" must reach the base's check and be
                -- refused by name, not turn into 20 here.
                w = meta.width == nil and catalog.WIDGET_DEFAULTS.w or meta.width,
                h = meta.height == nil and catalog.WIDGET_DEFAULTS.h or meta.height,
                order = tonumber(meta.order) or catalog.WIDGET_DEFAULTS.order,
                opens = type(meta.opens) == "string" and meta.opens ~= "" and meta.opens or nil,
            }
        end
    end
    table.sort(out, function(a: any, b: any): boolean
        if a.order ~= b.order then return a.order < b.order end
        return a.entry < b.entry
    end)
    return out
end

-- widgets() -> (list, nil) | (nil, reason). As with `list`, the first value
-- tells the outcomes apart: no widgets is an empty table, an unreadable
-- registry is nil.
function catalog.widgets(): (any, any)
    local found, err = registry.find({["meta.type"] = catalog.WIDGET_TYPE})
    if err then return nil, "widgets not read: " .. tostring(err) end
    if type(found) ~= "table" then return nil, "widgets not read: the registry answered with something other than a list" end
    return catalog.widget_list(found), nil
end

-- list() -> (catalog, nil) | (nil, reason)
--
-- The two outcomes are distinguishable by the FIRST value: an empty catalog
-- is a table, an unreadable registry is nil. Returning an empty list on a
-- failure would mean saying "there are no programs" where the truth is "we
-- could not look".
function catalog.list()
    local found, err = registry.find({ ["meta.type"] = catalog.WINDOW_TYPE })
    if err then return nil, "catalog not read: " .. tostring(err) end
    if type(found) ~= "table" then return nil, "catalog not read: the registry answered with something other than a list" end
    local declarations, ierr = registry.find({[".kind"] = "registry.entry", ["meta.type"] = catalog.IMAGES_TYPE})
    if ierr then return nil, "program icons not read: " .. tostring(ierr) end
    local built = catalog.build(found)
    local ok, why = catalog.assign_images(built.programs, declarations)
    if not ok then return nil, why end
    return built, nil
end

-- A program by its entry identifier. A shortcut needs it: it stores a
-- reference, and takes the name, the icon and the window size from the
-- registry — the program got updated, the shortcut leads to the new version.
function catalog.find(programs: any, entry)
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        if program.entry == entry then return program end
    end
    return nil
end

return catalog
