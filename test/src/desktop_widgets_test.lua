-- Desktop widgets in the shell (FR-006): the column at the right edge and
-- its second column, one hit table for both themes, the panel in cells, a
-- placement per row in pixels cut by the windows over it, a changed number
-- that re-sends only its rows, the catalog's widget entries, and the SDK
-- runner driving a widget the way it drives a window.
local test = require("test")
local fs = require("fs")
local gfx = require("gfx")
local tty = require("tty")
local text = require("text")
local glyphs = require("glyphs")
local palette = require("palette")
local ui = require("ui")
local gadget = require("gadget")
local gadgets = require("gadgets")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local sdk_render = require("sdk_render")
local catalog = require("catalog")
local app = require("app")
local desktop = require("desktop")
local fixture = require("fixture")
local scene = require("scene")

-- A widget as the base hands it to the theme (FR-006 §4).
local function widget(id: string, w: integer, h: integer, tree: any, extra: any?): any
    local item: any = {id = id, entry = "app:" .. id, w = w, h = h, waiting = false, stopped = false,
        content_state = {sdk = 1, revision = 1, ui = tree, interaction = {}}, state_revision = 1}
    for key, value in pairs(type(extra) == "table" and extra or {}) do item[key] = value end
    return item
end

local function label(value: string): any
    return {kind = "label", text = value}
end

