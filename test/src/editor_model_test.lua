-- The document model of the multi-line `editor` (FR-007 §3), pure: the lines,
-- the caret and the selection, the keys, one-level undo, find, and the
-- display rows word wrap makes. No plan, no renderer.
local test = require("test")
local editor = require("editor")

local VIEW = {columns = 40, wrap = false, tab = 8, page = 3}

local function key(name: string, mods: any?): any
    local event: any = {type = "key", key_type = name, key = name, action = "press"}
    for field, value in pairs(mods or {}) do event[field] = value end
    return event
end
local function typed(char: string, mods: any?): any
    local event: any = {type = "key", key_type = "runes", key = char, action = "press"}
    for field, value in pairs(mods or {}) do event[field] = value end
    return event
end
local function feed(state: any, events: any, view: any?): any
    local last: any = nil
    for _, event in ipairs(events) do last = editor.key(state, event, view or VIEW) end
    return last
end
local function write(state: any, text: string)
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do editor.key(state, typed(char), VIEW) end
end
local function at(state: any): string
    return tostring(state.caret.line) .. ":" .. tostring(state.caret.col)
end
local function rows_of(rows: any): string
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = row.line .. "/" .. row.start .. "-" .. row.stop end
    return table.concat(out, " ")
end
local CTRL, SHIFT = {ctrl = true}, {shift = true}

