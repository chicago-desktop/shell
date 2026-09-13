-- Pixel primitives of the shell: bevel, panel, field, button, marks, icons.
--
-- The pixel twin of `widgets`, and written by the same rule: NOTHING that
-- knows about the screen as a whole. Only arithmetic and calls into a
-- raster, so it is checked by a stub without the runtime — `tools/pixelprobe`.
--
-- ─── Two rules that make this file look exactly the way it does ─────────
--
-- FIRST. Decoration is free, interaction is quantized (FR-005 §4a). An edge
-- here is ONE pixel — that is what the whole move was for — but the mouse
-- reports coordinates in CELLS, SGR 1006 knows no others. So the place of
-- everything that gets clicked is named in cells and turned into pixels by
-- `pixels.box`, and the hit is computed by the caller's LAYOUT, in the same
-- cells and before painting: the taskbar — `chrome.taskbar_layout`, SDK
-- windows — `ui.plan`, the explorer — `render.layout`. Hand out rectangles
-- in pixels and divide them by the cell size, and at the border of two
-- neighbouring buttons rounding would decide who got the click, silently.
--
-- Hence the shape: the functions here take PIXELS and return no hits. The
-- former `button_at` and `title`, which returned a hit from the drawing, were
-- called only by the snapshots: everything clickable in the shell was already
-- placed by a layout.
--
-- SECOND. Rasters outlive the frame (FR-005 §4). No function here creates
-- rasters: a raster comes from outside, from whoever keeps it between
-- frames. If a primitive created its own raster, the theme would resend
-- everything every frame and get the same forty-seven milliseconds, only in
-- pieces.
--
-- Colors are exact values from the shared palette, the same one the cell
-- theme uses. A private copy of the values would diverge from the first,
-- and diverge in look.

local palette = require("palette")
local images = require("images")

local color = palette.exact

local pixels = {}

-- Edge thickness. One, not "however many it comes out": in Windows 95 the
-- relief is exactly one pixel of light at the top-left and one of dark at
-- the bottom-right, and the second edge of large frames is a different
-- color, not a different thickness.
pixels.EDGE = 1

local geometry = require("geometry")
local text_lib = require("text")
local whole = geometry.whole

-- box(col, row, cols, rows, cell) -> a rectangle in PIXELS
--
-- A place named in cells turns into pixels.
-- Everything that gets clicked is placed with this, and here is why — not
-- for convenience.
--
-- The rule "interaction is quantized" does not hold by discipline. Three
-- title buttons 16 px wide with an 18 px step look flawless and give HIT
-- ZONES THAT OVERLAP: with a 10 px cell the first occupies columns 24–26,
-- the second 26–28, the third 28–30, and a click on column 26 belongs to two
-- buttons at once. The one found first wins — silently, and in a screenshot
-- it is not visible at all.
--
-- So the place and size of an interactive detail are named IN CELLS, and
-- only the drawing INSIDE it stays free: a button two cells wide can carry a
-- 16×14 picture set in the center.
function pixels.box(col: any, row: any, cols: any, rows: any, cell: any): any
    local unit: any = type(cell) == "table" and cell or {}
    local cw = whole(unit.w)
    local ch = whole(unit.h)
    if cw < 1 then cw = 1 end
    if ch < 1 then ch = 1 end

    local span_x = math.max(1, whole(cols))
    local span_y = math.max(1, whole(rows))

    return {
        x = (whole(col) - 1) * cw + 1,
        y = (whole(row) - 1) * ch + 1,
        w = span_x * cw,
        h = span_y * ch,
    }
end

-- A one-pixel relief edge. Raised and sunken are one and the same function
-- with the colors swapped, exactly like `DrawEdge` in GDI.
function pixels.bevel(raster, x: any, y: any, w: any, h: any, raised)
    local left, top = whole(x), whole(y)
    local width, height = whole(w), whole(h)
    if width < 2 or height < 2 then return end

    local near = raised and color.light or color.shadow
    local far = raised and color.shadow or color.light

    raster:rect(left, top, width, pixels.EDGE, near)
    raster:rect(left, top, pixels.EDGE, height, near)
    raster:rect(left, top + height - pixels.EDGE, width, pixels.EDGE, far)
    raster:rect(left + width - pixels.EDGE, top, pixels.EDGE, height, far)
end

-- Panel: face and a raised edge. Everything gray is made of it — the window
-- frame, the taskbar, the button, the menu panel.
function pixels.panel(raster, x: any, y: any, w: any, h: any)
    raster:rect(whole(x), whole(y), whole(w), whole(h), color.face)
    pixels.bevel(raster, x, y, w, h, true)
