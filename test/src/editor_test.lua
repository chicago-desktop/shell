-- The multi-line `editor` component (FR-007 §3, §4): one plan for the keys,
-- the pointer and both renderers — the display rows and bars in the plan,
-- the selection band and the caret in pixels in the fixed-pitch face's
-- columns, the exact rows in cells, the document kept by the SDK and reached
-- by the application through `context.editor`.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local palette = require("palette")
local editor = require("editor")
local app = require("app")
local chrome_pixels = require("chrome_pixels")

local CELL = {w = 10, h = 20}

local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end
local function head(row: any, count: integer): string
    local out = {}
    for char in plain(row):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out < count then out[#out + 1] = char end
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
local function font_of(file: string): any
    local files = assert(fs.get("app:system_fonts"))
    return assert(gfx.font(assert(files:readfile(file)), {size = 13, smooth = true}))
end
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
local function mouse(action: string, x: integer, y: integer, extra: any?): any
    local event: any = {type = "mouse", action = action, button = "left", x = x, y = y}
    for field, value in pairs(extra or {}) do event[field] = value end
    return event
end
local function doc(text: string, extra: any?): any
    local node: any = {kind = "editor", id = "doc", text = text, font = "mono"}
    for field, value in pairs(extra or {}) do node[field] = value end
    return node
end
local function at(state: any): string
    return tostring(state.caret.line) .. ":" .. tostring(state.caret.col)
end
-- The editor over a button, 20×6: the editor is 20×5 from (1, 1).
local function framed(document_text: string, extra: any?): any
    return {kind = "column", children = {doc(document_text, extra or {}), {kind = "button", id = "ok", size = 1, text = "OK"}}}
end
local function painted(tree: any, interaction: any, fonts: any): any
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "editor", state_revision = 1, content_state = {sdk = 1, revision = 1,
        ui = tree, interaction = interaction}}, {x = 1, y = 1, cols = 20, rows = 6}, CELL, fonts, store))
    return placed.raster
