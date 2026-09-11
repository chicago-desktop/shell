-- Width of the theme's character set.
--
-- Catches the most expensive mistake here: a character two cells wide shifts
-- everything to its right on the line, and the frame falls apart on every
-- line where it occurs. From outside it looks like an arithmetic error in the
-- drawing, not like an unlucky character, and people will look in the wrong
-- place.
--
-- The check lives here, not in the theme itself: a "let's measure ourselves"
-- branch inside a drawing library is not a test but extra code in the frame.
-- The theme hands out the set itself, via `all()`, exactly for this check.
local test = require("test")
local tty = require("tty")
local glyphs = require("glyphs")
local palette = require("palette")

local function define_tests()
    test.describe("butschster.windows glyphs", function()
        test.it("keeps every character of the set in one cell", function()
            local set = glyphs.all()
            test.is_true(#set > 0, "the set must not be empty: there would be nothing to measure")
            for _, ch in ipairs(set) do
                test.eq(tty.text.width(ch), 1, "character wider than a cell: " .. tostring(ch))
            end
        end)
    end)

    test.describe("butschster.windows palette", function()
        test.it("keeps the same names in both sets", function()
            -- A key forgotten in the fallback set shows up not as a failure
            -- but as nil in a style, that is, as a color "whatever happens"
            -- on one part out of twenty. On a 16-color terminal people will
            -- see it but will not be able to link it to the missing key.
            local names = palette.names()
            test.is_true(#names > 0, "the palette must not be empty")
            for _, name in ipairs(names) do
                test.not_nil(palette.exact[name], name .. ": missing from the exact set")
                test.not_nil(palette.basic[name], name .. ": missing from the fallback set")
            end

            -- And the other way round: an extra name in the fallback set means
            -- the exact set has fallen behind it, and one part is painted
            -- with the wrong color.
            local known = {}
            for _, name in ipairs(names) do known[name] = true end
            for name in pairs(palette.basic) do
                test.is_true(known[name] == true,
                    tostring(name) .. ": present in the fallback set but not in the exact one")
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