end

-- Win95 controls have two distinct edges. Keep the one-pixel bevel for
-- separators and window trim; a pushbutton/edit field is a different detail.
local function edge_pair(r: any, x: any, y: any, w: any, h: any, near: any, far: any)
    x, y, w, h = whole(x), whole(y), whole(w), whole(h)
    if w < 2 or h < 2 then return end
    r:rect(x, y, w - 1, 1, near)
    r:rect(x, y, 1, h - 1, near)
    r:rect(x, y + h - 1, w, 1, far)
    r:rect(x + w - 1, y, 1, h, far)
end
function pixels.edge(r: any, x: any, y: any, w: any, h: any, raised: any)
    if raised then
        edge_pair(r, x, y, w, h, color.light, color.frame)
        edge_pair(r, whole(x) + 1, whole(y) + 1, whole(w) - 2, whole(h) - 2, color.face, color.shadow)
    else
        edge_pair(r, x, y, w, h, color.shadow, color.light)
        edge_pair(r, whole(x) + 1, whole(y) + 1, whole(w) - 2, whole(h) - 2, color.frame, color.face)
    end
end
function pixels.focus_rect(r: any, x: any, y: any, w: any, h: any)
    x, y, w, h = whole(x), whole(y), whole(w), whole(h)
    if w < 2 or h < 2 then return end
    for at = 0, w - 1, 2 do
        r:rect(x + at, y, 1, 1, color.frame)
        r:rect(x + at, y + h - 1, 1, 1, color.frame)
    end
    for at = 2, h - 2, 2 do
        r:rect(x, y + at, 1, 1, color.frame)
        r:rect(x + w - 1, y + at, 1, 1, color.frame)
    end
end

-- List field: white and sunken. Icons inside a window lie on it, not on the
-- panel face — in the Windows 95 Explorer these are different surfaces.
function pixels.field(raster, x: any, y: any, w: any, h: any)
    raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
    pixels.edge(raster, x, y, w, h, false)
end

-- A caption centered in a rectangle.
--
-- The width comes from the font ITSELF (`font:measure`), not the number of
-- characters times the glyph width: a proportional font is half the point
-- of pixels, and a computed width misses by a different amount in every
-- language.
function pixels.label(raster, x: any, y: any, w: any, h: any, text, font, tint)
    if not font then return 0 end
    local caption = tostring(text or "")
    if caption == "" then return 0 end

    local width = font:measure(caption)
    local height = font:height()
    local left = whole(x) + (whole(w) - whole(width)) // 2
    local top = whole(y) + (whole(h) - whole(height)) // 2
    return raster:text(left, top, caption, {font = font, color = tint or color.face_text})
end

