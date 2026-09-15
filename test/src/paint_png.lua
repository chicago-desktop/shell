-- The second level of the pixel probe: a real PNG.
--
-- The pure-Lua stub catches layout, overlaps and hits in milliseconds, but
-- it has no glyphs and no font metrics either. That an edge came out ONE
-- pixel wide, that Cyrillic got drawn, that the color is the right one — is
-- visible only in the screenshot, and a person or an agent looks at it with
-- Read.
--
-- Draws with THE SAME `chicago.shell.theme:pixels` that will ship to the
-- running system. A private copy of the painting for the sake of a
-- screenshot would be checking the copy.
--
--   cd test && wippy run --host wippy.terminal:host paint-png
--
-- The files land in `test/shots/`. The directory is not in the module's
-- distribution: screenshots are a check, not part of the shell.

local fs = require("fs")
local gfx = require("gfx")

local pixels = require("pixels")
local images = require("images")
local catalog = require("catalog")
local desktop_view = require("desktop_view")
local model = require("model")
local rasters = require("rasters")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local ui = require("ui")
local explorer_window = require("explorer_window")
local sysprops_window = require("sysprops_window")
local display_window = require("display_window")
local sdk_render = require("sdk_render")
local widget_scene = require("widget_scene")

-- Cell size. This command has NO terminal — it writes files, it does not
-- draw on a screen — so `gfx.cell_size()` honestly stays silent here, and
-- this is measured, not assumed.
--
-- Hence the rule: the number is given from outside, as an argument, and the
-- report writes WHERE it came from. The guess "8×16" is right often enough
-- to look correct, and a picture of the wrong size reads as a drawing error,
-- not as a question that was never asked.
--
--   wippy run --host wippy.terminal:host paint-png 10x20
local FALLBACK = {w = 10, h = 20}

-- The report is put down as a FILE next to the screenshots, not printed.
--
-- `print` from a process under the terminal host does not get out —
-- measured: the screenshots were written, and not a single line appeared. A
-- report told only to the log is told to no one: the numbers about font
-- metrics and about rasters outliving the frame are half the check, and it
-- has to be READ.
local REPORT = "report.txt"

-- The desktop teal. In a live frame the cells lay it down; here it is only
-- for the sake of the screenshot: so that a person sees the same thing they
-- will see on the screen.
local color_desktop = "#008080"

local SHOTS = "app:shots"
local FONTS = "app:system_fonts"
local FACE = "LiberationSans-Regular.ttf"
-- Bold is a separate FILE, not an option: in Windows 95 the title is set in
-- it, and synthesizing it by smearing pixels means ceasing to look alike.
local BOLD = "LiberationSans-Bold.ttf"

local function cell_size(spec)
    local w, h = gfx.cell_size()
    if w and h then return {w = w, h = h}, "the terminal answered" end

    local given_w, given_h = string.match(tostring(spec or ""), "^(%d+)[xX×](%d+)$")
    if given_w then
        return {w = math.tointeger(tonumber(given_w)) or FALLBACK.w,
                h = math.tointeger(tonumber(given_h)) or FALLBACK.h}, "given as an argument"
    end

    return FALLBACK, "FALLBACK VALUE — the terminal is silent, no argument"
end

local function load_font(file, size)
    local store, err = fs.get(FONTS)
    if err or not store then return nil, "fonts did not open: " .. tostring(err) end
    local data, rerr = store:readfile(file)
    if rerr or not data then return nil, "font not read: " .. tostring(rerr) end
    local face = gfx.font(data, {size = size, smooth = true})
    return face, nil
end

-- ─── scenes ──────────────────────────────────────────────────────────────
--
-- The same as in the stub: the screenshot and the map must show one and the
-- same thing, otherwise one of the two levels checks something other than
-- the second.

-- Clickable things go by CELLS: `pixels.box` gives the place, the drawing is
-- `inset` pixels smaller than its cells. In the shell the layout computes the
-- hit, not the drawing, so there is none here.
local function button_in_cells(raster, col, row, cols, rows, spec, cell, inset)
    local area = pixels.box(col, row, cols, rows, cell)
    pixels.button(raster, area.x + inset, area.y + inset, area.w - inset * 2, area.h - inset * 2, spec, cell)
    return area