local function define_tests()
    test.describe("windows.shell.sdk editor document", function()
        test.it("go-lua: table.concat(t, sep, j + 1, j) is t[j], not the empty string — a tripwire", function()
            -- The model joins runes through its own `slice` because of this:
            -- a caret at a line's end cut the tail as the last rune again.
            -- When this fails the VM was fixed, and `slice` may go.
            test.eq(table.concat({"a", "b"}, "", 3, 2), "b")
            test.eq(table.concat({"a", "b"}, "", 1, 0), "", "with j = 0 there is no t[j] to return")
        end)

        test.it("keeps a document as lines; set replaces it with the caret at the start and no undo", function()
            local state = editor.new("one\r\ntwo\rthree")
            test.eq(#state.lines, 3)
            test.eq(editor.text(state), "one\ntwo\nthree", "CRLF and CR read as LF")
            test.eq(at(state), "1:0")
            test.is_false(editor.dirty(state))
            test.eq(#editor.new("").lines, 1, "an empty document is one empty line")
            test.is_true(editor.document(state))
            test.is_false(editor.document({cursor = 0, selected = false}), "a field's state is not a document")
            write(state, "x")
            test.is_true(editor.dirty(state))
            editor.mark(state)
            test.is_false(editor.dirty(state), "mark is the saved point")
            editor.set(state, "a\nb")
            test.eq(editor.text(state), "a\nb")
            test.eq(at(state), "1:0")
            test.is_nil(state.undo, "set clears the undo step")
            test.is_false(editor.dirty(state))
        end)

        test.it("types runes, breaks a line with Enter and joins lines with Backspace and Delete", function()
            local state = editor.new("")
            test.eq(editor.key(state, typed("a"), VIEW), "change")
            write(state, "bж")
            test.eq(editor.text(state), "abж")
            test.eq(at(state), "1:3", "a Cyrillic letter is one column")
            test.eq(feed(state, {key("left")}), "caret")
            feed(state, {key("enter")})
            test.eq(editor.text(state), "ab\nж")
            test.eq(at(state), "2:0")
            feed(state, {key("backspace")})
            test.eq(editor.text(state), "abж", "Backspace at a line's start joins it to the one above")
            test.eq(at(state), "1:2")
            feed(state, {key("delete")})
            test.eq(editor.text(state), "ab")
            feed(state, {key("enter"), key("up"), key("end"), key("delete")})
            test.eq(editor.text(state), "ab", "Delete at a line's end joins the next one")
            feed(state, {key("tab")})
            test.eq(editor.text(state), "ab\t", "Tab is one rune")
            test.is_nil(feed(state, {key("backspace", {action = "release"})}), "a release edits nothing")
        end)

        test.it("jumps by words both ways, across a line's end", function()
            local state = editor.new("hello  world\nnext")
            feed(state, {key("right", CTRL)})
            test.eq(at(state), "1:7", "past the word and its spaces")
            feed(state, {key("right", CTRL)})
            test.eq(at(state), "1:12")
            feed(state, {key("right", CTRL)})
            test.eq(at(state), "2:0", "over the line's end")
            feed(state, {key("left", CTRL)})
            test.eq(at(state), "1:12")
            feed(state, {key("left", CTRL)})
            test.eq(at(state), "1:7", "to the start of the word")
            feed(state, {key("left", CTRL)})
            test.eq(at(state), "1:0")
        end)

        test.it("extends the selection with Shift from the anchor, and replaces it by typing", function()
            local state = editor.new("abc\ndef")
            feed(state, {key("right", SHIFT), key("right", SHIFT)})
            test.eq(editor.selection(state), "ab")
            feed(state, {key("down", SHIFT)})
            test.eq(editor.selection(state), "abc\nde", "the anchor stays where Shift began")
            write(state, "X")
            test.eq(editor.text(state), "Xf")
            test.eq(at(state), "1:1")
            feed(state, {key("right", SHIFT), key("right")})
            test.is_nil(editor.selection(state), "a move without Shift drops the selection")
            editor.select_all(state)
            test.eq(editor.selection(state), "Xf")
            test.is_true(editor.delete_selection(state))
            test.eq(editor.text(state), "")
            test.is_false(editor.delete_selection(state), "nothing selected, nothing deleted")
            local other = editor.new("ac")
            feed(other, {key("right")})
            editor.replace_selection(other, "b")
            test.eq(editor.text(other), "abc", "without a selection the text is inserted")
            editor.insert(other, "\nz")
            test.eq(editor.text(other), "ab\nzc")
            test.eq(at(other), "2:1")
        end)

        test.it("undoes one level and redoes on the second Undo; typing is one step", function()
            local state = editor.new("")
            test.is_false(editor.undo(state), "nothing to undo in a fresh document")
            write(state, "abc")
            test.is_true(editor.undo(state))
            test.eq(editor.text(state), "", "the typed word goes back whole")
            test.is_true(editor.undo(state))
            test.eq(editor.text(state), "abc", "the second Undo redoes")
            test.is_true(editor.undo(state))
            test.eq(editor.text(state), "")
            write(state, "x")
            feed(state, {key("left")})
            write(state, "y")
            test.eq(editor.text(state), "yx")
            editor.undo(state)
            test.eq(editor.text(state), "x", "a move between starts a new step")
            test.eq(at(state), "1:0", "the caret comes back with the text")
        end)

        test.it("finds down after the selection and up before it, with and without Match case", function()
            local state = editor.new("Alpha beta\nalpha Gamma ALPHA")
            test.is_true(editor.find(state, "alpha", {direction = "down"}))
            test.eq(editor.selection(state), "Alpha")
            test.eq(at(state), "1:5", "the caret at the match's end")
            test.is_true(state.reveal, "and brought into view")
            test.is_true(editor.find(state, "alpha", {direction = "down"}))
            test.eq(at(state), "2:5", "the next one, after the selection")
            test.is_true(editor.find(state, "alpha", {}))
            test.eq(at(state), "2:17", "down is the default")
            test.is_false(editor.find(state, "alpha", {direction = "down"}), "no wrapping around")
            test.eq(editor.selection(state), "ALPHA", "not found leaves the selection")
            test.is_true(editor.find(state, "alpha", {direction = "up"}))
            test.eq(state.anchor.line .. ":" .. state.anchor.col, "2:0", "up: before the selection")
            test.is_true(editor.find(state, "alpha", {direction = "up"}))
            test.eq(state.anchor.line .. ":" .. state.anchor.col, "1:0")
            test.is_false(editor.find(state, "alpha", {direction = "up"}))
            feed(state, {key("home", CTRL)})
            test.is_true(editor.find(state, "alpha", {match_case = true, direction = "down"}))
            test.eq(at(state), "2:5", "Match case skips Alpha")
            local cyrillic = editor.new("Привет мир\nпривет")
            test.is_true(editor.find(cyrillic, "ПРИВЕТ", {}))
            test.eq(at(cyrillic), "1:6")
            test.is_true(editor.find(cyrillic, "ПРИВЕТ", {}))
            test.eq(at(cyrillic), "2:6", "Cyrillic folds too")
            feed(cyrillic, {key("home", CTRL)})
            test.is_false(editor.find(cyrillic, "ПРИВЕТ", {match_case = true}))
            test.is_false(editor.find(cyrillic, "", {}), "an empty needle finds nothing")
        end)

        test.it("wraps display rows at the width after the last space, hard inside a long word, tabs at eight", function()
            test.eq(rows_of(editor.layout({"the quick brown fox"}, 10, true, 8)), "1/0-10 1/10-19")
            test.eq(rows_of(editor.layout({"the quick brown fox"}, 12, true, 8)), "1/0-10 1/10-19",
                "twelve would cut brown: the row ends after the space before it")
            test.eq(rows_of(editor.layout({"abcdefghijklmnop"}, 5, true, 8)), "1/0-5 1/5-10 1/10-15 1/15-16")
            test.eq(rows_of(editor.layout({"abcdefghijklmnop", ""}, 5, false, 8)), "1/0-16 2/0-0", "without wrap a line is a row")
            test.eq(rows_of(editor.layout({"\tx", "ab\tcdefgh"}, 10, true, 8)), "1/0-2 2/0-5 2/5-9",
                "a tab runs to column eight: a, b, the tab, c and d fill ten columns")
            test.eq(editor.columns(editor.runes("ab\tc"), 0, 4, 8), 9)
            test.eq(editor.columns(editor.runes("ab\tc"), 0, 3, 4), 4, "the tab stop follows `tab`")
            local tabbed = editor.new("\tx")
            local rows = editor.layout(tabbed.lines, 20, false, 8)
            test.eq(editor.at(tabbed, rows, 8, 1, 3).col, 0, "before the tab left of its middle")
            test.eq(editor.at(tabbed, rows, 8, 1, 5).col, 1, "after it past the middle")
            test.eq(editor.at(tabbed, rows, 8, 1, 30).col, 2, "the end past the text")
        end)

        test.it("walks display rows with the arrows, keeps the column, Home and End stay on the row", function()
            local view = {columns = 10, wrap = true, tab = 8, page = 2}
            local state = editor.new("the quick brown fox\nend")
            feed(state, {key("right"), key("right"), key("right"), key("right")}, view)
            feed(state, {key("down")}, view)
            test.eq(at(state), "1:14", "the wrapped part of the same line")
            feed(state, {key("down")}, view)
            test.eq(at(state), "2:3", "a shorter row: its end")
            feed(state, {key("up")}, view)
            test.eq(at(state), "1:14", "the column is kept")
            feed(state, {key("home")}, view)
            test.eq(at(state), "1:10", "Home: the row's start")
            feed(state, {key("end")}, view)
            test.eq(at(state), "1:19", "End of the line's last row")
            feed(state, {key("up"), key("end")}, view)
            test.eq(at(state), "1:9", "End of a wrapped row stops before its break")
            feed(state, {key("end", CTRL)}, view)
            test.eq(at(state), "2:3")
            feed(state, {key("home", CTRL)}, view)
            test.eq(at(state), "1:0")
            feed(state, {key("pgdown")}, view)
            test.eq(at(state), "2:0", "a page of two rows")
        end)

        test.it("leaves Ctrl+Z, X, C, V and Esc to the application; a read-only document only moves", function()
            local state = editor.new("abc")
            for _, char in ipairs({"z", "x", "c", "v"}) do
                test.is_nil(editor.key(state, typed(char, CTRL), VIEW), "Ctrl+" .. char)
            end
            test.is_nil(editor.key(state, key("esc"), VIEW))
            test.eq(editor.text(state), "abc")
            test.eq(editor.key(state, typed("a", CTRL), VIEW), "caret")
            test.eq(editor.selection(state), "abc", "Ctrl+A selects all")
            local frozen = {columns = 40, wrap = false, tab = 8, page = 3, read_only = true}
            local reader = editor.new("abc")
            test.is_nil(editor.key(reader, typed("x"), frozen))
            test.is_nil(editor.key(reader, key("delete"), frozen))
            test.is_nil(editor.key(reader, {type = "paste", text = "x"}, frozen))
            test.eq(editor.key(reader, key("right"), frozen), "caret")
            test.eq(editor.text(reader), "abc")
            test.eq(at(reader), "1:1")
        end)

        test.it("pastes lines at the caret, and the pointer places, extends and takes a word", function()
            local state = editor.new("ad")
            feed(state, {key("right")})
            test.eq(editor.key(state, {type = "paste", text = "b\r\nc"}, VIEW), "change")
            test.eq(editor.text(state), "ab\ncd")
            test.eq(at(state), "2:1")
            local words = editor.new("hello world  x")
            editor.word(words, {line = 1, col = 7})
            test.eq(editor.selection(words), "world")
            editor.word(words, {line = 1, col = 12})
            test.eq(editor.selection(words), "  ", "a double click on blanks takes the blanks")
            editor.press(words, {line = 1, col = 2}, false)
            test.is_nil(editor.selection(words))
            editor.press(words, {line = 1, col = 5}, true)
            test.eq(editor.selection(words), "llo", "Shift+press extends from the caret")
        end)

        test.it("brings the caret into view by rows and, without wrap, by columns", function()
            local state = editor.new("a\nb\nc\nd\ne\nf")
            state.caret = {line = 6, col = 0}
            local rows = editor.layout(state.lines, 10, false, 8)
            editor.reveal(state, rows, 8, 3, 10)
            test.eq(state.top, 3, "the last row is the page's last")
            state.caret = {line = 2, col = 0}
            editor.reveal(state, rows, 8, 3, 10)
            test.eq(state.top, 1)
            local wide = editor.new(string.rep("x", 30))
            wide.caret = {line = 1, col = 25}
            editor.reveal(wide, editor.layout(wide.lines, 10, false, 8), 8, 3, 10)
            test.eq(wide.left, 16, "column 25 is the tenth shown")
            editor.reveal(wide, editor.layout(wide.lines, 10, false, 8), 8, 3, nil)
            test.eq(wide.left, 0, "wrapped, nothing scrolls sideways")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
