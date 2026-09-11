-- The second level of the pixel probe: a real PNG.
--
-- The pure-Lua stub catches layout, overlaps and hits in milliseconds, but
-- it has no glyphs and no font metrics either. That an edge came out ONE
-- pixel wide, that Cyrillic got drawn, that the color is the right one — is
-- visible only in the screenshot, and a person or an agent looks at it with
-- Read.
--
-- Draws with THE SAME `butschster.windows.shell:pixels` that will ship to the
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
local run_window = require("run_window")
local render = require("render")
local render_pixels = require("render_pixels")
local datetime_window = require("datetime_window")
local sysprops_window = require("sysprops_window")
local display_window = require("display_window")
local calc_window = require("calc_window")
local taskman_window = require("taskman_window")
local sdk_render = require("sdk_render")
local reg_model = require("reg_model")
local regedit = require("regedit_window")

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
        {id = "butschster.windows.explorer:window", meta = {title = "My Computer", image = "my_computer", group = "", order = 10}},
        {id = "butschster.windows.calc:window", meta = {title = "Calculator", image = "calculator", order = 20}},
        {id = "butschster.windows.datetime:window", meta = {title = "Date & Time", image = "clock", order = 30}},
        {id = "butschster.windows.viewers:notepad", meta = {title = "Notepad", image = "text_document", order = 40}},
        {id = "example:bridge", meta = {title = "Jobs", group = "Programs/Bridge", order = 50}},
        {id = "example:content", meta = {title = "Articles", group = "Programs/Content machine", order = 60}},
        {id = "butschster.tui_desktop.desktop:window_pty", meta = {title = "Bash", image = "program", order = 70}},
        {id = "example:settings", meta = {title = "Properties", group = "Settings", order = 80}},
        {id = "butschster.windows.run:window", meta = {title = "Run…", image = "run", group = "", order = 900}},
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


    -- "My Computer" with the PIXEL backend. The layout is computed by the
    -- same `render.layout` as the cell path — that is what the separation is
    -- for: if they drifted apart, a click would land on a neighbor in one of
    -- the two modes.
    local function explorer_shots(store)
        local view: any = {
            title = "My Computer",
            selected = 2,
            offset = 0,
            objects = {
                {id = "app:app_fs", kind = "drive", title = "app_fs",
                 detail = "app:app_fs · fs.directory"},
                {id = "wippy.facade:public_files", kind = "drive", title = "public_files",
                 detail = "wippy.facade:public_files · fs.directory"},
                {id = "keeper:ui_static_fs", kind = "drive", title = "keeper ui_static_fs",
                 detail = "keeper:ui_static_fs · fs.embed"},
                {id = "programs", kind = "folder", title = "Programs",
                 detail = "12 object(s)"},
                {id = "desktop", kind = "folder", title = "Desktop",
                 detail = "3 object(s)"},
                {id = "windows", kind = "folder", title = "Open Windows",
                 detail = "2 object(s)"},
            },
        }

        local plan = render.layout(view, 46, 14)
        local placements = render_pixels.paint(store, plan, cell,
            {face = font, bold = bold}, "explorer")

        say(string.format("explorer: %d placements, %d icon hits",
            #placements, #plan.cells))

        for _, item in ipairs(placements) do
            local bytes = item.raster:encode("png")
            local file = "explorer-" .. string.gsub(item.id, "[^%w]", "-") .. ".png"
            if bytes then
                store_shots:writefile(file, bytes)
                say(string.format("  %-22s cell %2d,%-2d  %2d×%-2d cells  → %s",
                    item.id, item.x, item.y, item.cols, item.rows, file))
            end
        end

        -- The same frame once more: not a single placement has the right to
        -- be sent again. This is exactly the FR-005 §4 measure, applied to a
        -- real view, not to a training scene.
        local before: any = {}
        for _, item in ipairs(placements) do
            before[item.id] = {raster = item.raster, version = item.raster:version()}
        end
        local again = render_pixels.paint(store, plan, cell,
            {face = font, bold = bold}, "explorer")
        local moved = {}
        for _, item in ipairs(again) do
            local was: any = before[item.id]
            if not was then moved[#moved+1] = item.id .. " (appeared)"
            elseif was.raster ~= item.raster then moved[#moved+1] = item.id .. " (RECREATED)"
            elseif was.version ~= item.raster:version() then moved[#moved+1] = item.id end
        end
        say("explorer, the same frame once more: moved " .. #moved
            .. (#moved == 0 and "" or " — " .. table.concat(moved, ", ")))
        return #moved == 0
    end

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
                {id = "s1", kind = "shortcut", entry = "butschster.windows.explorer:window",
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
                {label = "Open", bold = true, entry = "butschster.windows.explorer:window", title = "My Computer"},
                {label = "Properties", entry = "butschster.windows.sysprops:window", separator_before = true},
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
            state.failure = "database is locked: SELECT id, x, y, image FROM butschster_windows_desktop"
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
            {id = "butschster.windows.explorer:window", meta = {title = "My Computer", image = "my_computer", order = 10, in_menu = false}},
            {id = "app.desktop:window_calc", meta = {title = "Calculator", image = "calculator", group = "Accessories"}},
            {id = "butschster.tui_desktop.apps:commander", meta = {title = "Stand Explorer"}},
            {id = "butschster.tui_desktop.apps:dataflows", meta = {title = "Runs"}},
            {id = "butschster.tui_desktop.apps:bridge_runs", meta = {title = "Job runs"}},
            {id = "butschster.tui_desktop.apps:bridge_jobs", meta = {title = "Bridge jobs"}},
            {id = "butschster.tui_desktop.apps:dataflow_detail", meta = {title = "Run nodes"}},
            {id = "butschster.tui_desktop.apps:clock", meta = {title = "Clock"}},
        }
        local built = catalog.build(records)
        assert(catalog.assign_images(built.programs, {{data = {images = {
            ["butschster.tui_desktop.apps:commander"] = "network_neighborhood",
            ["butschster.tui_desktop.apps:dataflows"] = "run",
            ["butschster.tui_desktop.apps:bridge_runs"] = "documents_stack",
            ["butschster.tui_desktop.apps:bridge_jobs"] = "system",
            ["butschster.tui_desktop.apps:dataflow_detail"] = "program_settings",
            ["butschster.tui_desktop.apps:clock"] = "clock",
        }}}}))
        local items = desktop_view.join({
            {id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window", title = "My Computer", x = 2, y = 1},
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

    -- Same native window path that the compositor now uses for Explorer.
    local function explorer_native_shot()
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local records = {}
        for _, name in ipairs({"app.desktop:system_fonts", "app:app_fs", "app:codex_store", "app:data_dir",
            "app:system_fonts", "app:tmp", "app:uploads", "app:uploads_store", "butschster.blog:ui_fs",
            "butschster.bridge:ui_fs", "butschster.windows:assets", "kickside:ui_fs"}) do
            records[#records + 1] = {id = name, kind = "fs.directory"}
        end
        local objects = model.drives(records)
        for index = #objects + 1, 65 do objects[index] = {id = "fs" .. index, kind = "drive", title = "File system " .. index} end
        local state: any = {width = 110, height = 34, top = 1,
            bottom = 34 - chrome_pixels.layout(110, 34).bottom,
            items = {{id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window",
                title = "My Computer", x = 10, y = 2},
                {id = "programs", kind = "folder", title = "Programs", x = 20, y = 10}},
            windows = {{id = "explorer", entry = "butschster.windows.explorer:window", image = "my_computer",
                title = "My Computer", window_type = "app", content = "pixels",
                render = "butschster.windows.explorer:render_pixels", x = 34, y = 8, w = 64, h = 20,
                content_state = {title = "My Computer", objects = objects, selected = 0, offset = 0}}},
            focused_id = "explorer", clock = "12:00"}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("explorer-native.png", assert(canvas:encode("png")))
        say("pixel explorer window: explorer-native.png")
    end

    -- Fixture metadata mirrors the declarations; the dialog uses its live renderer.
    local function run_shot()
        -- The signed-in user — as the first row of "Start", as on the live
        -- running system.
        chrome.use_user({id = "u1", name = "butschster"})
        chrome_pixels.use_fonts(font, bold)
        chrome_pixels.use_cell_size(cell.w, cell.h)
        local found = catalog.build({
            {id = "butschster.windows.explorer:window", meta = {title = "My Computer", image = "my_computer", order = 10, in_menu = false}},
            {id = "butschster.windows.calc:window", meta = {title = "Calculator", image = "calculator", group = "Accessories", order = 20}},
            {id = "butschster.tui_desktop.desktop:window_pty", meta = {title = "Bash", image = "console", group = "Accessories"}},
            {id = "butschster.windows.run:window", meta = {title = "Run…", image = "run", order = 900}},
        })
        local items = found.programs
        local state: any = {width = 100, height = 32, top = 1,
            bottom = 32 - chrome_pixels.layout(100, 32).bottom,
            items = {{id = "computer", kind = "shortcut", entry = "butschster.windows.explorer:window",
                title = "My Computer", x = 8, y = 2}},
            -- The title is the one the window names itself (`definition.title`):
            -- "Run" without the ellipsis, the ellipsis stays with the menu item.
            windows = {{id = "run", entry = "butschster.windows.run:window", image = "run",
                title = run_window.definition.title, window_type = "dialog", content = "pixels", resizable = false,
                render = "butschster.windows.sdk:render", x = 30, y = 7, w = 50, h = 10,
                content_state = {sdk = 1, revision = 1, interaction = ui.interaction(),
                    ui = run_window.definition.view({text = "claude --resume", pending = false}, {width = 48, height = 7})}}},
            focused_id = "run", clock = "12:00",
            menu = {items = catalog.menu_items(items), open = {"Accessories"}, cursor = 1}}
        local painted = chrome_pixels.paint(state, cell.w, cell.h)
        local canvas = gfx.raster(state.width * cell.w, state.height * cell.h)
        canvas:fill(color_desktop)
        for _, placement in ipairs(painted.placements) do
            canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
        end
        store_shots:writefile("run-bash.png", assert(canvas:encode("png")))
    end
    run_shot()

    -- Sample data goes through the same Task Manager renderer as live windows.
    do
        local MB = 1024 * 1024
        local state: any = {tab = 3, selected = 0, offset = 0, heap_history = {}, goroutine_history = {},
            snapshot = {taken = 1788858300, goroutines = 428, cpu_count = 8, max_procs = 8,
                pid = "24680", hostname = "wippy-workstation", node_id = "local", node_role = "standalone",
                memory = {alloc = 286 * MB, heap_in_use = 312 * MB, heap_sys = 384 * MB, heap_released = 46 * MB, num_gc = 128},
                processes = {}, hosts = {{id = "app:processes", processes = 64}, {id = "wippy:processes", processes = 12}}, members = {{id = "local"}}},
            windows = {{id = "w1", title = "My Computer", ready = true, image = "my_computer"},
                {id = "w2", title = "Notepad — notes.txt", ready = true, image = "text_document"},
                {id = "w3", title = "Bash", ready = true, image = "program"},
                {id = "w4", title = "Task Manager", ready = true, image = "system"}}}
        for index = 1, 150 do
            state.goroutine_history[index] = math.floor(360 + math.sin(index / 8) * 24 + math.sin(index / 3) * 14 + index / 3)
            state.heap_history[index] = (230 + (index % 45) * 1.8) * MB
        end
        for index = 1, 76 do
            state.snapshot.processes[index] = {pid = "local:process-" .. string.format("%04d", index),
                source = index == 1 and "butschster.windows:shell" or "app.workers:worker_" .. string.format("%02d", index),
                state = index % 4 == 0 and "running" or "waiting", steps = index * 147, started = 1788850100}
        end
        local names = {"applications", "processes", "performance", "node"}
        for tab = 1, 4 do
            state.tab, state.selected_id = tab, tab == 1 and "w2" or (tab == 2 and "local:process-0002" or nil)
            local client = {width = 76, height = 24}
            local scene = {width = 110, height = 36, top = 1, bottom = 34, items = {}, clock = "12:00",
                focused_id = "taskman", windows = {{id = "taskman", entry = "butschster.windows.taskman:window",
                    title = "Task Manager", image = "system", window_type = "app", content = "pixels",
                    render = "butschster.windows.sdk:render", state_revision = tab, x = 17, y = 4, w = 78, h = 27,
                    content_state = {sdk = 1, revision = tab, interaction = ui.interaction(),
                        ui = taskman_window.definition.view(state, client)}}}}
            local rendered = chrome_pixels.paint(scene, cell.w, cell.h)
            local canvas = gfx.raster(scene.width * cell.w, scene.height * cell.h)
            canvas:fill(color_desktop)
            for _, placement in ipairs(rendered.placements) do
                canvas:blit(placement.raster, (placement.x - 1) * cell.w + 1, (placement.y - 1) * cell.h + 1)
            end
            store_shots:writefile("taskman-" .. names[tab] .. ".png", assert(canvas:encode("png")))
        end
    end

    -- Real shell chrome with a sample of the cell text layer represented in PNG.
    do
        local mono = assert(load_font("LiberationMono-Regular.ttf", 14))
        local window = {id = "bash", entry = "butschster.tui_desktop.desktop:window_pty",
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

    explorer_native_shot()
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

    local explorer_ok = explorer_shots(rasters.store())
    if not explorer_ok then
        say("FAILURE: the explorer recreates rasters — the screen will stay OLD, not slow")
    end

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
    view_shot("datetime", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
        interaction = ui.interaction(), ui = datetime_window.definition.view({tab = 1, clock = {
            year = 2026, month = 9, day = 8, hour = 21, minute = 47, second = 23,
            first_weekday = 1, days = 30, zone = "UTC+04:00"}}, {width = 42, height = 20})}}, 42, 20)
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
    do
        -- Network Neighborhood: a mesh of two nodes, the leader is the
        -- neighbor. The screenshot is taken from an INVENTED membership on
        -- purpose: the live cluster here is single-node, and a "one computer"
        -- picture would show neither the leader nor the addresses.
        local network_window = require("network_window")
        local snap: any = {node_id = "kickside", node_addr = "127.0.0.1:7946", node_role = "voter",
            leader = "mesh-node",
            members = {{id = "mesh-node", is_local = false, addr = "127.0.0.1:7947"},
                {id = "kickside", is_local = true, addr = "127.0.0.1:7946"}}}
        local state: any = {snapshot = snap, selected = "kickside", about = false}
        view_shot("network", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
            interaction = ui.interaction(), ui = network_window.definition.view(state, {width = 60, height = 14})}}, 60, 14)
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
    do
        -- Registry viewer: a tree with expanded branches and an entry with fields.
        local sample = {
            {id = "app:db", kind = "db.sql.sqlite", meta = {comment = "Stand database"}, data = {file = ".wippy/app.db"}},
            {id = "app:api", kind = "http.router", meta = {}, data = {prefix = "/api/v1"}},
            {id = "app.desktop:window_calc", kind = "process.lua", meta = {type = "tui_desktop.window", title = "Calculator"}, data = {}},
            {id = "butschster.windows.shell:chrome", kind = "library.lua", meta = {comment = "Cell theme"}, data = {source = "file://chrome.lua", modules = {"tty"}}},
            {id = "butschster.windows.shell:pixels", kind = "library.lua", meta = {comment = "Pixel primitives"}, data = {source = "file://pixels.lua"}},
            {id = "butschster.windows.shell:palette", kind = "library.lua", meta = {}, data = {}},
            {id = "butschster.windows:shell", kind = "process.lua", meta = {title = "Windows 95 shell"}, data = {method = "main", modules = {"gfx", "tty"}}},
            {id = "butschster.windows:terminal", kind = "terminal.host", meta = {}, data = {hide_logs = true}},
            {id = "wippy.security:process", kind = "security.group", meta = {}, data = {}},
        }
        local session = regedit.session(sample)
        for _, key in ipairs({"", "butschster", "butschster.windows", "butschster.windows.shell"}) do
            session.expanded[key] = true
        end
        session.rows = reg_model.flatten(session.root, session.expanded)
        session.selected = "butschster.windows.shell:chrome"
        view_shot("regedit", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
            interaction = ui.interaction(), ui = regedit.definition.view(session, {width = 78, height = 22})}}, 78, 22)
    end
    do
        local calc_state = calc_window.definition.init(nil, {})
        calc_state.calc.entry, calc_state.calc.memory, calc_state.calc.pressed = "1234.5", 1, "5"
        view_shot("calc", sdk_render, {id = "shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
            interaction = ui.interaction(),
            ui = calc_window.definition.view(calc_state, {width = 27, height = 14, native = true})}}, 27, 14)
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

    return steady and explorer_ok, nil
end

return {main = main}
