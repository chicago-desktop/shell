-- The `terminal` view: someone else's screen inside a window. What the plan
-- measures, and what the cells renderer actually puts on the screen.
local test = require("test")
local ui = require("ui")
local cells = require("cells")
local glyphs = require("glyphs")

local ESC = string.char(27)

local function screen(rows: any, cursor: any, width: integer, height: integer): any
    local state = ui.interaction()
    local tree: any = {kind = "terminal", rows = rows, cursor = cursor}
    local plan = ui.plan(tree, width, height, state)
    return cells.rows(plan, state, width, height), plan
end

local function joined(drawn: any): string
    return table.concat(drawn, "\n")
end

local function define_tests()
    test.describe("what the plan measures", function()
        test.it("measures the screen in cells when there are no pixels", function()
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 40, 10, state)
            test.eq(plan.items[1].columns, 40, "a column is a cell")
            test.eq(plan.items[1].page, 10, "a row is a row")
        end)

        test.it("measures the screen in mono glyphs when it draws pixels", function()
            -- A mono column is 8 px and a terminal cell here is 10, so the
            -- remote screen is WIDER in columns than the window is in cells.
            -- Measuring it in cells and stretching each glyph to 10 px would
            -- resample a bitmap face at a fraction nobody chose.
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 40, 10, state, {cell = {w = 10, h = 20}})
            test.eq(plan.items[1].columns, 50, "40 cells of 10 px hold 50 mono columns")
            test.eq(plan.items[1].page, 10, "the rows do not change")
        end)

        test.it("takes no input", function()
            -- A terminal's keys belong to whatever is on the other side; the
            -- window forwards them itself. A view that took focus here would
            -- eat them.
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", id = "remote", rows = {}}, 20, 4, state)
            test.eq(#plan.focusable, 0, "nothing to focus")
        end)
    end)

    test.describe("where the pointer lands", function()
        test.it("maps a cell to a column of that screen", function()
            -- The middle of the cell is converted, not its left edge: a
            -- pointer standing on a cell means the column under the middle
            -- of it, and the edges of the two are not the same places.
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 40, 10, state, {cell = {w = 10, h = 20}})
            local item, column, row = ui.terminal_at(plan, 1, 1)
            test.not_nil(item, "the pointer is over the screen")
            test.eq(column, 1, "the first cell is the first column")
            test.eq(row, 1, "the first row")
            local _, wider = ui.terminal_at(plan, 5, 3)
            test.eq(wider, 6, "the fifth cell's middle stands in the sixth mono column")
        end)

        test.it("maps a cell to itself when there are no pixels", function()
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 40, 10, state)
            local _, column, row = ui.terminal_at(plan, 5, 3)
            test.eq(column, 5, "a column is a cell")
            test.eq(row, 3, "a row is a row")
        end)

        test.it("says nothing about a pointer that is somewhere else", function()
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 10, 4, state)
            test.is_nil((ui.terminal_at(plan, 99, 1)), "outside the screen")
        end)

        test.it("keeps a column inside the screen", function()
            local state = ui.interaction()
            local plan = ui.plan({kind = "terminal", rows = {}}, 8, 3, state, {cell = {w = 10, h = 20}})
            local _, column = ui.terminal_at(plan, 8, 1)
            test.is_true(column <= plan.items[1].columns, "never past the last column")
        end)
    end)

    test.describe("characters the face does not have", function()
        test.it("draws a block element from geometry", function()
            -- The frames of a remote desktop are built from these, and the
            -- fixed-pitch face does not carry them: asked for one it draws
            -- nothing, and the screen arrives with every border missing.
            local shape = glyphs.shape("▁")
            test.not_nil(shape, "the lower one eighth has a shape")
            test.eq(#shape, 1, "one rectangle")
            test.eq(shape[1].h, 1 / 8, "an eighth of the cell high")
            test.eq(shape[1].y, 7 / 8, "sitting on the bottom")
        end)

        test.it("draws a quadrant as its quarters", function()
            test.eq(#glyphs.shape("▟"), 3, "upper right, lower left, lower right")
            test.eq(#glyphs.shape("▛"), 3, "upper left, upper right, lower left")
        end)

        test.it("leaves an ordinary character to the font", function()
            test.is_nil(glyphs.shape("A"), "a letter is type, not geometry")
            test.is_nil(glyphs.shape(" "), "and so is a space")
        end)

        test.it("has a shape for the small icons a desktop draws", function()
            -- An empty cell in their place is never right.
            test.not_nil(glyphs.shape("▣"), "the icon above My Computer")
            test.not_nil(glyphs.shape("⊞"), "the one on Start")
            test.not_nil(glyphs.shape("▤"), "a menu folder")
        end)

        test.it("reads a codepoint out of a multi-byte character", function()
            test.eq(glyphs.codepoint("▁"), 0x2581, "three bytes, one codepoint")
            test.eq(glyphs.codepoint("A"), 65, "and one byte")
        end)

        test.it("keeps every rectangle inside the cell", function()
            -- A rectangle past the cell would paint over the neighbour, and
            -- the neighbour is someone else's character.
            for _, char in ipairs({"▁", "▛", "▟", "▏", "▕", "▔", "█", "▒", "▣", "⊞"}) do
                for _, part in ipairs(glyphs.shape(char)) do
                    test.is_true(part.x >= 0 and part.y >= 0
                        and part.x + part.w <= 1.0001 and part.y + part.h <= 1.0001,
                        "inside the cell: " .. char)
                end
            end
        end)
    end)

    test.describe("what reaches the screen", function()
        test.it("draws the rows it was given", function()
            local drawn = screen({"first", "second"}, nil, 20, 3)
            test.is_true(joined(drawn):find("first", 1, true) ~= nil, "the first row")
            test.is_true(joined(drawn):find("second", 1, true) ~= nil, "the second row")
        end)

        test.it("keeps the colours the other side chose", function()
            -- The row is placed as it came. Styling it here would overwrite
            -- the colours of the screen being shown, and nothing would say so.
            local drawn = screen({ESC .. "[31mred"}, nil, 20, 1)
            test.is_true(joined(drawn):find("31m", 1, true) ~= nil, "the row's own colour survives")
        end)

        test.it("does not print an escape it cannot use", function()
            local drawn = screen({"a" .. ESC .. "[2Jb"}, nil, 20, 1)
            test.is_true(joined(drawn):find("2J", 1, true) == nil, "no stray sequence as text")
        end)

        test.it("shows the cursor without hiding what is under it", function()
            -- A block that covers the cell hides the character being typed.
            local drawn = screen({"abc"}, {x = 2, y = 1, visible = true}, 20, 1)
            test.is_true(joined(drawn):find("7m", 1, true) ~= nil, "the cell is reversed")
            test.is_true(joined(drawn):find("b", 1, true) ~= nil, "and the character is still there")
        end)

        test.it("leaves the cursor out when it is hidden", function()
            local drawn = screen({"abc"}, {x = 2, y = 1, visible = false}, 20, 1)
            test.is_true(joined(drawn):find("7m", 1, true) == nil, "nothing reversed")
        end)

        test.it("ignores a cursor standing outside the screen", function()
            local drawn = screen({"abc"}, {x = 99, y = 1, visible = true}, 20, 1)
            test.is_true(joined(drawn):find("7m", 1, true) == nil, "no cursor off the edge")
        end)

        test.it("draws a screen with no rows at all", function()
            local drawn = screen({}, nil, 12, 3)
            test.eq(#drawn, 3, "three rows of window")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
