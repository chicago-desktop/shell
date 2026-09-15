-- The context menu of FR-008 §4 in the SDK: a right press on a list, a table
-- or an icon grid says `context` with the entry and the cell, and a `menu`
-- with `popup = {x, y}` floats there — chosen, dismissed, flipped, drawn as
-- any menu's list.
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
local function slice(row: any, from: integer, count: integer): string
    local out = {}
    local column = 0
    for char in plain(row):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        column = column + 1
        if column >= from and #out < count then out[#out + 1] = char end
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
local function press(x: integer, y: integer, button: string?): any
    return {type = "mouse", action = "press", button = button or "left", x = x, y = y}
end
local function key(name: string): any
    return {type = "key", key_type = name, key = name, action = "press"}
end
local function menu_at(x: integer, y: integer): any
    return ui.context_menu{id = "ctx", x = x, y = y, items = {
        {id = "open", text = "Open", accel = 1},
        {separator = true},
        {id = "props", text = "Properties", shortcut = "Alt+Enter"},
        {id = "view", text = "View", items = {{id = "large", text = "Large Icons", bullet = true}, {id = "small", text = "Small Icons"}}},
    }}
end
local function with_menu(x: integer, y: integer): any
    return {kind = "column", children = {{kind = "list", id = "files", items = {"a", "b", "c"}}, menu_at(x, y)}}
end