end
-- One cells frame as a picture: every cell its background and its rune in
-- its foreground, read from the frame's own SGR — the cells mode as it
-- looks, not only its text.
local DIGITS = "0123456789abcdef"
local function hex(value: any): string
    local n = math.tointeger(math.max(0, math.min(255, tonumber(value) or 0))) or 0
    return DIGITS:sub(n // 16 + 1, n // 16 + 1) .. DIGITS:sub(n % 16 + 1, n % 16 + 1)
end
local function pictured_cells(rows: any, cols: integer, count: integer, font: any): any
    local shot = gfx.raster(cols * CELL.w, count * CELL.h)
    shot:fill("#c0c0c0")
    for row = 1, count do
        local line = tostring(rows[row] or "")
        local fg, bg = "#000000", "#c0c0c0"
        local column, at_byte = 0, 1
        while at_byte <= #line and column < cols do
            local sgr = line:match("^\27%[([%d;:]*)m", at_byte)
            if sgr then
                local params = {}
                for number in sgr:gmatch("%d+") do params[#params + 1] = tonumber(number) end
                local index = 1
                while index <= #params do
                    local code = params[index]
                    if code == 0 then fg, bg = "#000000", "#c0c0c0"
                    elseif code == 39 then fg = "#000000"
                    elseif code == 49 then bg = "#c0c0c0"
                    elseif (code == 38 or code == 48) and params[index + 1] == 2 then
                        local colour = "#" .. hex(params[index + 2]) .. hex(params[index + 3]) .. hex(params[index + 4])
                        if code == 38 then fg = colour else bg = colour end
                        index = index + 4
                    end
                    index = index + 1
                end
                at_byte = at_byte + #sgr + 3
            else
                local char = line:match("^[%z\1-\127\194-\244][\128-\191]*", at_byte) or " "
                shot:rect(column * CELL.w + 1, (row - 1) * CELL.h + 1, CELL.w, CELL.h, bg)
                if char ~= " " then shot:text(column * CELL.w + 1, (row - 1) * CELL.h + 3, char, {font = font, color = fg}) end
                column = column + 1
                at_byte = at_byte + #char
            end
        end
    end
    return shot
end

local function define_tests()
    test.describe("windows.shell.sdk editor component", function()
        test.it("lays out a horizontal bar only without wrap, a vertical bar always", function()
            local state = ui.interaction()
            local plain_plan = ui.plan(doc("hello"), 20, 6, state).by_id.doc
            test.eq(plain_plan.page, 5, "a row for the horizontal bar")
            test.eq(plain_plan.columns, 19, "a column for the vertical bar")
            test.not_nil(plain_plan.hbar)
            test.not_nil(plain_plan.bar)
            local wrapped = ui.plan(doc("hello", {wrap = true}), 20, 6, ui.interaction()).by_id.doc
            test.eq(wrapped.page, 6, "wrapped: every row is text")
            test.is_nil(wrapped.hbar, "no horizontal bar")
            test.not_nil(wrapped.bar)
            local pixel_plan = ui.plan(doc("hello"), 20, 6, ui.interaction(), {cell = CELL, scroll_cols = 2}).by_id.doc
            test.eq(pixel_plan.columns, 21, "180 px less the edge and margin, 8 px a column")
            local small = ui.plan(doc("hello"), 20, 6, ui.interaction(), {cell = {w = 8, h = 16}, scroll_cols = 2}).by_id.doc
            test.eq(small.columns, 17)
            local why = ui.problem(doc("x", {font = "sans"}))
            test.is_true(tostring(why):find("mono", 1, true) ~= nil, tostring(why))
            test.is_nil(ui.problem(doc("x")))
            test.is_nil(ui.problem({kind = "editor", id = "doc"}), "no font is the fixed-pitch one")
        end)

        test.it("makes the document from the node's text once and keeps it when the tree does not show it", function()
            local state = ui.interaction()
            ui.plan(doc("first"), 20, 6, state)
            local document = state.editors.doc
            test.is_true(editor.document(document))
            test.eq(editor.text(document), "first")
            ui.plan(doc("second"), 20, 6, state)
            test.eq(editor.text(state.editors.doc), "first", "the state owns the text afterwards")
            ui.plan({kind = "label", text = "a sheet over the document"}, 20, 6, state)
            test.eq(state.editors.doc, document, "a sheet in its place does not drop the document")
            local context = app.context({width = 20, height = 6})
            local made = context.editor("doc")
            editor.set(made, "from a file")
            test.eq(context.editor("doc"), made, "one document per id")
            ui.plan(doc("ignored"), 20, 6, context.interaction)
            test.eq(editor.text(context.interaction.editors.doc), "from a file")
        end)

        test.it("brings the caret into view in the plan after a key moved it past the page", function()
            local lines = {}
            for index = 1, 10 do lines[index] = "l" .. index end
            local state = ui.interaction()
            local plan = ui.plan(doc(table.concat(lines, "\n")), 20, 6, state)
            ui.event(plan, state, key("end", {ctrl = true}))
            test.eq(state.editors.doc.top, 0, "the key only asks")
            ui.plan(doc(""), 20, 6, state)
            test.eq(state.editors.doc.top, 5, "the plan shows the tenth row as the page's last")
        end)

        test.it("repaints only the rows whose text changed", function()
            local fonts = {face = font_of("LiberationSans-Regular.ttf"), mono = font_of("LiberationMono-Regular.ttf")}
            local function keys(text: string, name: string): any
                local interaction = ui.interaction()
                interaction.editors.doc = editor.new(text)
                interaction.focus = "doc"
                local seen: any = {}
                local store: any = {take = function(id: any, cols: any, rows: any, cell: any, row_key: any): (any, boolean)
                    seen[id] = row_key
                    return gfx.raster(cols * cell.w, rows * cell.h), true
                end}
                render.rows({id = name, state_revision = 1, content_state = {sdk = 1, revision = 1, ui = doc(""),
                    interaction = interaction}}, {x = 1, y = 1, cols = 20, rows = 6}, CELL, fonts, store)
                return seen
            end
            local before = keys("l1\nl2\nl3", "keys-a")
            local after = keys("l1\nlX\nl3", "keys-b")
            test.eq(before["win:keys-a:sdk:row:1"], after["win:keys-b:sdk:row:1"], "row 1 is as it was")
            test.is_true(before["win:keys-a:sdk:row:2"] ~= after["win:keys-b:sdk:row:2"], "row 2 is repainted")
        end)

        test.it("the shell keeps the fixed-pitch face it is given, and none when there is none", function()
            local face, mono = font_of("LiberationSans-Regular.ttf"), font_of("LiberationMono-Regular.ttf")
            chrome_pixels.use_fonts(face, face, face, mono)
            test.eq(chrome_pixels.fonts.mono, mono)
            chrome_pixels.use_fonts(face, face, face)
            test.is_nil(chrome_pixels.fonts.mono, "a set without it: the editor falls back to the face")
        end)

        test.it("takes the keys when focused: an edit is a drawn change, a move a caret, Ctrl+Z goes to the window", function()
            local state = ui.interaction()
            local plan = ui.plan(doc("ab"), 20, 6, state)
            test.eq(state.focus, "doc")
            local changed = ui.event(plan, state, typed("x"))
            test.eq(changed and changed.type, "change")
            test.eq(changed and changed.id, "doc")
            test.is_true(changed and changed.drawn == true, "drawn whatever update answers")
            test.eq(ui.event(plan, state, key("right")).type, "caret")
            test.is_nil(ui.event(plan, state, typed("z", {ctrl = true})), "Ctrl+Z is the application's")
            test.is_nil(ui.event(plan, state, key("esc")))
            test.eq(ui.event(plan, state, key("tab")).type, "change", "Tab types a tab")
            test.eq(state.focus, "doc", "and keeps the focus")
            ui.event(plan, state, {type = "paste", text = "Q"})
            test.eq(editor.text(state.editors.doc), "xa\tQb")
            local reader = ui.interaction()
            local frozen = ui.plan(doc("ab", {read_only = true}), 20, 6, reader)
            test.is_nil(ui.event(frozen, reader, typed("x")))
            test.eq(editor.text(reader.editors.doc), "ab")
        end)

        test.it("puts the caret under the pointer, selects by a drag, a word by a double click, extends with Shift", function()
            local state = ui.interaction()
            local plan = ui.plan(doc("hello world\nsecond line\nthird"), 20, 6, state)
            local document = state.editors.doc
            test.eq(ui.event(plan, state, mouse("press", 3, 2, {time = 1000})).type, "caret")
            test.eq(at(document), "2:2")
            test.eq(state.capture and state.capture.id, "doc", "the drag is the editor's")
            ui.event(plan, state, mouse("motion", 7, 2))
            test.eq(editor.selection(document), "cond")
            ui.event(plan, state, mouse("release", 7, 2))
            test.is_nil(state.capture)
            ui.event(plan, state, mouse("press", 3, 1, {time = 5000}))
            ui.event(plan, state, mouse("press", 3, 1, {time = 5200}))
            test.eq(editor.selection(document), "hello", "two presses 200 ms apart are a double click")
            ui.event(plan, state, mouse("press", 8, 1, {time = 9000}))
            ui.event(plan, state, mouse("press", 8, 1, {time = 9800}))
            test.is_nil(editor.selection(document), "800 ms apart they are two clicks")
            test.eq(at(document), "1:7")
            ui.event(plan, state, mouse("press", 1, 1, {time = 20000}))
            ui.event(plan, state, mouse("press", 5, 1, {time = 30000, shift = true}))
            test.eq(editor.selection(document), "hell", "Shift+press extends")
            local pixel_state = ui.interaction()
            local pixel_plan = ui.plan(doc("hello world"), 20, 6, pixel_state, {cell = CELL, scroll_cols = 2})
            ui.event(pixel_plan, pixel_state, mouse("press", 5, 1))
            test.eq(at(pixel_state.editors.doc), "1:5", "in pixels a cell's middle is in the fifth 8-px column")
            ui.event(plan, state, mouse("press", 5, 1, {time = 40000}))
            test.eq(at(document), "1:4", "in cells a column is a cell")
        end)

        test.it("scrolls by the wheel and both bars, as a text view does", function()
            local lines = {}
            for index = 1, 10 do lines[index] = "l" .. index end
            local state = ui.interaction()
            local plan = ui.plan(doc(table.concat(lines, "\n")), 20, 6, state)
            local document = state.editors.doc
            local wheeled = ui.event(plan, state, {type = "mouse", action = "wheel", button = "wheel_down", x = 3, y = 3})
            test.eq(wheeled and wheeled.type, "scroll")
            test.eq(document.top, 3)
            ui.event(plan, state, mouse("press", 20, 5))
            test.eq(document.top, 4, "the down arrow of the vertical bar")
            local wide_state = ui.interaction()
            local wide = ui.plan(doc(string.rep("x", 40)), 20, 6, wide_state)
            local long = wide_state.editors.doc
            ui.event(wide, wide_state, mouse("press", 19, 6))
            test.eq(long.left, 1, "the right arrow of the horizontal bar")
            wide = ui.plan(doc(string.rep("x", 40)), 20, 6, wide_state)
            ui.event(wide, wide_state, mouse("press", 3, 6))
            test.eq(wide_state.capture and wide_state.capture.id, "doc", "a press on the thumb drags it")
            ui.event(wide, wide_state, mouse("motion", 13, 6))
            test.eq(long.left, 22, "dragged to the end")
            ui.event(wide, wide_state, mouse("release", 13, 6))
            test.is_nil(wide_state.capture)
        end)

        test.it("draws the exact rows in cells: the text, a tab to column eight, the horizontal bar", function()
            local state = ui.interaction()
            local rows: any = cells.rows(ui.plan(doc("hello world\nab\tc"), 12, 4, state), state, 12, 4)
            test.eq(head(rows[1], 11), "hello world")
            test.eq(head(rows[2], 11), "ab      c  ")
            test.eq(head(rows[3], 11), string.rep(" ", 11))
            test.eq(head(rows[4], 11), "◀████████░▶", "the bar under the text, its thumb 8 of 9 cells")
            local wrapped_state = ui.interaction()
            local wrapped: any = cells.rows(ui.plan(doc("hello world\nab\tc", {wrap = true}), 9, 4, wrapped_state),
                wrapped_state, 9, 4)
            test.eq(head(wrapped[1], 8) .. "|" .. head(wrapped[2], 8) .. "|" .. head(wrapped[3], 8) .. "|" .. head(wrapped[4], 8),
                "hello   |world   |ab      |c       ", "wrapped at eight columns, no bar row")
            -- A selection shows without the focus too; the caret only with it,
            -- so both frames here are unfocused and differ by the selection alone.
            local function drawn_with(anchor: any): any
                local interaction = ui.interaction()
                interaction.editors.doc = editor.new("hello world\nab")
                interaction.editors.doc.caret = {line = 1, col = 5}
                interaction.editors.doc.anchor = anchor
                interaction.focus = "ok"
                local tree = {kind = "column", children = {doc("x", {size = 3}), {kind = "button", id = "ok", size = 1, text = "OK"}}}
                return cells.rows(ui.plan(tree, 12, 4, interaction), interaction, 12, 4)
            end
            local marked: any = drawn_with({line = 1, col = 0})
            local bare: any = drawn_with(nil)
            test.eq(plain(marked[1]), plain(bare[1]), "a selection changes no text")
            test.is_true(marked[1] ~= bare[1], "it inverts its cells")
            test.eq(marked[2], bare[2], "a row without it is as it was")
        end)

        test.it("draws in pixels a band per row under the selection and a 1-px caret in the 8-px columns", function()
            local color: any = palette.exact
            local fonts = {face = font_of("LiberationSans-Regular.ttf"), mono = font_of("LiberationMono-Regular.ttf")}
            test.eq(math.floor(fonts.mono:measure("M") + 0.5), ui.MONO_PX, "the plan's column is the face's M")
            local function state_of(caret: any, anchor: any, focus: string): any
                local interaction = ui.interaction()
                interaction.editors.doc = editor.new("    \n   M")
                interaction.editors.doc.caret = caret
                interaction.editors.doc.anchor = anchor
                interaction.focus = focus
                return interaction
            end
            -- The editor from x = 1: its columns from x = 5, 8 px each; its
            -- first row y = 1..20, the band 16 px from y = 3.
            local band = painted(framed(""), state_of({line = 1, col = 3}, {line = 1, col = 0}, "doc"), fonts)
            test.eq(region(band, 6, 10, 1, 1), filled(color.select_bg, 1, 1), "the band under columns 0..2")
            test.eq(region(band, 30, 10, 1, 1), filled(color.field, 1, 1), "column 3 is not selected")
            test.is_true(region(band, 6, 2, 1, 1) ~= filled(color.select_bg, 1, 1), "the band stays under the sunken edge")
            local caret = painted(framed(""), state_of({line = 1, col = 2}, nil, "doc"), fonts)
            test.eq(region(caret, 20, 10, 1, 1), filled(color.field_text, 1, 1), "the caret before column 2")
            test.eq(region(caret, 21, 10, 1, 1), filled(color.field, 1, 1), "one pixel wide")
            local away = painted(framed(""), state_of({line = 1, col = 2}, nil, "ok"), fonts)
            test.eq(region(away, 20, 10, 1, 1), filled(color.field, 1, 1), "no caret without the focus")
            test.eq(region(caret, 5, 23, 24, 15), filled(color.field, 24, 15), "three blank columns on row 2")
            test.is_true(region(caret, 29, 23, 8, 15) ~= filled(color.field, 8, 15), "M in the fourth column")
            test.eq(region(caret, 37, 23, 8, 15), filled(color.field, 8, 15), "and nothing after it")
            local sans_only = painted(framed(""), state_of({line = 1, col = 2}, nil, "ok"), {face = fonts.face})
            test.is_true(region(sans_only, 29, 23, 8, 15) ~= filled(color.field, 8, 15), "without mono the face draws it")
        end)

        test.it("draws the bars in pixels: the horizontal one only without wrap", function()
            local color: any = palette.exact
            local fonts = {face = font_of("LiberationSans-Regular.ttf"), mono = font_of("LiberationMono-Regular.ttf")}
            local plain_raster = painted(framed("hello"), ui.interaction(), fonts)
            local wrapped_raster = painted(framed("hello", {wrap = true}), ui.interaction(), fonts)
            test.is_true(region(plain_raster, 100, 90, 1, 1) ~= filled(color.field, 1, 1), "the bar on the last row")
            test.eq(region(wrapped_raster, 100, 90, 1, 1), filled(color.field, 1, 1), "wrapped, that row is text")
            test.is_true(region(plain_raster, 190, 50, 1, 1) ~= filled(color.field, 1, 1), "the vertical bar")
            test.is_true(region(wrapped_raster, 190, 50, 1, 1) ~= filled(color.field, 1, 1), "in both")
            -- 40 columns in 21: the thumb stands from the arrow's cell, x = 11.
            local long_raster = painted(framed(string.rep("x", 40)), ui.interaction(), fonts)
            test.is_true(region(long_raster, 11, 81, 80, 20) ~= region(plain_raster, 11, 81, 80, 20),
                "a thumb on the horizontal bar when there is more to see")
        end)

        test.it("draws an edit and a move whatever update answers", function()
            local definition: any = {update = function() return false end}
            local context = app.context({})
            test.is_true(app.dispatch(definition, {}, context, {type = "change", id = "doc", drawn = true}))
            test.is_true(app.dispatch(definition, {}, context, {type = "caret", id = "doc"}))
            test.is_false(app.dispatch(definition, {}, context, {type = "change", id = "box", value = true}),
                "a checkbox's change still asks update")
        end)

        test.it("paints a 40×10 editor with three lines, a selection and word wrap, in pixels and in cells", function()
            local fonts = {face = font_of("LiberationSans-Regular.ttf"), mono = font_of("LiberationMono-Regular.ttf")}
            local tree = {kind = "editor", id = "doc", wrap = true, font = "mono",
                text = "Windows 95 Notepad keeps a plain text file.\nThe second line.\n\tA tab, then words that wrap at the window's width."}
            local interaction = ui.interaction()
            ui.plan(tree, 40, 10, interaction)
            interaction.editors.doc.anchor = {line = 1, col = 11}
            interaction.editors.doc.caret = {line = 1, col = 18}
            interaction.focus = "doc"
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "editor-shot", state_revision = 1, content_state = {sdk = 1,
                revision = 1, ui = tree, interaction = interaction}}, {x = 1, y = 1, cols = 40, rows = 10}, CELL, fonts, store))
            local cell_state = ui.interaction()
            cell_state.editors.doc = interaction.editors.doc
            cell_state.focus = "doc"
            local rows: any = cells.rows(ui.plan(tree, 40, 10, cell_state), cell_state, 40, 10)
            test.is_true(plain(rows[1]):find("Windows 95", 1, true) ~= nil, plain(rows[1]))
            local shot = gfx.raster(40 * CELL.w, 10 * CELL.h * 2 + 10)
            shot:fill("#808080")
            shot:blit(placed.raster, 1, 1)
            shot:blit(pictured_cells(rows, 40, 10, fonts.mono), 1, 10 * CELL.h + 11)
            assert(assert(fs.get("app:shots")):writefile("editor.png", assert(shot:encode("png"))))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
