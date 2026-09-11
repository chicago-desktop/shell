-- Layout of the icon grid inside the window.
--
-- This is where the numbers that make the window lie silently are computed: how many objects
-- fit, which row to draw from and whether a scrollbar is needed. An error in
-- any of them does not look like an error — it looks like "there are no more objects".
local test = require("test")
local icons = require("icons")
local render = require("render")
local tty = require("tty")

local function define_tests()
    test.describe("butschster.windows explorer render", function()
        test.it("reserves address height for its icon and borders and shares all rows with hits", function()
            for _, ch in ipairs({12, 16, 18, 20, 22, 24, 32}) do
                local metrics = render.pixel_metrics(8, ch)
                local plan = render.layout({address_open = true, address_items = {{title = "Root"}}}, 50, 25, metrics)
                local address = plan.address
                test.is_true(address.rows * ch >= 24)
                test.is_true((address.rows - 1) * ch < 24)
                for _, hit in pairs(address.hits) do
                    test.eq(hit.row, address.row)
                    test.eq(hit.bottom_row, address.row + address.rows - 1)
                    test.is_true(hit.bottom_row < plan.field.y)
                end
                test.eq(address.dropdown[1].row, address.row + address.rows + 1, "dropdown border precedes its first item")
            end
            local cells = render.layout({}, 50, 25)
            test.eq(cells.address.rows, 1)
            test.eq(cells.field.y, 4)
        end)

        test.it("counts rows by the picture, not by the grid step", function()
            -- The grid step is four rows, the picture three: the last row does not need
            -- a gap below itself, the field's frame is below it. Count by the step, and
            -- a whole row of icons disappears, and with it a scrollbar appears
            -- that would not be there without it.
            -- Height 21: menu bar, toolbar, address bar, field, status.
            local shape = render.shape(64, 21, 0, 0)
            test.eq(shape.rows, 4, "a field of fifteen rows fits four rows")
            test.eq(shape.columns, 5)
        end)

        test.it("does not draw a row that did not get enough lines", function()
            -- A row that did not get enough lines would climb onto the status bar and
            -- stay there: the surface differ does not know it belongs to someone else.
            local shape = render.shape(64, 6, 10, 0)
            test.eq(shape.rows, 0)
        end)

        test.it("sets up scrolling only when there is something to scroll", function()
            -- A bar over fully visible content is a promise that there is more
            -- somewhere, and the person will drag it.
            test.is_false(render.shape(64, 21, 20, 0).scrolling,
                "twenty objects in four rows of five fit entirely")
            test.is_true(render.shape(64, 21, 71, 0).scrolling)
        end)

        test.it("gives the bar a column instead of drawing icons under it", function()
            -- Count the width twice, and the icons slide under the bar exactly when
            -- it appears.
            local roomy = render.shape(64, 20, 20, 0)
            local tight = render.shape(64, 20, 500, 0)
            test.eq(roomy.columns, 5)
            test.eq(tight.columns, 5, "sixty-two cells minus the bar is still five columns")

            -- But here a column really is lost: the width is exactly on the
            -- boundary, and the bar eats the last one.
            local edge = render.shape(38, 20, 500, 0)
            test.eq(render.shape(38, 20, 4, 0).columns, 3, "without the bar, three columns")
            test.eq(edge.columns, 2, "with the bar, two fit")
        end)

        test.it("clamps scrolling instead of showing emptiness past the last row", function()
            -- A window narrowed after scrolling would otherwise show an empty
            -- field and a counter promising objects.
            local shape = render.shape(64, 21, 71, 999)
            test.eq(shape.total, 15, "seventy-one objects at five per row make fifteen rows")
            test.eq(shape.first, 11, "the last screen starts from the eleventh row")
        end)

        test.it("does not scroll what is already visible", function()
            test.eq(render.shape(64, 20, 3, 7).first, 0,
                "three objects have nowhere to scroll, whatever offset is named")
        end)

        test.it("counts hits by the layout, not by the drawing", function()
            -- Hits used to be returned by whoever drew, and that was right
            -- while there was a single drawer. With two backends, "one table"
            -- now means the layout: two drawers, each counting hits
            -- in its own way, will drift apart silently, and a click will land on a neighbor
            -- in one of the two modes.
            local view = {
                title = "My Computer",
                selected = 2,
                objects = {
                    {id = "a", kind = "drive", title = "app_fs"},
                    {id = "b", kind = "drive", title = "public_files"},
                    {id = "c", kind = "folder", title = "Programs"},
                },
            }

            local plan = render.layout(view, 46, 14)
            test.eq(#plan.cells, 3, "all three objects fit")
            test.is_true(#plan.tools > 0, "the toolbar is laid out without drawing")

            -- And now the same thing DRAWN: the rectangle that
            -- icons.cell returned must match what the plan predicted.
            -- If they diverged by a cell, a click would land on a neighbor.
            local canvas = tty.canvas(46, 14)
            for _, cell in ipairs(plan.cells) do
                local box = icons.cell(canvas, cell.x, cell.y, cell.object,
                    {surface = "panel", room = cell.room, selected = cell.selected})
                test.not_nil(box, "the icon must be drawn")
                test.eq(box.from, cell.from, "the left edge diverged from the plan")
                test.eq(box.to, cell.to, "the right edge diverged from the plan")
                test.eq(box.top, cell.top, "the top diverged from the plan")
                test.eq(box.bottom, cell.bottom, "the bottom diverged from the plan")
            end
        end)

        test.it("gives the cell backend the same hits as the layout", function()
            local view = {
                title = "My Computer",
                objects = {{id = "a", kind = "drive", title = "app_fs"}},
            }
            local plan = render.layout(view, 46, 14)
            local canvas = tty.canvas(46, 14)
            local hits = render.cells(canvas, plan)

            test.eq(#hits.cells, #plan.cells)
            test.eq(hits.cells[1].from, plan.cells[1].from)
            test.eq(hits.cells[1].index, 1)
            test.eq(#hits.tools, #plan.tools)
        end)

        test.it("lays out the menu bar and the open list with one table for both backends", function()
            local plan = render.layout({menu_open = 3}, 46, 14)
            local titles = {}
            for _, hit in ipairs(plan.menu_hits) do titles[#titles + 1] = hit.menu end
            test.eq(table.concat(titles, " "), "File View Go Help", "the bar has only menus with actions, no \"Edit\"")
            local ids = {}
            for _, row in ipairs(plan.menu_popup.hits) do ids[#ids + 1] = row.id end
            test.eq(table.concat(ids, " "), "back forward up")
            test.eq(plan.menu_popup.hits[1].row, render.MENU_ROW + 2, "the list's frame is the row under the menu, the item is below it")

            local canvas = tty.canvas(46, 14)
            local hits = render.cells(canvas, plan)
            test.eq(#hits.menu, #plan.menu_hits, "title hits come from the plan")
            test.eq(#hits.menu_popup, 3)
            local rows: any = canvas:rows()
            for index, name in ipairs({"Back", "Forward", "Up One Level"}) do
                local row = plan.menu_popup.hits[index].row
                local line = tostring(rows[row]):gsub("\27%[[%d;:]*m", "")
                test.is_true(line:find(name, 1, true) ~= nil, name .. " is drawn in the row of its hit: " .. line)
            end
            test.is_nil(render.layout({}, 46, 14).menu_popup, "a closed menu does not lay out a list")
        end)

        test.it("names the failure instead of the objects, not together with them", function()
            -- "Did not read" and "read emptiness" are different statements, and
            -- an icon next to the reason would mean it was read halfway.
            local plan = render.layout({failure = "drive did not open", objects = {}}, 46, 14)
            test.eq(#plan.cells, 0)
            test.eq(plan.status.count, "—", "the counter does not pass the failure off as zero objects")
            test.is_nil(plan.scroll, "there is nothing to scroll")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
