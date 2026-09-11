-- "Display Properties": colors and their format, the resolution caption,
-- the layout of two tabs without overlaps, choosing a color and "Apply"
-- through a substituted write, "OK" closes only after a successful write;
-- the theme repaints the desktop from one point in both modes.
local test = require("test")
local model = require("model")
local ui = require("ui")
local display = require("display_window")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local widgets = require("widgets")
local palette = require("palette")

local function fixture(): any
    local written = {}
    return {tab = 1, chosen = "#008080", saved = "#008080",
        info = {screen = {width = 100, height = 28}, cell = {w = 10, h = 20}, pixels = true},
        persist = function(hex: any) written[#written + 1] = hex; return true, nil end}, written
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
        test.it("lays out both tabs without overlaps", function()
            for tab = 1, 2 do
                local state = fixture()
                state.tab = tab
                for _, dims in ipairs({{58, 22}, {48, 18}}) do
                    local plan = ui.plan(display.definition.view(state, {width = dims[1], height = dims[2]}), dims[1], dims[2], ui.interaction())
                    test.not_nil(plan.by_id.pages)
                    test.not_nil(plan.by_id.ok)
                    local monitors = 0
                    for index, item in ipairs(plan.items) do
                        if item.node.kind == "monitor" then monitors = monitors + 1 end
                        test.is_true(item.rect.x + item.rect.w <= dims[1] + 1)
                        test.is_true(item.rect.y + item.rect.h <= dims[2] + 1)
                        if item.node.kind ~= "group" then
                            for other = index + 1, #plan.items do
                                local b = plan.items[other]
                                if b.node.kind ~= "group" then
                                    local r = item.rect
                                    test.is_true(r.x + r.w <= b.rect.x or b.rect.x + b.rect.w <= r.x
                                        or r.y + r.h <= b.rect.y or b.rect.y + b.rect.h <= r.y,
                                        "overlap " .. tostring(item.node.kind) .. "/" .. tostring(b.node.kind))
                                end
                            end
                        end
                    end
                    test.eq(monitors, 1, "a preview monitor on every tab")
                end
            end
        end)
        test.it("choosing a color, \"Apply\" and \"OK\" write through the substituted write", function()
            local state, written = fixture()
            local closed = 0
            local context = {width = 58, height = 22, close = function() closed = closed + 1 end}
            local plan = ui.plan(display.definition.view(state, context), 58, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled == true, "nothing to apply: the button is disabled")
            display.definition.update(state, {type = "select", id = "colors", index = 2, value = {id = "#000080", text = "Navy"}}, context)
            test.eq(state.chosen, "#000080")
            test.eq(state.saved, "#008080")
            plan = ui.plan(display.definition.view(state, context), 58, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled ~= true)
            display.definition.update(state, {type = "activate", id = "apply"}, context)
            test.eq(#written, 1)
            test.eq(written[1], "#000080")
            test.eq(state.saved, "#000080")
            test.eq(closed, 0, "\"Apply\" does not close the window")
            display.definition.update(state, {type = "select", id = "colors", index = 1, value = {id = "#zzzzzz"}}, context)
            test.eq(state.chosen, "#000080", "an invalid color is not accepted")
            display.definition.update(state, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1)
            test.eq(#written, 1, "OK without changes does not write a second time")
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
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