local function spots_of(list: any, width: integer, top: integer, bottom: integer): string
    local out = {}
    for _, spot in ipairs(gadgets.layout(list, width, top, bottom)) do
        out[#out + 1] = tostring(spot.id) .. "@" .. tostring(spot.x) .. "," .. tostring(spot.y)
            .. " " .. tostring(spot.w) .. "x" .. tostring(spot.h)
    end
    return table.concat(out, "; ")
end

-- A canvas row without its styles, and the cell a text or a character is in.
local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end
local function column(line: string, needle: string): any
    local at = line:find(needle, 1, true)
    if not at then return nil end
    return #text.runes(line:sub(1, at - 1)) + 1
end
local function rune(line: string, at: integer): any
    return text.runes(line)[at]
end

-- pixel(raster, x, y) / swatch(colour) — one pixel as PNG bytes. gfx has no
-- pixel read, so a 1×1 raster is cut out of the source and compared with a
-- 1×1 raster of the expected colour.
local function pixel(raster: any, x: integer, y: integer): string
    local one = gfx.raster(1, 1)
    one:blit(raster, 2 - x, 2 - y)
    return assert(one:encode("png"))
end
local function swatch(colour: string): string
    local one = gfx.raster(1, 1)
    one:fill(colour)
    return assert(one:encode("png"))
end

local function use_fonts(): any
    -- A pattern or wallpaper left by a test that failed mid-way must not
    -- paint under this one.
    chrome.use_pattern(nil)
    chrome.use_wallpaper(nil, nil)
    local files = assert(fs.get("chicago.shell.theme:fonts"))
    local face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
    local bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
    chrome_pixels.use_fonts(face, bold)
    chrome_pixels.use_cell_size(10, 20)
    return face
end

local function define_tests()
    test.describe("desktop widgets: the layout", function()
        test.it("stands in the right column, one row under the top, an empty row apart, at x = width - w", function()
            local list = {widget("g1", 20, 7, label("a")), widget("g2", 20, 8, label("b")), widget("g3", 20, 9, label("c"))}
            test.eq(spots_of(list, 110, 1, 32), "g1@90,2 20x7; g2@90,10 20x8; g3@90,19 20x9")
        end)

        test.it("opens a second column, one empty column left of the first column's widest", function()
            local list = {widget("g1", 20, 7, label("a")), widget("g2", 20, 8, label("b")),
                widget("g3", 20, 9, label("c")), widget("g4", 12, 5, label("d"))}
            test.eq(spots_of(list, 80, 1, 22), "g1@60,2 20x7; g2@60,10 20x8; g3@39,2 20x9; g4@47,12 12x5")
            -- The widest, not the last: a narrower widget at the bottom of the
            -- first column does not pull the second one over the wider above.
            local narrow = {widget("a", 20, 10, label("a")), widget("b", 16, 10, label("b")), widget("c", 20, 5, label("c"))}
            test.eq(spots_of(narrow, 80, 1, 22), "a@60,2 20x10; b@64,13 16x10; c@39,2 20x5")
        end)

        test.it("draws a wide widget at a third of the screen and leaves out one that fits nowhere", function()
            local list = {widget("g1", 20, 7, label("a")), widget("g2", 20, 8, label("b")), widget("g3", 20, 9, label("c"))}
            test.eq(spots_of(list, 45, 1, 11), "g1@30,2 15x7; g2@14,2 15x8")
            for _, hit in ipairs(gadgets.hits(gadgets.layout(list, 45, 1, 11))) do
                test.is_true(hit.widget ~= "g3", "a widget that is not drawn has no hits")
            end
            -- Two columns and no more, even where a third would fit.
            local three = {widget("a", 20, 7, label("a")), widget("b", 20, 7, label("b")), widget("c", 20, 7, label("c"))}
            test.eq(spots_of(three, 110, 1, 11), "a@90,2 20x7; b@69,2 20x7")
            -- Taller than the desktop: nowhere, even in an empty column; the
            -- next one still takes the top of the first column.
            test.eq(spots_of({widget("tall", 20, 40, label("a")), widget("g1", 20, 5, label("b"))}, 110, 1, 32), "g1@90,2 20x5")
            test.eq(spots_of({widget("", 20, 5, label("a"))}, 110, 1, 32), "", "without an id there is nothing to name its rows by")
            test.eq(spots_of({widget("g1", 20, 5, label("a"))}, 8, 1, 6), "", "a third of a tiny screen is narrower than a panel")
        end)
    end)

    test.describe("desktop widgets: the hits", function()
        test.it("gives a hit per widget row, the same records in both themes, after the icons'", function()
            use_fonts()
            local state: any = {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00", windows = {},
                items = {{id = "icon", kind = "folder", title = "Folder", x = 2, y = 2}},
                widgets = {widget("g1", 20, 7, label("a"), {title = "Weather", opens = "app:weather"}),
                    widget("g2", 20, 8, label("b")), widget("g9", 20, 30, label("nowhere"))}}
            local function records(hits: any): (string, integer, integer)
                local out = {}
                local first_widget, last_icon = 0, 0
                for index, hit in ipairs(hits) do
                    if hit.widget ~= nil then
                        out[#out + 1] = table.concat({tostring(hit.row), tostring(hit.from), tostring(hit.to),
                            tostring(hit.widget), tostring(hit.entry), tostring(hit.title)}, "|")
                        if first_widget == 0 then first_widget = index end
                    else
                        last_icon = index
                    end
                end
                return table.concat(out, " "), first_widget, last_icon
            end
            local in_cells, cells_first, cells_icon = records(chrome.fill(tty.canvas(80, 24), 80, 24, state))
            local in_pixels, pixels_first, pixels_icon = records(chrome_pixels.paint(state, 10, 20).hits.desktop)
            chrome_pixels.fonts = nil
            test.eq(in_pixels, in_cells, "one layout, one hit table for both themes")
            local expected = {}
            for row = 2, 8 do expected[#expected + 1] = row .. "|60|79|g1|app:weather|Weather" end
            for row = 10, 17 do expected[#expected + 1] = row .. "|60|79|g2|nil|nil" end
            test.eq(in_cells, table.concat(expected, " "))
            test.is_true(cells_icon > 0 and cells_first > cells_icon, "cells: the icon's records come first")
            test.is_true(pixels_icon > 0 and pixels_first > pixels_icon, "pixels: the icon's records come first")
        end)
    end)

    test.describe("desktop widgets: cells", function()
        test.it("draws a raised panel, the title in its top edge and the body at the inner rectangle, under the icons", function()
            local canvas = tty.canvas(scene.WIDTH, scene.HEIGHT)
            chrome.fill(canvas, scene.WIDTH, scene.HEIGHT, scene.state())
            local rows: any = canvas:rows()
            local top = plain(rows[2])
            test.eq(rune(top, 90), glyphs.bevel.corner_light, "the panel's top-left corner")
            test.eq(column(top, " Weather "), 91, "the title in the top edge, one cell in")
            test.eq(column(plain(rows[4]), "+21 °C"), 96, "the value right of the picture, on the stat's second row")
            test.eq(rune(plain(rows[8]), 109), glyphs.bevel.corner_shadow, "the bottom-right corner, seven rows down")
            -- An icon dropped on a widget stays on top of it: widgets are drawn first.
            local over = scene.state()
            over.items[#over.items + 1] = {id = "over", kind = "folder", title = "Over", x = 94, y = 11}
            local covered = tty.canvas(scene.WIDTH, scene.HEIGHT)
            chrome.fill(covered, scene.WIDTH, scene.HEIGHT, over)
            local shown: any = covered:rows()
            test.is_true((plain(shown[11]) .. plain(shown[12]) .. plain(shown[13])):find("Over", 1, true) ~= nil,
                "the icon's caption stands over the widget")
        end)

        test.it("draws nothing in a waiting body, a broken tree's reason, and a stopped widget's last row", function()
            local stat = gadget.stat{caption = "Heap", value = 38, unit = " MB"}
            local canvas = tty.canvas(80, 24)
            chrome.fill(canvas, 80, 24, {width = 80, height = 24, top = 1, bottom = 22, items = {}, widgets = {
                widget("wait", 20, 5, stat, {title = "Waiting", waiting = true}),
                widget("broken", 20, 5, {kind = "sparkline"}),
                widget("stopped", 20, 6, stat, {stopped = true}),
            }})
            local rows: any = canvas:rows()
            local function body(row: integer): string
                return table.concat(text.runes(plain(rows[row])), "", 61, 78)
            end
            for row = 3, 5 do test.eq(body(row), string.rep(" ", 18), "waiting: row " .. row .. " is empty") end
            test.is_true(column(plain(rows[2]), " Waiting ") == 61, "waiting: the title stays")
            local reason = body(9) .. body(10) .. body(11)
            test.is_true(reason:find("unknown SDK", 1, true) ~= nil and reason:find("sparkline", 1, true) ~= nil,
                "a broken tree names its reason: " .. reason)
            test.eq(column(plain(rows[18]), "stopped"), 61, "stopped: the body's last row")
            test.is_true(body(16):find("38 MB", 1, true) ~= nil, "stopped: the last tree stays above it")
        end)
    end)

    test.describe("desktop widgets: pixels", function()
        test.it("renders changed panel sizes and removes stale rows after shrinking", function()
            use_fonts()
            local state = scene.state()
            state.widgets[1].w, state.widgets[1].h = 28, 9
            local large = chrome_pixels.paint(state, 10, 20)
            assert(assert(fs.get("app:shots")):writefile("widgets-resized.png",
                assert(scene.compose(large, state, {w = 10, h = 20}):encode("png"))))
            state.widgets[1].w, state.widgets[1].h = 20, 7
            local small = chrome_pixels.paint(state, 10, 20)
            local count = 0
            for _, placement in ipairs(small.placements) do
                if tostring(placement.id):find("widget:g1:row:", 1, true) == 1 then count = count + 1 end
            end
            test.eq(count, 7, "the complete placement list contains only the new seven rows")
            chrome_pixels.fonts = nil
        end)

        test.it("gives a placement per row on the desktop layer, under the icons, cut by the window over it", function()
            use_fonts()
            local state = scene.state()
            local painted = chrome_pixels.paint(state, 10, 20)
            -- The screenshot for the eye, from the frame checked below.
            assert(assert(fs.get("app:shots")):writefile("widgets.png",
                assert(scene.compose(painted, state, {w = 10, h = 20}):encode("png"))))
            chrome_pixels.fonts = nil
            local by_id: any = {}
            local first_icon, last_widget = 0, 0
            for index, placed in ipairs(painted.placements) do
                local id = tostring(placed.id)
                by_id[id] = placed
                if id:find("desk:", 1, true) == 1 and first_icon == 0 then first_icon = index end
                if id:find("widget:", 1, true) == 1 then last_widget = index end
            end
            for n = 1, 7 do
                local row: any = by_id["widget:g1:row:" .. n]
                test.not_nil(row, "weather row " .. n)
                test.eq(tostring(row.x) .. "," .. tostring(row.y) .. " " .. tostring(row.cols) .. "x" .. tostring(row.rows)
                    .. " layer " .. tostring(row.layer), "90," .. (1 + n) .. " 20x1 layer 0")
            end
            test.is_true(first_icon > last_widget, "the icons are painted after the widgets")
            -- The window covers rows 22..29: the goroutines' rows 4..9 (its
            -- history), and nothing of the memory widget above.
            for n = 1, 3 do
                test.not_nil(by_id["widget:g3:row:" .. n], "the goroutines' row " .. n .. " is clear of the window")
            end
            for n = 1, 8 do test.not_nil(by_id["widget:g2:row:" .. n], "the memory widget is whole: row " .. n) end
            for n = 4, 9 do
                test.is_nil(by_id["widget:g3:row:" .. n], "row " .. n .. " is under the window and goes as a crop")
                local crop: any = nil
                for id in pairs(by_id) do
                    if tostring(id):find("widget:g3:row:" .. n .. ":crop:", 1, true) == 1 then crop = id end
                end
                test.not_nil(crop, "the visible part of row " .. n)
            end
        end)

        test.it("draws the raised frame and the titled group, and waiting, a broken tree and stopped in their rows", function()
            use_fonts()
            local stat = gadget.stat{caption = "Heap", value = 38, unit = " MB"}
            -- Copies of the row rasters, taken right after the frame: the store
            -- paints the next frame into the same buffers.
            local function rows_of(item: any): any
                local painted = chrome_pixels.paint({width = 80, height = 24, top = 1, bottom = 22, clock = "12:00",
                    items = {}, windows = {}, widgets = {item}}, 10, 20)
                local out: any = {}
                for _, placed in ipairs(painted.placements) do
                    local n = tostring(placed.id):match("^widget:[^:]+:row:(%d+)$")
                    if n then
                        local copy = gfx.raster(200, 20)
                        copy:blit(placed.raster, 1, 1)
                        out[math.tointeger(tonumber(n)) or 0] = copy
                    end
                end
                return out
            end
            local function png(raster: any): string
                return assert(raster:encode("png"))
            end
            local color: any = palette.exact
            local running = rows_of(widget("p1", 20, 6, stat, {title = "Heap", state_revision = 4}))
            test.eq(pixel(running[1], 1, 1), swatch(color.light), "the raised edge: light at the top-left")
            test.eq(pixel(running[6], 200, 20), swatch(color.frame), "the raised edge: black at the bottom-right")
            test.eq(pixel(running[3], 199, 10), swatch(color.shadow), "the raised edge: its inner shadow on the right")
            test.eq(pixel(running[3], 6, 10), swatch(color.shadow), "a title puts a group's etched frame inside the ring")
            -- The caption's letters, not only the face under them: a 30×14
            -- piece of the caption is not plain face.
            local caption = gfx.raster(30, 14)
            caption:blit(running[1], 2 - 15, 2 - 5)
            local face = gfx.raster(30, 14)
            face:fill(color.face)
            test.is_true(png(caption) ~= png(face), "the title's text is drawn")
            -- The title and the flags change the rows while the revision
            -- stands still; each is checked against a frame that differs in
            -- it alone.
            local retitled = rows_of(widget("p1", 20, 6, stat, {title = "Memory", state_revision = 4}))
            test.is_true(png(retitled[1]) ~= png(running[1]), "a new title repaints the top row under the same revision")
            rows_of(widget("p1", 20, 6, stat, {title = "Heap", state_revision = 4}))
            local stopped = rows_of(widget("p1", 20, 6, stat, {title = "Heap", stopped = true, state_revision = 4}))
            test.eq(png(stopped[2]), png(running[2]), "stopped: the tree above stays as it was")
            test.is_true(png(stopped[5]) ~= png(running[5]), "stopped: the body's last row says so, under the same revision")
            local waiting = rows_of(widget("p1", 20, 6, stat, {title = "Heap", waiting = true, state_revision = 1}))
            test.eq(png(waiting[3]), png(waiting[4]), "waiting: a body row is the frame's sides and nothing else")
            local untitled = rows_of(widget("p1", 20, 6, stat, {waiting = true, state_revision = 2}))
            test.eq(pixel(untitled[3], 6, 10), swatch(color.face), "no title, no group frame")
            test.is_true(png(untitled[1]) ~= png(waiting[1]), "the title is drawn in the top row")
            local broken = rows_of(widget("p1", 20, 6, {kind = "sparkline"}, {title = "Heap", state_revision = 3}))
            chrome_pixels.fonts = nil
            test.is_true(png(broken[2]) ~= png(waiting[2]), "a broken tree shows its reason in the body")
            test.eq(png(broken[6]), png(waiting[6]), "the frame's bottom row is the same")
        end)

        test.it("draws nothing focused: a tree with controls is laid out and never given the focus", function()
            local tree = {kind = "row", gap = 1, children = {
                {kind = "button", id = "first", size = 8, text = "OK"},
                {kind = "button", id = "second", size = 8, text = "OK"}}}
            local plan, interaction = gadgets.plan(tree, 18, 3)
            test.not_nil(plan.by_id.first, "cells: the controls are laid out")
            test.is_nil(interaction.focus, "cells: none takes the focus")
            test.is_false(plan.focus_on_button)
            use_fonts()
            local painted = chrome_pixels.paint({width = 80, height = 24, top = 1, bottom = 22, clock = "12:00",
                items = {}, windows = {}, widgets = {widget("f1", 20, 5, tree)}}, 10, 20)
            chrome_pixels.fonts = nil
            local row: any = nil
            for _, placed in ipairs(painted.placements) do
                if placed.id == "widget:f1:row:3" then row = placed.raster end
            end
            test.not_nil(row)
            local function crop(from: integer): string
                local part = gfx.raster(80, 20)
                part:blit(row, 2 - from, 1)
                return assert(part:encode("png"))
            end
            test.eq(crop(11), crop(101), "pixels: two equal buttons look equal — neither focused nor the default")
            -- A tree that does not lay out is refused with its reason, not an error in the frame.
            local refused, why = sdk_render.tree_rows({id = "widget:bad", tree = {kind = "sparkline"}, x = 1, y = 1,
                cols = 10, rows = 3, cell = {w = 10, h = 20}, fonts = {}, store = {}})
            test.is_nil(refused)
            test.is_true(tostring(why):find("unknown SDK control", 1, true) ~= nil, tostring(why))
        end)

        test.it("re-sends only the rows of a changed number, and nothing for an unchanged frame", function()
            use_fonts()
            local function snapshot(painted: any): (any, integer)
                local out: any = {}
                local count = 0
                for _, placed in ipairs(painted.placements) do
                    if tostring(placed.id):find("widget:", 1, true) == 1 then
                        out[placed.id] = {raster = placed.raster, version = placed.raster:version()}
                        count = count + 1
                    end
                end
                return out, count
            end
            local function moved(before: any, painted: any): string
                local names = {}
                for _, placed in ipairs(painted.placements) do
                    local id = tostring(placed.id)
                    local was: any = before[id]
                    if id:find("widget:", 1, true) == 1
                        and (was == nil or was.raster ~= placed.raster or was.version ~= placed.raster:version()) then
                        names[#names + 1] = id
                    end
                end
                table.sort(names)
                return table.concat(names, ",")
            end
            local before, total = snapshot(chrome_pixels.paint(scene.state({revision = 1}), 10, 20))
            local calls: any = {count = 0}
            local plan = ui.plan
            ui.plan = function(...) calls.count = calls.count + 1; return plan(...) end
            local same = chrome_pixels.paint(scene.state({revision = 1}), 10, 20)
            ui.plan = plan
            test.eq(moved(before, same), "", "a frame without a change re-sends no widget row")
            test.eq(calls.count, 0, "the same revision is not laid out again")
            before = snapshot(same)
            local ticked_frame = chrome_pixels.paint(scene.state({revision = 2, goroutines = 431}), 10, 20)
            local ticked = moved(before, ticked_frame)
            test.eq(ticked, "widget:g3:row:2,widget:g3:row:3", "only the rows the changed number stands in")
            before = snapshot(ticked_frame)
            local bare_frame = chrome_pixels.paint(scene.state({unrevised = true, goroutines = 431}), 10, 20)
            test.eq(moved(before, bare_frame), "", "without a revision the tree is laid out anew, and still nothing repaints")
            before = snapshot(bare_frame)
            local changed = moved(before, chrome_pixels.paint(scene.state({unrevised = true, goroutines = 432}), 10, 20))
            test.eq(changed, "widget:g3:row:2,widget:g3:row:3", "without a revision a changed number still shows")
            chrome_pixels.fonts = nil
            assert(assert(fs.get("app:shots")):writefile("widgets-cost.txt", string.format(
                "10x20 cells, 110x34 screen, three widgets: %d widget placements; an unchanged frame re-sent none; "
                .. "the goroutine count 428 -> 431 re-sent %s\n", total, ticked)))
        end)

        test.it("forgets the row keys of a widget that is gone", function()
            use_fonts()
            local state = scene.state({revision = 5})
            chrome_pixels.paint(state, 10, 20)
            test.is_true(sdk_render.remembered("widget:g3"))
            table.remove(state.widgets, 3)
            chrome_pixels.paint(state, 10, 20)
            chrome_pixels.fonts = nil
            test.is_false(sdk_render.remembered("widget:g3"), "the keys of the gone widget")
            test.is_true(sdk_render.remembered("widget:g1"), "the others stay")
        end)
    end)

    test.describe("desktop widgets: the entries and the runner", function()
        test.it("reads widget entries: the defaults, a declared size as declared, by order then id", function()
            local list = catalog.widget_list({
                {id = "app:b", meta = {type = "chicago.widget", title = "B", order = 20, width = 30, height = 8, opens = "app:x"}},
                {id = "app:a", meta = {type = "chicago.widget"}},
                {id = "app:c", meta = {type = "chicago.widget", order = 20, width = "wide"}},
                {meta = {type = "chicago.widget", title = "No id"}},
                {id = "app:d", meta = {type = "chicago.widget", title = "", opens = ""}},
            })
            local out = {}
            for _, item in ipairs(list) do
                out[#out + 1] = table.concat({tostring(item.entry), tostring(item.title), tostring(item.w), tostring(item.h),
                    tostring(item.order), tostring(item.opens)}, "|")
            end
            test.eq(table.concat(out, " "),
                "app:b|B|30|8|20|app:x app:c|nil|wide|5|20|nil app:a|nil|20|5|100|nil app:d|nil|20|5|100|nil")
        end)

        test.it("resolves independent explicit instances and rejects invalid compositions atomically", function()
            local definitions = {{id = "app:definition", kind = "process.lua", meta = {
                type = "chicago.widget", width = 20, height = 7, min_width = 12, title = "Default"}}}
            local function instance(id: string, data: any): any return {id = id, data = data} end
            local entries = {
                instance("app:b", {widget = "app:definition", width = 24, config = {value = "B"}}),
                instance("app:a", {widget = "app:definition", config = {value = "A"}}),
                instance("app:off", {widget = "app:definition", enabled = false}),
            }
            local list, err = catalog.widget_instances(definitions, entries)
            test.is_nil(err)
            test.eq(#list, 2)
            test.eq(list[1].instance, "app:a")
            test.eq(list[2].instance, "app:b")
            test.eq(list[1].entry, list[2].entry)
            test.eq(list[1].w, 20)
            test.eq(list[2].w, 24)
            test.eq(list[1].config.value, "A")
            test.eq(list[2].config.value, "B")
            test.eq(#assert(catalog.widget_instances(definitions, {})), 0, "no automatic definition instances")
            for _, bad in ipairs({
                {widget = "app:missing"}, {widget = "app:definition", width = 11},
                {widget = "app:definition", width = "20"}, {widget = "app:definition", enabled = "false"},
                {widget = "app:definition", config = {value = function() end}},
                {widget = "app:definition", order = 1.5},
            }) do
                local result, why = catalog.widget_instances(definitions, {entries[1], instance("app:bad", bad)})
                test.is_nil(result)
                test.is_true(tostring(why):find("app:bad", 1, true) ~= nil)
            end
            local result, why = catalog.widget_instances(definitions, {entries[1], entries[1]})
            test.is_nil(result)
            test.not_nil(why)
        end)

        test.it("gives providers the exact content width used by the frame on narrow screens", function()
            local instance = widget("g1", 40, 8, label("adaptive"))
            for _, screen in ipairs({30, 60, 120}) do
                local geometry = gadgets.geometry(instance, screen)
                local spots = gadgets.layout({instance}, screen, 1, 24)
                test.eq(geometry.width, spots[1].w - 2)
                test.eq(geometry.height, spots[1].h - 2)
                test.eq(chrome.widget_geometry(instance, screen).width, geometry.width)
                test.eq(chrome_pixels.widget_geometry(instance, screen).width, geometry.width)
            end
        end)

        test.it("finds the harness's widget entry in the real registry, and not among the programs", function()
            local found, err = catalog.widgets()
            test.is_nil(err)
            local probe: any = nil
            for _, item in ipairs(found or {}) do
                if item.entry == "app:widget_probe" then probe = item end
            end
            test.not_nil(probe, "the harness declares app:widget_probe")
            test.eq(table.concat({tostring(probe.title), tostring(probe.w), tostring(probe.h), tostring(probe.order),
                tostring(probe.opens)}, "|"), "Probe widget|22|7|30|app:grouped_probe")
            local programs = assert(catalog.list())
            test.is_nil(catalog.find(programs.programs, "app:widget_probe"), "a widget is not a program of the menu")
        end)

        test.it("runs a widget on the SDK runner as it is: its id, the interval, a published view, no update", function()
            -- Observations live in a table: an error under pcall splits a
            -- closure's upvalues from its owner (the go-lua trap).
            local seen: any = {frames = {}, closed = {}, views = 0}
            local publish, close = desktop.publish_state, desktop.close
            desktop.publish_state = function(id: any, state: any): (any, any)
                seen.frames[#seen.frames + 1] = {id = id, state = state}
                -- The compositor stops a widget by closing it; three frames are enough.
                if #seen.frames == 3 then process.send(process.pid(), "window.input", {event = {type = "close"}}) end
                return true, nil
            end
            desktop.close = function(id: any): (any, any)
                seen.closed[#seen.closed + 1] = tostring(id)
                return true, nil
            end
            local definition: any = {interval = "10ms", view = function(): any
                seen.views = seen.views + 1
                return gadget.lines{lines = {"view " .. seen.views}}
            end}
            app.run(definition, nil, "g7", nil, {width = 18, height = 3, cell_w = 10, cell_h = 20})
            desktop.publish_state, desktop.close = publish, close
            test.is_true(#seen.frames >= 3, "the interval redraws a widget without update: " .. #seen.frames)
            for index, frame in ipairs(seen.frames) do
                test.eq(frame.id, "g7", "published under the widget's id")
                test.eq(frame.state.sdk, 1)
                test.eq(frame.state.revision, index)
            end
            test.eq(seen.frames[3].state.ui.children[1].text, "view 3")
            test.eq(table.concat(seen.closed, ","), "g7", "the runner closes the widget's id when it ends")
            -- The harness's widget: its tick is an ordinary update.
            local context = app.context({window_id = "g7", width = 18, height = 5, native = true, cell_w = 10, cell_h = 20})
            local model = fixture.definition.init(nil, context)
            test.is_true(app.dispatch(fixture.definition, model, context, {type = "tick"}))
            test.eq(model.ticks, 1)
            test.is_nil(ui.problem(fixture.definition.view(model, context)))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
