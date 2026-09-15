-- The List view (FR-008 §4): `icons` with `small = true, flow = "columns"`
-- fills a column top to bottom, then the next one, and scrolls sideways by
-- columns — the plan at two sizes, the bar, the keys, the selection rules,
-- context, the rows a selection move repaints, and both renderers.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local palette = require("palette")
local glyphs = require("glyphs")
local pixels = require("pixels")

local CELL = {w = 10, h = 20}

local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end
-- slice(row, from, count) -> `count` characters of a drawn row from column `from`.
local function slice(row: any, from: integer, count: integer): string
    local out = {}
    local column = 0
    for char in plain(row):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        column = column + 1
        if column >= from and #out < count then out[#out + 1] = char end
    end
    return table.concat(out)
end
-- region(raster, x, y, w, h) / filled(colour) — a part of a raster and a
-- plain pixel as PNG bytes: gfx has no pixel read.
local function region(raster: any, x: integer, y: integer, w: integer?, h: integer?): string
    local part = gfx.raster(w or 1, h or 1)
    part:blit(raster, 2 - x, 2 - y)
    return assert(part:encode("png"))
end
local function filled(colour: string): string
    local part = gfx.raster(1, 1)
    part:fill(colour)
    return assert(part:encode("png"))
end
local function face(): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end

-- `count` files "File 1" … as the explorer gives them: an id, a title, a
-- picture and a glyph.
local function files(count: integer): any
    local out = {}
    for index = 1, count do out[index] = {id = "f" .. index, title = "File " .. index, image = "document", icon = "▤"} end
    return out
end
-- `bare`: `flow = "columns"` without `small` — the List view is small icons
-- by itself.
local function view(items: any, selected: any?, bare: boolean?): any
    return {kind = "icons", id = "files", items = items, small = (not bare) or nil, flow = "columns", selected = selected}
end
local function laid(items: any, width: integer, height: integer, selected: any?, state: any?, pixel_plan: boolean?): (any, any, any)
    local interaction = state or ui.interaction()
    local plan = ui.plan(view(items, selected), width, height, interaction, pixel_plan and {cell = CELL} or nil)
    return plan.by_id.files, interaction, plan
end
local function at(item: any, index: integer): any
    for _, cell in ipairs(item.cells) do
        if cell.index == index then return cell end
    end
    return nil
end
local function place(cell: any): string
    return tostring(cell and cell.x) .. "," .. tostring(cell and cell.y)
end
local function key(name: string): any
    return {type = "key", key_type = name, key = name, action = "press"}
end
local function press(x: integer, y: integer, button: string?, extra: any?): any
    local event: any = {type = "mouse", action = "press", button = button or "left", x = x, y = y}
    for name, value in pairs(extra or {}) do event[name] = value end
    return event
end
local function wheel(state: any, width: integer, height: integer)
    local plan = ui.plan(view(files(12)), width, height, state)
    ui.event(plan, state, {type = "mouse", action = "wheel", button = "wheel_down", x = 5, y = 2})