end

local function scene_window(raster, cell, font, bold)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    -- The title bar, the way the theme paints it: a rectangle and a bold caption.
    raster:rect(4, 4, w - 6, cell.h - 2, "#000080")
    if bold then raster:text(8, 4 + (cell.h - 2 - bold:height()) // 2, "My Computer",
        {font = bold, color = "#ffffff"}) end

    -- Title buttons are placed IN CELLS, two per button: placed by pixels
    -- with a step of 18, they would look the same, but their hit zones would
    -- overlap — the probe caught exactly that.
    local marks = {"minimize", "maximize", "close"}
    for index, id in ipairs(marks) do
        local area = button_in_cells(raster, 24 + (index - 1) * 2, 1, 2, 1,
            {id = id, label = "", font = font}, cell, 2)
        -- The mark is placed by the DRAWN rectangle, not by the cell: the
        -- button has an inset, and a mark computed from the cell would slide
        -- off.
        pixels.caption_mark(raster, id, area.x + 2, area.y + 2, area.w - 4, area.h - 4)
    end

    pixels.field(raster, 4, cell.h + 4, w - 6, h - cell.h - 7)
end

local function scene_buttons(raster, cell, font, bold)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)

    -- One width for both: "OK" and "Cancel" of different widths are the first
    -- thing that gives away a fake. Computed by the widest MEASURED caption
    -- and rounded up to whole cells, no less than seventy-five pixels — as in
    -- Windows 95.
    local labels = {"OK", "Cancel"}
    local span = pixels.button_span(font, labels, cell, 75)
    for index, label in ipairs(labels) do
        button_in_cells(raster, 2 + (index - 1) * (span + 1), 2, span, 1,
            {id = label, label = label, font = font, pressed = index == 2}, cell, 2)
    end
end

local SCENES = {
    {name = "window", cols = 30, rows = 8, paint = scene_window},
    {name = "buttons", cols = 23, rows = 3, paint = scene_buttons},
}

