-- Windows 95-style shell: the base compositor, called with its own theme.
--
-- There is not a single line of window mechanics of its own here. Window
-- hosting, PTY, the command channel and the workshop stay in
-- butschster/tui-desktop; from here come the look (the theme), the catalog
-- with menu folders and the desktop layout.
--
-- A copy of the compositor instead of a call would diverge from the original
-- on the first edit, and that would be discovered a week later on the live
-- stand.

local logger = require("logger")
local environment = require("environment")
local fs = require("fs")
local gfx = require("gfx")
local library = require("library")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local catalog = require("catalog")
local defaults = require("defaults")
local seed = require("seed")
local view = require("view")
local repo = require("repo")
local patterns = require("patterns")
local wallpapers = require("wallpapers")
local logon_screen = require("logon_screen")
local logon_provider = require("logon_provider")

local SERVICE_NAME = "butschster.windows.shell"

-- Font of the pixel theme. It arrives as BYTES through `fs`, not as a path
-- inside `gfx`: file reads are governed by the process's permissions, and a
-- module that opens paths itself would be a road around them. As a side
-- effect this means the font can arrive from anywhere — from the module's
-- embedded filesystem, from the database.
--
-- Bold is a SEPARATE file, not an option: in Windows 95 the title bar is set
-- in it, and synthesizing it by smearing pixels means ceasing to look alike.
-- The environment is read by `butschster.windows.config:environment` — which
-- also holds both traps that make "the variable is not set" sometimes a lie:
-- `env.get` does not see the process environment, and `get_all` keeps silent
-- about a permission denial.