end
local function keys_of(set: any): string
    local out = {}
    for name, on in pairs(type(set) == "table" and set or {}) do
        if on then out[#out + 1] = tostring(name) end
    end
    table.sort(out)
    return table.concat(out, ",")
end

local function define_tests()
    test.describe("windows.shell.sdk List view", function()
        test.it("fills columns top to bottom at two sizes: the column by the widest caption, the last partial, the bar only when needed", function()
            local roomy = ui.list_shape(files(12), 40, 6)
            test.eq(table.concat({roomy.column, roomy.lines, roomy.total, roomy.fit, tostring(roomy.bar)}, ","), "10,6,2,4,false",
                "\"File 12\" and three cells; two columns of six fit in 40")
            local wide = laid(files(12), 40, 6)
            test.is_nil(wide.hbar, "no bar when the columns fit")
            test.eq(#wide.cells, 12)
            test.eq(place(at(wide, 6)), "1,6", "down the first column")
            test.eq(place(at(wide, 7)), "11,1", "then the next one")
            local tight = ui.list_shape(files(12), 25, 4)
            test.eq(table.concat({tight.column, tight.lines, tight.total, tight.fit, tostring(tight.bar)}, ","), "10,3,4,2,true",
                "four columns of three: the last row went to the bar")
            local narrow = laid(files(12), 25, 4)
            test.not_nil(narrow.hbar)
            test.is_true(narrow.hbar.limit > 0, "there is somewhere to scroll")
            test.eq(narrow.bar_cols, 0, "and no vertical bar")
            test.eq(#narrow.cells, 9, "two whole columns and the partial third")
            local partial = at(narrow, 7)
            test.eq(place(partial) .. "," .. tostring(partial and partial.room), "21,1,5", "the third keeps the five cells left")
            test.is_nil(at(narrow, 10), "the fourth is out of view")
            test.eq(ui.list_shape({{title = string.rep("a", 40)}}, 60, 5).column, 32, "capped")
            test.eq(ui.list_shape({{title = string.rep("a", 40)}}, 20, 5).column, 20, "never wider than the view")
            test.eq(ui.list_shape({{title = "a"}}, 40, 5).column, 8, "at least eight cells")
        end)

        test.it("scrolls by columns: the wheel, a press on the bar, and the selected item's column revealed", function()
            local state = ui.interaction()
            wheel(state, 25, 4)
            test.eq(state.offsets.files, 1, "the wheel turns one column")
            local turned = laid(files(12), 25, 4, nil, state)
            test.eq(place(at(turned, 4)), "1,1", "the second column now stands first")
            for _ = 1, 5 do wheel(state, 25, 4) end
            test.eq(state.offsets.files, 2, "no further than the last whole columns")
            local fresh = ui.interaction()
            local plan = ui.plan(view(files(12)), 25, 4, fresh)
            ui.event(plan, fresh, press(25, 4))
            test.eq(fresh.offsets.files, 1, "the bar's right arrow: one column")
            test.is_nil(ui.event(plan, fresh, press(10, 4, "right")), "the bar is no entry's row: no context")
            local revealed = laid(files(12), 25, 4, "f12")
            test.eq(revealed.offset, 2, "the selected item's column comes into view")
            test.not_nil(at(revealed, 12))
            local dragging = ui.interaction()
            local drag_plan = ui.plan(view(files(12)), 25, 4, dragging)
            local thumb: any = drag_plan.by_id.files.hbar
            local grab = math.tointeger(1 + thumb.start) or 1
            ui.event(drag_plan, dragging, press(grab, 4))
            test.not_nil(dragging.capture, "a press on the thumb takes it")
            ui.event(drag_plan, dragging, {type = "mouse", action = "motion", button = "left", x = grab + 12, y = 4})
            test.is_true((dragging.offsets.files or 0) > 0, "dragging the thumb right scrolls the columns")
        end)

        test.it("keys: ↑/↓ within a column, ←/→ to the same row of the neighbour, Home, End and Enter", function()
            local items = files(12)
            local function step(selected: string, name: string): (any, any)
                local _, state, plan = laid(items, 25, 4, selected)
                local action = ui.event(plan, state, key(name))
                return action and action.value and action.value.id, state
            end
            test.eq(step("f5", "up"), "f4")
            test.eq(step("f5", "down"), "f6")
            test.eq(step("f6", "down"), "f6", "the bottom of a column stays")
            test.eq(step("f4", "up"), "f4", "so does its top")
            test.eq(step("f5", "left"), "f2")
            test.eq(step("f2", "left"), "f2", "the first column has no left")
            test.eq(step("f5", "right"), "f8")
            test.eq(step("f11", "right"), "f11", "the last column has no right")
            test.eq(step("f12", "home"), "f1")
            local last, state = step("f1", "end")
            test.eq(last, "f12")
            test.eq(state.offsets.files, 2, "End reveals the last column")
            local _, eleven, shorter = laid(files(11), 25, 4, "f9")
            test.eq(ui.event(shorter, eleven, key("right")).value.id, "f11", "the next column is shorter: its last item")
            local _, entered, plan = laid(items, 25, 4, "f5")
            local enter = ui.event(plan, entered, key("enter"))
            test.eq(enter and (enter.type .. ":" .. enter.value.id), "activate:f5")
        end)

        test.it("Ctrl and Shift select as the grid does, and a right press is context with the entry", function()
            local items = files(12)
            local state = ui.interaction()
            local function click(selected: any, x: integer, y: integer, extra: any?): any
                local plan = ui.plan(view(items, selected), 40, 6, state)
                return ui.event(plan, state, press(x, y, "left", extra))
            end
            local first = click({}, 3, 1)
            test.eq(first and first.index, 1)
            test.eq(keys_of(first.selected), "f1")
            test.eq(keys_of(click(first.selected, 13, 2, {ctrl = true}).selected), "f1,f8", "Ctrl adds f8")
            local anchored = click({}, 3, 2)
            test.eq(keys_of(click(anchored.selected, 3, 4, {shift = true}).selected), "f2,f3,f4", "Shift takes the range")
            local plan = ui.plan(view(items, {}), 40, 6, state)
            local on_entry = ui.event(plan, state, press(13, 2, "right"))
            test.eq(on_entry and on_entry.type, "context")
            test.eq(on_entry and on_entry.value and on_entry.value.id, "f8")
            test.eq(ui.event(plan, state, press(25, 3, "right")).index, 0, "the empty field")
        end)

        test.it("draws in cells: a glyph and a caption per column, the partial one cut with …, the bar on the last row", function()
            local state = ui.interaction()
            local plan = ui.plan(view(files(12), "f4", true), 25, 4, state)
            local rows: any = cells.rows(plan, state, 25, 4)
            test.eq(slice(rows[1], 3, 6), "File 1")
            test.eq(slice(rows[1], 13, 6), "File 4")
            test.eq(slice(rows[1], 23, 3), "Fi…", "the partial column cuts its caption")
            test.eq(slice(rows[4], 1, 1), glyphs.scrollbar.left)
            test.eq(slice(rows[4], 25, 1), glyphs.scrollbar.right, "across the whole width: no vertical bar")
            test.not_nil(plain(rows[4]):find(glyphs.scrollbar.thumb, 1, true))
            local _, roomy_state, roomy = laid(files(12), 40, 6)
            local last = cells.rows(roomy, roomy_state, 40, 6)[6]
            test.is_nil(plain(last):find(glyphs.scrollbar.left, 1, true), "no bar when the columns fit")
            test.eq(slice(last, 13, 7), "File 12")
        end)

        test.it("draws in pixels: the band on the selected caption, the field elsewhere, the bar on the last row", function()
            local fonts = {face = face()}
            local color: any = palette.exact
            local function painted(width: integer, height: integer, selected: any): any
                local store = rasters.store()
                store.begin()
                local placed = assert(render.placement({id = "list", state_revision = 1, content_state = {sdk = 1, revision = 1,
                    interaction = ui.interaction(), ui = view(files(12), selected, true)}}, {x = 1, y = 1, cols = width, rows = height},
                    CELL, fonts, store))
                return placed.raster
            end
            local narrow = painted(25, 4, "f5")
            -- f5 is the second column's second row: its cell starts at 101,21,
            -- the 16-px picture ends at 118, the band a pixel before the caption.
            test.eq(region(narrow, 121, 22), filled(color.select_bg), "the band hugs the caption")
            test.eq(region(narrow, 120, 22), filled(color.field), "between the picture and the band")
            test.eq(region(narrow, 121, 5), filled(color.field), "f4 above is not selected")
            local item = laid(files(12), 25, 4, "f5", nil, true)
            local expected = gfx.raster(250, 20)
            pixels.hscrollbar(expected, 1, 1, 250, 20, item.hbar, CELL.w, CELL.w)
            test.eq(region(narrow, 3, 63, 246, 16), region(expected, 3, 3, 246, 16), "the last row is the horizontal bar")
            local roomy = painted(40, 6, nil)
            test.eq(region(roomy, 305, 110), filled(color.field), "no bar when the columns fit")
        end)

        test.it("a selection move repaints the two rows it touches, not the whole view", function()
            local fonts = {face = face()}
            local store = rasters.store()
            local inner = {x = 1, y = 1, cols = 40, rows = 6}
            local function window(selected: string, revision: integer): any
                return {id = "listrows", state_revision = revision, content_state = {sdk = 1, revision = revision,
                    interaction = ui.interaction(), ui = {kind = "column", children = {view(files(12), selected)}}}}
            end
            store.begin()
            local first = assert(render.rows(window("f2", 1), inner, CELL, fonts, store))
            local before: any = {}
            for _, placed in ipairs(first) do before[placed.id] = placed.raster:version() end
            store.begin()
            local second = assert(render.rows(window("f5", 2), inner, CELL, fonts, store))
            local dirty = {}
            for _, placed in ipairs(second) do
                if placed.raster:version() ~= before[placed.id] then dirty[#dirty + 1] = placed.id:match(":row:(%d+)$") end
            end
            test.eq(table.concat(dirty, ","), "2,5", "f2's row and f5's row")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
