-- Pixel probe: a `gfx` stand-in in pure Lua.
--
-- It checks what is not visible in the code and on the running system is
-- visible only to a human eye: where the pixels landed, whether the hits
-- matched the drawing, and whether everything that gets clicked is aligned to
-- the cell grid.
--
-- Works without a runtime and without a terminal, in milliseconds. This is the
-- first of two levels; the second is a real PNG through `raster:encode`, and it
-- is in the test suite. The levels share ONE AND THE SAME primitive code: the
-- stand-in replaces `gfx`, and the drawing is done by `src/shell/pixels.lua` —
-- the very one that goes to the running system.
--
-- ─── THE CAVEAT WITHOUT WHICH THE PROBE BECOMES A FALSE WITNESS ─────────
--
-- The stand-in DOES NOT KNOW the real font metrics. `font:measure` here
-- computes the width by approximation, not by glyphs, so the probe checks the
-- LAYOUT AT GIVEN MEASUREMENTS, not the measurements themselves. A caption
-- that will not fit into a button on the running system fits here.
--
-- Only the second level knows the real metrics: there it is a live `gfx.font`
-- and a live font. The two checks do not replace each other — this one says
-- where the rectangles landed, that one — how wide the text turned out.

-- Markers for build.py: it replaces the lines below with the bodies of the
-- files themselves.
local BASE = "src/"

-- The cell size of the person's terminal, measured: Windows Terminal answered
-- `CSI 16 t`. The numbers here are not "roughly like this": the whole
-- quantization check rests on them, and were we to put 8×16 — the alignment
-- would add up where on the live screen it does not.
local CELL = {w = 10, h = 20}

-- ─── gfx stand-in ────────────────────────────────────────────────────────
--
-- Records every call. The pixels are held in a sparse table: a window frame
-- is half a million pixels, and a dense array here would take longer to
-- compute than it takes to draw on the running system.

