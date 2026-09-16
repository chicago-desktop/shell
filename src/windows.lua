-- The Chicago shell: the base compositor, called with its own theme.
--
-- There is not a single line of window mechanics of its own here. Window
-- hosting, PTY, the command channel and the workshop stay in
-- chicago/tui-desktop; from here come the look (the theme), the catalog
-- with menu folders and the desktop layout.
--
-- A copy of the compositor instead of a call would diverge from the original
-- on the first edit, and that would be discovered a week later on the live
-- stand.

local logger = require("logger")
local ctx = require("ctx")
local environment = require("environment")
local font_set = require("font_set")
local gfx = require("gfx")
local library = require("library")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local catalog = require("catalog")
local desktop_menu = require("desktop_menu")
local defaults = require("defaults")
local seed = require("seed")
local view = require("view")
local repo = require("repo")
local patterns = require("patterns")
local wallpapers = require("wallpapers")
local logon_screen = require("logon_screen")
local logon_provider = require("logon_provider")
local startup = require("startup")

local SERVICE_NAME = "chicago.shell.desktop"

-- Fonts of the pixel theme: `chicago.shell.theme:font_set` names the store
-- (CHICAGO_FONTS, by default the module's own `chicago.shell.theme:fonts`)
-- and makes the faces of it. The environment is read by
-- `chicago.shell.config:environment` — which also holds both traps that make
-- "the variable is not set" sometimes a lie: `env.get` does not see the
-- process environment, and `get_all` keeps silent about a permission denial.
local FONTS = font_set.store()

-- Pixel mode is switched on EXPLICITLY, not by the presence of graphics
-- (FR-005 §6): a terminal that can do sixel is no reason to redraw the
-- interface differently from what the person asked for.
--
-- Answers with a second value saying WHERE it was taken from, so that "did
-- not ask" and "asked, but it could not be read" do not look the same.
local function wants_pixels(): (boolean, string)
    local asked, source = environment.read("CHICAGO_PIXELS")
    if asked == "1" or asked == "true" or asked == "yes" then return true, source end
    if asked ~= nil then return false, "set to \"" .. tostring(asked) .. "\"" end
    return false, source
end

local function main()
    local log = logger:named("chicago.shell")

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

        -- The logged-on user's profile rides in the catalog, behind the user
        -- row: the compositor opens a menu row as `items[hit.index]`, so the
        -- row must BE an item for a click and Enter to open it — no seam in
        -- the base is needed.
        local items = catalog.menu_items(found.programs)
        local profile = chrome.profile_item(chrome.session.user)
        if profile then items[#items + 1] = profile end
        return items, nil
    end

    -- Whose layout this desktop shows: the logged-on person's, or the shared
    -- one without logon. Several people use one runtime at once (terminal.ssh),
    -- and an icon one of them moves must not move on the others' screens.
    -- Asked every time, not taken once: the person is known only after logon.
    local function layout(): any
        local session: any = chrome.session
        local user: any = type(session) == "table" and session.user or nil
        return repo.of(type(user) == "table" and user.id or nil)
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

        local _, ferr = seed.furnish(defaults.resolve(programs), layout())
        if ferr then log:warn("desktop furniture not created", {error = tostring(ferr)}) end

        local _, serr = seed.ensure(programs, layout())
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
        local hex, err = layout().setting("desktop_color")
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
        local name, err = layout().setting("desktop_pattern")
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
        local name, err = layout().setting("desktop_wallpaper")
        local mode, merr = layout().setting("wallpaper_mode")
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

    -- The logged-on user's name, the same way: the profile window can rename
    -- the account, and Start must not keep showing the name from logon. The
    -- application names a function ({user_id} → {name}) in
    -- CHICAGO_USER_FUNC; `read`, not `read_or`: there is no
    -- default, and unset keeps the name as it was at logon. A refusal or a
    -- failure keeps the old name and says why in the log.
    local user_func, user_func_source, user_func_denied = environment.read(logon_provider.USER_FUNC_ENV)
    if user_func_denied then log:warn("user name refresh not enabled", {reason = tostring(user_func_source)}) end
    local function apply_user_name()
        local user: any = chrome.session.user
        if user_func == nil or type(user) ~= "table" then return end
        local name, why, denied = logon_provider.display_name(user_func, user.id)
        if name then
            chrome.rename_user(name)
        elseif denied then
            log:warn("user name not refreshed: permission denied", {func = tostring(user_func), reason = tostring(why)})
        else
            log:warn("user name not refreshed", {func = tostring(user_func), reason = tostring(why)})
        end
    end

    local function desktop_items()
        apply_desktop_color()
        apply_desktop_pattern()
        apply_desktop_wallpaper()
        apply_user_name()
        -- The catalog is read BEFORE the layout: furniture is created from
        -- it, and reading the layout earlier would mean handing over a frame
        -- without the icons just created — they would appear only on the next
        -- refresh.
        local found = catalog.list()
        furnish(found)

        local items, err = layout().list()
        if err then return {}, "layout not read: " .. tostring(err) end

        -- A catalog failure does NOT get in here. `failure` means "the layout
        -- was not read", and the theme draws no icons at all on it — saying
        -- so because of an unreadable catalog means removing from the desktop
        -- shortcuts the person never lost. Without the catalog, icons are
        -- drawn, just without the broken marker: accusing a working program
        -- is worse than keeping silent.
        return view.join(items or {}, found), nil
    end

    -- Desktop widgets (FR-006): the registry's `chicago.widget` entries,
    -- read when the compositor asks — at desktop start and on
    -- `desktop.refresh` — so a widget added to the registry appears without
    -- a restart. The base spawns and stops them and does not read the
    -- registry itself. A registry failure is the second value and the list
    -- stays empty: "no widgets" and "could not look" are different
    -- statements, and the log names the second.
    local function widget_catalog()
        local found, err = catalog.widgets()
        if err or not found then
            log:warn("widgets not read", {error = tostring(err)})
            return {}, err or "widgets not read"
        end
        return found, nil
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
        local item, err = layout().update(id, {x = x, y = y})
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
        pixel_note = "pixels off: CHICAGO_PIXELS " .. tostring(source)
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
            local fonts, ferr = font_set.load(FONTS, height, log)
            if not fonts then
                pixel_note = "pixels off: no font (" .. tostring(ferr) .. ")"
                log:warn("pixel mode not enabled: no font", {error = tostring(ferr)})
            else
                chrome_pixels.use_fonts(fonts.face, fonts.bold, fonts.display, fonts.mono)
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
    -- The profile window: a click on the logged-on user's row at the top of
    -- Start opens it with `args.user_id`. `read`, not `read_or`: there is no
    -- default profile, and unset leaves the row a caption, as before. A
    -- permission denial is not "unset", and it is named in the log.
    local profile_entry, profile_source, profile_denied = environment.read("CHICAGO_PROFILE_ENTRY")
    if profile_denied then log:warn("profile row not enabled", {reason = tostring(profile_source)}) end

    local logon: any = nil
    local logon_config, logon_error = logon_provider.configured()
    -- The terminal host may have let this person in without asking who they
    -- are; then there is no desktop without a logon.
    local refusal = logon_provider.unvouched_refusal(ctx.get("terminal.auth"), logon_config, logon_error)
    if refusal then
        log:warn("desktop refused", {reason = refusal})
        return nil, refusal
    end
    if logon_error then
        log:warn("logon not enabled", {reason = tostring(logon_error)})
    elseif logon_config then
        logon = function(screen)
            -- A key the SSH host saw the client prove, registered to an
            -- account: its owner is let in without the password screen. A
            -- refusal (the key was removed meanwhile, the account is blocked)
            -- is not the end — the screen asks as usual.
            local identity: any, why: any = nil, nil
            local account_key = ctx.get("terminal.key")
            if type(account_key) == "string" and account_key ~= "" then
                identity, why = logon_provider.authenticate_key(logon_config, account_key)
                if identity then
                    log:info("logged on by SSH key", {user = tostring(identity.context and identity.context.user_id)})
                else
                    log:warn("SSH key logon refused; asking for the password", {reason = tostring(why)})
                end
            end
            if not identity then
                identity, why = logon_screen.run(screen, function(login, password)
                    return logon_provider.authenticate(logon_config, login, password)
                end)
            end
            -- The logged-on user's name goes into "Start", for both themes at
            -- once: they compute the menu layout with one function and read
            -- one table.
            if type(identity) == "table" then
                local context: any = type(identity.context) == "table" and identity.context or {}
                chrome.use_user({id = context.user_id, name = context.user_name,
                    entry = profile_entry ~= nil and tostring(profile_entry) or nil})
                -- Startup windows (`chicago.startup`), once per desktop, right
                -- after this logon: a process of their own asks the
                -- compositor for them once its loop runs, and they open under
                -- this person (programs/startup.lua says why not from here).
                -- A failure is a line in the log, never a refused logon.
                local helper, startup_error = startup.begin(identity)
                if startup_error then
                    log:warn("startup windows not opened", {reason = tostring(startup_error)})
                elseif helper then
                    log:info("startup windows requested", {process = tostring(helper)})
                end
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
        -- The widgets the compositor spawns as state providers, read like
        -- the desktop items (FR-006 §3).
        widgets = widget_catalog,
        move_desktop_item = move_desktop_item,
        -- "Properties" on a right-click on the empty desktop is "Display
        -- Properties".
        desktop_menu = desktop_menu.read,
        -- Windows built by the base's workshop are returned to the registry
        -- at startup. The shell often comes up alone, and without restoring
        -- them its menu would show a catalog without them, without explaining
        -- where they went. A restore failure goes into restore_report and is
        -- visible in GET /chicago/status.
        restore = true,
        logon = logon,
    })
    return ok, err
end

return {main = main}