-- The same measure as in the stub, but on the REAL gfx.
--
-- The stub is our own, and a store checked only against it is proven
-- against our own invention. Here the rasters are real, and `version` is
-- moved by the runtime, not by Lua.
--
-- The IDENTITY of the raster is compared, not only its version. Found out by
-- mutation: a store that recreates the raster every frame hands out a fresh
-- buffer, the painting code repeats the same calls — and the version comes
-- out the very same. The numbers match, and everything flies to the screen
-- anew.
local lines = {}
local function say(text)
    lines[#lines + 1] = tostring(text)
    print(text)
end

local function check_frames(cell, font)
    local store = rasters.store()

    local function paint(state: any)
        store.begin()
        local title, dirty = store.take("win:title", 30, 1, cell,
            state.title .. "|" .. tostring(state.focused))
        if dirty then
            pixels.panel(title, 1, 1, 30 * cell.w, cell.h)
            title:rect(2, 2, 30 * cell.w - 4, cell.h - 4, state.focused and "#000080" or "#808080")
            pixels.label(title, 2, 2, 30 * cell.w - 4, cell.h - 4, state.title, font, "#ffffff")
        end
        store.place("win:title", 1, 1)

        local bar, bar_dirty = store.take("taskbar", 30, 1, cell, state.clock)
        if bar_dirty then
            pixels.panel(bar, 1, 1, 30 * cell.w, cell.h)
            pixels.label(bar, 24 * cell.w, 1, 5 * cell.w, cell.h, state.clock, font)
        end
        store.place("taskbar", 1, 8)

        return store.frame(cell)
    end

    local function snapshot(placements)
        local out: any = {}
        for _, item in ipairs(placements) do
            out[item.id] = {raster = item.raster, version = item.raster:version()}
        end
        return out
    end

    local function moved(before: any, after: any)
        local names = {}
        for id, now in pairs(after) do
            local was: any = before[id]
            if not was then names[#names+1] = id .. " (appeared)"
            elseif was.raster ~= now.raster then names[#names+1] = id .. " (RECREATED)"
            elseif was.version ~= now.version then names[#names+1] = id end
        end
        table.sort(names)
        return names
    end

    local state: any = {title = "My Computer", focused = true, clock = "21:47"}
    local first = snapshot(paint(state))
    local second = snapshot(paint(state))
    local still = moved(first, second)
    say(string.format("frame without changes: %d of %d placements moved%s",
        #still, 2, #still == 0 and "" or "  ◄ ERROR: " .. table.concat(still, ", ")))

    state.clock = "21:48"
    local ticked = moved(second, snapshot(paint(state)))
    say(string.format("clock changed: repainted %s%s",
        table.concat(ticked, ", "),
        (#ticked == 1 and ticked[1] == "taskbar") and "" or "  ◄ ERROR: only taskbar was expected"))

    return #still == 0 and #ticked == 1 and ticked[1] == "taskbar"
end

local function main(spec)
    local store_shots, serr = fs.get(SHOTS)
    if not store_shots then
        print("FAILURE: the screenshots directory did not open: " .. tostring(serr))
        return false, serr
    end

    local cell, source = cell_size(spec)
    say("cell " .. cell.w .. "×" .. cell.h .. " px (" .. source .. ")")

    local font, ferr = load_font(FACE, 13)
    if not font then
        say("FAILURE: " .. tostring(ferr))
        return false, ferr
    end
    local bold, berr = load_font(BOLD, 13)
    if not bold then
        say("FAILURE: bold did not load: " .. tostring(berr))
        return false, berr
    end

    local comparison = gfx.raster(615, 270)
    comparison:fill("#c0c0c0")
    for index, variant in ipairs({{size = 13, smooth = false, name = "Before: 13 px, no smoothing"},
        {size = 13, smooth = true, name = "After: 13 px, smoothing"}}) do
        local left = (index - 1) * 305 + 10
        local regular = assert(load_font(FACE, variant.size))
        local heavy = assert(load_font(BOLD, variant.size))
        comparison:text(left, 8, variant.name, {font = font, color = "#000000", smooth = true})
        for line, label in ipairs({"My Computer", "Calculator", "Date & Time", "Notepad", "Run…", "Shut Down…"}) do
            comparison:text(left, 24 + line * 26, label, {font = regular, color = "#000000", smooth = variant.smooth})
        end
        comparison:rect(left, 211, 284, 32, "#000080")
        comparison:text(left + 8, 218, "Programs  ·  Content machine", {font = heavy, color = "#ffffff", smooth = variant.smooth})
    end
    assert(store_shots:writefile("font-comparison.png", assert(comparison:encode("png"))))

    -- Fixed public labels reproduce the menu used to report unreadable text.
    local font_menu = catalog.build({
        {id = "chicago.shell.explorer:window", meta = {title = "My Computer", image = "my_computer", group = "", order = 10}},
        {id = "chicago.shell.calc:window", meta = {title = "Calculator", image = "calculator", order = 20}},
        {id = "chicago.shell.datetime:window", meta = {title = "Date & Time", image = "clock", order = 30}},
        {id = "chicago.shell.viewers:notepad", meta = {title = "Notepad", image = "text_document", order = 40}},
        {id = "example:bridge", meta = {title = "Jobs", group = "Programs/Bridge", order = 50}},
        {id = "example:content", meta = {title = "Articles", group = "Programs/Content machine", order = 60}},
        {id = "chicago.tui_desktop.desktop:window_pty", meta = {title = "Bash", image = "program", order = 70}},
        {id = "example:settings", meta = {title = "Properties", group = "Settings", order = 80}},
        {id = "chicago.shell.run:window", meta = {title = "Run…", image = "run", group = "", order = 900}},
    })
    chrome_pixels.use_fonts(font, bold)
    chrome_pixels.use_cell_size(cell.w, cell.h)
    local menu_scene = {width = 64, height = 18, top = 1, bottom = 16,
        items = {}, windows = {}, clock = "12:00",
        menu = {items = catalog.menu_items(font_menu.programs), open = {"Programs"}, cursor = 6}}
    local menu_frame = chrome_pixels.paint(menu_scene, cell.w, cell.h)
    local menu_image = gfx.raster(menu_scene.width * cell.w, menu_scene.height * cell.h)
    menu_image:fill(color_desktop)
    for _, placement in ipairs(menu_frame.placements) do
        menu_image:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
    end
    assert(store_shots:writefile("font-menu.png", assert(menu_image:encode("png"))))

    -- Font metrics are printed next to the screenshot: the stub does not know
    -- them and computes an approximation, and otherwise a divergence between
    -- the levels would be discovered by a caption not fitting into a button
    -- on the running system.
    local sample = "My Computer"
    local tw, th = font:measure(sample)
    say(string.format("font %d px, line height %d, ascent %d; \"%s\" = %d×%d px",
        font:size(), font:height(), font:ascent(), sample, tw, th))


    -- ─── the whole screen in one screenshot ──────────────────────────────
    --
    -- The compositor places the placements separately, but a person looks at
    -- the SCREEN. Pieces laid out across eight files show neither that the
    -- frame met up nor that an icon did not run over a window.
    --
    -- `blit` gathers them into one raster at the same coordinates at which
    -- the surface will place them — that is, the screenshot lies exactly as
    -- much as the coordinates lie, and not a bit more.
    local function screen_shot(file, notice)
        chrome_pixels.use_fonts(font, bold)

        local cols, rows = 100, 28
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local layout = chrome_pixels.layout(cols, rows)
        local state: any = {
            width = cols, height = rows, top = 1, bottom = rows - layout.bottom,
            windows = {
                {id = "w1", title = "Command Prompt", x = 20, y = 4, w = 52, h = 14,
                 window_type = "app"},
                {id = "w2", title = "System Properties", x = 44, y = 12, w = 44, h = 10,
                 window_type = "dialog"},
            },
            focused_id = "w2",
            items = {
                {id = "s1", kind = "shortcut", entry = "chicago.shell.explorer:window",
                 title = "My Computer", x = 2, y = 1},
                {id = "f1", kind = "folder", title = "Programs", x = 2, y = 5},
                {id = "s2", kind = "shortcut", entry = "app:bin", image = "recycle_bin", title = "Recycle Bin", x = 2, y = 9},
                {id = "s3", kind = "shortcut", entry = "app:gone", title = "Old program",
                 x = 2, y = 13, broken = true},
            },
            selected = "f1",
            clock = "21:47",
            notice = "",
            menu = {open = {"Programs"}, cursor = 2, items = {
                {entry = "app:calc", title = "Calculator", icon = "▣",
                 group = {"Programs"}},
                {entry = "app:notepad", title = "Notepad", group = {"Programs"}},
                {entry = "app:paint", title = "Paint", group = {"Programs"}},
                {entry = "app:ping", title = "Ping", group = {"Programs", "Communications"}},
                {entry = "app:bash", title = "MS-DOS Prompt"},
                {entry = "app:docs", image = "documents", title = "Documents"},
                {entry = "app:settings", image = "settings", title = "Settings"},
                {entry = "app:shutdown", image = "shutdown", title = "Shut Down…"},
            }},
        }

        if notice == "context" then
            -- The context menu of the "My Computer" icon: the anchor at the
            -- icon, "Open" in bold, "Properties" past the separator line.
            state.selected = "s1"
            state.menu = {anchor = {x = 6, y = 2}, cursor = 2, open = {}, items = {
                {label = "Open", bold = true, entry = "chicago.shell.explorer:window", title = "My Computer"},
                {label = "Properties", entry = "chicago.shell.sysprops:window", separator_before = true},
            }}
        elseif notice == "over" then
            -- A window under the open "Start": its raster is cut by the menu
            -- panels, not laid over them. In the screenshot the stacking order
            -- is the same as without the fix; what is visible here is that the
            -- menu is whole, and the proof of "the window will not be resent
            -- on top" is the test `menu above windows`.
            state.windows[1].x, state.windows[1].y = 3, 6
            state.focused_id = "w1"
        elseif notice == "layout" then
            -- The desktop layout could not be read: instead of icons, a notice
            -- box with the reason, in the taskbar — the compositor's message.
            -- There is one window, and it is below the notice box, so that the
            -- reason is visible in full.
            state.items, state.selected, state.menu = {}, nil, nil
            state.windows = {state.windows[2]}
            state.failure = "database is locked: SELECT id, x, y, image FROM chicago_shell_desktop"
                .. " ORDER BY position; retry after the shell restarts"
            state.notice = "could not open: app:gone — entry not found"
        elseif notice then
            state.menu = {items = {}}
            if notice == "failure" then state.menu.failure = "the registry is temporarily unavailable" end
        end
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local screen = gfx.raster(cols * cell.w, rows * cell.h)
        -- The desktop as a fill: in a live frame these are CELL styles, not a
        -- picture (FR-005 §3a). Here it is painted so that the screenshot
        -- shows the same as a person will see — but such a raster never gets
        -- into the frame.
        screen:fill(color_desktop)
        for _, window in ipairs(state.windows) do
            screen:rect((window.x - 1) * cell.w + 1, (window.y - 1) * cell.h + 1,
                window.w * cell.w, window.h * cell.h,
                window.window_type == "dialog" and "#c0c0c0" or "#ffffff")
        end

        for _, item in ipairs(painted.placements) do
            screen:blit(item.raster, (item.x - 1) * cell.w + 1, (item.y - 1) * cell.h + 1)
        end

        local bytes = screen:encode("png")
        if bytes then
            store_shots:writefile(file, bytes)
            say(string.format("screen: %d placements, %d icons, %d taskbar buttons, %d menu items → %s",
                #painted.placements, #painted.hits.desktop, #painted.hits.bars,
                #painted.hits.menu, file))
        end
    end

    -- Same catalog adapter and desktop join as the live shell. This scene uses
    -- the host's actual window identities, including runtime workshop windows.
    local function menu_icons_shot()
        chrome.use_user({id = "u1", name = "butschster"})
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local records = {
            {id = "chicago.shell.explorer:window", meta = {title = "My Computer", image = "my_computer", order = 10, in_menu = false}},
            {id = "app.desktop:window_calc", meta = {title = "Calculator", image = "calculator", group = "Accessories"}},
            {id = "chicago.tui_desktop.apps:commander", meta = {title = "Stand Explorer"}},
            {id = "chicago.tui_desktop.apps:dataflows", meta = {title = "Runs"}},
            {id = "chicago.tui_desktop.apps:bridge_runs", meta = {title = "Job runs"}},
            {id = "chicago.tui_desktop.apps:bridge_jobs", meta = {title = "Bridge jobs"}},
            {id = "chicago.tui_desktop.apps:dataflow_detail", meta = {title = "Run nodes"}},
            {id = "chicago.tui_desktop.apps:clock", meta = {title = "Clock"}},
        }
        local built = catalog.build(records)
        assert(catalog.assign_images(built.programs, {{data = {images = {
            ["chicago.tui_desktop.apps:commander"] = "network_neighborhood",
            ["chicago.tui_desktop.apps:dataflows"] = "run",
            ["chicago.tui_desktop.apps:bridge_runs"] = "documents_stack",
            ["chicago.tui_desktop.apps:bridge_jobs"] = "system",
            ["chicago.tui_desktop.apps:dataflow_detail"] = "program_settings",
            ["chicago.tui_desktop.apps:clock"] = "clock",
        }}}}))
        local items = desktop_view.join({
            {id = "computer", kind = "shortcut", entry = "chicago.shell.explorer:window", title = "My Computer", x = 2, y = 1},
        }, built)
        local state = {width = 100, height = 36, top = 1, bottom = 36 - chrome_pixels.layout(100, 36).bottom,
            items = items, windows = {}, clock = "12:00",
            menu = {items = catalog.menu_items(built.programs), open = {"Accessories"}, cursor = 1}}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("menu-icons.png", assert(canvas:encode("png")))
        say("catalog → menu and desktop: menu-icons.png")
    end

    -- Desktop widgets (FR-006 §10): three in the right column and a window
    -- over part of the middle one — the scene desktop_widgets_test checks.
    do
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local state = widget_scene.state()
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        store_shots:writefile("widgets.png", assert(widget_scene.compose(painted, state, cell):encode("png")))
        say("desktop widgets: " .. #painted.placements .. " placements → widgets.png")
    end



    -- Real shell chrome with a sample of the cell text layer represented in PNG.
    do
        local mono = assert(load_font("LiberationMono-Regular.ttf", 14))
        local window = {id = "bash", entry = "chicago.tui_desktop.desktop:window_pty",
            title = "Bash", image = "program", window_type = "app", x = 16, y = 6, w = 72, h = 20}
        local state = {width = 100, height = 32, top = 1, bottom = 30, items = {},
            windows = {window}, focused_id = "bash", clock = "12:00"}
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        local defaults = chrome_pixels.content_colors(window)
        canvas:rect((window.x - 1) * cell.w + 1, (window.y - 1) * cell.h + 1,
            window.w * cell.w, window.h * cell.h, defaults.background)
        local rows = {"user@wippy:~$ printf 'Hello, Wippy!\\n'", "Hello, Wippy!", "",
            "user@wippy:~$ ls", "Desktop  Documents  Programs", "", "user@wippy:~$ "}
        for index, row in ipairs(rows) do
            canvas:text(window.x * cell.w + 1, (window.y + index - 1) * cell.h + 1,
                row, {font = mono, color = index == 5 and "#55ffff" or defaults.foreground})
        end
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("bash-black.png", assert(canvas:encode("png")))
    end

    -- A rotation check separate from the theme: if the caption is not visible
    -- on the screen, we need to know whether it is the rotation that does not
    -- work or the place that was computed wrong.
    do
        local label = chrome.MENU_BANNER
        local tw = bold:measure(label)
        local th = bold:height()
        local temp = gfx.raster(tw, th + 2)
        temp:fill("#000080")
        temp:text(1, 1, label, {font = bold, color = "#ffffff"})

        local canvas = gfx.raster(60, tw + 20)
        canvas:fill("#c0c0c0")
        canvas:blit(temp, 4, 8, {rotate = 270})
        canvas:blit(temp, 34, 8, {rotate = 90})
        local bytes = canvas:encode("png")
        if bytes then
            store_shots:writefile("banner.png", bytes)
            say(string.format("rotation: string %d×%d px, 270° on the left, 90° on the right → banner.png",
                tw, th))
        end
    end

    local steady = check_frames(cell, font)
    if not steady then
        say("FAILURE: rasters do not outlive the frame — the screen will be correct, but everything will be flying")
    end

    menu_icons_shot()
    screen_shot("desktop.png", nil)
    screen_shot("menu-empty.png", "empty")
    screen_shot("menu-failure.png", "failure")
    screen_shot("menu-context.png", "context")
    screen_shot("desktop-failure.png", "layout")
    screen_shot("menu-over-window.png", "over")

    -- Native 32px and 16px assets side by side, rendered through the real gfx.
    local atlas = gfx.raster(960, ((#images.NAMES + 4) // 5) * 80)
    atlas:fill("#c0c0c0")
    for index, name in ipairs(images.NAMES) do
        local x = ((index - 1) % 5) * 192 + 12
        local y = ((index - 1) // 5) * 80 + 8
        for _, size in ipairs({32, 16}) do
            local picture, why = images.get(name, size)
            if not picture then error(tostring(why)) end
            atlas:blit(picture, size == 32 and x or x + 52, size == 32 and y or y + 8)
        end
        atlas:text(x, y + 44, name, {font = font, color = "#000000"})
    end
    store_shots:writefile("stock-icons.png", assert(atlas:encode("png")))

    -- View windows whole: the pieces are gathered into one raster at the same
    -- coordinates at which the surface will place them. Look with your eyes:
    -- the calendar, the arrows, the colors of the calculator's captions — no
    -- test will show this.
    local function view_shot(name, lib: any, window: any, cols: any, rows: any)
        local store = rasters.store()
        local inner = {x = 1, y = 1, cols = cols, rows = rows}
        store.begin()
        local placed, why = lib.placement(window, inner, cell, {face = font, bold = bold}, store)
        if not placed then
            say("FAILURE: " .. name .. " was not drawn: " .. tostring(why))
            return
        end
        -- A renderer may return one placement instead of a list (the SDK does so).
        if placed.raster then placed = {placed} end
        local cw = math.tointeger(cell.w) or 10
        local ch = math.tointeger(cell.h) or 20
        local whole_view = gfx.raster((math.tointeger(cols) or 1) * cw, (math.tointeger(rows) or 1) * ch)
        whole_view:fill("#c0c0c0")
        for _, item in ipairs(placed) do
            local at: any = item
            whole_view:blit(at.raster :: gfx.Raster, ((math.tointeger(at.x) or 1) - 1) * cw + 1,
                ((math.tointeger(at.y) or 1) - 1) * ch + 1)
        end
        local bytes = whole_view:encode("png")
        if bytes then
            store_shots:writefile(name .. ".png", bytes)
            say(string.format("%s: %d placements → %s.png", name, #placed, name))
        end
    end
    -- "System Properties", three tabs on one snapshot state.
    do
        local snap: any = {hostname = "kickside", pid = "964748", cwd = "/home/butschster/repos/wippy/kickside",
            node_id = "node-1", node_role = "leader", goroutines = 428, cpu_count = 8, max_procs = 8,
            memory = {alloc = 100 * 1024 * 1024, heap_in_use = 200 * 1024 * 1024, heap_sys = 300 * 1024 * 1024,
                heap_released = 10 * 1024 * 1024, num_gc = 57, sys = 320 * 1024 * 1024},
            hosts = {{id = "app:processes", workers = 4, processes = 64, executed = 1000},
                {id = "app.workers:host", workers = 2, processes = 12, executed = 88}},
            modules = {{name = "gfx"}, {name = "tty"}, {name = "sql"}, {name = "json"}}}
        local records = {{id = "app:db", kind = "db.sql.sqlite"}, {id = "app:fs", kind = "fs.directory"},
            {id = "app:system_fonts", kind = "fs.directory"}, {id = "app:api", kind = "http.service"},
            {id = "wippy.terminal:host", kind = "terminal.host"}}
        local sysprops_model = require("sysprops_model")
        local tree = sysprops_model.tree(snap, records)
        for tab = 1, 3 do
            local state: any = {tab = tab, snapshot = snap, records = records, tree = tree,
                expanded = sysprops_model.expanded_all(tree), selected = "host:app:processes"}
            view_shot("sysprops-" .. tab, sdk_render, {id = "shot", state_revision = tab, content_state = {sdk = 1, revision = tab,
                interaction = ui.interaction(), ui = sysprops_window.definition.view(state, {width = 58, height = 22})}}, 58, 22)
        end
    end
    -- Folder windows (FR-008 §8): My Computer in Large Icons without the
    -- toolbar, a drive folder in Details with the toolbar on, and the object
    -- context menu. The window's own `view` on a state built here: no reader,
    -- no compositor — what the SDK renderer makes of the tree.
    do
        local explorer = explorer_window.definition
        local drives = {}
        for _, name in ipairs({"app:app_fs", "app:data_dir", "app:system_fonts", "chicago.shell:assets",
            "keeper:ui_static_fs", "vlad.doom:ui_static_fs"}) do
            drives[#drives + 1] = {id = name, kind = name:find("ui_static", 1, true) and "fs.embed" or "fs.directory"}
        end
        local function folder(path: any, objects: any, extra: any): any
            local state: any = {path = path, objects = model.sort(objects, "name"), selection = {},
                drives = model.drives(drives), view = "large", sort = "name", toolbar = false, statusbar = true,
                browse = "separate"}
            for key, value in pairs(extra or {}) do state[key] = value end
            return state
        end
        local function shot(name: string, state: any, cols: integer, rows: integer)
            view_shot(name, sdk_render, {id = name, state_revision = 1, content_state = {sdk = 1, revision = 1,
                interaction = ui.interaction(), ui = explorer.view(state, {width = cols, height = rows})}}, cols, rows)
        end
        shot("mycomputer", folder("", model.root(drives)), 46, 14)
        local programs = {{entry = "chicago.shell.viewers:notepad", title = "Notepad", image = "notepad",
            file_image = "text_document", file_type = "Text Document", opens = {"txt", "md", "lua", "yaml"}}}
        local stamp = 1789300200
        local files = model.files({
            {name = "explorer", type = "directory", modified = stamp},
            {name = "sdk", type = "directory", modified = stamp - 3600},
            {name = "README.md", type = "file", size = 18342, modified = stamp - 86400},
            {name = "_index.yaml", type = "file", size = 2210, modified = stamp - 7200},
            {name = "window.lua", type = "file", size = 136192, modified = stamp - 600},
            {name = "icon.png", type = "file", size = 1051, modified = stamp - 172800},
        }, "drive/app:app_fs/src", "app:app_fs", "src", programs)
        local details = folder("drive/app:app_fs/src", files, {view = "details", toolbar = true})
        details.selection = {["window.lua"] = true}
        shot("folder-details", details, 70, 20)
        local context = folder("drive/app:app_fs/src", files, {view = "large"})
        context.selection = {["README.md"] = true}
        context.popup = {x = 20, y = 7, target = "object"}
        shot("folder-context", context, 46, 14)
    end
    -- "Display Properties": the four tabs at the entry's 46×24, the client
    -- inside the pixel frame; the Background with a pattern chosen.
    for tab = 1, 4 do
        local state: any = {tab = tab, chosen = "#008080", saved = "#008080", pattern = "Weave", pattern_saved = "(None)",
            info = {screen = {width = 100, height = 28}, cell = {w = cell.w, h = cell.h}, pixels = true},
            persist = function() return true, nil end}
        view_shot("display-" .. tab, sdk_render, {id = "shot", state_revision = tab, content_state = {sdk = 1, revision = tab,
            interaction = ui.interaction(), ui = display_window.definition.view(state, {width = 44, height = 22, native = true})}}, 44, 22)
    end
    -- The farewell screen: the large font is computed from the cell height, as
    -- in the shell.
    do
        local big_size = math.max(20, math.min(64, (cell.h * 17) // 10))
        local big, big_err = load_font(BOLD, big_size)
        if not big then
            say("FAILURE: the large font did not load: " .. tostring(big_err))
        else
            chrome_pixels.use_fonts(font, bold, big)
            chrome_pixels.use_cell_size(cell.w, cell.h)
            local raster, col, row = chrome_pixels.farewell_raster(cell, 100, 28)
            if raster then
                local screen = gfx.raster(100 * cell.w, 28 * cell.h)
                screen:fill("#000000")
                local at_x = ((math.tointeger(col) or 1) - 1) * (math.tointeger(cell.w) or 10) + 1
                local at_y = ((math.tointeger(row) or 1) - 1) * (math.tointeger(cell.h) or 20) + 1
                screen:blit(raster :: gfx.Raster, at_x, at_y)
                local png: any = screen:encode("png")
                store_shots:writefile("farewell.png", png :: string)
                say(string.format("farewell: font %d px, raster at cell %d,%d → farewell.png", big_size, col, row))
            else
                say("FAILURE: the farewell screen was not drawn")
            end
        end
    end

    for _, scene in ipairs(SCENES) do
        local raster = gfx.raster(scene.cols * cell.w, scene.rows * cell.h)
        scene.paint(raster, cell, font, bold)

        local bytes, eerr = raster:encode("png")
        if not bytes then
            say("FAILURE: " .. scene.name .. " did not encode: " .. tostring(eerr))
            return false, eerr
        end

        local path = scene.name .. ".png"
        local ok, werr = store_shots:writefile(path, bytes)
        if not ok then
            say("FAILURE: " .. path .. " was not written: " .. tostring(werr))
            return false, werr
        end
        say(string.format("%-10s %4d×%-4d px  version %d  %d bytes  → test/shots/%s",
            scene.name, scene.cols * cell.w, scene.rows * cell.h,
            raster:version(), #bytes, path))
    end

    local report = table.concat(lines, "\n") .. "\n"
    local wrote, rerr = store_shots:writefile(REPORT, report)
    if not wrote then print("report was not written: " .. tostring(rerr)) end

    return steady, nil
end

return {main = main}
