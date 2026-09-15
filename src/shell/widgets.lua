-- Classic primitives that know nothing about the screen.
--
-- A separate library, because TWO draw with it. The theme draws the window
-- frame and the taskbar; the "My Computer" window draws its menu bar,
-- toolbar, tabs and status bar inside itself — and does it on its own, into
-- its own viewport, knowing nothing about the theme. A private copy of the
-- relief in the second one would diverge from the frame around it, and it
-- would diverge in LOOK, not by failing: two almost identical buttons get
-- noticed a week later.
--
-- The border is drawn like this: here is what is drawn at its own
-- coordinates and does not ask how wide the screen is. Everything that knows
-- about the screen as a whole — the window frame, the taskbar, the Start
-- menu, the desktop icons — stays in the theme.
--
-- The drawing target is any `tty.canvas`: both the one the compositor holds
-- and the one a window creates for itself. It is one and the same type, so
-- the cut runs here, and not along the process boundary.

local tty = require("tty")
local text_lib = require("text")

local glyphs = require("glyphs")
local palette = require("palette")

local color = palette.active

local scroll = require("scroll")
local widgets = {}

-- ─── Measures ────────────────────────────────────────────────────────────

function widgets.whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local whole = widgets.whole

-- Width is counted in CELLS. `#text` counts bytes and does not see SGR: on
-- Cyrillic it lies twofold, on styled text — threefold.
function widgets.cells(text): integer
    return whole(tty.text.width(text))
end

local cells = widgets.cells

