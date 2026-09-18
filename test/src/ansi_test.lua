-- Styled terminal rows decoded into cells: what a pixel renderer is handed
-- when it has to paint someone else's screen one rune at a time. Pure.
local test = require("test")
local ansi = require("ansi")

local ESC = string.char(27)

local function sgr(params: string): string
    return ESC .. "[" .. params .. "m"
end

local function chars(cells: any): string
    local out = {}
    for _, cell in ipairs(cells) do out[#out + 1] = cell.char end
    return table.concat(out)
end

local function define_tests()
    test.describe("width", function()
        test.it("pads a short row to the width asked for", function()
            local cells = ansi.decode("ab", 5)
            test.eq(#cells, 5, "five cells")
            test.eq(chars(cells), "ab   ", "the rest is spaces")
        end)

        test.it("cuts a row that does not fit", function()
            test.eq(chars(ansi.decode("abcdef", 3)), "abc", "three cells")
        end)

        test.it("carries the pen into the padding", function()
            -- A row that sets a background and ends means the background to
            -- the end of the row; that is how a terminal paints a filled bar,
            -- and stopping at the last rune would leave a hole in it.
            local cells = ansi.decode(sgr("44") .. "ab", 4)
            test.eq(cells[4].bg, "#0000ee", "the padding keeps the background")
        end)

        test.it("gives a nil row a row of blanks", function()
            test.eq(chars(ansi.decode(nil, 3)), "   ", "no row is an empty row")
        end)
    end)

    test.describe("colour", function()
        test.it("reads the sixteen by name", function()
            local cells = ansi.decode(sgr("31") .. "r" .. sgr("0") .. "d", 2)
            test.eq(cells[1].fg, "#cd0000", "red")
            test.is_nil(cells[2].fg, "reset means default, not black")
        end)

        test.it("reads a bright colour", function()
            test.eq(ansi.decode(sgr("91") .. "x", 1)[1].fg, "#ff0000", "bright red")
        end)

        test.it("reads a palette index", function()
            test.eq(ansi.decode(sgr("38;5;196") .. "x", 1)[1].fg, "#ff0000", "cube 196")
        end)

        test.it("reads a truecolour triplet", function()
            test.eq(ansi.decode(sgr("48;2;18;52;86") .. "x", 1)[1].bg, "#123456", "exact background")
        end)

        test.it("has a colour for palette index zero", function()
            -- Index zero is where a float key silently misses the integer one
            -- it equals, and the colour comes back nil for that one entry
            -- alone.
            test.eq(ansi.indexed(0), "#000000", "index 0 resolves")
            test.eq(ansi.indexed(16), "#000000", "the cube's own black resolves")
            test.eq(ansi.indexed(255), "#eeeeee", "the last grey resolves")
        end)

        test.it("keeps attributes apart from colour", function()
            local cells = ansi.decode(sgr("1;4;7") .. "x", 1)
            test.is_true(cells[1].bold, "bold")
            test.is_true(cells[1].underline, "underline")
            test.is_true(cells[1].reverse, "reverse")
        end)
    end)

    test.describe("ink", function()
        test.it("fills in the caller's defaults", function()
            local fg, bg = ansi.ink(ansi.decode("x", 1)[1], "#000000", "#c0c0c0")
            test.eq(fg, "#000000", "the default ink")
            test.eq(bg, "#c0c0c0", "the default paper")
        end)

        test.it("swaps them for reverse video", function()
            -- Forgetting this loses every selection and every menu bar, and
            -- the row still draws, so nothing points at the mistake.
            local fg, bg = ansi.ink(ansi.decode(sgr("7") .. "x", 1)[1], "#000000", "#c0c0c0")
            test.eq(fg, "#c0c0c0", "ink and paper change places")
            test.eq(bg, "#000000", "paper is the old ink")
        end)
    end)

    test.describe("what is not drawn", function()
        test.it("drops a sequence that is not SGR", function()
            -- A cursor move inside a row that is already laid out is a lie,
            -- and printed as text it is the "8;2;255;255;255m" that fills a
            -- screen with rubbish.
            test.eq(chars(ansi.decode("a" .. ESC .. "[2J" .. "b", 2)), "ab", "only the text")
        end)

        test.it("drops an OSC 8 hyperlink and keeps its text", function()
            local row = ESC .. "]8;;https://example.invalid" .. ESC .. "\\link" .. ESC .. "]8;;" .. ESC .. "\\"
            test.eq(chars(ansi.decode(row, 4)), "link", "the words, not the link")
        end)

        test.it("drops an escape that never ends", function()
            test.eq(chars(ansi.decode("a" .. ESC .. "[38;5", 2)), "a ", "a cut sequence prints nothing")
        end)
    end)

    test.describe("runes", function()
        test.it("counts a multi-byte character as one cell", function()
            local cells = ansi.decode("привет", 6)
            test.eq(#cells, 6, "six cells, not twelve bytes")
            test.eq(cells[1].char, "п", "the first rune whole")
        end)

        test.it("draws a byte that is not UTF-8 instead of losing the row", function()
            local cells = ansi.decode("a" .. string.char(0xFF) .. "b", 3)
            test.eq(#cells, 3, "three cells")
            test.eq(cells[3].char, "b", "the text after it survives")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
