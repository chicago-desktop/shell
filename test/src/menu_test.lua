-- The menu rows Windows 95 menus need (FR-007 §7, FR-008 §7): a shortcut
-- column, a checkmark, a radio bullet, one level of submenus and F10 — laid
-- out once by the plan, drawn by both renderers, walked by keys and pointer.
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
local L, R = glyphs.bevel.left, glyphs.bevel.right

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
-- region(raster, x, y, w, h) / filled(colour, w, h) — a part of a raster and
-- a plain one as PNG bytes: gfx has no pixel read.
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
local function pixel(raster: any, x: integer, y: integer): string return region(raster, x, y, 1, 1) end
local function swatch(colour: string): string return filled(colour, 1, 1) end
local function face_font(): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end

-- Notepad's Edit and Explorer's View in one bar: a shortcut, a checked row, a
-- bullet, and a row that opens a submenu with a bullet, a separator, a
-- disabled checked row and a plain one.
local function tree(): any
    return {kind = "column", children = {
        {kind = "menu", id = "bar", size = 1, entries = {
            {title = "Edit", accel = 1, items = {
                {id = "undo", text = "Undo", accel = 1, shortcut = "Ctrl+Z"},
                {separator = true},
                {id = "wrap", text = "Word Wrap", checked = true},
                {id = "large", text = "Large", bullet = true},
                {id = "arrange", text = "Arrange", items = {
                    {id = "by_name", text = "by Name", bullet = true},
                    {separator = true},
                    {id = "auto", text = "Auto", checked = true, disabled = true},
                    {id = "by_date", text = "by Date"},
                }},
            }},
            {title = "View", accel = 1, items = {{id = "refresh", text = "Refresh", shortcut = "F5"}}},
        }},
        {kind = "label", text = ""},
    }}
end
local function laid(state: any, pixel_plan: boolean?, width: integer?, height: integer?): any
    return ui.plan(tree(), width or 40, height or 12, state, pixel_plan and {cell = CELL} or nil)
end
local function opened(open: any): any
    local state = ui.interaction()
    state.menus.bar = open
    return state
end
local function key(name: string, action: string?): any
    return {type = "key", key_type = name, key = name, action = action or "press"}
end
local function press(x: integer, y: integer): any
    return {type = "mouse", action = "press", button = "left", x = x, y = y}
end
local function motion(x: integer, y: integer): any
    return {type = "mouse", action = "motion", button = "none", x = x, y = y}
end
local function painted(open: any, font: any): any
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "menus", state_revision = 1, content_state = {sdk = 1, revision = 1,
        ui = tree(), interaction = opened(open)}}, {x = 1, y = 1, cols = 40, rows = 12}, CELL, {face = font}, store))
    return placed.raster
end

