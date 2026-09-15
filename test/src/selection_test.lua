-- The views FR-008 needs from the SDK: Small Icons (`icons` with `small`), a
-- multi-selection set on `icons` and `table` with Explorer's Ctrl and Shift
-- rules, and a picture in a table cell — one plan, both renderers.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local palette = require("palette")
local glyphs = require("glyphs")

local CELL = {w = 10, h = 20}

local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end
local function head(row: any, count: integer): string
    local out = {}
    for char in plain(row):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out < count then out[#out + 1] = char end
    end
    return table.concat(out)
end
local function region(raster: any, x: integer, y: integer, w: integer, h: integer): string
    local part = gfx.raster(w, h)
    part:blit(raster, 2 - x, 2 - y)
    return assert(part:encode("png"))
end
local function filled(colour: string, w: integer, h: integer): string
    local part = gfx.raster(w, h)
    part:fill(colour)
    return assert(part:encode("png"))
end
local function face_font(): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end
local function painted(tree: any, cols: integer, rows: integer, fonts: any): any
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "selection", state_revision = 1, content_state = {sdk = 1, revision = 1,
        ui = tree, interaction = ui.interaction()}}, {x = 1, y = 1, cols = cols, rows = rows}, CELL, fonts, store))
    return placed.raster
end
-- A set as sorted text: "b,d".
local function listed(set: any): string
    local out = {}
    for name, on in pairs(set or {}) do if on then out[#out + 1] = tostring(name) end end
    table.sort(out)
    return table.concat(out, ",")
end
local function click(x: integer, y: integer, mods: any?): any
    local event: any = {type = "mouse", action = "press", button = "left", x = x, y = y}
    for name, value in pairs(mods or {}) do event[name] = value end
    return event
end
local function key(name: string, extra: any?): any
    local event: any = {type = "key", key_type = name, key = name, action = "press"}
    for field, value in pairs(extra or {}) do event[field] = value end
    return event
end
local CTRL_A = {key = "a", ctrl = true}

local function letters(small: boolean, selected: any): any
    local items: any = {
        {id = "a", title = "alpha"}, {id = "b", title = "beta", kind = "folder"}, {id = "c", title = "gamma", icon = "▣"},
        {id = "d", title = "a very long caption here"}, {id = "e", title = "epsilon"},
    }
    if small then
        items[#items + 1] = {id = "f", title = "phi"}
        items[#items + 1] = {id = "g", title = "psi"}
    end
    return {kind = "icons", id = "grid", small = small or nil, items = items, selected = selected}
end
local function files(selected: any): any
    local rows = {}
    for index = 1, 6 do rows[index] = {id = "r" .. index, cells = {"row " .. index}} end
    return {kind = "table", id = "files", columns = {{title = "Name", weight = 1}}, rows = rows, selected = selected}
end

local function define_tests()
    test.describe("chicago.shell.sdk Small Icons", function()
        test.it("lays small icons out in 15-cell columns one row high and walks them as the large grid", function()
            test.eq(listed({[ui.icon_grid(true).w] = true, [ui.icon_grid(true).h + 100] = true}), "101,15")
            test.eq(ui.icon_grid().w, 12, "the large grid is unchanged")
            local state = ui.interaction()
            local plan = ui.plan(letters(true, 1), 46, 3, state)
            local grid = plan.by_id.grid
            test.eq(grid.columns, 3, "three 15-cell columns in 46")
            test.eq(grid.rows_total, 3)
            test.eq(grid.page, 3, "a page is three one-row rows")
            local second: any = grid.cells[2]
            test.eq(second.x .. "," .. second.y .. " " .. second.box.from .. ".." .. second.box.to .. "x"
                .. second.box.top .. ".." .. second.box.bottom, "16,1 16..29x1..1")
            test.eq(grid.cells[4].y, 2, "the fourth starts the second row")
            local picked = ui.event(plan, state, click(16, 1))
            test.eq(picked and picked.index, 2, "a click on the row hits the item")
            state.focus = "grid"
            test.eq(ui.event(plan, state, key("down")).index, 4, "down moves by a row of three")
        end)

        test.it("draws a small icon in cells as its glyph, a space and the caption, cut with an ellipsis", function()
            local state = ui.interaction()
            local rows: any = cells.rows(ui.plan(letters(true, 1), 46, 3, state), state, 46, 3)
            test.eq(head(rows[1], 45), glyphs.icons.unknown .. " alpha" .. string.rep(" ", 8)
                .. glyphs.icons.folder .. " beta" .. string.rep(" ", 9)
                .. "▣ gamma" .. string.rep(" ", 8))
            test.eq(head(rows[2], 14), glyphs.icons.unknown .. " a very long…")
        end)

        test.it("draws a small icon in pixels as a 16-px picture and the caption 3 px after it", function()
            local color: any = palette.exact
            local raster = painted(letters(true, 1), 46, 3, {face = face_font()})
            -- The first cell from x = 1: the picture at 3..18, the caption's
            -- band from 21; the second cell's band would start at 171.
            test.eq(region(raster, 21, 10, 1, 1), filled(color.select_bg, 1, 1), "the selected caption's band")
            test.eq(region(raster, 20, 10, 1, 1), filled(color.field, 1, 1), "air between the picture and the caption")
            test.eq(region(raster, 171, 10, 1, 1), filled(color.field, 1, 1), "an unselected caption has no band")
        end)
    end)

    test.describe("chicago.shell.sdk multi-selection", function()
        test.it("icons: a click selects one, Ctrl toggles, Shift takes the range in view order, Ctrl+A all", function()
            local state = ui.interaction()
            local set: any = {}
            local function act(event: any): any
                local plan = ui.plan(letters(false, set), 38, 8, state)
                local action = ui.event(plan, state, event)
                if action and action.selected then set = action.selected end
                return action
            end
            test.eq(listed(act(click(13, 1)).selected), "b")
            test.eq(state.anchors.grid, "b", "the click is the anchor")
            test.eq(listed(act(click(1, 5, {ctrl = true})).selected), "b,d", "Ctrl adds")
            test.eq(listed(act(click(13, 1, {ctrl = true})).selected), "d", "Ctrl again removes")
            test.eq(listed(act(click(13, 5, {shift = true})).selected), "b,c,d,e", "Shift: from the anchor b to e")
            test.eq(state.anchors.grid, "b", "Shift keeps the anchor")
            test.eq(listed(act(click(1, 1, {shift = true})).selected), "a,b", "and back from it")
            state.focus = "grid"
            test.eq(listed(act(key("runes", CTRL_A)).selected), "a,b,c,d,e")
            set = {c = true}
            test.eq(listed(act(click(25, 5, {ctrl = true})).selected), "c", "Ctrl on empty space keeps the set")
            local cleared = act(click(25, 5))
            test.eq(cleared.index, 0)
            test.eq(listed(cleared.selected), "", "empty space clears it")
            act(click(25, 1))
            test.eq(listed(act(key("right")).selected), "d", "an arrow moves from the anchor and selects one")
            test.eq(state.anchors.grid, "d")
        end)

        test.it("icons: the set is what is drawn, and the single selected index still works", function()
            local plan = ui.plan(letters(false, {b = true, d = true}), 38, 8, ui.interaction())
            local shown = {}
            for _, spot in ipairs(plan.by_id.grid.cells) do shown[#shown + 1] = spot.selected and "x" or "." end
            test.eq(table.concat(shown), ".x.x.")
            local state = ui.interaction()
            local single = ui.plan(letters(false, 2), 38, 8, state)
            test.is_true(single.by_id.grid.cells[2].selected)
            local action = ui.event(single, state, click(25, 1))
            test.eq(action.index, 3)
            test.is_nil(action.selected, "a single selection's action carries no set")
        end)

        test.it("table: the same rules, keys select one, and a click below the rows clears", function()
            local state = ui.interaction()
            local set: any = {}
            local function act(event: any): any
                local plan = ui.plan(files(set), 30, 8, state)
                local action = ui.event(plan, state, event)
                if action and action.selected then set = action.selected end
                return action
            end
            test.eq(listed(act(click(3, 4)).selected), "r3")
            test.eq(listed(act(click(3, 6, {shift = true})).selected), "r3,r4,r5")
            test.eq(listed(act(click(3, 5, {ctrl = true})).selected), "r3,r5")
            state.focus = "files"
            local moved = act(key("down"))
            test.eq(moved.index, 5, "down from the anchor r4")
            test.eq(listed(moved.selected), "r5")
            test.eq(listed(act(key("runes", CTRL_A)).selected), "r1,r2,r3,r4,r5,r6")
            local below = act(click(3, 8))
            test.eq(below.index, 0)
            test.eq(listed(below.selected), "")
        end)

        test.it("table: every row of the set is drawn selected, and a change repaints only the rows it touches", function()
            local color: any = palette.exact
            local raster = painted(files({r2 = true, r4 = true}), 30, 8, {})
            test.eq(region(raster, 5, 50, 1, 1), filled(color.select_bg, 1, 1), "r2")
            test.eq(region(raster, 5, 70, 1, 1), filled(color.field, 1, 1), "r3")
            test.eq(region(raster, 5, 90, 1, 1), filled(color.select_bg, 1, 1), "r4")
            -- In cells a selected row differs from the same row unselected only by its style.
            local chosen: any = cells.rows(ui.plan(files({r2 = true, r4 = true}), 30, 8, ui.interaction()), ui.interaction(), 30, 8)
            local none: any = cells.rows(ui.plan(files({}), 30, 8, ui.interaction()), ui.interaction(), 30, 8)
            test.is_true(chosen[3] ~= none[3], "r2 inverted in cells")
            test.eq(chosen[4], none[4], "r3 as it was")
            test.is_true(chosen[5] ~= none[5], "r4 inverted in cells")
            local fonts = {}
            local function keys(selected: any, name: string): any
                local seen: any = {}
                local store: any = {take = function(id: any, cols: any, rows: any, cell: any, row_key: any): (any, boolean)
                    seen[id] = row_key
                    return gfx.raster(cols * cell.w, rows * cell.h), true
                end}
                render.rows({id = name, state_revision = 1, content_state = {sdk = 1, revision = 1, ui = files(selected),
                    interaction = ui.interaction()}}, {x = 1, y = 1, cols = 30, rows = 8}, CELL, fonts, store)
                return seen
            end
            local before = keys({r1 = true}, "rows-a")
            local after = keys({r1 = true, r3 = true}, "rows-b")
            test.is_true(before["win:rows-a:sdk:row:4"] ~= after["win:rows-b:sdk:row:4"], "r3's row is repainted")
            test.eq(before["win:rows-a:sdk:row:3"], after["win:rows-b:sdk:row:3"], "r2's row is not")
        end)
    end)

    test.describe("chicago.shell.sdk tree pointer", function()
        test.it("a click on a tree row is a select with pointer, a key is one without", function()
            local tree = {kind = "tree", id = "keys", selected = 1, rows = {
                {id = "hkcu", label = "HKEY_CURRENT_USER", depth = 0, has_children = true, kind = "folder", trail = {}},
                {id = "hklm", label = "HKEY_LOCAL_MACHINE", depth = 0, has_children = true, kind = "folder", trail = {}},
            }}
            local state = ui.interaction()
            local plan = ui.plan(tree, 30, 5, state)
            local clicked = ui.event(plan, state, click(8, 1))
            test.eq(clicked and clicked.type, "select")
            test.is_true(clicked and clicked.pointer == true, "a click says it came from the pointer")
            state.focus = "keys"
            local moved = ui.event(plan, state, key("down"))
            test.eq(moved and moved.index, 2)
            test.is_nil(moved and moved.pointer, "a key does not")
        end)
    end)

    test.describe("chicago.shell.sdk table cell pictures", function()
        local function pictured(image: any): any
            local first: any = image and {text = "MMMMMM", image = image, icon = glyphs.icons.folder, kind = "folder"} or "MMMMMM"
            return {kind = "table", id = "files", columns = {{title = "Name", weight = 1}},
                rows = {{id = "f", cells = {first}}}}
        end
        test.it("shows a cell's icon character before its text in cells", function()
            local state = ui.interaction()
            local rows: any = cells.rows(ui.plan(pictured("folder"), 30, 4, state), state, 30, 4)
            test.eq(head(rows[2], 9), " " .. glyphs.icons.folder .. " MMMMMM")
            local bare: any = cells.rows(ui.plan(pictured(nil), 30, 4, ui.interaction()), ui.interaction(), 30, 4)
            test.eq(head(bare[2], 7), " MMMMMM")
        end)

        test.it("draws a cell's 16-px picture two pixels in and its text 3 px after it", function()
            local color: any = palette.exact
            local fonts = {face = face_font()}
            local with = painted(pictured("folder"), 30, 4, fonts)
            local without = painted(pictured(nil), 30, 4, fonts)
            test.is_true(region(with, 3, 23, 16, 16) ~= filled(color.field, 16, 16), "the picture")
            test.eq(region(with, 19, 21, 3, 20), filled(color.field, 3, 20), "air after the picture, the text from x = 22")
            test.is_true(region(without, 19, 21, 3, 20) ~= filled(color.field, 3, 20), "without it the text starts a cell in")
            test.eq(region(without, 3, 23, 8, 16), filled(color.field, 8, 16), "and there is no picture")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
