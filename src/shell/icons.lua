-- An icon with a caption, one for the whole shell.
--
-- A separate library, not a piece of the theme, for one reason: the icon is
-- drawn by TWO parties. The desktop draws it through the compositor, and the
-- "My Computer" window draws it itself, from inside its own process, into its
-- own tty. Repeated in the second, it would diverge from the first at the
-- first edit, and diverge in LOOK, not as a failure: inside Windows 95 there
-- would be a different Windows 95, and it would be noticed a week later.
--
-- Hence the shape of the functions: they take the drawing TARGET, not
-- someone's canvas. Any `tty.canvas` serves as a target, both the one the
-- compositor holds and the one a window sets up for its own viewport; it is
-- one and the same type, so the cut runs here, not along the process
-- boundary.
--
-- There are two surfaces, and they must not be confused: on the desktop the
-- caption is white on teal, in a window it is black on the white list field.

local tty = require("tty")

local glyphs = require("glyphs")
local palette = require("palette")

local color = palette.active

local icons = {}

-- The icon cell. `w` and `h` are the grid STEP, `drawn` is how many lines the
-- picture takes. The numbers differ on purpose: the step lays icons out, the
-- drawn part is what hits are computed from. Take one instead of the other
-- and the icons will stand edge to edge, and the caption of one will run
-- into the picture of the next.
local CELL_W = 12
local CELL_H = 4
local CELL_DRAWN = 3
local CELL_CAPTION = 2
local CELL_LEFT = 2

function icons.grid()
    return {w = CELL_W, h = CELL_H, drawn = CELL_DRAWN, caption = CELL_CAPTION, left = CELL_LEFT}
end

local function desktop_surface(): any
    return {
        back   = tty.style():background(color.desktop),
        icon   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
        select = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    }
end

local surfaces = {
    desktop = {
        back   = tty.style():background(color.desktop),
        icon   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
        select = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    },
    panel = {
        back   = tty.style():background(color.field),
        icon   = tty.style():foreground(color.field_text):background(color.field),
        text   = tty.style():foreground(color.field_text):background(color.field),
        -- On the white field yellow is not visible at all, so broken is maroon
        -- here. The color differs, the sign is the same: the ▨ icon plus a
        -- caption that differs from the others.
        broken = tty.style():bold():foreground(color.alert):background(color.field),
        select = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    },
}

local geometry = require("geometry")
local whole = geometry.whole

local function cells(text): integer
    return whole(tty.text.width(text))
end

local function clip(text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    return tty.text.truncate(tostring(text or ""), width)
end

-- Word wrap. The second value is a flag that the text did NOT fit: a word
-- longer than the line had to be cut, or there were not enough lines.
-- Without it "fitted" and "half fitted" are indistinguishable on output, and
-- the difference is exactly whether a person sees the whole name or not.
function icons.wrap(text, room: any, limit: any)
    local width = whole(room)
    local max = whole(limit)
    local out = {}
    if width <= 0 or max <= 0 then return out, true end

    local overflow = false
    local line = ""

    local function flush(): boolean
        if line == "" then return true end
        if #out >= max then
            overflow = true
            return false
        end
        out[#out + 1] = line
        line = ""
        return true
    end

    for word in tostring(text):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if cells(candidate) <= width then
            line = candidate
        else
            if not flush() then return out, true end
            if cells(word) > width then
                -- A word that is itself wider than the line has nowhere to wrap.
                overflow = true
                line = clip(word, width)
            else
                line = word
            end
        end
    end
    flush()
    return out, overflow
end

-- caption_lines(title, room): the caption the way the icon will draw it.
--
-- Exposed on purpose: repeating this rule on your side means setting up a
-- copy that will drift silently, because the test on the copy stays green
-- while the screen shows something else. The second value is "the name did
-- not fit", and that is what furniture is checked by.
function icons.caption_lines(title, room: any)
    local width = whole(room)
    if width <= 0 then width = CELL_W end
    return icons.wrap(title or "?", width, CELL_CAPTION)
end

local function centered(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local body = clip(text, width)
    local left = (width - cells(body)) // 2
    return style:render(string.rep(" ", left) .. body
        .. string.rep(" ", width - left - cells(body)))
end

-- Icon: the picture as a line and a caption of up to two lines under it,
-- centered.
--
-- Returns the occupied rectangle, {from, to, top, bottom}, or nil if there
-- was not enough room. The hit is built from it by the CALLER: the desktop's
-- hit carries entry, w, h and args, the window's its own set, and imposing
-- one's shape on the other makes things awkward for both.
--
-- `state`: `selected` means selected, `surface` is "desktop" or "panel",
-- `room` is the column width if it is narrower than the cell (at the right
-- edge).
-- box(x, y, room) -> the icon rectangle in CELLS
--
-- Pulled out of the drawing because it now has two readers: `icons.cell`
-- draws, and `render.layout` computes the window layout, and computes it
-- BEFORE anything is drawn, because the pixel backend does not draw here.
--
-- If they computed it separately, the hit would drift from the drawing by a
-- cell, and that is exactly the defect because of which the rule "drawing
-- and hit-testing from one table" appeared here at all. Now there is one
-- table and it is here.
--
-- `room` is the column width, `CELL_DRAWN` is how many lines the picture
-- takes. The height is NOT equal to the grid step: the step lays icons out,
-- the drawn part is what hits are computed from.
function icons.box(x: any, y: any, room: any): any
    local col, row = whole(x), whole(y)
    local span = whole(room)
    if span <= 0 then span = CELL_W end
    if span < 3 then return nil end
    return {from = col, to = col + span - 1, top = row, bottom = row + CELL_DRAWN - 1}
end

function icons.cell(target, x: any, y: any, item, state)
    local opts: any = type(state) == "table" and state or {}
    local surface: any = surfaces[opts.surface] or surfaces.desktop

    local col, row = whole(x), whole(y)
    local span = whole(opts.room)
    if span <= 0 then span = CELL_W end
    local box = icons.box(col, row, span)
    if not box then return nil end

    local record: any = type(item) == "table" and item or {}

    -- A broken shortcut is visible both by its icon and by the caption color.
    -- The icon alone is not enough on a small font, the color alone not on a
    -- monochrome terminal; and it has no right to disappear: a vanished icon
    -- reads as "I deleted it by accident", a broken one as "the program is
    -- gone".
    local broken = record.broken and true or false
    local glyph
    if broken then glyph = glyphs.icons.broken
    elseif record.kind == "folder" then glyph = glyphs.icons.folder
    elseif type(record.icon) == "string" and record.icon ~= "" then glyph = record.icon
    else glyph = glyphs.icons.unknown end

    target:put(col, row, centered(surface.icon, glyph, span), span)

    -- Selection is an inversion of the TEXT, not of the whole column: in the
    -- Windows 95 explorer the blue rectangle hugs the caption, and it shows
    -- where the caption ends.
    local caption = broken and surface.broken or surface.text
    if opts.selected then caption = surface.select end

    local lines = icons.caption_lines(record.title, span)
    for line = 1, CELL_CAPTION do
        local text = lines[line]
        if text then
            local pad = (span - cells(text)) // 2
            target:put(col, row + line,
                surface.back:render(string.rep(" ", pad))
                .. caption:render(text)
                .. surface.back:render(string.rep(" ", span - pad - cells(text))),
                span)
        end
    end

    return box
end

-- The desktop was repainted: the icon cell styles are re-read from the
-- palette.
function icons.use_desktop()
    surfaces.desktop = desktop_surface()
end

return icons
