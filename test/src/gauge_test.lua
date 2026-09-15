-- The gauge's orientation: the default stays Task Manager's vertical LED
-- meter; `orient = "horizontal"` is a Windows 95 progress bar in both
-- renderers, filled by one rule (`ui.gauge_filled`).
local test = require("test")
local gfx = require("gfx")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local palette = require("palette")
local glyphs = require("glyphs")

local CELL = {w = 10, h = 20}

-- pixel(raster, x, y) / swatch(colour) — one pixel as PNG bytes: gfx has no
-- pixel read, so a 1×1 raster is cut out and compared with one of the
-- expected colour.
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
local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end

-- The gauge alone in a client of `cols` × `rows` cells, drawn by the SDK renderer.
local function painted(tree: any, cols: integer, rows: integer): any
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "gauge", state_revision = 1,
        content_state = {sdk = 1, revision = 1, ui = tree}}, {x = 1, y = 1, cols = cols, rows = rows}, CELL, {}, store))
    return placed.raster
end

local function bar(value: any, ceiling: any): any
    return {kind = "gauge", orient = "horizontal", value = value, ceiling = ceiling}
end

local function define_tests()
    test.describe("chicago.shell.sdk gauge orientation", function()
        test.it("lays a gauge out in either orientation and refuses any other", function()
            for _, orient in ipairs({"vertical", "horizontal", false}) do
                local tree: any = {kind = "gauge", value = 1, ceiling = 2}
                if orient then tree.orient = orient end
                test.is_nil(ui.problem(tree), tostring(orient))
                local plan = ui.plan(tree, 20, 2, ui.interaction())
                local item: any = plan.items[1]
                test.eq(tostring(item.rect.w) .. "x" .. tostring(item.rect.h), "20x2", tostring(orient))
                test.eq(item.node.orient, orient or nil)
            end
            local why = ui.problem({kind = "gauge", orient = "diagonal"})
            test.is_true(tostring(why):find("orient", 1, true) ~= nil, tostring(why))
        end)

        test.it("fills the share of value over ceiling, clamped, to the nearest unit", function()
            test.eq(ui.gauge_filled({value = 50, ceiling = 100}, 19), 10)
            test.eq(ui.gauge_filled({value = 26, ceiling = 100}, 10), 3)
            test.eq(ui.gauge_filled({value = 0, ceiling = 100}, 19), 0)
            test.eq(ui.gauge_filled({value = 100, ceiling = 100}, 19), 19)
            test.eq(ui.gauge_filled({value = 250, ceiling = 100}, 19), 19, "over the ceiling is full, not wider")
            test.eq(ui.gauge_filled({value = -50, ceiling = 100}, 10), 0, "below zero is empty")
            test.eq(ui.gauge_filled({value = 0.4, ceiling = 0}, 10), 4, "no ceiling counts as one")
        end)

        test.it("draws a horizontal gauge in pixels as a sunken progress bar of navy blocks", function()
            local color: any = palette.exact
            -- 200×20 px: the bar is 18 px from y = 2, its blocks from x = 3,
            -- 8 px wide on a 10 px step — 19 fit; half of them is 10.
            local half = painted(bar(50, 100), 20, 1)
            test.eq(pixel(half, 1, 2), swatch(color.shadow), "the sunken edge: shadow at the top-left")
            test.eq(pixel(half, 200, 19), swatch(color.light), "the sunken edge: light at the bottom-right")
            test.eq(pixel(half, 7, 10), swatch(color.select_bg), "the first block is navy")
            test.eq(pixel(half, 11, 10), swatch(color.face), "two pixels of face between blocks")
            test.eq(pixel(half, 97, 10), swatch(color.select_bg), "the tenth block is filled")
            test.eq(pixel(half, 107, 10), swatch(color.face), "the eleventh is not")
            local empty = painted(bar(0, 100), 20, 1)
            test.eq(pixel(empty, 7, 10), swatch(color.face), "nothing filled at zero")
            local over = painted(bar(300, 100), 20, 1)
            test.eq(pixel(over, 187, 10), swatch(color.select_bg), "the last block is filled")
            test.eq(pixel(over, 193, 10), swatch(color.face), "and nothing past it")
        end)

        test.it("keeps the vertical LED meter as the default, apart from the horizontal bar", function()
            local function png(raster: any): string return assert(raster:encode("png")) end
            local plain_gauge = png(painted({kind = "gauge", value = 50, ceiling = 100, caption = "50"}, 8, 6))
            local vertical = png(painted({kind = "gauge", orient = "vertical", value = 50, ceiling = 100, caption = "50"}, 8, 6))
            local horizontal = png(painted({kind = "gauge", orient = "horizontal", value = 50, ceiling = 100, caption = "50"}, 8, 6))
            test.eq(plain_gauge, vertical, "no orient is the vertical meter, so Task Manager does not change")
            test.is_true(horizontal ~= vertical)
        end)

        test.it("draws a horizontal gauge in cells as a sunken field of blocks on its middle row", function()
            local function rows_of(tree: any): any
                local interaction = ui.interaction()
                return cells.rows(ui.plan(tree, 12, 2, interaction), interaction, 12, 2)
            end
            local half: any = rows_of(bar(50, 100))
            test.eq(plain(half[1]), string.rep(" ", 12), "the row above is face")
            test.eq(plain(half[2]), glyphs.bevel.left .. string.rep("█", 5) .. string.rep(" ", 5) .. glyphs.bevel.right)
            local empty: any = rows_of(bar(0, 100))
            test.eq(plain(empty[2]), glyphs.bevel.left .. string.rep(" ", 10) .. glyphs.bevel.right)
            local full: any = rows_of(bar(120, 100))
            test.eq(plain(full[2]), glyphs.bevel.left .. string.rep("█", 10) .. glyphs.bevel.right)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