local function whole_cell(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Via `read_or`, not `read(...) or …`: the default is substituted, but a
-- permission denial is named in the log instead of passing for "the person
-- did not override it".
local FONTS = environment.read_or("BUTSCHSTER_WINDOWS_FONTS", "app:system_fonts")
local FONT_FACE = "LiberationSans-Regular.ttf"
local FONT_BOLD = "LiberationSans-Bold.ttf"
local FONT_SIZE = 13

-- Pixel mode is switched on EXPLICITLY, not by the presence of graphics
-- (FR-005 §6): a terminal that can do sixel is no reason to redraw the
-- interface differently from what the person asked for.
--
-- Answers with a second value saying WHERE it was taken from, so that "did
-- not ask" and "asked, but it could not be read" do not look the same.
local function wants_pixels(): (boolean, string)
    local asked, source = environment.read("BUTSCHSTER_WINDOWS_PIXELS")
    if asked == "1" or asked == "true" or asked == "yes" then return true, source end
    if asked ~= nil then return false, "set to \"" .. tostring(asked) .. "\"" end
    return false, source
end

-- Fonts for the pixel theme. A failure here is NOT a reason to take the shell
-- down: it comes up in cells and states the reason. An empty screen instead
-- of a desktop reads as a broken stand, not as a file that was not found.
-- The large font is for the farewell screen: in Windows 95 "It's now safe to
-- turn off your computer" is set large, in two lines, across the whole
-- screen. The size is computed from the cell height, not a constant: on a
-- terminal with a different cell, a 34-pixel caption would be either tiny or
-- wider than the screen.
local function display_size(cell_h: any): integer
    local size = (whole_cell(cell_h) * 17) // 10
    if size < 20 then size = 20 end
    if size > 64 then size = 64 end
    return math.tointeger(size) or 34
end

local function load_fonts(log, cell_h: any)
    local store, err = fs.get(FONTS)
    if err or not store then
        return nil, "fonts not opened (" .. FONTS .. "): " .. tostring(err)
    end

    local face_data, ferr = store:readfile(FONT_FACE)
    if ferr or not face_data then
        return nil, FONT_FACE .. " not read: " .. tostring(ferr)
    end
    local bold_data, berr = store:readfile(FONT_BOLD)
    if berr or not bold_data then
        return nil, FONT_BOLD .. " not read: " .. tostring(berr)
    end

    -- Thresholding small TrueType glyphs erases thin strokes. Set smoothing
    -- once on each face so the shell and every client share readable text.
    return {face = gfx.font(face_data, {size = FONT_SIZE, smooth = true}),
            bold = gfx.font(bold_data, {size = FONT_SIZE, smooth = true}),
            display = gfx.font(bold_data, {size = display_size(cell_h), smooth = true})}, nil
end

local function main()
    local log = logger:named("windows.shell")

    -- The catalog is read when the menu is opened, not at startup: a window
    -- built by the workshop while the shell is running gets into the menu
    -- without a restart.
    --
    -- A registry failure is returned as the SECOND value, and the list stays
    -- empty. The theme must show the reason as text: "there is nothing" and
    -- "could not read" are different statements, and a person who sees the
    -- first instead of the second will go looking for the error in their own
    -- application, where there is none.
    local function menu_catalog()
        local found, err = catalog.list()
        if err or not found then return {}, err or "catalog not read" end

        -- A typo in `window_type` does not prevent showing the program, but
        -- it must be named: unnamed, it lives forever, and all that time the
        -- window is drawn as something other than what it was declared as.
        for _, warning in ipairs(found.warnings or {}) do
            log:warn("unknown window type", {
                entry = tostring((warning :: any).entry),
                window_type = tostring((warning :: any).window_type),
            })
        end

        return catalog.menu_items(found.programs), nil
    end

    -- What appears on the desktop by itself. First-run furniture is created
    -- before programs: the compositor lays out icons in the order the layout
    -- returns them, and "My Computer" must take the head of the column
    -- rather than land under whatever happened to come along.
    --
    -- Places are not chosen here: the row is written without coordinates,
    -- and the compositor places the icon itself, knowing the screen width at
    -- the moment of the frame. The shell does not know it yet at startup, and
    -- a place it chose could end up past the edge — and an icon past the edge
    -- is not clipped, it disappears entirely.
    --
    -- A failure here does not hide the desktop and does not cancel the
    -- frame: the layout is already there, and an icon that was not created is
    -- a reason to say so in the log, not to show emptiness.
    local function furnish(found: any)
        local programs = type(found) == "table" and found.programs or {}

        local _, ferr = seed.furnish(defaults.resolve(programs))
        if ferr then log:warn("desktop furniture not created", {error = tostring(ferr)}) end

        local _, serr = seed.ensure(programs)
        if serr then log:warn("shortcuts not placed on the desktop", {error = tostring(serr)}) end
    end

    -- The desktop layout. Handed over as a function, not a table: the
    -- compositor re-reads it on the `desktop.refresh` command, and an icon
    -- moved by a handler from outside lands in place without restarting the
    -- shell.
    --
    -- The catalog is mixed in right here: an icon opens a window with the
    -- sizes from the registry, not from a copy taken when the shortcut was
    -- created.
    -- The desktop color is a setting from "Display Properties". It is read at
    -- startup and on every `desktop.refresh`: the properties window writes to
    -- the database and pushes the compositor, and the compositor re-reads the
    -- desktop by this same path. A database failure does not bring the
    -- desktop down: the previous color stays, the reason goes to the log.
    local function apply_desktop_color()
        local hex, err = repo.setting("desktop_color")
        if err then
            log:warn("desktop color not read", {error = tostring(err)})
            return
        end
        if type(hex) == "string" and hex ~= "" and not chrome.use_desktop(hex) then
            log:warn("desktop color in the database is invalid", {value = hex})
        end
    end

    -- The desktop pattern, the same way: a name in the settings, the rows
    -- from the pattern library; a name nobody knows is no pattern.
    local function apply_desktop_pattern()
        local name, err = repo.setting("desktop_pattern")
        if err then
            log:warn("desktop pattern not read", {error = tostring(err)})
            return
        end
        chrome.use_pattern(patterns.find(name))
    end

    -- The wallpaper, the same way: a name and a mode in the settings, the
    -- picture's file from the wallpaper list; a name nobody knows is none,
    -- and a missing mode is the one the wallpaper is meant for.
    local function apply_desktop_wallpaper()
        local name, err = repo.setting("desktop_wallpaper")
        local mode, merr = repo.setting("wallpaper_mode")
        if err or merr then
            log:warn("desktop wallpaper not read", {error = tostring(err or merr)})
            return
        end
        local entry: any = wallpapers.find(name)
        if entry == nil then
            chrome.use_wallpaper(nil, nil)
            return
        end
        chrome.use_wallpaper(entry.file, (mode == "tile" or mode == "center") and mode or entry.mode)
    end

    local function desktop_items()
        apply_desktop_color()
        apply_desktop_pattern()
        apply_desktop_wallpaper()
        -- The catalog is read BEFORE the layout: furniture is created from
        -- it, and reading the layout earlier would mean handing over a frame
        -- without the icons just created — they would appear only on the next
        -- refresh.
        local found = catalog.list()
        furnish(found)

        local items, err = repo.list()
        if err then return {}, "layout not read: " .. tostring(err) end

        -- A catalog failure does NOT get in here. `failure` means "the layout
        -- was not read", and the theme draws no icons at all on it — saying
        -- so because of an unreadable catalog means removing from the desktop
        -- shortcuts the person never lost. Without the catalog, icons are
        -- drawn, just without the broken marker: accusing a working program
        -- is worse than keeping silent.
        return view.join(items or {}, found), nil
    end

    -- Dragging an icon with the mouse is driven by the compositor, and the
    -- position is recorded by the shell — by the same path as the PATCH
    -- handler, that is, through one repository. A second way to record the
    -- position would diverge from the first on the first edit.
    --
    -- This function does not bring the frame down under any outcome: a
    -- failed write is returned as a reason, the icon stays where it was, and
    -- the person sees the desktop, not a crash.
    local function move_desktop_item(id, x, y)
        if type(id) ~= "string" or id == "" then
            return false, "icon not named"
        end
        local item, err = repo.update(id, {x = x, y = y})
        if err then return false, "writing the position: " .. tostring(err) end
        -- `false` from the repository means "no such row", not a database
        -- failure. Silence here would turn a typo into a successful move.
        if item == false then return false, "no such icon: " .. id end
        return true, nil
    end

    -- Pixel mode is assembled HERE, not in the mechanics, and not on a whim:
    -- the mechanics entry does not declare `gfx`, so it cannot ask the
    -- terminal for the cell size. It makes the decision; we ask the question.
    --
    -- Every failure along the way leaves the shell in cells and NAMES the
    -- reason. Pixel mode that silently failed to turn on looks like "for some
    -- reason it is the old way", and the person goes looking for a breakage
    -- where there is none.
    --
    -- NAMING IT ONLY IN THE LOG MEANS NAMING IT TO NOBODY. This host's log is
    -- muted on purpose (`hide_logs: true`): a log line breaks the frame for
    -- good, because the surface differ considers itself the only writer to
    -- the terminal. So the only reader of the reason is the screen.
    -- This cost a round here: the shell came up in cells, and from outside
    -- that was indistinguishable from "pixels turned on, but look the old
    -- way".
    local theme: any = chrome
    local cell_size: any = nil
    -- A short note about the outcome — it goes into the empty-desktop hint,
    -- that is, into the first thing the person sees after launch.
    local pixel_note = "pixels off"

    local asked, source = wants_pixels()
    log:info("pixel mode", {asked = asked, source = source})

    if not asked then
        -- "Did not ask" and "asked, but it could not be read" are different
        -- statements, and the person can fix the second. So the source goes
        -- to the screen together with the outcome: a permission denial looks
        -- like an unset variable exactly until it is called by its name.
        pixel_note = "pixels off: BUTSCHSTER_WINDOWS_PIXELS " .. tostring(source)
    end

    if asked then
        local protocol, why = gfx.supported()
        local width, height = gfx.cell_size()

        if not protocol then
            pixel_note = "pixels off: the terminal has no graphics (" .. tostring(why) .. ")"
            log:warn("pixel mode not enabled: the terminal has no graphics",
                {reason = tostring(why)})
        elseif not width or not height then
            -- The guess "8×16" is right often enough to look correct, and a
            -- picture of the wrong size reads as a drawing error, not as a
            -- question that was never asked. Hence a failure, not a default.
            pixel_note = "pixels off: the terminal did not report a cell size"
            log:warn("pixel mode not enabled: the terminal did not report a cell size",
                {reason = tostring(height)})
        else
            local fonts, ferr = load_fonts(log, height)
            if not fonts then
                pixel_note = "pixels off: no font (" .. tostring(ferr) .. ")"
                log:warn("pixel mode not enabled: no font", {error = tostring(ferr)})
            else
                chrome_pixels.use_fonts(fonts.face, fonts.bold, fonts.display)
                chrome_pixels.use_cell_size(width, height)
                theme = chrome_pixels
                cell_size = function()
                    local w, h = gfx.cell_size()
                    if type(w) == "number" and type(h) == "number" then
                        chrome_pixels.use_cell_size(w, h)
                    end
                    return w, h
                end
                pixel_note = "pixels: " .. tostring(protocol) .. " " .. width .. "x" .. height
                log:info("pixel mode enabled",
                    {protocol = protocol, cell = width .. "x" .. height})
            end
        end
    end

    -- This must not be written as a bare `return library.run(...)`: in
    -- go-lua v1.5.18 a tail call of a yield function from the base frame of a
    -- coroutine is not executed at all — silently, in 0 ms.
    local clock_entry, clock_error = catalog.taskbar_clock()
    theme.clock_entry = clock_entry
    if clock_error then log:warn("taskbar clock not configured", {error = clock_error}) end

    -- Logon — if the application named a logon function and a token store.
    -- Without them the shell comes up without logon, under its own actor:
    -- that is how it always was, and a stand without a users module keeps
    -- working. A permission denial is not "not configured": it is named in
    -- the log.
    local logon: any = nil
    local logon_config, logon_error = logon_provider.configured()
    if logon_error then
        log:warn("logon not enabled", {reason = tostring(logon_error)})
    elseif logon_config then
        logon = function(screen)
            local identity, why = logon_screen.run(screen, function(login, password)
                return logon_provider.authenticate(logon_config, login, password)
            end)
            -- The logged-on user's name goes into "Start", for both themes at
            -- once: they compute the menu layout with one function and read
            -- one table.
            if type(identity) == "table" then
                local context: any = type(identity.context) == "table" and identity.context or {}
                chrome.use_user({id = context.user_id, name = context.user_name})
            end
            return identity, why
        end
        log:info("logon enabled", {func = logon_config.func, store = logon_config.store})
    end

    local ok, err = library.run({
        chrome = theme,
        pixels = cell_size ~= nil,
        -- As a function, not a value: the cell size changes when the person
        -- changes the terminal font, and a number taken once would drift away
        -- from the screen.
        cell_size = cell_size,
        service_name = SERVICE_NAME,
        hint = "Start — programs · alt+n — bash window · ctrl+q — quit · " .. pixel_note,
        -- Optional seams to the base. Should the compositor not support them,
        -- the menu falls back to its own flat catalog, and the desktop stays
        -- without icons; the shell still comes up and works.
        catalog = menu_catalog,
        desktop_items = desktop_items,
        move_desktop_item = move_desktop_item,
        -- "Properties" on a right-click on the empty desktop is "Display
        -- Properties".
        desktop_properties = "butschster.windows.display:window",
        -- Windows built by the base's workshop are returned to the registry
        -- at startup. The shell often comes up alone, and without restoring
        -- them its menu would show a catalog without them, without explaining
        -- where they went. A restore failure goes into restore_report and is
        -- visible in GET /windows/status.
        restore = true,
        logon = logon,
    })
    return ok, err
end

return {main = main}
