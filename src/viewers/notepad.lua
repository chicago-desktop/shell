-- Notepad — a viewer for text files from a registry drive.
--
-- A cell window, like the calculator: it opens the surface of its own port
-- by itself and draws frames; the frame, title and buttons are drawn by the
-- theme. The file comes as the open argument — a string the explorer
-- assembled through `files` — and is read by the `fs` module under the
-- window's own permissions: access is to the drive entry, not to a directory
-- on the machine.
--
-- Read-only. A Notepad that can write is an editor, and it has other duties:
-- saving, asking before closing, undo. There are none of those here, and the
-- window does not hide it — the status bar says so outright.
--
-- Lines do not wrap, as in Windows 95 by default: a long line runs off to
-- the right, and it is scrolled with the arrows. Wrapping would turn one line
-- of the file into three lines on screen, and the line number in the status
-- would lie.

local channel = require("channel")
local input = require("input")
local scroll = require("scroll")
local tty = require("tty")

local files = require("files")
local widgets = require("widgets")

local TAB = "    "
local LINE_CAP = 4000

local styles = widgets.styles

-- Split a string into UTF-8 characters. The runtime's Lua has no `utf8`
-- library — a window using `utf8.codes` died on the first frame, and from
-- the outside it looked like "clicked — nothing opened".
local text_lib = require("text")
local UTF8_CHAR = text_lib.RUNE

local geometry = require("geometry")
local whole = geometry.whole

-- File → lines. Tabs are expanded into spaces: the terminal draws them by
-- itself and in its own way, and a column counted here would not match the
-- screen.
local function split_lines(text: string): {string}
    local lines: {string} = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", ""):gsub("\t", TAB)
        if #line > LINE_CAP then line = line:sub(1, LINE_CAP) end
        lines[#lines + 1] = line
    end
    if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
        lines[#lines] = nil
    end
    return lines
end

-- Cut `skip` cells off the left, return no more than `room` cells. By
-- characters, not by bytes: Cyrillic is two bytes per cell, and a cut by
-- bytes would split a letter in half.
local function slice(text: any, skip_cells: any, room_cells: any): string
    local line, skip, room = tostring(text or ""), whole(skip_cells), whole(room_cells)
    if room < 1 then return "" end
    local out, used, passed = {}, 0, 0
    for char in line:gmatch(UTF8_CHAR) do
        local w = widgets.cells(char)
        if passed < skip then
            passed = passed + w
        else
            if used + w > room then break end
            out[#out + 1] = char
            used = used + w
        end
    end
    return table.concat(out)
end

local function draw(out, canvas, width: any, height: any, doc: any)
    local w, h = whole(width), whole(height)
    canvas:clear(styles.field:render(" "))

    local text_rows = h - 1
    local blank = styles.field:render(string.rep(" ", w))
    for row = 1, text_rows do canvas:put(1, row, blank, w) end

    if doc.failure then
        if w > 2 then canvas:put(2, 1, widgets.fit(styles.field, tostring(doc.failure), w - 2), w - 2) end
    else
        for row = 1, text_rows do
            local line = doc.lines[doc.top + row]
            if not line then break end
            local shown = slice(line, doc.left, w - 1)
            if shown ~= "" then
                canvas:put(1, row, styles.field:render(shown), w - 1)
            end
        end
    end

    local position = doc.failure and "" or string.format("Ln %d of %d", math.min(doc.top + 1, math.max(1, #doc.lines)), #doc.lines)
    local column = doc.left > 0 and string.format("Col +%d", doc.left) or ""
    widgets.statusbar(canvas, 1, h, w, {
        {text = doc.name .. " · " .. files.human_size(doc.size) .. " · read-only"},
        {text = position, width = 16},
        {text = column, width = 10},
    })

    assert(out:present(canvas:rows(), {cursor = {x = 1, y = 1, visible = false}}))
end

local function main(argument)
    local events = assert(tty.events())
    assert(tty.start())

    local out = assert(tty.surface({hide_cursor = true, synchronized_output = true}))

    local width, height = tty.screen_size()
    width, height = whole(width), whole(height)
    width, height = whole(math.max(1, width)), whole(math.max(1, height))

    local doc: any = {lines = {}, top = 0, left = 0, name = "", size = 0, failure = nil}

    local file, why = files.parse(argument)
    if not file then
        doc.failure = why
    else
        doc.name = file.name
        local text, read_err = files.read(file.drive, file.path, files.MAX_TEXT)
        if not text then
            doc.failure = read_err
        else
            doc.size = #text
            doc.lines = split_lines(text :: string)
        end
    end

    local longest = 0
    for _, line in ipairs(doc.lines) do longest = math.max(longest, widgets.cells(line)) end
    local canvas = tty.canvas(width, height)
    draw(out, canvas, width, height, doc)

    local function page(): integer return whole(math.max(1, height - 1)) end
    local function scroll_to(wanted: any)
        doc.top = scroll.clamp(wanted, #doc.lines, page())
    end

    while true do
        local selected = channel.select({events:case_receive()})
        if not selected.ok then break end
        local event = input.normalize(selected.value)

        if event.type == "close" then
            break
        elseif event.type == "resize" then
            local w, h = whole(event.width), whole(event.height)
            width, height = whole(math.max(1, w)), whole(math.max(1, h))
            doc.left = scroll.clamp(doc.left, longest, width - 1)
            canvas = tty.canvas(width, height)
            scroll_to(doc.top)
            draw(out, canvas, width, height, doc)
        elseif event.type == "key" and event.action ~= "release" then
            local key = tostring(event.key or "")
            if key == "down" then scroll_to(doc.top + 1)
            elseif key == "up" then scroll_to(doc.top - 1)
            elseif key == "pgdown" or key == " " then scroll_to(doc.top + page())
            elseif key == "pgup" then scroll_to(doc.top - page())
            elseif key == "home" then scroll_to(0); doc.left = 0
            elseif key == "end" then scroll_to(#doc.lines)
            elseif key == "right" then doc.left = scroll.clamp(doc.left + 8, longest, width - 1)
            elseif key == "left" then doc.left = math.max(0, doc.left - 8)
            end
            draw(out, canvas, width, height, doc)
        elseif event.type == "mouse" and event.action == "wheel" then
            if event.button == "wheel_down" then scroll_to(doc.top + 3)
            elseif event.button == "wheel_up" then scroll_to(doc.top - 3) end
            draw(out, canvas, width, height, doc)
        end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