local function new_raster(w, h)
    local self = {}
    local px = {}
    local version = 0
    local ops = {}

    local ink = {}

    local function put(x, y, colour, is_text)
        if x < 1 or y < 1 or x > w or y > h then return false end
        px[(y - 1) * w + x] = colour
        -- Text is marked separately: a filled rectangle and a caption of the
        -- same colour are otherwise indistinguishable on the map, and the
        -- difference between "a white fill here" and "a white caption here"
        -- is the whole difference between "empty" and "the caption spilled
        -- out of its element".
        if is_text then ink[(y - 1) * w + x] = true end
        return true
    end

    self.__raster = true
    self.__ops = ops
    self.__w, self.__h = w, h

    self.size = function() return w, h end
    self.version = function() return version end

    self.fill = function(_, colour)
        for y = 1, h do for x = 1, w do px[(y - 1) * w + x] = colour end end
        version = version + 1
        ops[#ops+1] = {op = "fill", colour = colour}
    end

    self.rect = function(_, x, y, rw, rh, colour)
        local touched = false
        for row = y, y + rh - 1 do
            for col = x, x + rw - 1 do
                if put(col, row, colour) then touched = true end
            end
        end
        -- The version moves only if pixels moved: a version that went forward
        -- without a drawing would make the surface resend the same picture
        -- every frame — a still image would start flickering.
        if touched then version = version + 1 end
        ops[#ops+1] = {op = "rect", x = x, y = y, w = rw, h = rh, colour = colour}
    end

    self.set = function(_, x, y, colour)
        if put(x, y, colour) then version = version + 1 end
        ops[#ops+1] = {op = "set", x = x, y = y, colour = colour}
    end

    self.text = function(_, x, y, text, opts)
        opts = opts or {}
        local font = opts.font
        local advance = font and font:measure(text) or 0
        local height = font and font:height() or 0
        -- Text is not broken down into pixels — the stand-in has no glyphs. The
        -- occupied rectangle is marked so the map shows WHERE the caption is,
        -- and it is immediately visible if it spilled out of its element.
        for row = y, y + height - 1 do
            for col = x, x + advance - 1 do put(col, row, opts.color or "#000000", true) end
        end
        if advance > 0 then version = version + 1 end
        ops[#ops+1] = {op = "text", x = x, y = y, text = text,
                       w = advance, h = height, colour = opts.color}
        return advance
    end

    -- Transfer of one raster into another. The stand-in does not transfer
    -- pixels — it marks the OCCUPIED area and records the call: the map in
    -- cells shows where the drawing landed, and the accuracy of the colours is
    -- the snapshot's business.
    --
    -- A right-angle rotation swaps width and height, and that matters here:
    -- the room for a rotated caption is computed from its HEIGHT, and a
    -- mistake in this swap is exactly what cannot be seen on the map otherwise.
    self.blit = function(_, source, x, y, opts)
        opts = opts or {}
        local sw, sh = source:size()
        local turn = tonumber(opts.rotate) or 0
        if turn == 90 or turn == 270 then sw, sh = sh, sw end
        local touched = false
        for row = y, y + sh - 1 do
            for col = x, x + sw - 1 do
                if put(col, row, "#blit") then touched = true end
            end
        end
        if touched then version = version + 1 end
        ops[#ops+1] = {op = "blit", x = x, y = y, w = sw, h = sh, rotate = turn}
    end

    self.at = function(x, y) return px[(y - 1) * w + x] end
    self.is_text = function(x, y) return ink[(y - 1) * w + x] == true end
    return self
end

-- Font stand-in. Width by approximation — see the caveat in the header.
local function new_font(size)
    local self = {}
    local advance = math.floor(size * 0.55)
    self.measure = function(_, text)
        local count = 0
        for _ in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
        return count * advance, size
    end
    self.height = function() return size end
    self.ascent = function() return math.floor(size * 0.8) end
    self.size = function() return size end
    return self
end

local gfx = {}
gfx.supported = function() return "sixel", nil end
gfx.cell_size = function() return CELL.w, CELL.h end
gfx.raster = function(w, h) return new_raster(w, h) end
gfx.font = function(_, opts) return new_font((opts and opts.size) or 12) end

-- ─── tty stand-in ────────────────────────────────────────────────────────
--
-- IT CAN DO EXACTLY AS MUCH AS IS NEEDED FOR THE LIBRARIES TO LOAD. This is a
-- condition, not economy: a stub that starts pretending to be the real `tty`
-- will drift from it, and the checks will start lying the other way.
--
-- `widgets` and `icons` build style tables at load time — they need only
-- `tty.style()`. NOBODY here needs a canvas: the probe calls `render.layout`,
-- which draws nothing, and `render_pixels`, which draws into a raster.
-- So `tty.canvas` is absent, and an attempt to draw into cells fails loudly —
-- instead of quietly drawing into nowhere.
local function new_style()
    local self: any = {}
    local function same() return self end
    self.foreground = same
    self.background = same
    self.bold = same
    self.faint = same
    self.underline = same
    self.width = same
    self.render = function(_, text) return tostring(text) end
    return self
end

local tty = {style = new_style}
tty.text = {
    width = function(text)
        local count = 0
        for _ in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
        return count
    end,
    truncate = function(text) return text end,
}

-- ─── loading the primitives ──────────────────────────────────────────────
-- Decoder double checks placement geometry only. Native PNG bytes, masks and
-- colours are checked by images_test and the real paint-png renderer.
gfx.image = function(data) return new_raster(tonumber(data), tonumber(data)) end
local fs = {get = function()
    return {readfile = function(_, path) return path:match("^(%d+)/") end}
end}
local logger = {named = function() return {warn = function() end} end}
local modules = {gfx = gfx, tty = tty, fs = fs, logger = logger}
local saved_require = require
require = function(name)
    if modules[name] then return modules[name] end
    if saved_require then return saved_require(name) end
    error("no module " .. tostring(name))
end

modules.scroll = dofile(BASE .. "core/scroll.lua")
modules.sdk_render, modules.regedit_render = {}, {}
modules.palette = dofile(BASE .. "shell/palette.lua")
modules.glyphs = dofile(BASE .. "shell/glyphs.lua")
modules.widgets = dofile(BASE .. "shell/widgets.lua")
modules.icons = dofile(BASE .. "shell/icons.lua")
modules.images = dofile(BASE .. "shell/images.lua")
modules.pixels = dofile(BASE .. "shell/pixels.lua")
modules.rasters = dofile(BASE .. "shell/rasters.lua")
-- `chrome` is pulled in here not for drawing into cells but for ONE table of
-- title-button sets: a second list would drift from the first.
modules.menu_layout = dofile(BASE .. "shell/menu_layout.lua")
modules.chrome = dofile(BASE .. "shell/chrome.lua")
modules.render = dofile(BASE .. "explorer/render.lua")
modules.render_pixels = dofile(BASE .. "explorer/render_pixels.lua")
modules.explorer_layout = modules.render
modules.explorer_pixels = modules.render_pixels
-- Other clients have runtime tests; this geometry probe does not open them.
modules.datetime_render, modules.calc_render, modules.picture_render, modules.run_render, modules.taskman_render = {}, {}, {}, {}, {}
modules.placements = dofile(BASE .. "shell/placements.lua")
modules.chrome_pixels = dofile(BASE .. "shell/chrome_pixels.lua")

local pixels = modules.pixels
local rasters = modules.rasters
local chrome = modules.chrome
local chrome_pixels = modules.chrome_pixels
local render = modules.render
local render_pixels = modules.render_pixels

-- ─── printing ────────────────────────────────────────────────────────────
--
-- The map is printed in CELLS, not in pixels: a thousand by five hundred and
-- sixty pixels is unreadable, and the mouse speaks in cells anyway. Each cell
-- is the letter of the colour that dominates it, and next to it is the same
-- grid of hits. This is the check "what is drawn is what gets pressed" in the
-- units in which one clicks.

local alphabet = "abcdefghijklmnopqrstuvwxyz"

local function cell_map(raster, hits)
    local w, h = raster:size()
    local cols = math.ceil(w / CELL.w)
    local rows = math.ceil(h / CELL.h)

    local letters, legend, next_letter = {}, {}, 0
    local function mark(colour)
        if not colour then return "." end
        if not letters[colour] then
            next_letter = next_letter + 1
            letters[colour] = alphabet:sub(next_letter, next_letter)
            legend[#legend+1] = letters[colour] .. " = " .. colour
        end
        return letters[colour]
    end

    print(string.format("    raster %d×%d px = %d×%d cells%s, version %d, calls %d",
        w, h, cols, rows,
        (w % CELL.w == 0 and h % CELL.h == 0) and "" or "  ◄ NOT A WHOLE NUMBER OF CELLS",
        raster:version(), #raster.__ops))

    for row = 1, rows do
        local line = {}
        for col = 1, cols do
            -- The dominant colour of the cell: it shows what a person will see
            -- when the picture lands in the grid.
            local tally, best, top, text = {}, nil, 0, false
            for y = (row - 1) * CELL.h + 1, math.min(row * CELL.h, h) do
                for x = (col - 1) * CELL.w + 1, math.min(col * CELL.w, w) do
                    local colour = raster.at(x, y)
                    if colour then
                        tally[colour] = (tally[colour] or 0) + 1
                        if tally[colour] > top then top, best = tally[colour], colour end
                    end
                    if raster.is_text(x, y) then text = true end
                end
            end
            local letter = mark(best)
            line[col] = text and letter:upper() or letter
        end

        local marks = {}
        for col = 1, cols do marks[col] = "·" end
        for index, hit in ipairs(hits or {}) do
            if row >= hit.row and row <= (hit.bottom_row or hit.row) then
                -- The letter by the hit's NUMBER, not by the first letter of the
                -- name: "minimize" and "maximize" give the same letter, and on
                -- the map two different buttons would look like one.
                local letter = alphabet:sub(index, index)
                for col = hit.from, hit.to do
                    if col >= 1 and col <= cols then marks[col] = letter end
                end
            end
        end

        print(string.format("%3d |%s|%s|", row, table.concat(line), table.concat(marks)))
    end
    print("    colours — " .. table.concat(legend, ", "))
end

-- ─── checks ──────────────────────────────────────────────────────────────
--
-- The probe not only shows but also ASSERTS. The FR-005 §4a rule cannot be
-- checked by eye on a snapshot: whether the grab zone is aligned to the grid
-- is visible only as a number.

local failures = 0
local function check(ok, what)
    if ok then return end
    failures = failures + 1
    print("    ✗ " .. what)
end

-- Two hits have no right to share a cell.
--
-- This is NOT nitpicking and not something visible on a snapshot. Three title
-- buttons 16 px wide at an 18 px pitch look flawless, but with a 10 px cell
-- their zones overlap: a click on the shared column belongs to two buttons at
-- once, and the one found first wins. Silently.
local function check_overlap(hits)
    local owner = {}
    for _, hit in ipairs(hits or {}) do
        for row = hit.row, (hit.bottom_row or hit.row) do
            for col = hit.from, hit.to do
                local key = row .. ":" .. col
                local taken = owner[key]
                check(taken == nil,
                    "cell " .. col .. "," .. row .. " belongs to two at once: "
                        .. tostring(taken) .. " and " .. tostring(hit.id))
                owner[key] = tostring(hit.id)
            end
        end
    end
end

local function check_hits(raster, hits)
    local w, h = raster:size()
    local cols = math.ceil(w / CELL.w)
    local rows = math.ceil(h / CELL.h)
    for _, hit in ipairs(hits or {}) do
        local name = tostring(hit.id or "unnamed")
        check(hit.from >= 1 and hit.to <= cols,
            name .. ": the hit ran off the raster horizontally ("
                .. hit.from .. ".." .. hit.to .. " with " .. cols .. " columns)")
        check(hit.row >= 1 and (hit.bottom_row or hit.row) <= rows,
            name .. ": the hit ran off the raster vertically")
        check(hit.from <= hit.to and hit.row <= (hit.bottom_row or hit.row),
            name .. ": degenerate hit")
        check(math.floor(hit.from) == hit.from and math.floor(hit.row) == hit.row,
            name .. ": the hit is not in whole cells — the mouse knows no such coordinates")
    end
end

-- ─── scenes ──────────────────────────────────────────────────────────────

local function scene(title, cols, rows, paint)
    local raster = gfx.raster(cols * CELL.w, rows * CELL.h)
    print("")
    print("┌── " .. title)
    local hits = paint(raster) or {}
    cell_map(raster, hits)
    check_hits(raster, hits)
    check_overlap(hits)
    return raster, hits
end

local font = gfx.font("", {size = 13})

-- Clickable things are placed by CELLS: `pixels.box` gives the place, the hit
-- is the same cells named BEFORE painting, as the layout does in the shell,
-- not recomputed from the drawing's pixels. `inset` is how much smaller the
-- drawing is than its cells: decoration is free, interaction is quantized.
local function place_button(raster, col, row, cols, rows, spec, inset)
    local area = pixels.box(col, row, cols, rows, CELL)
    pixels.button(raster, area.x + inset, area.y + inset,
        area.w - inset * 2, area.h - inset * 2, spec, CELL)
    return {id = spec.id, from = col, to = col + cols - 1, row = row, bottom_row = row + rows - 1}
end

scene("window: a one-pixel edge, a title and three buttons", 30, 8, function(raster)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)

    -- The title INSIDE the frame, as in the reference: the strip starts after
    -- the edge.
    raster:rect(4, 4, w - 6, CELL.h - 2, "#000080")
    raster:text(8, 6, "My Computer", {font = font, color = "#ffffff"})

    -- Title buttons are placed IN CELLS, two per button, and this is not
    -- decoration: placed by pixels at an 18 pitch, they would look the same,
    -- but the hit zones would overlap — the probe caught exactly this when the
    -- scene was written in pixels.
    local hits = {}
    local ids = {"minimize", "maximize", "close"}
    for index, id in ipairs(ids) do
        hits[#hits+1] = place_button(raster, 24 + (index - 1) * 2, 1, 2, 1,
            {id = id, label = "", font = font}, 2)
    end

    pixels.field(raster, 4, CELL.h + 4, w - 6, h - CELL.h - 7)
    return hits
end)

scene("dialog buttons: normal, pressed", 24, 4, function(raster)
    local w, h = raster:size()
    pixels.panel(raster, 1, 1, w, h)
    local hits = {}
    hits[#hits+1] = place_button(raster, 2, 2, 7, 1,
        {id = "ok", label = "OK", font = font}, 2)
    hits[#hits+1] = place_button(raster, 10, 2, 7, 1,
        {id = "cancel", label = "Cancel", font = font, pressed = true}, 2)
    return hits
end)

-- ─── THE MAIN MEASURE: a frame drawn twice ──────────────────────────────
--
-- This is the first thing the probe must be able to measure, and here is why.
--
-- If rasters are recreated every frame, the screen stays CORRECT. The picture
-- is the same, the colours are the same, nothing flickers — everything just
-- flies anew, and a keystroke costs forty-seven milliseconds instead of one.
-- Such an error cannot be seen by eye either on a snapshot or on the running
-- system: slowness has no call stack.
--
-- It is checked in the only possible way — by versions. A frame without
-- changes has no right to move a single one.

-- A shell frame in miniature: a title, two side edges, a taskbar.
-- Cut by ROWS on purpose (FR-005 §3): one placement for the whole window
-- would mean that typing text inside redraws all the chrome.
local function paint_frame(store, state)
    store.begin()

    local title, dirty = store.take("win:title", 30, 1, CELL,
        state.title .. "|" .. tostring(state.focused))
    if dirty then
        pixels.panel(title, 1, 1, 300, CELL.h)
        title:rect(2, 2, 296, CELL.h - 4, state.focused and "#000080" or "#808080")
        pixels.label(title, 2, 2, 296, CELL.h - 4, state.title, font, "#ffffff")
    end
    store.place("win:title", 1, 1)

    for _, side in ipairs({{"left", 1}, {"right", 30}}) do
        local edge, edge_dirty = store.take("win:" .. side[1], 1, 6, CELL, tostring(state.rows))
        if edge_dirty then pixels.panel(edge, 1, 1, CELL.w, 6 * CELL.h) end
        store.place("win:" .. side[1], side[2], 2)
    end

    local bar, bar_dirty = store.take("taskbar", 30, 1, CELL, state.clock)
    if bar_dirty then
        pixels.panel(bar, 1, 1, 300, CELL.h)
        pixels.label(bar, 240, 1, 56, CELL.h, state.clock, font)
    end
    store.place("taskbar", 1, 8)

    if state.menu then
        local menu, menu_dirty = store.take("menu", 12, 5, CELL, state.menu)
        if menu_dirty then pixels.panel(menu, 1, 1, 120, 5 * CELL.h) end
        store.place("menu", 1, 3)
    end

    return store.frame(CELL)
end

-- A frame snapshot: for each placement — THE RASTER ITSELF and its version.
--
-- The raster is not here for beauty. Comparing versions alone does NOT CATCH
-- this error, and that was found out by mutation: a store that recreates the
-- raster every frame hands out a fresh buffer with version 0, the code drawing
-- into it repeats the same calls — and the version comes out THE VERY SAME.
-- The numbers match, and everything flies to the screen anew.
--
-- Only identity tells them apart: the surface can understand that the picture
-- did not change only while it is THE SAME raster. A new object with the same
-- number is, for the surface, a new picture.
local function snapshot(placements)
    local out = {}
    for _, item in ipairs(placements) do
        out[item.id] = {raster = item.raster, version = item.raster:version()}
    end
    return out
end

local function moved(before, after)
    local names = {}
    for id, now in pairs(after) do
        local was = before[id]
        if not was then
            names[#names+1] = id .. " (appeared)"
        elseif was.raster ~= now.raster then
            names[#names+1] = id .. " (RECREATED)"
        elseif was.version ~= now.version then
            names[#names+1] = id
        end
    end
    table.sort(names)
    return names
end

do
    print("")
    print("┌── rasters outlive the frame")

    local store = rasters.store()
    local state = {title = "My Computer", focused = true, rows = 6, clock = "21:47"}

    local first = paint_frame(store, state)
    local after_first = snapshot(first)
    print("    first frame: placements " .. #first .. ", rasters in the store " .. store.size())

    -- The same frame once more. Not a single version has the right to move.
    local second = paint_frame(store, state)
    local after_second = snapshot(second)
    local changed = moved(after_first, after_second)
    check(#changed == 0,
        "a frame without changes moved versions: " .. table.concat(changed, ", ")
            .. " — the rasters are recreated, and the screen is correct all the while")
    print("    the same frame repeated: versions moved " .. #changed)

    -- The clock changed — ONLY the taskbar must be redrawn. If more was
    -- redrawn, then someone's key depends on something the picture does not
    -- depend on.
    state.clock = "21:48"
    local third = paint_frame(store, state)
    local ticked = moved(after_second, snapshot(third))
    check(#ticked == 1 and ticked[1] == "taskbar",
        "the clock change redrew: " .. table.concat(ticked, ", ") .. " (expected only taskbar)")
    print("    the clock changed: redrawn " .. table.concat(ticked, ", "))

    -- An open menu adds a placement; a closed one must DISAPPEAR from the
    -- list, not stay as a picture on top of the screen.
    state.menu = "open"
    local with_menu = paint_frame(store, state)
    check(#with_menu == #third + 1, "the menu did not add a placement")

    state.menu = nil
    local without_menu = paint_frame(store, state)
    check(#without_menu == #third, "the closed menu stayed in the list of placements")
    local names = {}
    for _, item in ipairs(without_menu) do names[#names+1] = item.id end
    check(not (table.concat(names, ",")):find("menu", 1, true),
        "the menu stayed in the frame after closing")
    print("    menu open/closed: placements " .. #with_menu .. " / " .. #without_menu
        .. ", rasters in the store " .. store.size())

    -- A store that only grows is a leak, and it shows not as a refusal but as
    -- memory. The discarded menu must leave the store too.
    check(store.size() == #without_menu,
        "the store kept more rasters than there are in the frame: " .. store.size())
end

-- ─── EXPLORER WITH THE PIXEL BACKEND ────────────────────────────────────
--
-- What is checked here is the SLICING and the KEYS — something not visible on
-- a snapshot at all, which would otherwise cost a full run on the local build.
--
-- The layout is computed by the same `render.layout` as the cell path. Were
-- they to drift apart, a click would land on a neighbour in one of the two
-- modes, and both snapshots would look right.

local function explorer_view(extra: any)
    local view: any = {
        title = "My Computer",
        selected = 2,
        offset = 0,
        objects = {
            {id = "app:app_fs", kind = "drive", title = "app_fs", detail = "app:app_fs"},
            {id = "wippy.facade:public_files", kind = "drive", title = "public_files",
             detail = "wippy.facade:public_files"},
            {id = "keeper:ui_static_fs", kind = "drive", title = "keeper ui_static_fs",
             detail = "keeper:ui_static_fs"},
            {id = "programs", kind = "folder", title = "Programs", detail = "12 objects"},
            {id = "desktop", kind = "folder", title = "Desktop", detail = "3 objects"},
            {id = "windows", kind = "folder", title = "Open Windows", detail = "2 objects"},
        },
    }
    for key, value in pairs(type(extra) == "table" and extra or {}) do view[key] = value end
    return view
end

local function paint_explorer(store, view)
    local plan = render.layout(view, 46, 14)
    return render_pixels.paint(store, plan, CELL, {face = font, bold = font}, "explorer"), plan
end

do
    print("")
    print("┌── explorer: slicing into placements and keys")

    local store = rasters.store()
    local placements, plan = paint_explorer(store, explorer_view())

    for _, item in ipairs(placements) do
        print(string.format("    %-18s cell %2d,%-3d %2d×%-3d cells", item.id,
            item.x, item.y, item.cols, item.rows))
    end

    -- Slicing by ROWS: placements have no right to cover each other,
    -- otherwise redrawing one touches the rows of another and that one is sent
    -- anew as well.
    local occupied = {}
    for _, item in ipairs(placements) do
        for row = item.y, item.y + item.rows - 1 do
            check(occupied[row] == nil,
                "row " .. row .. " is shared by two placements: "
                    .. tostring(occupied[row]) .. " and " .. item.id)
            occupied[row] = item.id
        end
    end

    -- Every icon hit must lie INSIDE the field: a hit that ran off its
    -- placement leads to a picture that is not there.
    local field: any = nil
    for _, item in ipairs(placements) do
        if item.id == "explorer:field" then field = item end
    end
    check(field ~= nil, "the field is not placed")
    if field then
        for _, cell in ipairs(plan.cells) do
            check(cell.from >= field.x and cell.to <= field.x + field.cols - 1
                    and cell.top >= field.y and cell.bottom <= field.y + field.rows - 1,
                "the hit of icon " .. cell.index .. " lies outside the field")
        end
    end

    local before = snapshot(placements)

    -- The same frame once more.
    local again = snapshot((paint_explorer(store, explorer_view())))
    local still = moved(before, again)
    check(#still == 0, "a frame without changes moved: " .. table.concat(still, ", "))
    print("    the same frame once more: moved " .. #still)

    -- The selection changed — the field AND the status line are redrawn, and
    -- the menu with the toolbar are NOT.
    --
    -- The status line is not superfluous here: it shows the `detail` of the
    -- selected object — the full drive id, which does not fit into the caption
    -- under the icon. Another object was selected — its text changed too. This
    -- is a consequence of the view, not a key miss, and it costs one 46×1
    -- placement.
    --
    -- The check is written as an enumeration, not a number: "two were redrawn"
    -- would pass on the pair "field and menu" too, that is, on a real error.
    local selected = moved(again, snapshot((paint_explorer(store, explorer_view({selected = 3})))))
    check(table.concat(selected, ",") == "explorer:field,explorer:status",
        "the selection change redrew: " .. table.concat(selected, ", ")
            .. " (expected the field and the status line)")
    print("    the selection changed: redrawn " .. table.concat(selected, ", "))

    -- The notice changed — only the status line.
    local base = snapshot((paint_explorer(store, explorer_view({selected = 3}))))
    local noticed = moved(base,
        snapshot((paint_explorer(store, explorer_view({selected = 3, notice = "showing the first 500"})))))
    check(#noticed == 1 and noticed[1] == "explorer:status",
        "the notice change redrew: " .. table.concat(noticed, ", "))
    print("    the notice changed: redrawn " .. table.concat(noticed, ", "))
end

-- ─── THE SHELL THEME IN PIXELS ──────────────────────────────────────────
--
-- What is checked here is the slicing of the whole frame: the desktop with
-- icons, window frames, the taskbar. A slicing error is visible neither on a
-- snapshot nor on the running system — the screen is correct, typing in bash
-- just costs forty-seven milliseconds.

local function desktop_state(extra: any)
    local state: any = {
        width = 60, height = 20, top = 1, bottom = 19,
        windows = {
            {id = "w1", title = "Command Prompt", x = 6, y = 3, w = 40, h = 12,
             window_type = "app"},
        },
        focused_id = "w1",
        items = {
            {id = "s1", kind = "shortcut", entry = "app:computer", title = "My Computer", x = 2, y = 1},
            {id = "f1", kind = "folder", title = "Programs", x = 2, y = 5},
            {id = "s2", kind = "shortcut", entry = "app:gone", title = "Old program", x = 2, y = 9, broken = true},
        },
        clock = "21:47",
        status = "Command Prompt · 38x9 · windows: 1",
    }
    for key, value in pairs(type(extra) == "table" and extra or {}) do state[key] = value end
    return state
end

do
    print("")
    print("┌── shell theme: slicing the frame")

    chrome_pixels.use_fonts(font, font)
    local painted = chrome_pixels.paint(desktop_state(), CELL.w, CELL.h)
    local placements = painted.placements

    for _, item in ipairs(placements) do
        print(string.format("    %-18s cell %2d,%-3d %2d×%-3d cells", item.id,
            item.x, item.y, item.cols, item.rows))
    end

    -- THE COST OF ONE KEYSTROKE. The window content changes on every
    -- keystroke, the rows are redrawn, and EVERY placement lying on those
    -- rows is sent anew. This is not checked "yes/no" — it is measured,
    -- because the question is not "does it touch" but "what does it cost".
    --
    -- The yardstick is the full screen: 1000×560 px, 47 ms, 131 KB. Getting
    -- away from those is what all this was started for, and we have to stay an
    -- order of magnitude below.
    local window = desktop_state().windows[1]
    local body_top, body_bottom = window.y + 2, window.y + window.h - 2
    local cost, culprits = 0, {}
    for _, item in ipairs(placements) do
        if item.y <= body_bottom and item.y + item.rows - 1 >= body_top then
            local area = item.cols * CELL.w * item.rows * CELL.h
            cost = cost + area
            culprits[#culprits + 1] = item.id .. " " .. area .. "px"
        end
    end

    local full = 100 * CELL.w * 28 * CELL.h
    print(string.format("    a keystroke in the window resends %d px (%.1f%% of the full screen): %s",
        cost, cost * 100 / full, table.concat(culprits, ", ")))

    -- The threshold is not round but derived: a tenth of the full screen is
    -- already 4–5 ms per keystroke, and over ssh that is noticeable.
    check(cost < full // 10,
        "a keystroke resends " .. cost .. " px — that is more than a tenth of the screen")

    -- A WIDE placement across the content, on the other hand, is always a
    -- slicing error, however little it weighs: it means a piece of chrome is
    -- not cut by rows.
    for _, item in ipairs(placements) do
        local touches = item.y <= body_bottom and item.y + item.rows - 1 >= body_top
        local own_window = string.find(item.id, "^win:") ~= nil
        check(not touches or not own_window or item.cols <= 1,
            item.id .. " covers content rows at a width of " .. item.cols
                .. " — the frame is not cut by rows")
    end

    -- The taskbar lies on its own row, where windows do not go.
    local bars: any = nil
    for _, item in ipairs(placements) do
        if item.id == "bars" then bars = item end
    end
    check(bars ~= nil, "the taskbar is not in the frame")
    if bars then
        check(bars.y + bars.rows - 1 == 20 and bars.rows == chrome_pixels.layout(60, 20).bottom,
            "the taskbar must occupy the bottom area declared by the theme")
    end

    -- Hits arrive in GROUPS, not as a flat list: `id` means different things
    -- in the three lists.
    check(painted.hits.desktop ~= nil and painted.hits.bars ~= nil
            and painted.hits.menu ~= nil,
        "hits must arrive in groups {desktop, bars, menu}")
    -- Hits are NOT checked by number here: both night-time errors would have
    -- passed the check "there are at least two of them". The shape is verified
    -- by a separate block below — against what the character mode gives on the
    -- same state.
    check(#painted.hits.bars >= 2, '"Start" and the window button must be clickable')

    -- Every visible interactive cell belongs to an image. Covered cells belong
    -- to the foreground window, so a cropped icon need not retain a whole placement.
    local state = desktop_state()
    for _, hit in ipairs(painted.hits.desktop) do
        for x = hit.from, hit.to do
            local covered = false
            for _, window in ipairs(state.windows) do
                if not window.minimized and x >= window.x and x < window.x + window.w
                    and hit.row >= window.y and hit.row < window.y + window.h then covered = true end
            end
            if not covered then
                local found = false
                for _, item in ipairs(placements) do
                    if item.id:find("desk:" .. hit.id, 1, true) == 1
                        and x >= item.x and x < item.x + item.cols
                        and hit.row >= item.y and hit.row < item.y + item.rows then found = true end
                end
                check(found, "a visible icon cell has no image")
            end
        end
    end

    -- ─── THE HITS OF THE TWO MODES MUST MATCH IN SHAPE ─────────────────
    --
    -- There is one compositor for both modes, and a hit it cannot read is
    -- indistinguishable from a missing one: the click simply does nothing.
    --
    -- That is how two clicks got lost at once. "Start" gave `id = "menu"`
    -- instead of `action = "menu"` — the compositor checks `id` first, looked
    -- for a window with that name and did not find one. And the desktop icons
    -- gave ONE hit for three rows with `bottom_row`, unsupported at the time:
    -- the icon would be clickable on the picture and not on the caption.
    --
    -- The check does not count hits but compares them with what the CHARACTER
    -- MODE gives on the same state. Counting is useless: both errors would have
    -- passed the check "at least two hits".
    do
        local state = desktop_state()
        local canvas = {
            clear = function() end,
            put = function() end,
            put_rows = function() end,
            rows = function() return {} end,
        }
        local cell_desk = chrome.fill(canvas, state.width, state.height, {
            top = state.top, bottom = state.bottom,
            items = state.items, selected = state.selected,
        })
        local cell_bars = chrome.bars(canvas, state.width, state.height, {
            windows = state.windows, focused_id = state.focused_id,
            status = state.status, clock = state.clock,
        })

        local function shape_of(hit: any)
            local keys = {}
            for key, value in pairs(hit) do
                if value ~= nil and key ~= "bottom_row" then keys[#keys + 1] = key end
            end
            table.sort(keys)
            return table.concat(keys, ",")
        end

        local function shapes(list)
            local seen, out = {}, {}
            for _, hit in ipairs(list or {}) do
                local form = shape_of(hit)
                if not seen[form] then seen[form] = true; out[#out + 1] = form end
            end
            table.sort(out)
            return out
        end

        local function compare(what, cells_list, pixels_list)
            local left = shapes(cells_list)
            local right = shapes(pixels_list)
            check(what == "desktop" or #cells_list == #pixels_list,
                what .. ": hits in cells " .. #cells_list
                    .. ", in pixels " .. #pixels_list)
            check(table.concat(left, " | ") == table.concat(right, " | "),
                what .. ": the shape of the hits diverged\n        cells:  "
                    .. table.concat(left, " | ") .. "\n        pixels: "
                    .. table.concat(right, " | "))
            print("    " .. what .. ": " .. #pixels_list .. " hits, shapes "
                .. table.concat(right, " | "))
        end

        check(#painted.hits.desktop == #state.items * chrome_pixels.icon_grid().drawn,
            "an icon must be clickable on every row of its layout")
        compare("desktop", cell_desk, painted.hits.desktop)
        compare("taskbar", cell_bars, painted.hits.bars)
    end

    -- ─── THE CURSOR REACHES THE PIXELS ─────────────────────────────────
    --
    -- In character mode the highlight is drawn by one piece of code, in pixels
    -- by another. A cursor that moves with the arrows and is not highlighted is
    -- "the arrows work, but the person does not see where it is": worse than
    -- arrows that do not work, because it looks like working ones.
    --
    -- What is checked is not "something got drawn" but the DIFFERENCE: the
    -- same frame without the cursor has no right to carry a highlight, and with
    -- the cursor it must.
    do
        local menu_items = {
            {entry = "app:calc", title = "Calculator", group = {"Programs"}},
            {entry = "app:notepad", title = "Notepad", group = {"Programs"}},
            {entry = "app:bash", title = "MS-DOS Prompt"},
        }

        local function highlights(cursor)
            local fresh = chrome_pixels
            local painted = fresh.paint(desktop_state({
                menu = {items = menu_items, open = {"Programs"}, cursor = cursor},
            }), CELL.w, CELL.h)

            local count = 0
            for _, item in ipairs(painted.placements) do
                if string.find(item.id, "^menu:") then
                    for _, op in ipairs(item.raster.__ops) do
                        if op.colour == "#000080" and op.op == "rect" then count = count + 1 end
                    end
                end
            end
            return count, painted
        end

        -- Rasters live between frames, so an honest comparison needs different
        -- keys: without the cursor and with the cursor are different pictures,
        -- and the store will redraw them both.
        local without = highlights(nil)
        local with_cursor = highlights(2)

        check(with_cursor > without,
            "the cursor was not highlighted in pixels: highlights without it " .. without
                .. ", with it " .. with_cursor
                .. " — the arrows will work, and the person will not see where it is")
        print("    highlights in the menu: without the cursor " .. without
            .. ", with the cursor " .. with_cursor)
    end

    -- The menu scenes above changed the pressed state of Start. Close it
    -- before taking the baseline for an unchanged-frame assertion.
    local before = snapshot(chrome_pixels.paint(desktop_state(), CELL.w, CELL.h).placements)
    local again = snapshot(chrome_pixels.paint(desktop_state(), CELL.w, CELL.h).placements)
    local still = moved(before, again)
    check(#still == 0, "a frame without changes moved: " .. table.concat(still, ", "))
    print("    the same frame once more: moved " .. #still)

    -- The clock changed — ONLY the taskbar must be redrawn.
    local ticked = moved(again,
        snapshot(chrome_pixels.paint(desktop_state({clock = "21:48"}), CELL.w, CELL.h).placements))
    check(#ticked == 1 and ticked[1] == "bars",
        "the clock change redrew: " .. table.concat(ticked, ", "))
    print("    the clock changed: redrawn " .. table.concat(ticked, ", "))
end

-- Native client placements stay inside the viewport even after a small resize.
for _, unit in ipairs({{w = 8, h = 16}, {w = 8, h = 18}, {w = 10, h = 20}}) do
    for _, dimensions in ipairs({{12, 3}, {20, 8}, {32, 16}, {62, 18}}) do
        local width, height = dimensions[1], dimensions[2]
        local objects = {}
        for index = 1, 65 do objects[index] = {id = tostring(index), kind = "drive", title = "Drive " .. index} end
        local plan = render.layout({title = "My Computer", objects = objects, offset = 0},
            width, height, render.pixel_metrics(unit.w, unit.h))
        local client = rasters.store()
        local placements = render_pixels.paint(client, plan, unit, {face = font, bold = font}, "native")
        for _, place in ipairs(placements) do
            check(place.x >= 1 and place.y >= 1 and place.x + place.cols - 1 <= width
                and place.y + place.rows - 1 <= height, "native client placement escaped its viewport: " .. place.id)
        end
        local hits = render.hits(plan)
        check_overlap(hits.scroll)
        for _, cell in ipairs(hits.cells) do
            check(cell.from >= 1 and cell.to <= width and cell.top >= 1 and cell.bottom <= height,
                "native icon hit escaped its viewport")
        end
    end
end

print("")
if failures == 0 then
    print("no checks violated")
else
    print("CHECKS VIOLATED: " .. failures)
    error("pixelprobe failed")
end