local function define_tests()
    test.describe("chicago.shell.sdk menu rows", function()
        test.it("keeps a list without shortcuts at its width and grows one with them by the widest plus two", function()
            local plain_menu = {kind = "menu", id = "m", size = 1, entries = {
                {title = "File", items = {{id = "open", text = "Open"}, {separator = true}, {id = "exit", text = "Exit"}}},
                {title = "Help", items = {{id = "about", text = "Properties", checked = false}}},
            }}
            for _, pixel_plan in ipairs({false, true}) do
                local where = pixel_plan and "pixels" or "cells"
                local state = ui.interaction()
                state.menus.m = {index = 1, cursor = 0}
                local plan = ui.plan(plain_menu, 40, 10, state, pixel_plan and {cell = CELL} or nil)
                test.eq(plan.by_id.m.popup.rect.w, 10, where .. ": at least eight cells and the frame, as before")
                state.menus.m = {index = 2, cursor = 0}
                plan = ui.plan(plain_menu, 40, 10, state, pixel_plan and {cell = CELL} or nil)
                test.eq(plan.by_id.m.popup.rect.w, 16, where .. ": the text and four cells, as before")
                local edit = laid(opened({index = 1, cursor = 0}), pixel_plan)
                test.eq(edit.by_id.bar.popup.rect.w, 23, where .. ": 13 for the text, 6 for Ctrl+Z, 2 between, the frame")
                local view = laid(opened({index = 2, cursor = 0}), pixel_plan)
                test.eq(view.by_id.bar.popup.rect.w, 17, where .. ": 11 for Refresh, 2 for F5, 2 between, the frame")
            end
        end)

        test.it("draws in cells the check, the bullet, the right-aligned shortcut and the submenu arrow", function()
            local state = opened({index = 1, cursor = 0})
            local rows: any = cells.rows(laid(state), state, 40, 12)
            test.eq(slice(rows[3], 1, 23), L .. " Undo" .. string.rep(" ", 9) .. "Ctrl+Z " .. R,
                "the shortcut ends one cell before the edge")
            test.eq(slice(rows[5], 1, 23), L .. glyphs.icons.check .. "Word Wrap" .. string.rep(" ", 11) .. R)
            test.eq(slice(rows[6], 1, 23), L .. glyphs.icons.radio .. "Large" .. string.rep(" ", 15) .. R)
            test.eq(slice(rows[7], 1, 23), L .. " Arrange" .. string.rep(" ", 12) .. glyphs.icons.submenu .. R,
                "the arrow in the last cell")
            local view = opened({index = 2, cursor = 0})
            local shown: any = cells.rows(laid(view), view, 40, 12)
            test.eq(slice(shown[3], 7, 17), L .. " Refresh    F5 " .. R)
        end)

        test.it("draws in pixels a 7-px check and a 6-px bullet before the text, the shortcut ending a cell early", function()
            local font = face_font()
            local color: any = palette.exact
            local ink, face = swatch(color.face_text), swatch(color.face)
            local raster = painted({index = 1, cursor = 0}, font)
            -- The list is 230 px from x = 1, its rows from y = 21, 20 px each;
            -- the text starts at x = 21, the check at x = 10, the bullet at 11.
            test.eq(pixel(raster, 16, 67), ink, "the check's top-right pixel")
            test.eq(pixel(raster, 10, 69), ink, "the check's left stroke")
            test.eq(pixel(raster, 11, 69), face, "the notch of the check")
            test.eq(pixel(raster, 14, 69), ink)
            test.eq(pixel(raster, 12, 73), ink, "the check's bottom point")
            test.eq(pixel(raster, 10, 73), face)
            test.eq(pixel(raster, 11, 88), face, "the bullet's corner is cut")
            test.eq(pixel(raster, 12, 88), ink)
            test.eq(pixel(raster, 11, 90), ink, "the bullet is six pixels wide")
            test.eq(pixel(raster, 16, 90), ink)
            test.eq(pixel(raster, 17, 90), face)
            test.eq(pixel(raster, 11, 93), face)
            -- Ctrl+Z ends at x = 211, a cell before the edge's 20 px; its text
            -- stands on y = 23..39, under the list's 3 px frame.
            local width = math.tointeger(font:measure("Ctrl+Z")) or 0
            test.eq(region(raster, 211, 23, 15, 17), filled(color.face, 15, 17), "nothing after the shortcut")
            test.is_true(region(raster, 211 - width, 23, width, 17) ~= filled(color.face, width, 17), "the shortcut itself")
            -- Arrange is the last row, 101..120; its band stops 3 px short
            -- for the frame, 101..117, and the 7 px arrow is centred in it.
            test.eq(pixel(raster, 219, 106), ink, "the submenu arrow's base")
            test.eq(pixel(raster, 219, 112), ink, "the base's bottom")
            test.eq(pixel(raster, 219, 113), face, "centred in the band, not in the row")
            test.eq(pixel(raster, 222, 109), ink, "the arrow's point")
            test.eq(pixel(raster, 223, 109), face)
            test.eq(pixel(raster, 220, 106), face)
        end)

        test.it("centres the marks in the first and the last band, under and over the 3 px frame", function()
            local font = face_font()
            local color: any = palette.exact
            local ink, face = swatch(color.face_text), swatch(color.face)
            local marked = {kind = "column", children = {
                {kind = "menu", id = "bar", size = 1, entries = {
                    {title = "View", accel = 1, items = {
                        {id = "large", text = "Large", bullet = true},
                        {id = "small", text = "Small"},
                        {id = "wrap", text = "Word Wrap", checked = true},
                    }},
                }},
                {kind = "label", text = ""},
            }}
            local store = rasters.store()
            store.begin()
            local raster = assert(render.placement({id = "marks", state_revision = 1, content_state = {sdk = 1, revision = 1,
                ui = marked, interaction = opened({index = 1, cursor = 0})}}, {x = 1, y = 1, cols = 40, rows = 12},
                CELL, {face = font}, store)).raster
            -- Rows from y = 21, 20 px each. The first band is 24..40: the 6 px
            -- bullet stands on 29..34, not on the row's 28..33.
            test.eq(pixel(raster, 12, 29), ink, "the bullet's top")
            test.eq(pixel(raster, 12, 28), face, "nothing above it")
            test.eq(pixel(raster, 12, 34), ink, "the bullet's bottom")
            test.eq(pixel(raster, 12, 35), face)
            -- The last band is 61..77: the 7 px check stands on 66..72, not on 67..73.
            test.eq(pixel(raster, 16, 66), ink, "the check's top-right pixel")
            test.eq(pixel(raster, 16, 65), face, "nothing above it")
            test.eq(pixel(raster, 12, 72), ink, "the check's bottom point")
            test.eq(pixel(raster, 12, 73), face)
        end)

        test.it("opens a submenu to the right with its first item on the row that opened it, in both modes", function()
            local open = {index = 1, cursor = 5, sub = 5, sub_cursor = 0}
            local plan = laid(opened(open))
            local popup = plan.by_id.bar.popup
            local sub = popup.sub
            test.not_nil(sub, "the submenu is laid out")
            test.eq(sub.rect.x .. "," .. sub.rect.y .. "," .. sub.rect.w .. "," .. sub.rect.h, "24,6,13,6",
                "cells: right of the list, a frame row above its items")
            test.eq(sub.rect.y + sub.lead, popup.rect.y + popup.lead + 4, "by Name on the Arrange row")
            local shown: any = cells.rows(plan, opened(open), 40, 12)
            test.eq(slice(shown[7], 24, 13), L .. glyphs.icons.radio .. "by Name   " .. R)
            test.eq(slice(shown[9], 24, 13), L .. glyphs.icons.check .. "Auto      " .. R)
            local pixel_sub = laid(opened(open), true).by_id.bar.popup.sub
            test.eq(pixel_sub.rect.x .. "," .. pixel_sub.rect.y .. "," .. pixel_sub.rect.w .. "," .. pixel_sub.rect.h, "24,6,13,4",
                "pixels: no frame rows, the first item on the row under Arrange's")
            -- No room at the right: the submenu stands left of the list.
            local wide = {kind = "menu", id = "bar", size = 1, entries = {
                {title = "Documents List", items = {{id = "x", text = "X"}}},
                {title = "Arrange", items = {{id = "icons", text = "Arrange Icons", items = {
                    {id = "name", text = "by Name"}, {id = "type", text = "by Type"}}}}},
            }}
            local flipped = ui.plan(wide, 40, 12, opened({index = 2, cursor = 1, sub = 1}))
            local list = flipped.by_id.bar.popup
            test.eq(list.sub.rect.x + list.sub.rect.w, list.rect.x, "the submenu ends where the list begins")
            -- No room below: it moves up to end on the last row.
            local low = laid(opened(open), false, 40, 9).by_id.bar.popup.sub
            test.eq(low.rect.y + low.rect.h - 1, 9)
        end)

        test.it("a click on a submenu's row opens it, a click in the submenu gives the leaf", function()
            local state = ui.interaction()
            test.is_nil(ui.event(laid(state), state, press(2, 1)))
            test.is_nil(ui.event(laid(state), state, press(3, 7)), "Arrange opens, it is not a choice")
            test.eq(state.menus.bar.sub, 5)
            local plan = laid(state)
            test.eq(ui.hit(plan, 26, 10), plan.by_id.bar, "the submenu is on top")
            local chosen = ui.event(plan, state, press(26, 10))
            test.eq(chosen and chosen.type, "activate")
            test.eq(chosen and chosen.id, "by_date", "the leaf's id")
            test.eq(chosen and chosen.menu, "bar")
            test.is_nil(state.menus.bar, "closed after the choice")
            ui.event(laid(state), state, press(2, 1))
            ui.event(laid(state), state, press(3, 7))
            test.is_nil(ui.event(laid(state), state, press(26, 9)), "a disabled row chooses nothing")
        end)

        test.it("walks into a submenu by keys and back, as the Start menu's folders", function()
            local state = ui.interaction()
            test.is_nil(ui.event(laid(state), state, key("f10", "release")), "a release opens nothing")
            test.is_nil(state.menus.bar)
            ui.event(laid(state), state, key("f10"))
            test.eq(state.menus.bar and state.menus.bar.index, 1, "F10 opens the first menu")
            local plan = laid(state)
            for _ = 1, 4 do ui.event(plan, state, key("down")) end
            test.eq(state.menus.bar.cursor, 5, "the separator is skipped on the way to Arrange")
            ui.event(plan, state, key("right"))
            test.eq(state.menus.bar.sub, 5, "→ opens the submenu")
            test.eq(state.menus.bar.sub_cursor, 1, "on its first row")
            -- No frame between: the keys read the submenu from the node.
            ui.event(plan, state, key("down"))
            test.eq(state.menus.bar.sub_cursor, 4, "the separator and the disabled row are skipped")
            local chosen = ui.event(plan, state, key("enter"))
            test.eq(chosen and chosen.id, "by_date")
            test.is_nil(state.menus.bar)

            ui.event(laid(state), state, key("f10"))
            plan = laid(state)
            for _ = 1, 4 do ui.event(plan, state, key("down")) end
            ui.event(plan, state, key("enter"))
            test.eq(state.menus.bar.sub_cursor, 1, "Enter on Arrange opens it too")
            ui.event(plan, state, key("left"))
            test.is_nil(state.menus.bar.sub, "← closes the submenu")
            test.eq(state.menus.bar.cursor, 5, "and leaves the list on Arrange")
            ui.event(plan, state, key("right"))
            ui.event(plan, state, key("esc"))
            test.is_nil(state.menus.bar.sub, "Esc closes the submenu first")
            test.not_nil(state.menus.bar.index, "the list stays")
            ui.event(plan, state, key("right"))
            ui.event(plan, state, key("right"))
            test.eq(state.menus.bar.index, 2, "→ inside the submenu moves on to the next menu")
            test.is_nil(state.menus.bar.sub)
            ui.event(laid(state), state, key("esc"))
            test.is_nil(state.menus.bar, "Esc closes the menu")
            ui.event(laid(state), state, key("f10"))
            ui.event(laid(state), state, key("f10"))
            test.is_nil(state.menus.bar, "F10 again closes it")
        end)

        test.it("follows the pointer: a submenu's row opens it, another row closes it, another title takes over", function()
            local state = opened({index = 1, cursor = 0})
            ui.event(laid(state), state, motion(3, 7))
            test.eq(state.menus.bar.cursor, 5)
            test.eq(state.menus.bar.sub, 5, "the pointer over Arrange opens it")
            test.eq(state.menus.bar.sub_cursor, 0, "the keys stay in the list")
            ui.event(laid(state), state, motion(26, 10))
            test.eq(state.menus.bar.sub_cursor, 4, "the pointer walks the submenu")
            ui.event(laid(state), state, motion(3, 3))
            test.eq(state.menus.bar.cursor, 1)
            test.is_nil(state.menus.bar.sub, "another row closes it")
            ui.event(laid(state), state, motion(38, 11))
            test.not_nil(state.menus.bar, "the pointer passing elsewhere closes nothing")
            ui.event(laid(state), state, motion(8, 1))
            test.eq(state.menus.bar.index, 2, "over View the open menu moves there")
        end)

        test.it("refuses a row both checked and a bullet, and a submenu inside a submenu", function()
            local function menu(items: any): any
                return {kind = "menu", id = "m", entries = {{title = "A", items = items}}}
            end
            test.is_nil(ui.problem(tree()))
            local both = ui.problem(menu({{id = "x", text = "X", checked = true, bullet = true}}))
            test.is_true(tostring(both):find("checked and a bullet", 1, true) ~= nil, tostring(both))
            local inner = ui.problem(menu({{id = "p", text = "P", items = {{id = "q", text = "Q", checked = true, bullet = true}}}}))
            test.is_true(tostring(inner):find("checked and a bullet", 1, true) ~= nil, tostring(inner))
            local deep = ui.problem(menu({{id = "p", text = "P", items = {{id = "q", text = "Q", items = {{id = "r", text = "R"}}}}}}))
            test.is_true(tostring(deep):find("one level", 1, true) ~= nil, tostring(deep))
        end)

        test.it("paints an open submenu with its cursor, and keys the rows it covers", function()
            local font = face_font()
            local color: any = palette.exact
            local raster = painted({index = 1, cursor = 5, sub = 5, sub_cursor = 1}, font)
            -- The submenu's box from x = 231, y = 101; the cursor row's
            -- highlight 3 px in, before the bullet.
            test.eq(pixel(raster, 236, 106), swatch(color.select_bg), "by Name highlighted")
            local closed = painted({index = 1, cursor = 5}, font)
            test.eq(pixel(closed, 236, 106), swatch(color.face), "no submenu, the label's face")
            local fonts = {face = font}
            local function keys(open: any, name: string): any
                local seen: any = {}
                local store: any = {take = function(id: any, cols: any, rows: any, cell: any, row_key: any): (any, boolean)
                    seen[id] = row_key
                    return gfx.raster(cols * cell.w, rows * cell.h), true
                end}
                render.rows({id = name, state_revision = 1, content_state = {sdk = 1, revision = 1, ui = tree(),
                    interaction = opened(open)}}, {x = 1, y = 1, cols = 40, rows = 12}, CELL, fonts, store)
                local out: any = {}
                for row = 1, 12 do out[row] = seen["win:" .. name .. ":sdk:row:" .. row] end
                return out
            end
            local first = keys({index = 1, cursor = 5, sub = 5, sub_cursor = 1}, "keys-a")
            local last = keys({index = 1, cursor = 5, sub = 5, sub_cursor = 4}, "keys-b")
            test.is_true(first[9] ~= last[9], "row 9, under the list, holds by Date: its key follows the cursor")
            test.eq(first[11], last[11], "a row the submenu does not reach keeps its key")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