-- Word wrap BY MEASURED width, not by character count.
--
-- This is half of what the move to pixels was for: the font is
-- proportional, and "how many characters will fit" is a question that has no
-- answer. A caption computed by characters misses by a different amount in
-- every language.
--
-- A long name is wrapped by characters; the last line marks with an ellipsis
-- the part that did not have room.
function pixels.wrap(font, text, room: any, limit: any): any
    local out = {}
    if not font then return out end
    local width = whole(room)
    local max = whole(limit)
    if width <= 0 or max <= 0 then return out end

    local function fits(piece)
        local measured = font:measure(piece)
        return whole(measured) <= width
    end

    local function clip(word)
        local kept = ""
        for _, rune in ipairs(text_lib.runes(word)) do
            if not fits(kept .. rune) then break end
            kept = kept .. rune
        end
        return kept
    end

    local line = ""
    local words = {}
    for word in tostring(text or ""):gmatch("%S+") do words[#words + 1] = word end
    for index, word in ipairs(words) do
        local candidate = line == "" and word or (line .. " " .. word)
        if fits(candidate) then
            line = candidate
        else
            if line ~= "" then
                if #out == max - 1 then
                    out[#out + 1] = pixels.ellipsize(font, candidate, width)
                    return out
                end
                out[#out + 1] = line
                line = ""
            end
            local rest = word
            while not fits(rest) do
                if #out == max - 1 then
                    out[#out + 1] = pixels.ellipsize(font, rest, width)
                    return out
                end
                local part = clip(rest)
                if part == "" then return out end
                out[#out + 1] = part
                rest = rest:sub(#part + 1)
            end
            line = rest
        end
    end
    if line ~= "" and #out < max then out[#out + 1] = line end
    return out
end

-- A button by pixels. A clickable one is placed by cells — `pixels.box` gives
-- the rectangle, the drawing may be smaller than it (a 16x14 title button
-- inside two cells), and the hit comes from the layout: the WHOLE cell, not
-- only the drawing, or the margin around the button is dead while it looks
-- like part of it.
-- caption(font, text, width) -> what a button `width` pixels wide can show.
--
-- The two bevels take 2 px per side, and a caption that fits between them is
-- drawn whole and centred, with no further padding. Only a longer caption is
-- ellipsized, and never down to the ellipsis alone: "…" names no button,
-- so then the caption is cut to the runes that fit.
--
-- Measured with the shell's bold Liberation Sans 13: "MC" is 20 px, "sqrt"
-- 24 px. At an 8 px cell a four-cell calculator key is 28 px, so the old
-- 10 px reserve left 18 px and showed "..." on MC, MR, MS, M+ and sqrt, and
-- even 1 px of air per side would still cut sqrt. The bevels alone leave 24.
pixels.CAPTION_PAD = 4
function pixels.caption(font, text, width: any): string
    local caption = tostring(text or "")
    if not font or caption == "" then return "" end
    local room = whole(width) - pixels.CAPTION_PAD
    if room <= 0 then return "" end
    if whole(font:measure(caption)) <= room then return caption end
    local short = pixels.ellipsize(font, caption, room)
    if short ~= "" and short ~= "…" then return short end
    local kept = ""
    for _, rune in ipairs(text_lib.runes(caption)) do
        if whole(font:measure(kept .. rune)) > room then break end
        kept = kept .. rune
    end
    return kept
end

function pixels.button(raster, x: any, y: any, w: any, h: any, spec: any, cell: any)
    local options: any = type(spec) == "table" and spec or {}
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    local pressed = options.pressed and not options.disabled
    raster:rect(left, top, width, height, color.face)
    if options.default and not options.disabled then
        edge_pair(raster, left, top, width, height, color.frame, color.frame)
        left, top, width, height = left + 1, top + 1, width - 2, height - 2
    end
    if pressed then
        edge_pair(raster, left, top, width, height, color.frame, color.frame)
        edge_pair(raster, left + 1, top + 1, width - 2, height - 2, color.shadow, color.face)
    else
        pixels.edge(raster, left, top, width, height, true)
    end
    local shift = pressed and 1 or 0
    local label = options.font and pixels.caption(options.font, options.label, width) or ""
    if options.disabled then
        -- One pass keeps small labels legible; a white offset looks doubled.
        pixels.label(raster, x, y, w, h, label, options.font, color.shadow)
    else
        local tint = options.color or color.face_text
        pixels.label(raster, whole(x) + shift, whole(y) + shift, w, h, label, options.font, tint)
        -- The accelerator is an underlined letter, as with `widgets.accel` in
        -- cells. It is computed by the same arithmetic with which
        -- `pixels.label` places the caption: a second calculation of the text
        -- position would drift apart from the first.
        local at = whole(options.accel)
        if at > 0 and options.font and label ~= "" then
            local runes = text_lib.runes(label)
            if at <= #runes then
                local font: any = options.font
                local before = whole(font:measure(table.concat(runes, "", 1, at - 1)))
                local glyph = math.max(1, whole(font:measure(runes[at])))
                local text_left = whole(x) + shift + (whole(w) - whole(font:measure(label))) // 2
                local text_top = whole(y) + shift + (whole(h) - whole(font:height())) // 2
                raster:rect(text_left + before, text_top + whole(font:height()) - 2, glyph, 1, tint)
            end
        end
        if options.focused then pixels.focus_rect(raster, left + 4, top + 4, width - 8, height - 8) end
    end
end

-- Standard 13px checkbox, independent of font glyph coverage.
function pixels.checkbox(r: any, x: any, y: any, checked: any, disabled: any)
    x, y = whole(x), whole(y)
    r:rect(x, y, 13, 13, disabled and color.face or color.field)
    pixels.edge(r, x, y, 13, 13, false)
    if checked then
        local tint = disabled and color.shadow or color.face_text
        for step = 0, 2 do r:rect(x + 3 + step, y + 5 + step, 1, 3, tint) end
        for step = 0, 4 do r:rect(x + 5 + step, y + 7 - step, 1, 3, tint) end
    end
end

-- Menu marks, as Windows 95 draws them in the column before an item's text:
-- a 7×7 checkmark (a checked item) and a 6×6 round bullet (the chosen one of
-- a group). Rows of the checkmark, top to bottom, `#` inked.
local CHECK_ROWS = {"......#", ".....##", "#...###", "##.###.", "#####..", ".###...", "..#...."}
function pixels.mark_check(raster, x: any, y: any, tint)
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    for row, line in ipairs(CHECK_ROWS) do
        for column = 1, #line do
            if line:sub(column, column) == "#" then raster:set(left + column - 1, top + row - 1, ink) end
        end
    end
end
function pixels.mark_bullet(raster, x: any, y: any, tint)
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    raster:rect(left + 1, top, 4, 1, ink)
    raster:rect(left, top + 1, 6, 4, ink)
    raster:rect(left + 1, top + 5, 4, 1, ink)
end

-- ─── Title button marks ──────────────────────────────────────────────────
--
-- With primitives, not with the font: in Windows 95 these were small
-- rasters, and drawn with a font they come out a different weight and do
-- not sit on the grid. They are not taken from a file (`gfx.image`, the
-- `images` library): a six-pixel mark is simpler to draw with `rect` than to
-- keep as a separate picture.

-- Minimize: a short bold line at the bottom edge.
function pixels.mark_minimize(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left + 2, top + side - 4, side - 5, 2, tint or color.face_text)
end

-- Maximize: a frame with a thickened top edge — that is a window title bar
-- drawn in six pixels.
function pixels.mark_maximize(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    raster:rect(left + 1, top + 1, side - 2, side - 2, ink)
    raster:rect(left + 2, top + 4, side - 4, side - 6, color.face)
end

-- Close: two diagonals. A diagonal cannot be drawn with rectangles, so it is
-- laid down pixel by pixel — exactly the case `set` exists for.
-- Two pixels thick: at one, the cross reads as dirt on the screen.
function pixels.mark_close(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local span = side - 4
    for step = 0, span - 1 do
        raster:set(left + 2 + step, top + 2 + step, ink)
        raster:set(left + 3 + step, top + 2 + step, ink)
        raster:set(left + 2 + span - 1 - step, top + 2 + step, ink)
        raster:set(left + 3 + span - 1 - step, top + 2 + step, ink)
    end
end

-- Submenu arrow: a right-pointing triangle. Built from strips of different
-- length — there is no diagonal, and a triangle is made of just that.
function pixels.mark_submenu(raster, x: any, y: any, size: any, tint)
    local side = math.max(4, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local half = side // 2
    for step = 0, half do
        local height = (half - step) * 2 + 1
        raster:rect(left + step, top + half - (half - step), 1, height, ink)
    end
end

-- Menu item icon: a program is a small window with a title bar, a folder is
-- the same folder as on the desktop. With primitives, not a symbol: the font
-- has no geometric symbols, and in their place emptiness comes out.
function pixels.mark_program(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left, top, side, side, color.field)
    pixels.bevel(raster, left, top, side, side, true)
    raster:rect(left + 1, top + 1, side - 2, 3, tint or color.title_active_bg)
end

function pixels.mark_folder(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left, top + 2, side, side - 3, "#c8a848")
    raster:rect(left, top, side // 2, 2, "#c8a848")
    pixels.bevel(raster, left, top + 2, side, side - 3, true)
end

-- Title button marks — like the Windows 95 rasters in a 16×14 button: the
-- "minimize" bar 6×2 at the bottom left, "maximize" — a 9×9 frame with a
-- double top edge, "close" — an 8×7 cross with a two-pixel stroke. Computed
-- from the size of the BUTTON, not from the center of a square: a 12×10
-- button on a small cell gets the same marks four pixels smaller, a button
-- two pixels narrower — the same mark one pixel to the left.
local CAPTION_GLYPHS = {
    minimize = function(raster, x: any, y: any, w: any, h: any, ink)
        local bar = math.max(2, whole(w) // 2 - 2)
        raster:rect(whole(x) + 3 + (bar - 2) // 4, whole(y) + whole(h) - 5, bar, 2, ink)
    end,
    maximize = function(raster, x: any, y: any, w: any, h: any, ink)
        local bw, bh = whole(w) - 7, whole(h) - 5
        local lid = bh >= 7 and 2 or 1
        raster:rect(whole(x) + 3, whole(y) + 2, bw, lid, ink)
        raster:rect(whole(x) + 3, whole(y) + 2 + lid, 1, bh - lid, ink)
        raster:rect(whole(x) + 3 + bw - 1, whole(y) + 2 + lid, 1, bh - lid, ink)
        raster:rect(whole(x) + 3, whole(y) + 2 + bh - 1, bw, 1, ink)
    end,
    close = function(raster, x: any, y: any, w: any, h: any, ink)
        local size = math.max(4, whole(w) - 8)
        local rows = size - 1
        local left, top = whole(x) + 4, whole(y) + (whole(h) - rows) // 2
        for line = 0, rows - 1 do
            for _, column in ipairs({line, line + 1, size - 1 - line, size - line}) do
                if column >= 0 and column < size then raster:set(left + column, top + line, ink) end
            end
        end
    end,
}
function pixels.caption_mark(raster, id, x: any, y: any, w: any, h: any, tint)
    local glyph = CAPTION_GLYPHS[tostring(id)]
    if type(glyph) ~= "function" then return end
    local width, height = whole(w), whole(h)
    -- The mark is computed from the full width (height + 2); a narrower
    -- button — shift left.
    local full = height + 2
    glyph(raster, whole(x) + (width - full) // 2, whole(y), full, height, tint or color.face_text)
end

-- Etched group frame (EDGE_ETCHED): shadow and right under it light —
-- exactly one pixel each, as with Windows 95 dialog frames.
function pixels.etched(r: any, x: any, y: any, w: any, h: any)
    edge_pair(r, x, y, w, h, color.shadow, color.light)
    edge_pair(r, whole(x) + 1, whole(y) + 1, whole(w) - 2, whole(h) - 2, color.light, color.shadow)
end

pixels.MARKS = {
    minimize = pixels.mark_minimize,
    maximize = pixels.mark_maximize,
    close = pixels.mark_close,
}

-- A row of buttons of the SAME width — by the widest caption.
--
-- In Windows 95 dialog buttons were one width, and "OK" and "Cancel" of
-- different widths are the first thing that gives away a fake. The width is
-- computed from the MEASURED text and then rounded up to whole cells: the
-- place of an interactive detail is named in cells, otherwise neighboring
-- buttons share a cell.
--
-- Returns the width in cells; the caller draws, by the same width.
function pixels.button_span(font, labels, cell: any, least: any): integer
    local unit: any = type(cell) == "table" and cell or {}
    local cw = math.max(1, whole(unit.w))

    local widest = whole(least)
    for _, label in ipairs(type(labels) == "table" and labels or {}) do
        local measured = font and font:measure(tostring(label)) or 0
        if whole(measured) > widest then widest = whole(measured) end
    end
    -- Margins at the sides of the caption: without them the text runs into
    -- the edge.
    local span = (widest + 16 + cw - 1) // cw
    if span < 1 then span = 1 end
    return math.tointeger(span) or 1
end

-- Clip captions using the actual font rather than character counts. The cut
-- is marked with "…", the same mark as in the cell renderer.
function pixels.ellipsize(font, text, room: any)
    local caption = tostring(text or "")
    if not font or whole(room) <= 0 then return "" end
    if whole(font:measure(caption)) <= whole(room) then return caption end
    local ending = "…"
    if whole(font:measure(ending)) > whole(room) then return "" end
    local kept = ""
    for _, rune in ipairs(text_lib.runes(caption)) do
        if whole(font:measure(kept .. rune .. ending)) > whole(room) then break end
        kept = kept .. rune
    end
    return kept .. ending
end

-- Native PNGs are cached by images for the lifetime of the process, and a
-- failure is reported there, once. Primitives stay for missing assets and
-- broken shortcuts.
local function native_icon(raster, x: any, y: any, item: any, size: any): boolean
    if not images.name_for(item) then return false end
    return images.icon(raster, whole(x), whole(y), item, size) == true
end

function pixels.icon(raster, x: any, y: any, item: any, size: any)
    local side = whole(size or 32)
    if native_icon(raster, x, y, item, side) then return end
    if side == 16 then
        if item.kind == "folder" or item.kind == "directory" or item.kind == "group" then
            pixels.mark_folder(raster, whole(x), whole(y), side, color.face_text)
        else
            pixels.mark_program(raster, whole(x), whole(y), side, color.face_text)
        end
        if item.broken then
            for i = 0, 7 do
                raster:set(whole(x) + 4 + i, whole(y) + 4 + i, color.alert)
                raster:set(whole(x) + 11 - i, whole(y) + 4 + i, color.alert)
            end
        end
        return
    end
    local left, top = whole(x), whole(y)
    local function rect(dx, dy, w, h, ink)
        raster:rect(left + dx, top + dy, w, h, ink)
    end
    local kind = item.kind
    if kind == "folder" or kind == "directory" then
        rect(2, 6, 12, 2, "#000000")
        rect(1, 8, 28, 21, "#000000")
        rect(3, 7, 10, 3, "#ffff80")
        rect(2, 10, 26, 17, "#808000")
        rect(3, 10, 24, 2, "#ffff80")
        rect(4, 13, 27, 2, "#000000")
        rect(3, 15, 27, 5, "#000000")
        rect(2, 20, 27, 6, "#000000")
        rect(1, 26, 27, 3, "#000000")
        rect(5, 14, 25, 2, "#ffff80")
        rect(4, 16, 25, 4, "#ffff00")
        rect(3, 20, 25, 6, "#ffff00")
        rect(2, 26, 25, 2, "#c0c000")
    elseif item.entry == "butschster.windows.explorer:window" then
        rect(4, 0, 24, 22, "#000000")
        rect(5, 1, 22, 20, "#c0c0c0")
        rect(5, 1, 22, 1, "#ffffff")
        rect(5, 1, 1, 19, "#ffffff")
        rect(7, 3, 18, 15, "#808080")
        rect(8, 4, 16, 12, "#000000")
        rect(9, 5, 14, 10, "#000080")
        rect(10, 6, 12, 1, "#008080")
        rect(10, 7, 11, 5, "#008080")
        rect(10, 13, 12, 1, "#0080ff")
        rect(21, 19, 3, 1, "#00ff00")
        rect(12, 22, 8, 3, "#808080")
        rect(10, 24, 12, 2, "#000000")
        rect(1, 26, 29, 6, "#000000")
        rect(2, 26, 27, 4, "#ffffff")
        rect(3, 27, 25, 3, "#c0c0c0")
        rect(4, 28, 16, 1, "#808080")
        rect(23, 28, 3, 1, "#000000")
    elseif kind == "drive" then
        rect(3, 12, 26, 16, "#000000")
        rect(4, 10, 23, 3, "#000000")
        rect(5, 9, 21, 2, "#000000")
        rect(6, 10, 19, 3, "#ffffff")
        rect(5, 13, 22, 3, "#c0c0c0")
        rect(4, 17, 24, 9, "#c0c0c0")
        rect(4, 17, 24, 1, "#ffffff")
        rect(4, 18, 1, 8, "#ffffff")
        rect(7, 20, 14, 2, "#000000")
        rect(7, 22, 14, 1, "#ffffff")
        rect(24, 22, 2, 2, "#008000")
        rect(4, 26, 24, 1, "#808080")
    else
        rect(4, 2, 24, 28, "#000000")
        rect(5, 3, 22, 26, "#ffffff")
        rect(6, 4, 20, 5, "#000080")
        rect(7, 5, 3, 3, "#ffffff")
        rect(23, 5, 2, 3, "#c0c0c0")
        rect(8, 12, 15, 1, "#808080")
        rect(8, 15, 12, 1, "#808080")
        rect(8, 18, 15, 1, "#808080")
        rect(8, 21, 9, 1, "#808080")
        if item.broken then
            for i = 0, 8 do
                rect(12 + i, 13 + i, 2, 2, "#800000")
                rect(20 - i, 13 + i, 2, 2, "#800000")
            end
        end
    end
    if kind == "shortcut" and item.entry ~= "butschster.windows.explorer:window" then
        rect(0, 23, 10, 9, "#000000")
        rect(1, 24, 8, 7, "#ffffff")
        rect(3, 26, 4, 2, "#000000")
        rect(5, 25, 2, 4, "#000000")
        rect(2, 28, 2, 2, "#000000")
    end
end

-- ─── toolbar marks ───────────────────────────────────────────────────────
--
-- The toolbar symbols (✂ ⧉ ⎘ ↶ ✕ ▤ ▦ ▩ ≡ ☷) are glyphs for cells; Liberation
-- does not have them, and a missing rune is drawn as a space. So in pixels
-- each mark is primitives in a `size` square, as with the title buttons.

local function hline(raster, x: any, y: any, len: any, ink)
    raster:rect(whole(x), whole(y), math.max(1, whole(len)), 1, ink)
end

local function vline(raster, x: any, y: any, len: any, ink)
    raster:rect(whole(x), whole(y), 1, math.max(1, whole(len)), ink)
end

local function hollow(raster, x: any, y: any, w: any, h: any, ink)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    hline(raster, left, top, width, ink)
    hline(raster, left, top + height - 1, width, ink)
    vline(raster, left, top, height, ink)
    vline(raster, left + width - 1, top, height, ink)
end

-- Arrows: a shaft of two lines and a head of strips of decreasing length.
function pixels.mark_back(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = top + side // 2
    raster:rect(left + 5, mid - 1, side - 6, 3, ink)
    for step = 0, 4 do hline(raster, left + 1 + step, mid - step, 1 + step * 2 // 1, ink) end
    for step = 0, 4 do hline(raster, left + 1 + step, mid + step, 1, ink) end
    for step = 1, 4 do vline(raster, left + 1 + step, mid - step, step * 2 + 1, ink) end
end

function pixels.mark_forward(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = top + side // 2
    raster:rect(left + 1, mid - 1, side - 6, 3, ink)
    for step = 1, 4 do vline(raster, left + side - 2 - step, mid - step, step * 2 + 1, ink) end
    raster:set(left + side - 2, mid, ink)
end

function pixels.mark_up(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = left + side // 2
    raster:rect(mid - 1, top + 5, 3, side - 6, ink)
    for step = 1, 4 do hline(raster, mid - step, top + 1 + step, step * 2 + 1, ink) end
    raster:set(mid, top + 1, ink)
end

-- Scissors: two blades crossed and two handle rings at the bottom.
function pixels.mark_cut(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    for step = 0, side - 7 do
        raster:set(left + 2 + step, top + step, ink)
        raster:set(left + side - 3 - step, top + step, ink)
    end
    hollow(raster, left + 1, top + side - 5, 4, 4, ink)
    hollow(raster, left + side - 5, top + side - 5, 4, 4, ink)
end

-- Copy: two sheets, the second peeking out from under the first.
function pixels.mark_copy(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 1, top + 1, side - 5, side - 5, ink)
    raster:rect(left + 5, top + 5, side - 6, side - 6, color.field)
    hollow(raster, left + 5, top + 5, side - 6, side - 6, ink)
end

-- Paste: a clipboard with a clip and a sheet on it.
function pixels.mark_paste(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 1, top + 2, side - 4, side - 3, ink)
    raster:rect(left + side // 2 - 2, top + 1, 4, 2, ink)
    raster:rect(left + 5, top + 6, side - 6, side - 7, color.field)
    hollow(raster, left + 5, top + 6, side - 6, side - 7, ink)
end

-- Undo: a left arrow with a tail bent down and to the right.
function pixels.mark_undo(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local row = top + 4
    raster:rect(left + 4, row, side - 7, 2, ink)
    vline(raster, left + side - 4, row, 5, ink); vline(raster, left + side - 3, row, 5, ink)
    raster:rect(left + side - 8, row + 4, 5, 2, ink)
    for step = 1, 3 do vline(raster, left + 1 + step, row - step + 1, step * 2, ink) end
end

pixels.mark_delete = pixels.mark_close

-- Properties: a sheet with three lines.
function pixels.mark_properties(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 2, top + 1, side - 4, side - 2, ink)
    for line = 0, 2 do hline(raster, left + 4, top + 4 + line * 3, side - 8, ink) end
end

-- Four views: large icons, small ones, list, details.
function pixels.mark_view_large(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 1 do for col = 0, 1 do hollow(raster, left + 1 + col * 7, top + 1 + row * 7, 6, 6, ink) end end
end

function pixels.mark_view_small(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 2 do for col = 0, 2 do raster:rect(left + 1 + col * 5, top + 1 + row * 5, 3, 3, ink) end end
end

function pixels.mark_view_list(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 2 do
        raster:rect(left + 1, top + 2 + row * 5, 3, 3, ink)
        hline(raster, left + 6, top + 3 + row * 5, 8, ink)
    end
end

function pixels.mark_view_details(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 3 do hline(raster, left + 1, top + 1 + row * 4, 13, ink) end
    vline(raster, left + 1, top + 1, 13, ink); vline(raster, left + 6, top + 1, 13, ink); vline(raster, left + 13, top + 1, 13, ink)
end

-- A down triangle — the button that opens a list.
function pixels.mark_drop(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = left + side // 2
    for step = 0, 3 do hline(raster, mid - 3 + step, top + side // 2 - 2 + step, 7 - step * 2, ink) end
end

pixels.MARKS.back = pixels.mark_back
pixels.MARKS.forward = pixels.mark_forward
pixels.MARKS.up = pixels.mark_up
pixels.MARKS.cut = pixels.mark_cut
pixels.MARKS.copy = pixels.mark_copy
pixels.MARKS.paste = pixels.mark_paste
pixels.MARKS.undo = pixels.mark_undo
pixels.MARKS.delete = pixels.mark_delete
pixels.MARKS.properties = pixels.mark_properties
pixels.MARKS.view_large = pixels.mark_view_large
pixels.MARKS.view_small = pixels.mark_view_small
pixels.MARKS.view_list = pixels.mark_view_list
pixels.MARKS.view_details = pixels.mark_view_details
pixels.MARKS.drop = pixels.mark_drop

-- A faded Windows 95 mark: gray, with a white copy one pixel lower and to
-- the right.
function pixels.mark_disabled(raster, mark, x: any, y: any, size: any)
    if type(mark) ~= "function" then return end
    mark(raster, whole(x) + 1, whole(y) + 1, size, color.light)
    mark(raster, x, y, size, color.shadow)
end

function pixels.mark_help(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    raster:rect(left + 3, top + 1, 4, 1, ink)
    raster:set(left + 2, top + 2, ink)
    raster:rect(left + 7, top + 2, 1, 2, ink)
    raster:rect(left + 5, top + 4, 2, 1, ink)
    raster:rect(left + 4, top + 5, 1, 2, ink)
    raster:set(left + 4, top + 8, ink)
end
pixels.MARKS.help = pixels.mark_help

function pixels.flag(raster, x: any, y: any)
    if native_icon(raster, x, y, {image = "windows"}, 16) then return end
    local left, top = whole(x), whole(y)
    raster:rect(left + 3, top, 12, 13, "#000000")
    raster:rect(left + 4, top + 1, 4, 4, "#ff0000")
    raster:rect(left + 10, top + 2, 4, 4, "#00ff00")
    raster:rect(left + 4, top + 7, 4, 4, "#0000ff")
    raster:rect(left + 10, top + 8, 4, 4, "#ffff00")
    raster:rect(left, top + 1, 2, 2, "#000000")
    raster:rect(left + 1, top + 5, 2, 2, "#000000")
    raster:rect(left, top + 9, 2, 2, "#000000")
end


-- ─── Scroll bar and status bar ───────────────────────────────────────────
--
-- One bar for everyone: the SDK lists, tables and tree, the Explorer field.
-- Six painters over one `scroll.bar` drifted apart in thumb width and arrow
-- look; now the geometry arrives ready (`bar` from `scroll.bar`: start,
-- size, limit — in rows), and the bar has one look.
--
-- `row_h` — row height in pixels, `arrow_h` — height of the arrow button.
function pixels.scrollbar(raster, x: any, y: any, w: any, h: any, bar: any, row_h: any, arrow_h: any)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    if width < 3 or height < 4 then return end
    local arrow = math.min(math.max(4, whole(arrow_h)), height // 2)
    raster:rect(left, top, width, height, color.face)
    pixels.panel(raster, left, top, width, arrow)
    pixels.panel(raster, left, top + height - arrow, width, arrow)
    local center = left + width // 2
    for step = 0, 3 do
        raster:rect(center - step, top + (arrow - 4) // 2 + step, step * 2 + 1, 1, color.face_text)
        raster:rect(center - step, top + height - (arrow - 4) // 2 - step - 1, step * 2 + 1, 1, color.face_text)
    end
    local thumb: any = type(bar) == "table" and bar or {}
    if whole(thumb.limit) > 0 and whole(thumb.size) > 0 then
        pixels.panel(raster, left, top + whole(thumb.start) * whole(row_h), width, whole(thumb.size) * whole(row_h))
    end
end

-- Status bar: sunken fields, the last one stretches; a field has its own
-- width in pixels (`width`) or one taken from its text.
function pixels.statusbar(raster, x: any, y: any, w: any, h: any, fields: any, font: any)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    raster:rect(left, top, width, height, color.face)
    local list: any = type(fields) == "table" and fields or {}
    local at = left + 2
    local right = left + width - 2
    for index, entry in ipairs(list) do
        local field: any = type(entry) == "table" and entry or {text = tostring(entry)}
        local text = tostring(field.text or "")
        local text_w = font and whole(font:measure(text)) or 0
        local want = whole(field.width) > 0 and whole(field.width) or text_w + 12
        if index == #list then want = right - at end
        want = math.min(want, right - at)
        if want < 8 then break end
        pixels.bevel(raster, at, top + 1, want, height - 2, false)
        if font then
            raster:text(at + 4, top + (height - 15) // 2, pixels.ellipsize(font, text, want - 8),
                {font = font, color = color.face_text})
        end
        at = at + want + 2
    end
end

return pixels
