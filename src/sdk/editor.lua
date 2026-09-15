local text = require("text")
local geometry = require("geometry")
local editor = {}
-- One UTF-8 parse for the whole window, taken from the base; the name is kept for callers.
editor.runes = text.runes
local whole = geometry.whole
function editor.event(text: any, state: any, event: any): (any, any)
    local chars: {string} = editor.runes(text)
    state.cursor = whole(math.max(0, math.min(#chars, whole(state.cursor))))
    local key = event.action ~= "release" and (event.key_type or event.key) or nil
    local inserted: any = nil
    if event.type == "paste" then inserted = tostring(event.text or ""):gsub("[\r\n]", " ")
    elseif key == "runes" and event.ctrl and event.key == "a" then state.selected = true
    elseif key == "runes" and not event.ctrl and not event.alt then inserted = tostring(event.key or "")
    elseif key == "left" then state.cursor = math.max(0, state.cursor - 1); state.selected = false
    elseif key == "right" then state.cursor = math.min(#chars, state.cursor + 1); state.selected = false
    elseif key == "home" then state.cursor = 0; state.selected = false
    elseif key == "end" then state.cursor = #chars; state.selected = false
    elseif key == "backspace" or key == "delete" then
        if state.selected then chars, state.cursor, state.selected = {}, 0, false
        elseif key == "backspace" and state.cursor > 0 then table.remove(chars, whole(state.cursor)); state.cursor = state.cursor - 1
        elseif key == "delete" and state.cursor < #chars then table.remove(chars, whole(state.cursor + 1)) end
        return table.concat(chars), "change"
    elseif key == "enter" then return text, "activate" end
    if inserted then
        if state.selected then chars, state.cursor, state.selected = {}, 0, false end
        for _, char in ipairs(editor.runes(inserted)) do
            state.cursor = state.cursor + 1
            table.insert(chars, whole(state.cursor), char)
        end
        return table.concat(chars), "change"
    end
    return text, nil
end
-- The field's text as it is shown: a password shows asterisks, one per
-- rune, so that the caret and the selection are counted over the same
-- positions. The value itself stays in `node.text`, and editing works on it.
function editor.shown(node: any): string
    local value = tostring(node.text or "")
    if node.password then return string.rep("*", #editor.runes(value)) end
    return value
end
-- Cell-width conservative visible suffix around the caret. Renderers share it.
function editor.visible(text: any, editing: any, columns: any): (any, any)
    local chars: {string} = editor.runes(text)
    local cursor = whole(math.max(0, math.min(#chars, editing and editing.cursor or #chars)))
    local room = whole(math.max(1, columns - 2))
    local first = whole(math.max(1, cursor - room + 2))
    return table.concat(chars, "", first, whole(math.min(#chars, first + room - 1))), cursor - first + 1
end

-- ─── The document of a multi-line `editor` (FR-007 §3) ───────────────────
--
-- The state of an `editor` node lives in `interaction.editors[id]`, the map
-- the single-line field uses, told from the field's `{cursor, selected}` by
-- its `lines`:
--   lines       the text, one string per line, without "\n"
--   caret       {line, col}: the line 1-based, the column in runes before the caret
--   anchor      {line, col} | nil — the other end of the selection
--   top, left   the scroll: hidden display rows, hidden display columns
--   goal        the display column ↑ and ↓ keep, nil after a sideways move
--   undo        nil | {lines, caret, anchor, undone} — ONE level: the text
--               before the last edit; Undo swaps it with the current one, so
--               the next Undo redoes (classic Notepad)
--   typing      the last edit was typed: more typing joins its undo step
--   dirty       changed since `mark`
--   reveal      the plan brings the caret into view once, then clears it
-- The model is pure: the keys, the pointer and the application's calls all
-- go through the functions below, and the plan only reads and scrolls.
editor.TAB = 8

-- split(text) -> the lines of a text; CRLF and CR read as LF.
local function split(value: any): {string}
    local source: string = (tostring(value or ""):gsub("\r\n", "\n"))
    source = (source:gsub("\r", "\n"))
    local out: {string} = {}
    for line in (source .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    return out
end
local function point(line: any, col: any): any
    return {line = whole(line), col = whole(col)}
end
local function same(a: any, b: any): boolean
    return a.line == b.line and a.col == b.col
end
local function before(a: any, b: any): boolean
    return a.line < b.line or (a.line == b.line and a.col < b.col)
end
local function length(state: any, line: any): integer
    return #editor.runes(state.lines[whole(line)] or "")
end
local function blank(char: any): boolean
    return char == " " or char == "\t"
end
-- advance(char, column, tab) -> the display columns a rune takes at `column`:
-- one, and a tab to the next multiple of `tab`.
local function advance(char: any, column: integer, tab: integer): integer
    if char == "\t" then return tab - column % tab end
    return 1
end
-- slice(chars, from, to) -> runes from..to joined, "" when from > to. Not
-- `table.concat` alone: in this runtime's go-lua `concat(t, "", j + 1, j)`
-- is t[j], so the empty tail after a caret at a line's end came back as the
-- line's last rune (a tripwire in editor_model_test).
local function slice(chars: {string}, from: any, to: any): string
    local first, last = whole(from), whole(to)
    if first > last then return "" end
    return table.concat(chars, "", first, last)
end
-- span(state) -> the selection's two ends in order, or nil.
local function span(state: any): (any, any)
    local anchor: any, caret: any = state.anchor, state.caret
    if anchor == nil or same(anchor, caret) then return nil, nil end
    if before(anchor, caret) then return anchor, caret end
    return caret, anchor
end
local function remove(state: any, from: any, to: any)
    local first: {string} = editor.runes(state.lines[from.line])
    local last: {string} = editor.runes(state.lines[to.line])
    local joined = slice(first, 1, from.col) .. slice(last, to.col + 1, #last)
    if to.line > from.line then
        local kept: {string} = {}
        for index = 1, from.line - 1 do kept[#kept + 1] = state.lines[index] end
        kept[#kept + 1] = joined
        for index = to.line + 1, #state.lines do kept[#kept + 1] = state.lines[index] end
        state.lines = kept
    else
        state.lines[from.line] = joined
    end
    state.caret = point(from.line, from.col)
    state.anchor = nil
end
local function insert_at(state: any, value: string)
    local pieces = split(value)
    local caret: any = state.caret
    local chars: {string} = editor.runes(state.lines[caret.line])
    local head, tail = slice(chars, 1, caret.col), slice(chars, caret.col + 1, #chars)
    if #pieces == 1 then
        state.lines[caret.line] = head .. pieces[1] .. tail
        state.caret = point(caret.line, caret.col + #editor.runes(pieces[1]))
        return
    end
    local kept: {string} = {}
    for index = 1, caret.line - 1 do kept[#kept + 1] = state.lines[index] end
    kept[#kept + 1] = head .. pieces[1]
    for index = 2, #pieces - 1 do kept[#kept + 1] = pieces[index] end
    kept[#kept + 1] = pieces[#pieces] .. tail
    for index = caret.line + 1, #state.lines do kept[#kept + 1] = state.lines[index] end
    state.lines = kept
    state.caret = point(caret.line + #pieces - 1, #editor.runes(pieces[#pieces]))
end
local function copied(place: any): any
    if place == nil then return nil end
    return point(place.line, place.col)
end
local function snapshot(state: any): any
    local lines: {string} = {}
    for index, line in ipairs(state.lines) do lines[index] = line end
    return {lines = lines, caret = copied(state.caret), anchor = copied(state.anchor), undone = false}
end
-- remember(state, typing) — the undo point before an edit; typing that
-- follows typing keeps the point it already has, so Undo takes a typed word
-- back whole.
local function remember(state: any, typing: boolean)
    if typing and state.typing and state.undo ~= nil then return end
    state.undo = snapshot(state)
end
local function touched(state: any, typing: boolean)
    state.dirty = true
    state.goal = nil
    state.reveal = true
    state.typing = typing
end
local function move_to(state: any, target: any, extend: boolean)
    if extend then
        if state.anchor == nil then state.anchor = copied(state.caret) end
    else
        state.anchor = nil
    end
    state.caret = point(target.line, target.col)
    if state.anchor ~= nil and same(state.anchor, state.caret) then state.anchor = nil end
    state.typing = false
    state.reveal = true
end
-- type_in(state, text) — typed text: over a selection it replaces it.
local function type_in(state: any, typed: string)
    local from, to = span(state)
    if from ~= nil then
        remember(state, false)
        remove(state, from, to)
    else
        remember(state, true)
    end
    insert_at(state, typed)
    touched(state, true)
end
-- Ctrl+→ goes to the start of the next word, Ctrl+← to the start of this or
-- the previous one; a word is a run of what is not a space or a tab, and
-- both cross a line end.
local function word_right(state: any, place: any): any
    local chars: {string} = editor.runes(state.lines[place.line])
    if place.col >= #chars then
        if place.line < #state.lines then return point(place.line + 1, 0) end
        return point(place.line, #chars)
    end
    local col = place.col
    while col < #chars and not blank(chars[col + 1]) do col = col + 1 end
    while col < #chars and blank(chars[col + 1]) do col = col + 1 end
    return point(place.line, col)
end
local function word_left(state: any, place: any): any
    if place.col == 0 then
        if place.line > 1 then return point(place.line - 1, length(state, place.line - 1)) end
        return point(place.line, 0)
    end
    local chars: {string} = editor.runes(state.lines[place.line])
    local col = place.col
    while col > 0 and blank(chars[col]) do col = col - 1 end
    while col > 0 and not blank(chars[col]) do col = col - 1 end
    return point(place.line, col)
end
-- A letter's case for Find without Match case: ASCII and Cyrillic, by rune,
-- so a folded text keeps its rune positions.
local function folded(char: string): string
    if #char == 1 then return char:lower() end
    local lead, next_byte = whole(char:byte(1) or 0), whole(char:byte(2) or 0)
    if lead == 0xD0 and next_byte >= 0x90 and next_byte <= 0x9F then return string.char(0xD0, next_byte + 0x20) end
    if lead == 0xD0 and next_byte >= 0xA0 and next_byte <= 0xAF then return string.char(0xD1, next_byte - 0x20) end
    if lead == 0xD0 and next_byte == 0x81 then return string.char(0xD1, 0x91) end
    return char
end

-- new(text) -> the state of a document holding `text`, the caret at its start.
function editor.new(value: any): any
    return {lines = split(value), caret = point(1, 0), anchor = nil, top = 0, left = 0, goal = nil,
        undo = nil, typing = false, dirty = false, reveal = false}
end
-- document(state) -> whether a state is a multi-line document (not a field's).
function editor.document(state: any): boolean
    return type(state) == "table" and type(state.lines) == "table"
end
-- text(state) -> the document, lines joined with "\n" (files are written with LF).
function editor.text(state: any): string
    return table.concat(state.lines, "\n")
end
-- set(state, text) — replaces everything: the caret at the start, no
-- selection, no undo, not dirty.
function editor.set(state: any, value: any)
    state.lines = split(value)
    state.caret, state.anchor = point(1, 0), nil
    state.top, state.left, state.goal = 0, 0, nil
    state.undo, state.typing, state.dirty, state.reveal = nil, false, false, true
end
-- selected(state) -> whether anything is selected, without building the text.
function editor.selected(state: any): boolean
    local from = span(state)
    return from ~= nil
end
-- selection(state) -> the selected text, or nil without a selection.
function editor.selection(state: any): any
    local from, to = span(state)
    if from == nil then return nil end
    if from.line == to.line then
        return slice(editor.runes(state.lines[from.line]), from.col + 1, to.col)
    end
    local first: {string} = editor.runes(state.lines[from.line])
    local parts: {string} = {slice(first, from.col + 1, #first)}
    for index = from.line + 1, to.line - 1 do parts[#parts + 1] = state.lines[index] end
    parts[#parts + 1] = slice(editor.runes(state.lines[to.line]), 1, to.col)
    return table.concat(parts, "\n")
end
-- replace_selection(state, text) — the selection becomes `text`; without a
-- selection `text` is inserted at the caret. One undo step.
function editor.replace_selection(state: any, value: any): boolean
    local from, to = span(state)
    remember(state, false)
    if from ~= nil then remove(state, from, to) end
    insert_at(state, tostring(value or ""))
    touched(state, false)
    return true
end
-- insert(state, text) — `text` at the caret, over the selection if there is one.
function editor.insert(state: any, value: any): boolean
    return editor.replace_selection(state, value)
end
-- delete_selection(state) -> whether there was a selection to delete.
function editor.delete_selection(state: any): boolean
    local from, to = span(state)
    if from == nil then return false end
    remember(state, false)
    remove(state, from, to)
    touched(state, false)
    return true
end
function editor.select_all(state: any)
    state.anchor = point(1, 0)
    state.caret = point(#state.lines, length(state, #state.lines))
    if same(state.anchor, state.caret) then state.anchor = nil end
    state.goal, state.typing, state.reveal = nil, false, true
end
-- undo(state) -> whether there was a step: the text before the last edit
-- comes back, and the one it replaced becomes the step, so the next Undo
-- redoes — the classic one-level toggle.
function editor.undo(state: any): boolean
    local saved: any = state.undo
    if saved == nil then return false end
    local current = snapshot(state)
    current.undone = not saved.undone
    state.lines, state.caret, state.anchor = saved.lines, saved.caret, saved.anchor
    state.undo = current
    state.goal, state.typing = nil, false
    state.dirty, state.reveal = true, true
    return true
end
-- mark(state) — the saved point: not dirty until the next edit.
function editor.mark(state: any)
    state.dirty = false
end
function editor.dirty(state: any): boolean
    return state.dirty == true
end
-- find(state, needle, {match_case, direction}) -> whether it was found.
-- Down searches from the end of the selection (the caret without one), up
-- from its start; a match is selected, the caret at its end, and brought
-- into view. Not found leaves the selection as it was. No wrapping around,
-- as in Notepad.
function editor.find(state: any, needle: any, options: any?): boolean
    local given: any = type(options) == "table" and options or {}
    local exact = given.match_case == true
    local wanted: {string} = editor.runes(needle)
    if #wanted == 0 then return false end
    if not exact then for index, char in ipairs(wanted) do wanted[index] = folded(char) end end
    local function matches(chars: {string}, at: integer): boolean
        for offset = 1, #wanted do
            local char = chars[at + offset]
            if char == nil then return false end
            if not exact then char = folded(char) end
            if char ~= wanted[offset] then return false end
        end
        return true
    end
    local from, to = span(state)
    local up = given.direction == "up"
    local start: any = up and (from or state.caret) or (to or state.caret)
    local count = #state.lines
    local first, last, step = start.line, count, 1
    if up then first, last, step = start.line, 1, -1 end
    for line = first, last, step do
        local chars: {string} = editor.runes(state.lines[line])
        local found = -1
        if up then
            local at = line == start.line and start.col - #wanted or #chars - #wanted
            while at >= 0 do
                if matches(chars, at) then found = at; break end
                at = at - 1
            end
        else
            local at = line == start.line and start.col or 0
            while at + #wanted <= #chars do
                if matches(chars, at) then found = at; break end
                at = at + 1
            end
        end
        if found >= 0 then
            state.anchor = point(line, found)
            state.caret = point(line, found + #wanted)
            state.goal, state.typing, state.reveal = nil, false, true
            return true
        end
    end
    return false
end

-- columns(chars, from, to, tab) -> the display width of runes from+1..to of a
-- row, counted from the row's first column.
function editor.columns(chars: any, from: any, to: any, tab: any): integer
    local step = whole(math.max(1, whole(tab or editor.TAB)))
    local column = 0
    for index = whole(from) + 1, whole(to) do column = column + advance(chars[index], column, step) end
    return column
end
-- layout(lines, columns, wrap, tab) -> the display rows, {line, start, stop}
-- each: runes start+1..stop of the line. Without `wrap` a line is one row;
-- with it a line breaks at `columns` display columns after its last space
-- that fits, and hard where a word is longer than a row — `ui.wrap_text`'s
-- rule. Tab stops count from each row's start. The model keeps the real
-- lines; ↑ and ↓ walk these rows.
function editor.layout(lines: any, columns: any, wrap: any, tab: any): any
    local width = whole(math.max(1, whole(columns)))
    local step = whole(math.max(1, whole(tab or editor.TAB)))
    local rows: any = {}
    for index, line in ipairs(lines) do
        local chars: {string} = editor.runes(line)
        if wrap ~= true or #chars == 0 then
            rows[#rows + 1] = {line = index, start = 0, stop = #chars}
        else
            local start = 0
            while start < #chars do
                local column, fit = 0, start
                while fit < #chars do
                    local wide = advance(chars[fit + 1], column, step)
                    if column + wide > width then break end
                    column, fit = column + wide, fit + 1
                end
                local stop = fit
                if fit < #chars then
                    local cut = fit
                    while cut > start and chars[cut] ~= " " do cut = cut - 1 end
                    if cut > start then stop = cut end
                    if stop == start then stop = start + 1 end
                end
                rows[#rows + 1] = {line = index, start = start, stop = stop}
                start = stop
            end
        end
    end
    return rows
end
-- A caret at a wrapped row's `stop` stands at the next row's start; only a
-- line's last row keeps a caret at its end.
local function last_of_line(rows: any, index: integer): boolean
    return index == #rows or rows[index + 1].line ~= rows[index].line
end
-- locate(state, rows, tab) -> the display row of the caret and its column in it.
function editor.locate(state: any, rows: any, tab: any): (integer, integer)
    local caret: any = state.caret
    for index, row in ipairs(rows) do
        if row.line == caret.line and caret.col >= row.start and (caret.col < row.stop or last_of_line(rows, index)) then
            return index, editor.columns(editor.runes(state.lines[row.line]), row.start, caret.col, tab)
        end
    end
    return 1, 0
end
-- at(state, rows, tab, index, x) -> the place at display column `x` of row
-- `index`: before the rune under `x`, after it past its middle (a tab is
-- wide), the row's end past its text.
function editor.at(state: any, rows: any, tab: any, index: any, x: any): any
    local row: any = rows[whole(index)]
    if row == nil then return copied(state.caret) end
    local chars: {string} = editor.runes(state.lines[row.line])
    local step = whole(math.max(1, whole(tab or editor.TAB)))
    local goal = whole(math.max(0, whole(x)))
    local column, col = 0, whole(row.start)
    while col < row.stop do
        local wide = advance(chars[col + 1], column, step)
        if column + wide > goal then
            if (goal - column) * 2 >= wide then col = col + 1 end
            break
        end
        column, col = column + wide, col + 1
    end
    if col >= row.stop and not last_of_line(rows, whole(index)) then col = whole(math.max(row.start, row.stop - 1)) end
    return point(row.line, col)
end
-- glyphs(state, row, tab) -> what a display row draws: {char, x, w, selected}
-- per rune, `x` its display column from the row's start, `w` its width.
function editor.glyphs(state: any, row: any, tab: any): any
    local chars: {string} = editor.runes(state.lines[row.line])
    local from, to = span(state)
    local step = whole(math.max(1, whole(tab or editor.TAB)))
    local out: any = {}
    local column = 0
    for col = whole(row.start), whole(row.stop) - 1 do
        local char = chars[col + 1]
        local wide = advance(char, column, step)
        local here = point(row.line, col)
        out[#out + 1] = {char = char, x = column, w = wide,
            selected = from ~= nil and not before(here, from) and before(here, to)}
        column = column + wide
    end
    return out
end
-- reveal(state, rows, tab, page, columns) — the caret into view: `top` by
-- display rows, `left` by display columns (0 when `columns` is nil: a
-- wrapped document never scrolls sideways).
function editor.reveal(state: any, rows: any, tab: any, page: any, columns: any?)
    local index, x = editor.locate(state, rows, tab)
    local shown = whole(math.max(1, whole(page)))
    local top = whole(state.top)
    if index - 1 < top then top = index - 1 elseif index > top + shown then top = index - shown end
    state.top = whole(math.max(0, math.min(top, #rows - shown)))
    if columns == nil then
        state.left = 0
    else
        local room = whole(math.max(1, whole(columns)))
        local left = whole(state.left)
        if x < left then left = x elseif x >= left + room then left = x - room + 1 end
        state.left = whole(math.max(0, left))
    end
end
-- press(state, place, extend) — the pointer puts the caret at `place`; with
-- `extend` (Shift, or a drag) the selection runs from the anchor to it.
function editor.press(state: any, place: any, extend: any)
    move_to(state, place, extend == true)
    state.goal = nil
end
-- word(state, place) — a double click: the run of letters (or of blanks)
-- under `place` becomes the selection.
function editor.word(state: any, place: any)
    local chars: {string} = editor.runes(state.lines[whole(place.line)] or "")
    if #chars == 0 then
        editor.press(state, place, false)
        return
    end
    local at = whole(math.min(whole(place.col) + 1, #chars))
    local kind = blank(chars[at])
    local from, to = at - 1, at
    while from > 0 and blank(chars[from]) == kind do from = from - 1 end
    while to < #chars and blank(chars[to + 1]) == kind do to = to + 1 end
    state.anchor, state.caret = point(place.line, from), point(place.line, to)
    state.goal, state.typing, state.reveal = nil, false, true
end
-- key(state, event, view) -> "change" | "caret" | nil
--
-- The keys of FR-007 §3: runes, Enter, Tab, Backspace, Delete, the arrows,
-- Home, End, Page Up/Down, Ctrl with Home/End (the document) and ←/→ (a
-- word), Shift with any movement extends from the anchor, Ctrl+A selects all,
-- and a paste inserts. "change" after an edit, "caret" after a move; nil for
-- what it does not take — Ctrl+Z/X/C/V, Esc and the rest go to the
-- application as keys, and a read-only document takes no edit.
-- `view` = {columns, wrap, tab, page, read_only}: the display rows ↑, ↓,
-- Page Up/Down, Home and End walk.
function editor.key(state: any, event: any, view: any): any
    local read_only = view.read_only == true
    local tab = whole(math.max(1, whole(view.tab or editor.TAB)))
    if event.type == "paste" then
        if read_only then return nil end
        editor.replace_selection(state, tostring(event.text or ""))
        return "change"
    end
    if event.type ~= "key" or event.action == "release" then return nil end
    local key = tostring(event.key_type or event.key or "")
    local ctrl, shift = event.ctrl == true, event.shift == true
    if key == "runes" then
        local typed = tostring(event.key or "")
        if ctrl and not event.alt and typed:lower() == "a" then
            editor.select_all(state)
            return "caret"
        end
        if ctrl or event.alt or read_only or typed == "" then return nil end
        type_in(state, typed)
        return "change"
    end
    if key == "enter" or key == "tab" then
        if read_only or ctrl or event.alt then return nil end
        if key == "tab" then type_in(state, "\t") else editor.replace_selection(state, "\n") end
        return "change"
    end
    if key == "backspace" or key == "delete" then
        if read_only then return nil end
        local from, to = span(state)
        if from == nil then
            local caret: any = state.caret
            if key == "backspace" and caret.col > 0 then from, to = point(caret.line, caret.col - 1), copied(caret)
            elseif key == "backspace" and caret.line > 1 then from, to = point(caret.line - 1, length(state, caret.line - 1)), point(caret.line, 0)
            elseif key == "delete" and caret.col < length(state, caret.line) then from, to = copied(caret), point(caret.line, caret.col + 1)
            elseif key == "delete" and caret.line < #state.lines then from, to = copied(caret), point(caret.line + 1, 0) end
        end
        if from == nil then return nil end
        remember(state, false)
        remove(state, from, to)
        touched(state, false)
        return "change"
    end
    local caret: any = state.caret
    local target: any = nil
    local goal: any = nil
    if key == "left" then
        if ctrl then target = word_left(state, caret)
        elseif caret.col > 0 then target = point(caret.line, caret.col - 1)
        elseif caret.line > 1 then target = point(caret.line - 1, length(state, caret.line - 1))
        else target = copied(caret) end
    elseif key == "right" then
        if ctrl then target = word_right(state, caret)
        elseif caret.col < length(state, caret.line) then target = point(caret.line, caret.col + 1)
        elseif caret.line < #state.lines then target = point(caret.line + 1, 0)
        else target = copied(caret) end
    elseif key == "home" and ctrl then
        target = point(1, 0)
    elseif key == "end" and ctrl then
        target = point(#state.lines, length(state, #state.lines))
    elseif key == "home" or key == "end" or key == "up" or key == "down" or key == "pgup" or key == "pgdown" then
        local rows = editor.layout(state.lines, view.columns, view.wrap, tab)
        local index, x = editor.locate(state, rows, tab)
        local row: any = rows[index]
        if key == "home" then
            target = point(row.line, row.start)
        elseif key == "end" then
            target = point(row.line, last_of_line(rows, index) and row.stop or math.max(row.start, row.stop - 1))
        else
            goal = state.goal or x
            local step = (key == "up" or key == "down") and 1 or whole(math.max(1, whole(view.page or 1)))
            local wanted = index + ((key == "up" or key == "pgup") and -step or step)
            target = editor.at(state, rows, tab, math.max(1, math.min(#rows, wanted)), goal)
        end
    else
        return nil
    end
    move_to(state, target, shift)
    state.goal = goal
    return "caret"
end
return editor
