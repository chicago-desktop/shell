-- "Display Properties": colors and their format, the resolution caption,
-- four tabs laid out without overlaps in cells and at two pixel cells, the
-- Windows 95 metrics (the page margin, 75×23 buttons 6 px apart on the page's
-- right edge, a 4:3 monitor, the lists under it), choosing a color and a
-- pattern and "Apply" through a substituted write, "OK" closes only after a
-- successful write; the theme repaints the desktop from one point.
local test = require("test")
local model = require("model")
local ui = require("ui")
local render = require("render")
local display = require("display_window")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local widgets = require("widgets")
local palette = require("palette")

local function fixture(): any
    local written = {}
    return {tab = 1, chosen = "#008080", saved = "#008080", pattern = "(None)", pattern_saved = "(None)",
        info = {screen = {width = 100, height = 28}, cell = {w = 10, h = 20}, pixels = true},
        persist = function(settings: any) written[#written + 1] = settings; return true, nil end}, written
end

-- The window entry's size (`butschster.windows.display:window`, 46×24) minus
-- the frame of the theme that draws it: the client the compositor gives.
local WIDTH, HEIGHT = 46, 24
local function pixel_client(cw: integer, ch: integer): (integer, integer)
    chrome_pixels.use_cell_size(cw, ch)
    local inset: any = chrome_pixels.window_insets({})
    return WIDTH - inset.left - inset.right, HEIGHT - inset.top - inset.bottom
end
local function cell_client(): (integer, integer)
    local inset: any = chrome.window_insets({})
    return WIDTH - inset.left - inset.right, HEIGHT - inset.top - inset.bottom
end
local function pixel_plan(state: any, cw: integer, ch: integer): (any, integer, integer)
    local cols, rows = pixel_client(cw, ch)
    local tree = display.definition.view(state, {width = cols, height = rows, native = true})
    return ui.plan(tree, cols, rows, ui.interaction(), {cell = {w = cw, h = ch}, scroll_cols = widgets.scroll_cols(cw)}), cols, rows
end
-- Every rectangle the SDK renderer draws for the window, through a stub raster.
local function drawn(state: any, cw: integer, ch: integer): any
    local cols, rows = pixel_client(cw, ch)
    local rects: any = {}
    local raster: any = {fill = function() end, set = function() end, blit = function() end,
        text = function() return 0 end,
        rect = function(_, x, y, w, h, color) rects[#rects + 1] = {x = x, y = y, w = w, h = h, color = color} end}
    local store: any = {take = function() return raster, true end}
    local tree = display.definition.view(state, {width = cols, height = rows, native = true})
    assert(render.placement({id = "display", state_revision = 1, content_state = {sdk = 1, revision = 1, ui = tree}},
        {x = 1, y = 1, cols = cols, rows = rows}, {w = cw, h = ch}, {}, store))
    return rects
end

local function define_tests()
    test.describe("Display Properties model", function()
        test.it("checks the color format and captions the resolution", function()
            test.is_true(model.valid("#008080"))
            test.is_true(not model.valid("008080"))
            test.is_true(not model.valid("#00808"))
            test.is_true(not model.valid("#00zz80"))
            test.eq(model.resolution({width = 100, height = 28}, {w = 10, h = 20}), "100 × 28 cells, 1000 × 560 px")
            test.eq(model.cell_text({w = 10, h = 20}), "Terminal cell 10 × 20 px")
            test.eq(model.graphics(false), "Pixel graphics: no, cells only")
            test.eq(model.resolution({width = 80, height = 24}, nil), "80 × 24 cells")
            test.eq(model.resolution(nil, nil), "unknown")
            test.eq(#model.color_items("#008080"), #model.COLORS)
            local extra = model.color_items("#123456")
            test.eq(#extra, #model.COLORS + 1)
            test.eq(extra[#extra].id, "#123456")
        end)
    end)
    test.describe("Display Properties on the SDK", function()
        test.it("lays out all four tabs without overlaps, in cells and at 8×16 and 10×20", function()
            for tab = 1, 4 do
                local state = fixture()
                state.tab = tab
                local cols, rows = cell_client()
                local layouts: any = {{ui.plan(display.definition.view(state, {width = cols, height = rows}), cols, rows,
                    ui.interaction()), cols, rows, "cells"}}
                for _, cell in ipairs({{8, 16}, {10, 20}}) do
                    local plan, pcols, prows = pixel_plan(state, cell[1], cell[2])
                    layouts[#layouts + 1] = {plan, pcols, prows, cell[1] .. "x" .. cell[2]}
                end
                for _, layout in ipairs(layouts) do
                    local plan, width, height, where = layout[1], layout[2], layout[3], "tab " .. tab .. " " .. layout[4]
                    test.eq(#plan.by_id.pages.spans, 4, where .. ": all four tabs fit")
                    test.not_nil(plan.by_id.ok, where .. ": OK is laid out")
                    local monitors = 0
                    for index, item in ipairs(plan.items) do
                        local r = item.rect
                        if item.node.kind == "monitor" then monitors = monitors + 1 end
                        test.is_true(r.x >= 1 and r.y >= 1 and r.x + r.w <= width + 1 and r.y + r.h <= height + 1,
                            where .. ": " .. tostring(item.node.kind) .. " fits the client")
                        test.is_nil(tostring(item.node.text or ""):find("Selected", 1, true), where .. ": no \"Selected\" caption")
                        if item.node.kind ~= "group" then
                            for other = index + 1, #plan.items do
                                local b = plan.items[other]
                                if b.node.kind ~= "group" then
                                    test.is_true(r.x + r.w <= b.rect.x or b.rect.x + b.rect.w <= r.x
                                        or r.y + r.h <= b.rect.y or b.rect.y + b.rect.h <= r.y,
                                        where .. ": overlap " .. tostring(item.node.kind) .. "/" .. tostring(b.node.kind))
                                end
                            end
                        end
                    end
                    test.eq(monitors, 1, where .. ": a preview monitor")
                end
            end
        end)
        test.it("matches the Windows 95 dialog at 8×16 and 10×20", function()
            for _, cell in ipairs({{8, 16}, {10, 20}}) do
                local cw, ch = cell[1], cell[2]
                local where = cw .. "x" .. ch
                local plan = pixel_plan(fixture(), cw, ch)
                local page = plan.by_id.pages
                test.eq(page.rect.x, 2, where .. ": the page stands one column in — 7 px rounds to one")
                test.eq(page.rect.y, 1, where .. ": and on the top row — 7 px rounds to no row")
                local right = (page.rect.x + page.rect.w - 1) * cw
                local ok, cancel, apply = plan.by_id.ok, plan.by_id.cancel, plan.by_id.apply
                for _, button in ipairs({ok, cancel, apply}) do
                    local b: any = button
                    test.eq(b.px and b.px.w, 75, where .. ": " .. b.node.id .. " is 75 px wide")
                    test.is_true(b.px.x >= (b.rect.x - 1) * cw + 1 and b.px.x + b.px.w - 1 <= (b.rect.x + b.rect.w - 1) * cw,
                        where .. ": " .. b.node.id .. " is drawn inside its own cells")
                    test.is_true(b.rect.h * ch >= 23, where .. ": the row holds a 23 px button")
                end
                test.eq(cancel.px.x - (ok.px.x + ok.px.w), 6, where .. ": 6 px between OK and Cancel")
                test.eq(apply.px.x - (cancel.px.x + cancel.px.w), 6, where .. ": 6 px between Cancel and Apply")
                test.eq(apply.px.x + apply.px.w - 1, right, where .. ": the buttons end on the page frame's right edge")
                local monitor: any = nil
                for _, item in ipairs(plan.items) do if item.node.kind == "monitor" then monitor = item end end
                test.is_true(plan.by_id.patterns.rect.y > monitor.rect.y + monitor.rect.h - 1, where .. ": the pattern list under the monitor")
                -- What the renderer draws: three 75×23 buttons and a 4:3 screen.
                local buttons, screen = 0, nil
                for _, r in ipairs(drawn(fixture(), cw, ch)) do
                    if r.w == 75 and r.h == 23 then buttons = buttons + 1 end
                    if r.color == "#008080" and (screen == nil or r.w * r.h > screen.w * screen.h) then screen = r end
                end
                test.is_true(buttons >= 3, where .. ": three 75×23 buttons drawn, got " .. buttons)
                test.not_nil(screen, where .. ": the monitor draws the desktop color")
                test.is_true(math.abs(screen.w * 3 - screen.h * 4) <= 3, where .. ": the screen is 4:3, got " .. screen.w .. "×" .. screen.h)
            end
        end)
        test.it("choosing a color and a pattern, \"Apply\" and \"OK\" write through the substituted write", function()
            local state, written = fixture()
            local closed = 0
            local context = {width = 44, height = 22, close = function() closed = closed + 1 end}
            local plan = ui.plan(display.definition.view(state, context), 44, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled == true, "nothing to apply: the button is disabled")
            display.definition.update(state, {type = "select", id = "colors", index = 2, value = {id = "#000080", text = "Navy"}}, context)
            display.definition.update(state, {type = "select", id = "patterns", index = 2, value = {id = "Bricks", text = "Bricks"}}, context)
            test.eq(state.chosen .. "/" .. state.pattern, "#000080/Bricks")
            test.eq(state.saved .. "/" .. state.pattern_saved, "#008080/(None)")
            plan = ui.plan(display.definition.view(state, context), 44, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled ~= true)
            display.definition.update(state, {type = "activate", id = "apply"}, context)
            test.eq(#written, 1)
            test.eq(tostring(written[1].desktop_color) .. "/" .. tostring(written[1].desktop_pattern), "#000080/Bricks")
            test.eq(state.saved .. "/" .. state.pattern_saved, "#000080/Bricks")
            test.eq(closed, 0, "\"Apply\" does not close the window")
            display.definition.update(state, {type = "select", id = "colors", index = 1, value = {id = "#zzzzzz"}}, context)
            test.eq(state.chosen, "#000080", "an invalid color is not accepted")
            display.definition.update(state, {type = "select", id = "patterns", index = 1, value = {id = "Nope"}}, context)
            test.eq(state.pattern, "(None)", "a pattern nobody can draw is no pattern")
            display.definition.update(state, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1)
            test.eq(#written, 2, "OK writes the pending pattern")
            test.is_nil(written[2].desktop_color, "only what changed is written")
            test.eq(written[2].desktop_pattern, "(None)")
            -- A write failure keeps the window open and names the reason.
            local failing, _ = fixture()
            failing.persist = function() return nil, "database busy" end
            failing.chosen = "#000000"
            display.definition.update(failing, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1, "on a write failure the window stays")
            test.eq(failing.failure, "database busy")
            test.eq(display.definition.update(failing, {type = "key", key_type = "runes", key = "x"}, context), false)
        end)
        test.it("the theme repaints the desktop from one point in both modes", function()
            local before = widgets.styles.desktop
            test.is_true(chrome.use_desktop("#000080"))
            test.eq(palette.exact.desktop, "#000080")
            test.is_true(widgets.styles.desktop ~= before, "the cell style is re-read")
            test.is_true(not chrome.use_desktop("000080"), "a color without a hash is not accepted")
            test.eq(palette.exact.desktop, "#000080", "an invalid color changes nothing")
            test.is_true(chrome.use_desktop("#008080"))
            test.eq(palette.exact.desktop, "#008080")
            test.is_true(chrome.use_pattern({136, 84, 34, 69, 136, 21, 34, 81}), "eight bytes are a pattern")
            test.eq(chrome.pattern and chrome.pattern[1], 136)
            test.is_false(chrome.use_pattern({1, 2, 3}), "seven rows or fewer are not")
            test.is_false(chrome.use_pattern({1, 2, 3, 4, 5, 6, 7, 8, 9}), "nine rows are not either: no silent first eight")
            test.is_false(chrome.use_pattern({1, 2, 3, 4, 5, 6, 7, 300}), "a byte is at most 255")
            test.eq(chrome.pattern and chrome.pattern[1], 136, "a refused pattern changes nothing")
            test.is_true(chrome.use_pattern(nil))
            test.is_nil(chrome.pattern, "nil is no pattern")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