local function define_tests()
    test.describe("chicago.shell.sdk context", function()
        test.it("a right press on a list, a table and icons is context with the entry and the cell", function()
            local state = ui.interaction()
            local plan = ui.plan({kind = "column", children = {{kind = "button", id = "ok", size = 1, text = "OK"},
                {kind = "list", id = "files", items = {"a", "b", "c"}}}}, 20, 6, state)
            test.eq(state.focus, "ok")
            local on_row = ui.event(plan, state, press(3, 3, "right"))
            test.eq(on_row and on_row.type, "context")
            test.eq(on_row and on_row.id, "files")
            test.eq(on_row and on_row.index, 2)
            test.eq(on_row and on_row.value, "b")
            test.eq(tostring(on_row and on_row.x) .. "," .. tostring(on_row and on_row.y), "3,3", "the cell of the press")
            test.eq(state.focus, "files", "it takes the focus")
            local empty = ui.event(plan, state, press(3, 6, "right"))
            test.eq(empty and empty.index, 0, "the empty field")
            test.is_nil(empty and empty.value)
            test.is_nil(ui.event(plan, state, press(20, 3, "right")), "the scroll bar has none")
            test.is_nil(ui.event(plan, state, press(3, 3, "middle")))
            test.eq(ui.event(plan, state, press(3, 3)).type, "select", "the left button still selects")
            local table_state = ui.interaction()
            local table_plan = ui.plan({kind = "table", id = "t", columns = {{title = "Name", weight = 1}},
                rows = {{id = "r1", cells = {"one"}}, {id = "r2", cells = {"two"}}}}, 20, 5, table_state)
            test.is_nil(ui.event(table_plan, table_state, press(3, 1, "right")), "the header has none")
            local first = ui.event(table_plan, table_state, press(3, 2, "right"))
            test.eq(first and first.value and first.value.id, "r1")
            local items = {}
            for index, name in ipairs({"a", "b", "c", "d", "e"}) do items[index] = {id = name, title = name} end
            local grid_state = ui.interaction()
            local grid = ui.plan({kind = "icons", id = "grid", items = items}, 38, 8, grid_state)
            test.eq(ui.event(grid, grid_state, press(13, 1, "right")).index, 2)
            test.eq(ui.event(grid, grid_state, press(25, 5, "right")).index, 0, "between the icons")
            -- A tree too, with its visible row under the pointer: aICQ's contact list.
            local tree_state = ui.interaction()
            local tree_plan = ui.plan({kind = "tree", id = "folders", rows = {
                {id = "a", label = "A", depth = 0, has_children = true, expanded = true, kind = "folder"},
                {id = "b", label = "B", depth = 1, has_children = false, kind = "entry"},
            }}, 20, 5, tree_state)
            local on_child = ui.event(tree_plan, tree_state, press(6, 2, "right"))
            test.eq(on_child and on_child.type, "context")
            test.eq(on_child and on_child.value and on_child.value.id, "b", "the row under the pointer")
            test.eq(tree_state.focus, "folders", "it takes the focus")
            test.eq(ui.event(tree_plan, tree_state, press(6, 5, "right")).index, 0, "the tree's empty field")
        end)

        test.it("a context menu floats at its cell, taking no room, and is open while the tree carries it", function()
            local state = ui.interaction()
            local plan = ui.plan(with_menu(5, 3), 40, 12, state)
            test.eq(plan.by_id.files.rect.h, 12, "the list keeps the whole client")
            test.not_nil(state.menus.ctx, "open because it is in the tree")
            local popup = plan.by_id.ctx.popup
            test.eq(popup.rect.x .. "," .. popup.rect.y .. "," .. popup.rect.w .. "," .. popup.rect.h, "5,3,27,6",
                "at the cell: 14 for the text, 9 for Alt+Enter, 2 between, the frame")
            local rows: any = cells.rows(plan, state, 40, 12)
            test.eq(slice(rows[4], 5, 27), L .. " Open" .. string.rep(" ", 20) .. R)
            test.eq(slice(rows[6], 5, 27), L .. " Properties    Alt+Enter " .. R)
            test.eq(slice(rows[7], 5, 27), L .. " View" .. string.rep(" ", 19) .. glyphs.icons.submenu .. R)
            local chosen = ui.event(plan, state, press(7, 4))
            test.eq(chosen and chosen.type, "activate")
            test.eq(chosen and chosen.id, "open")
            test.eq(chosen and chosen.menu, "ctx")
            test.is_nil(state.menus.ctx)
        end)

        test.it("Esc, F10 and a press outside dismiss it; the keys walk it and its submenu", function()
            local state = ui.interaction()
            local plan = ui.plan(with_menu(5, 3), 40, 12, state)
            local escaped = ui.event(plan, state, key("esc"))
            test.eq(escaped and escaped.type, "dismiss", "not close: that is the window's")
            test.eq(escaped and escaped.id, "ctx")
            plan = ui.plan(with_menu(5, 3), 40, 12, state)
            test.eq(ui.event(plan, state, key("f10")).type, "dismiss")
            plan = ui.plan(with_menu(5, 3), 40, 12, state)
            local outside = ui.event(plan, state, press(38, 11))
            test.eq(outside and outside.type, "dismiss", "the press goes no further than the menu")
            plan = ui.plan(with_menu(5, 3), 40, 12, state)
            for _ = 1, 3 do ui.event(plan, state, key("down")) end
            test.eq(state.menus.ctx.cursor, 4, "the separator is skipped")
            ui.event(plan, state, key("right"))
            test.eq(state.menus.ctx.sub_cursor, 1, "→ opens View")
            plan = ui.plan(with_menu(5, 3), 40, 12, state)
            local sub = plan.by_id.ctx.popup.sub
            test.not_nil(sub)
            test.is_true(sub.rect.x + sub.rect.w - 1 <= 40, "the submenu stays in the client")
            local leaf = ui.event(plan, state, key("enter"))
            test.eq(leaf and leaf.id, "large", "the leaf's id")
        end)

        test.it("flips left and up to end at its cell when it would run past the edges", function()
            local popup = ui.plan(with_menu(38, 10), 40, 12, ui.interaction()).by_id.ctx.popup
            test.eq(popup.rect.x .. "," .. popup.rect.y, "12,5", "cells: 27 wide, 6 high, ending at 38,10")
            local pixel_popup = ui.plan(with_menu(38, 10), 40, 12, ui.interaction(), {cell = CELL}).by_id.ctx.popup
            test.eq(pixel_popup.rect.x .. "," .. pixel_popup.rect.y, "12,7", "pixels: no frame rows, 4 high")
            test.eq(ui.plan(with_menu(5, 3), 40, 12, ui.interaction(), {cell = CELL}).by_id.ctx.popup.rect.y, 3)
        end)

        test.it("paints its list in pixels over what is under it", function()
            local color: any = palette.exact
            local files = assert(fs.get("app:system_fonts"))
            local fonts = {face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))}
            local function painted(tree: any): any
                local store = rasters.store()
                store.begin()
                local placed = assert(render.placement({id = "ctx", state_revision = 1, content_state = {sdk = 1, revision = 1,
                    ui = tree, interaction = ui.interaction()}}, {x = 1, y = 1, cols = 40, rows = 12}, CELL, fonts, store))
                return placed.raster
            end
            local open = painted(with_menu(5, 3))
            local bare = painted({kind = "column", children = {{kind = "list", id = "files", items = {"a", "b", "c"}}}})
            test.eq(region(open, 44, 50, 1, 1), filled(color.face, 1, 1), "the list's face at the cell 5,3")
            test.eq(region(bare, 44, 50, 1, 1), filled(color.field, 1, 1), "without it, the list's white")
            -- The same Windows 95 frame as a bar's list.
            local box = render.menu_box(ui.plan(with_menu(5, 3), 40, 12, ui.interaction(), {cell = CELL}).by_id.ctx.popup, CELL)
            test.eq(region(open, box.x, box.y, 1, 1), filled(color.face, 1, 1), "the frame: face outermost")
            test.eq(region(open, box.x + 1, box.y + 1, 1, 1), filled(color.light, 1, 1), "then white")
            test.eq(region(open, box.x + box.w - 1, box.y + box.h - 1, 1, 1), filled(color.frame, 1, 1), "black at the bottom-right")
            test.eq(region(open, box.x + box.w - 2, box.y + box.h - 2, 1, 1), filled(color.shadow, 1, 1), "then dark gray")
        end)

        test.it("refuses a popup without its cell and a row both checked and a bullet", function()
            local lost = ui.problem({kind = "menu", id = "c", popup = {x = 1}, items = {}})
            test.is_true(tostring(lost):find("popup", 1, true) ~= nil, tostring(lost))
            local both = ui.problem(ui.context_menu{x = 1, y = 1, items = {{id = "x", text = "X", checked = true, bullet = true}}})
            test.is_true(tostring(both):find("checked and a bullet", 1, true) ~= nil, tostring(both))
            test.is_nil(ui.problem(menu_at(1, 1)))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