function widgets.clip(text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    return tty.text.truncate(tostring(text or ""), width)
end

local clip = widgets.clip

-- fit(style, text, room) — a string of EXACTLY `room` cells in one style.
--
-- Padding with spaces has to be done by hand: `style:width(n)` puts its
-- background under foreign SGR sequences only up to the first reset, and the
-- tail of the string is left with the terminal's background — on a gray
-- panel it shows as a hole.
function widgets.fit(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local clipped = clip(text, width)
    local gap = width - cells(clipped)
    if gap > 0 then clipped = clipped .. string.rep(" ", gap) end
    return style:render(clipped)
end

local fit = widgets.fit

function widgets.centered(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local body = clip(text, width)
    local left = (width - cells(body)) // 2
    return style:render(string.rep(" ", left) .. body
        .. string.rep(" ", width - left - cells(body)))
end

-- runes(text) — splitting into characters. Needed where the character's
-- NUMBER matters, not its byte offset: the underlined accelerator letter is
-- the fourth letter, not the fourth byte, and in Cyrillic these are
-- different places.
local runes = text_lib.runes

-- ─── Styles ──────────────────────────────────────────────────────────────
--
-- A shared table, not a copy for everyone: two identical grays differ to the
-- eye, but in the code they do not.
-- Styles are ONE table for the whole shell.
--
-- There were two: this one and the theme's own, almost the same. They did
-- not diverge right away, and it was discovered by a failure on the live
-- running system: the pixel theme took `widgets.styles.desktop`, which was
-- not here, because the teal desktop lived in someone else's copy. Two tables
-- of the same thing diverge exactly on the keys that both rarely need.
widgets.styles = {
    -- The desktop. Here, not in the theme: both the theme and the pixel fill
    -- paint with it, and both must take one and the same color.
    desktop        = tty.style():background(color.desktop),
    desktop_text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
    desktop_broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
    -- Window title. Active and inactive differ by BACKGROUND, not by text
    -- brightness: otherwise on a dark terminal theme both merge together.
    title          = tty.style():bold():foreground(color.title_active_fg):background(color.title_active_bg),
    title_idle     = tty.style():foreground(color.title_idle_fg):background(color.title_idle_bg),
    banner         = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    face      = tty.style():foreground(color.face_text):background(color.face),
    face_bold = tty.style():bold():foreground(color.face_text):background(color.face),
    face_dim  = tty.style():foreground(color.shadow):background(color.face),
    accel     = tty.style():underline():foreground(color.face_text):background(color.face),
    light     = tty.style():foreground(color.light):background(color.face),
    shadow    = tty.style():foreground(color.shadow):background(color.face),
    frame     = tty.style():foreground(color.frame):background(color.face),
    etched    = tty.style():foreground(color.shadow):background(color.light),
    console   = tty.style():foreground(color.console_text):background(color.console_bg),
    field     = tty.style():foreground(color.field_text):background(color.field),
    select    = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    alert     = tty.style():bold():foreground(color.alert):background(color.face),
    farewell  = tty.style():bold():foreground(color.farewell_text):background(color.farewell_bg),
    -- The balloon tip: pale yellow with black text, a black frame, the
    -- notification pictures as a letter on their own colour.
    tooltip         = tty.style():foreground(color.tooltip_text):background(color.tooltip_bg),
    tooltip_bold    = tty.style():bold():foreground(color.tooltip_text):background(color.tooltip_bg),
    tooltip_frame   = tty.style():foreground(color.frame):background(color.tooltip_bg),
    balloon_info    = tty.style():bold():foreground(color.info_text):background(color.info_bg),
    balloon_warning = tty.style():bold():foreground(color.warning_text):background(color.warning_bg),
    balloon_error   = tty.style():bold():foreground(color.error_text):background(color.error_bg),
    -- The tail stands on the desktop: pale yellow on the desktop colour.
    balloon_tail    = tty.style():foreground(color.tooltip_bg):background(color.desktop),
}
-- The desktop color is changed by a person ("Display Properties"), and the
-- styles taken from the palette at load time must be re-taken: otherwise the
-- desktop in cells would stay as before, while the icons in pixels would
-- already be recolored — two representations of one value would diverge
-- silently.
function widgets.use_desktop(hex: any)
    color.desktop = tostring(hex)
    widgets.styles.desktop = tty.style():background(color.desktop)
    widgets.styles.desktop_text = tty.style():bold():foreground(color.desktop_text):background(color.desktop)
    widgets.styles.desktop_broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop)
    widgets.styles.balloon_tail = tty.style():foreground(color.tooltip_bg):background(color.desktop)
end


local styles = widgets.styles

-- ─── Relief ──────────────────────────────────────────────────────────────
--
-- Relief is given by a one-cell edge: light at the top and left, dark at the
-- bottom and right. Swap them and you get a sunken detail with the same
-- code; both the pressed button and the recessed field rest on this.

-- bezel(body, sunken) — a detail with an edge on the left and right, in one
-- row.
--
-- `body` arrives ALREADY rendered: applying a style over a styled string
-- means wrapping it in a second SGR envelope, and the very first inner reset
-- leaves a tail with the terminal's background. The width of the result is
-- the width of the body plus two cells.
function widgets.bezel(body, sunken)
    local left = sunken and styles.shadow or styles.light
    local right = sunken and styles.light or styles.shadow
    return left:render(glyphs.bevel.left) .. body .. right:render(glyphs.bevel.right)
end

local bezel = widgets.bezel

function widgets.edge_top(width: any, sunken)
    local w = whole(width)
    if w <= 0 then return "" end
    local style = sunken and styles.shadow or styles.light
    if w == 1 then return style:render(glyphs.bevel.corner_light) end
    return style:render(glyphs.bevel.corner_light .. string.rep(glyphs.bevel.top, w - 1))
end

function widgets.edge_bottom(width: any, sunken)
    local w = whole(width)
    if w <= 0 then return "" end
    local style = sunken and styles.light or styles.shadow
    if w == 1 then return style:render(glyphs.bevel.corner_shadow) end
    return style:render(string.rep(glyphs.bevel.bottom, w - 1) .. glyphs.bevel.corner_shadow)
end

-- panel(target, x, y, box_w, body, sunken) — a rectangle with relief.
--
-- `body` — already rendered rows of EXACTLY `box_w - 2` cells. The height is
-- `#body + 2`. Raised and sunken differ only in which edge is light: one
-- shape for the menu, the notice box, the clock field and the list field.
-- Three different notice boxes would drift apart in look on the very first
-- edit.
function widgets.panel(target, x: any, y: any, box_w: any, body, sunken)
    local left, top, span = whole(x), whole(y), whole(box_w)
    if span < 3 then return end
    target:put(left, top, widgets.edge_top(span, sunken), span)
    for index, row in ipairs(body) do
        target:put(left, top + index, bezel(row, sunken), span)
    end
    target:put(left, top + #body + 1, widgets.edge_bottom(span, sunken), span)
end

-- A sunken field for someone else's content: the frame is drawn, the inside
-- is left to the caller.
function widgets.field(target, x: any, y: any, box_w: any, box_h: any)
    local w, h = whole(box_w), whole(box_h)
    if w < 3 or h < 2 then return end
    local body = {}
    for row = 1, h - 2 do body[row] = styles.face:render(string.rep(" ", w - 2)) end
    widgets.panel(target, x, y, w, body, true)
end

-- ─── Dialog parts ────────────────────────────────────────────────────────

-- accel(style, text, position) — text with an underlined accelerator letter.
--
-- The position is counted in LETTERS. Zero or one past the end of the string
-- means "no accelerator" and is rendered as plain text: underlining the
-- wrong letter is worse than underlining none — a person will press it and
-- nothing will happen.
function widgets.accel(style, text, position: any)
    local at = whole(position)
    local list = runes(text)
    if at < 1 or at > #list then return style:render(tostring(text)) end
    local head, tail = {}, {}
    for index = 1, at - 1 do head[#head + 1] = list[index] end
    for index = at + 1, #list do tail[#tail + 1] = list[index] end
    return style:render(table.concat(head))
        .. styles.accel:render(list[at])
        .. style:render(table.concat(tail))
end

-- Button width: two edges, two spaces around the caption and the caption
-- itself; the default button has two more cells of black outline.
function widgets.button_width(label, opts): integer
    local extra = (type(opts) == "table" and opts.default) and 2 or 0
    return cells(tostring(label or "")) + 4 + extra
end

-- button(label, opts) — a raised button in one row.
--
-- opts.pressed — pressed (the edges swap places), opts.default — the default
-- button: in the original it has a black outline on top of the relief, and
-- that is not decoration but the only sign of what Enter will do.
-- opts.accel — the number of the letter to underline. opts.disabled —
-- unavailable: the caption is dim (there is no white shadow in cells, etched
-- is only in pixels).
-- opts.focused — focused: the caption in inverse, the edges stay; there is
-- nothing to draw a dotted frame with in cells, and inverting the whole
-- button would read as a selected list row.
--
-- `opts.room` is the cells the button has. Two bevels and a space on each
-- side are the full look; a caption that does not fit with the spaces is
-- drawn without them, and one that does not fit even so is cut, never
-- replaced by an ellipsis. So a four-cell calculator key shows "MC" whole
-- instead of " MC" with the right bevel cut off. A button wider than its
-- caption fills its room, the caption centred, as in pixels: keys of one
-- calculator column are then the same width.
function widgets.button(label, opts)
    local options: any = type(opts) == "table" and opts or {}
    local caption = tostring(label or "")
    local text, lead = " " .. caption .. " ", 1
    local room = whole(options.room)
    if room > 0 then
        local inner = room - 2 - (options.default and 2 or 0)
        if cells(text) > inner then
            text, lead = cells(caption) <= inner and caption or clip(caption, math.max(0, inner)), 0
        end
        if cells(text) < inner then
            local spare = inner - cells(text)
            local left = spare // 2
            text, lead = string.rep(" ", left) .. text .. string.rep(" ", spare - left), lead + left
        end
    end
    local face = styles.face
    if options.disabled then face = styles.face_dim elseif options.focused then face = styles.select end
    local body = (options.accel and not options.disabled)
        and widgets.accel(face, text, whole(options.accel) + lead)
        or face:render(text)
    local out = bezel(body, options.pressed and true or false)
    if options.default then
        out = styles.frame:render(glyphs.bevel.left) .. out
            .. styles.frame:render(glyphs.bevel.right)
    end
    return out
end

-- etched(width) — a dialog separator in one row.
--
-- A half block paints the top of the cell with the text color and the
-- bottom with the background color: a dark edge above a light one, that is,
-- a real classic etched line, not just a thin rule. Two rows per
-- separator are not needed.
function widgets.etched(width: any)
    local w = whole(width)
    if w <= 0 then return "" end
    return styles.etched:render(string.rep(glyphs.shade.half_top, w))
end

-- ─── Window bars ─────────────────────────────────────────────────────────
--
-- The window ITSELF draws them, inside its own viewport: every window has
-- its own menu items, and "6 objects" is recounted on every folder open.
-- Hand them to the theme — and the compositor would start knowing how
-- someone else's window is built.

-- Menu bar: `File Edit View Help` with an underlined letter.
--
-- Returns hits. An item drawn without a hit is a word that gets clicked and
-- nothing happens, and from the screen it cannot be told apart from "the
-- menu is broken".
--
-- menu_hits(x, y, width, entries) -> {row, from, to, menu, index, accel}
-- Layout without drawing: both window backends draw by it, and by it the
-- window also computes a click — as with the toolbar.
function widgets.menu_hits(x: any, y: any, width: any, entries): any
    local hits: any = {}
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 1 then return hits end
    local used = 0
    for index, entry in ipairs(type(entries) == "table" and entries or {}) do
        local record: any = entry
        local text = type(record) == "table" and tostring(record.text or "?") or tostring(record)
        local at = type(record) == "table" and whole(record.accel) or 1
        if at < 1 then at = 1 end
        local room = cells(" " .. text .. " ")
        if used + room > span then break end
        hits[#hits + 1] = {row = row, from = left + used, to = left + used + room - 1,
            menu = text, index = index, accel = at}
        used = used + room
    end
    return hits
end

function widgets.menu_bar(target, x: any, y: any, width: any, entries)
    local left, row, span = whole(x), whole(y), whole(width)
    local hits = widgets.menu_hits(x, y, width, entries)
    if span < 1 then return hits end

    local parts, used = {}, 0
    for _, entry in ipairs(hits) do
        local hit: any = entry
        -- The leading space shifts the letter by one: the accelerator is
        -- counted by the item's NAME, not by the drawn string.
        parts[#parts + 1] = widgets.accel(styles.face, " " .. hit.menu .. " ", hit.accel + 1)
        used = used + (hit.to - hit.from + 1)
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
    return hits
end

-- Toolbar: buttons with an icon and a caption in one row.
-- Toolbar layout WITHOUT drawing.
--
-- Pulled out because there are now two readers: `widgets.toolbar` draws, and
-- `render.layout` computes the window layout — and computes it before
-- anything is drawn, because the second backend does not draw into a canvas.
-- A private formula in the second reader would give a button one cell to
-- the left of where it looks.
--
-- Returns hits and captions: the caption is needed by whoever will draw, so
-- as not to assemble it again by the same rules.
-- `fixed` — button width in cells, one for all: the pixel toolbar draws
-- 23×22 buttons after the classic model and names their place in cells
-- itself, not by the length of the caption, which is absent in pixels.
function widgets.toolbar_hits(x: any, y: any, width: any, buttons, fixed: any?): any
    local hits: any = {}
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 3 then return hits end
    local fixed_room = whole(fixed)

    local used = 0
    for _, entry in ipairs(type(buttons) == "table" and buttons or {}) do
        local button: any = entry
        if button.sep then
            if used + 1 > span then break end
            used = used + 1
        else
            local icon = type(button.icon) == "string" and button.icon or glyphs.icons.program
            local label = type(button.label) == "string" and button.label or ""
            local text = label ~= "" and (" " .. icon .. " " .. label .. " ") or (" " .. icon .. " ")
            local room = fixed_room > 0 and fixed_room or cells(text) + 2
            if used + room > span then break end
            hits[#hits + 1] = {
                row = row, from = left + used, to = left + used + room - 1,
                id = button.id, text = text, icon = icon, label = label,
                pressed = button.pressed and true or false,
                -- An unavailable button is drawn faded, not hidden, as in
                -- the original: the toolbar does not change shape depending on
                -- what is selected. A click on it is not an action, and the
                -- hit says so.
                disabled = button.disabled and true or false,
                title = type(button.title) == "string" and button.title or label,
            }
            used = used + room
        end
    end
    return hits
end

function widgets.toolbar(target, x: any, y: any, width: any, buttons)
    local left, row, span = whole(x), whole(y), whole(width)
    local hits = widgets.toolbar_hits(x, y, width, buttons)
    if span < 3 then return hits end

    -- Drawn by THE SAME numbers the layout returned: the separators between
    -- buttons are restored from the gaps, not computed anew.
    local parts, used = {}, 0
    for _, entry in ipairs(hits) do
        local button: any = entry
        local at = button.from - left
        while used < at do
            parts[#parts + 1] = styles.shadow:render(glyphs.bevel.left)
            used = used + 1
        end
        local face = button.disabled and styles.face_dim or styles.face
        parts[#parts + 1] = bezel(face:render(button.text), button.pressed)
        used = used + (button.to - button.from + 1)
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
    return hits
end

-- Address bar: the caption "Address", a sunken field with a folder icon and
-- the path, and on the right a ▾ button that opens the list. As in a classic
-- folder window (there it is a drop-down list on the toolbar; in the next
-- release — a row of its own).
--
-- Returns hits: `field` — the field itself, `drop` — the button. Both open
-- the list: in the original a click on the field selects the text, but the text
-- is not editable here, and a field that responds to nothing is worse than
-- a field that acts as a button.
widgets.ADDRESS_LABEL = " Address "
widgets.ADDRESS_DROP = " ▾ "

-- address_hits(x, y, width) -> {field, drop} | {}
--
-- The address bar geometry in cells is ONE for both backends: `address_bar`
-- draws by it, the pixel painter places the raster by it, and the window
-- computes a click by it. A private formula in any of the three would give
-- the ▾ button one cell to the left of where it looks.
function widgets.address_hits(x: any, y: any, width: any): any
    local left, row, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    if span < 12 then return hits end
    local label_w = cells(widgets.ADDRESS_LABEL)
    local drop_w = cells(widgets.ADDRESS_DROP) + 2
    local field_w = span - label_w - drop_w
    if field_w < 4 then return hits end
    hits.field = {row = row, from = left + label_w, to = left + label_w + field_w - 1}
    hits.drop = {row = row, from = left + label_w + field_w, to = left + span - 1}
    return hits
end

function widgets.address_bar(target, x: any, y: any, width: any, text: any, icon: any?): any
    local left, row, span = whole(x), whole(y), whole(width)
    local hits: any = widgets.address_hits(x, y, width)
    if not hits.field then return hits end
    local field_w = hits.field.to - hits.field.from + 1

    local mark = type(icon) == "string" and icon ~= "" and icon or glyphs.icons.folder
    local body = fit(styles.field, " " .. mark .. " " .. tostring(text or ""), field_w - 2)
    local line = styles.face:render(widgets.ADDRESS_LABEL) .. bezel(body, true)
        .. bezel(styles.face:render(widgets.ADDRESS_DROP), false)
    target:put(left, row, line, span)
    return hits
end

-- dropdown_hits(x, y, width, count) -> list rows: {row, from, to, index}
function widgets.dropdown_hits(x: any, y: any, width: any, count: any): any
    local left, top, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    local total = whole(count)
    if span < 6 or total < 1 then return hits end
    for index = 1, total do
        hits[#hits + 1] = {row = top + index, from = left, to = left + span - 1, index = index}
    end
    return hits
end

-- Drop-down list: a white field with a frame, a row per item, the current one
-- selected. Drawn over whatever is under it — as a list should be.
-- Returns row hits: {row, from, to, index}.
function widgets.dropdown(target, x: any, y: any, width: any, items: any, current: any): any
    local left, top, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    local list: any = type(items) == "table" and items or {}
    hits = widgets.dropdown_hits(x, y, width, #list)
    if #hits == 0 then return hits end
    local body = {}
    local chosen = whole(current)
    for index, item in ipairs(list) do
        local record: any = item
        local text = type(record) == "table" and tostring(record.title or "?") or tostring(record)
        local style = index == chosen and styles.select or styles.field
        body[#body + 1] = fit(style, " " .. text, span - 2)
    end
    widgets.panel(target, left, top, span, body, true)
    return hits
end

-- Status bar: sunken fields. The last one takes the remainder — otherwise on
-- a wide window a strip of bare face remains on the right, and the bar looks
-- unfinished.
function widgets.statusbar(target, x: any, y: any, width: any, fields)
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 3 then return end

    local list: any = type(fields) == "table" and fields or {}
    local parts, used = {}, 0
    for index, entry in ipairs(list) do
        local field: any = entry
        local text = type(field) == "table" and tostring(field.text or "") or tostring(field)
        local want = type(field) == "table" and whole(field.width) or 0
        if want <= 0 then want = cells(text) + 2 end
        if index == #list then want = span - used - 2 end
        if want < 1 then break end
        if used + want + 2 > span then want = span - used - 2 end
        if want < 1 then break end
        parts[#parts + 1] = bezel(fit(styles.face, " " .. text, want), true)
        used = used + want + 2
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
end

-- How many columns a vertical scrollbar takes. The classic bar is 16 px
-- wide; in pixels it takes as many whole cells as 16 px needs — two at an 8
-- or 10 px cell, one from 16 px up — and in cells one (`cell_w` absent or
-- zero). ONE rule for the SDK and the explorer: the layout reserves these
-- columns and the hit test reads the same number, so a bar drawn wider than
-- the place where it is pressed cannot happen.
local SCROLLBAR_PX = 16
widgets.SCROLLBAR_PX = SCROLLBAR_PX
function widgets.scroll_cols(cell_w: any): integer
    local cw = whole(cell_w)
    if cw <= 0 then return 1 end
    local cols = (SCROLLBAR_PX + cw - 1) // cw
    if cols < 1 then return 1 end
    return cols
end

-- Vertical scroll bar: arrow, track with a thumb, arrow.
--
-- Drawn ONLY when there is something to scroll. A bar over fully visible
-- content is a promise that there is more somewhere, and a person will drag
-- it.
--
-- `state`: first — the first visible row counting from zero, visible — how
-- many rows fit, total — how many there are in all.
--
-- Returns the arrows' hits. An arrow that cannot be clicked is the same stage
-- prop as a button that does nothing.
function widgets.scrollbar(target, x: any, y: any, box_h: any, state)
    local hits = {}
    local col, top, height = whole(x), whole(y), whole(box_h)
    if height < 3 then return hits end

    local bar: any = type(state) == "table" and state or {}
    local total = whole(bar.total)
    local visible = whole(bar.visible)
    if visible < 1 or total <= visible then return hits end

    local first = whole(bar.first)
    local last = total - visible
    if first < 0 then first = 0 end
    if first > last then first = last end

    target:put(col, top, styles.face:render(glyphs.scrollbar.up), 1)
    target:put(col, top + height - 1, styles.face:render(glyphs.scrollbar.down), 1)
    hits[#hits + 1] = {row = top, from = col, to = col, id = "scroll_up"}
    hits[#hits + 1] = {row = top + height - 1, from = col, to = col, id = "scroll_down"}

    -- The thumb is at least one cell tall: degenerating to zero, it
    -- disappears exactly where there is the most to scroll.
    local track = height - 2
    local thumb_data = scroll.bar(first, total, visible, height)
    local thumb, offset = thumb_data.size, thumb_data.start - 1

    for row = 0, track - 1 do
        local inside = row >= offset and row < offset + thumb
        local glyph = inside and glyphs.scrollbar.thumb or glyphs.scrollbar.track
        target:put(col, top + 1 + row, styles.face:render(glyph), 1)
    end

    return hits
end

-- Tabs with a page under them.
--
-- The whole trick is the GAP: the page frame is interrupted exactly under
-- the active tab, and that makes the tab merge with the page. Without the
-- gap it is just a row of buttons above a rectangle, and which one is
-- selected is visible only by boldness.
--
-- Draws the row of tabs, the page frame and its empty interior; the caller
-- places the page content at (x + 1, y + 2).
function widgets.tabs(target, x: any, y: any, box_w: any, box_h: any, labels, active: any)
    local hits = {}
    local left, top = whole(x), whole(y)
    local span, height = whole(box_w), whole(box_h)
    if span < 6 or height < 4 then return hits end

    local list: any = type(labels) == "table" and labels or {}
    local current = whole(active)
    if current < 1 then current = 1 end

    local parts, used = {}, 0
    local gap: any = {}
    for index, entry in ipairs(list) do
        local label = type(entry) == "table" and tostring(entry.text or "?") or tostring(entry)
        local text = " " .. label .. " "
        local room = cells(text) + 2
        if used + room > span then break end
        local style = index == current and styles.face_bold or styles.face_dim
        parts[#parts + 1] = bezel(style:render(text), false)
        hits[#hits + 1] = {row = top, from = left + used, to = left + used + room - 1,
                           index = index, tab = label}
        if index == current then gap.from, gap.to = used, used + room - 1 end
        used = used + room
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end
    target:put(left, top, table.concat(parts), span)

    local edge = {}
    for column = 0, span - 1 do
        if gap.from ~= nil and column >= gap.from and column <= gap.to then
            edge[#edge + 1] = styles.face:render(" ")
        elseif column == 0 then
            edge[#edge + 1] = styles.light:render(glyphs.bevel.corner_light)
        else
            edge[#edge + 1] = styles.light:render(glyphs.bevel.top)
        end
    end
    target:put(left, top + 1, table.concat(edge), span)

    local blank = bezel(styles.face:render(string.rep(" ", span - 2)), false)
    for row = 2, height - 2 do
        target:put(left, top + row, blank, span)
    end
    target:put(left, top + height - 1, widgets.edge_bottom(span, false), span)

    return hits
end

return widgets
