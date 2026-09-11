-- The shell's pixel theme: what a person sees instead of the character grid.
--
-- A separate entry, not a branch inside `chrome`, by the same rule as the
-- explorer's: an entry that declared `gfx` does not load AT ALL on a runtime
-- without it. Put the pixels in `chrome` and the cell path would die together
-- with the graphics, and there would be no fallback path (FR-005 §8b) left.
--
-- ─── THE FILL STAYS IN CELLS, AND THAT IS THE MAIN THING HERE ─────────────
--
-- The teal desktop, the grey face of the taskbar, the menu background — these
-- are CELL styles, not pictures (FR-005 §3a). Only what has its boundary
-- running INSIDE a cell is drawn in pixels: bevels, icons, captions.
--
-- The reason is the cost: it comes from the number of pixels, not from the
-- complexity of the picture. A single-color 1000×540 desktop encodes in 43 ms
-- and weighs 2.6 KB — the encoder walks every pixel. And a raster over the
-- whole desktop covers the rows of window content, and any keystroke in bash
-- repaints those rows, that is, sends the desktop again. Forty-seven
-- milliseconds per keystroke — exactly what we get away from by not drawing
-- the whole screen.
--
-- `fill` fills the desktop with cells; `window_background` fills each window
-- before its content; `paint` returns rasters and hits.
--
-- ─── WHAT IS SLICED BY ROWS ─────────────────────────────────────────────
--
-- The window frame is cut into four pieces (FR-005 §3), because the side edges
-- share rows with the content and are resent on every keystroke, while the
-- title and the bottom are not. The taskbar lies on its own row, where
-- windows do not go. Every desktop icon is its own placement: an icon changes
-- when it is moved or selected, and does not drag its neighbours along.

local gfx = require("gfx")

local chrome = require("chrome")
local palette = require("palette")
local pixels = require("pixels")
local rasters = require("rasters")
local widgets = require("widgets")
local explorer_layout = require("explorer_layout")
local explorer_pixels = require("explorer_pixels")

-- View windows: the content is drawn not by a process but by a pure `render`
-- library named in the window's entry (FR-005 §4b). The compositor cannot
-- call it — `require` only knows the declared imports, not an arbitrary id
-- from the registry — so the theme calls it, and every such library is
-- imported here STATICALLY and named in VIEWS by the id of its entry. A window
-- that named a render that is not in VIEWS gets not emptiness but a text with
-- the reason.
local picture_render = require("picture_render")
local sdk_render = require("sdk_render")

local color = palette.exact

local chrome_pixels = {}

-- The theme keeps rasters between frames, and there is nowhere else to keep
-- them: the `paint` contract carries no state. So this is module state, one
-- per process — and there is only one process here, the shell.
local store = rasters.store()
local clients: any = {}

-- A flag for the compositor: by it, it decides that the theme can do pixels.
chrome_pixels.pixel = true
chrome_pixels.content_colors = chrome.content_colors

-- The taskbar at the bottom, the desktop on top. The pixel grid takes the cell
-- size into account.
local geometry = require("geometry")
local whole = geometry.whole

-- Paint and input share these cell rectangles. Pixel decoration stays inside.
local unit: any = {w = 10, h = 20}

-- render entry id → library. The contract is the same for all:
--   lib.placement(window, inner, cell, fonts, store) -> placement | list | nil, reason
-- `inner` is the rectangle INSIDE the frame in cells, `cell` is the cell size,
-- `fonts` is the theme's {face, bold}, `store` is the theme's raster store
-- (whoever took a raster from it, that one's placement survives the frame
-- without a store of its own).
-- Explorer shares layout with its controller and keeps four cached slices.
local function explorer_placement(window: any, inner: any, cell: any, fonts: any)
    local client = clients[window.id] or rasters.store()
    clients[window.id] = client
    local state: any = window.content_state or {title = "My Computer", objects = {}}
    local plan = explorer_layout.layout(state, inner.cols, inner.rows,
        explorer_layout.pixel_metrics(cell.w, cell.h))
    local placed = explorer_pixels.paint(client, plan, cell, fonts, "client:" .. window.id)
    for _, placement in ipairs(placed) do
        placement.x = placement.x + inner.x - 1
        placement.y = placement.y + inner.y - 1
    end
    return placed
end

local VIEWS: any = {
    ["butschster.windows.sdk:render"] = sdk_render,
    ["butschster.windows.explorer:render_pixels"] = {placement = explorer_placement},
    ["butschster.windows.viewers:picture_render"] = picture_render,
}
function chrome_pixels.forget(id)
    picture_render.forget(id)
end
function chrome_pixels.renders(reference)
    return VIEWS[tostring(reference)] ~= nil
end

-- The title metrics follow Windows 95, in pixels: above the blue bar, two rows
-- of the frame (face and light), the bar itself 18 px, buttons 16×14 two
-- pixels from its edges, the window frame four pixels.
--
-- The bar lives in ONE terminal row as long as the row is no shorter than
-- 16 px, and shrinks to fit it: at a 20 px cell that is exactly the original's
-- 18 px, at 16 — 14 px with 12×10 buttons. Otherwise the title would take two
-- rows and leave a grey strip under itself, which is read as an error; the bar
-- takes a second row only where even 14 px do not fit in one (a cell under
-- 16).
local TITLE_TOP = 3
local TITLE_HEIGHT = 18
local TITLE_LEAST = 14
local TITLE_BUTTON_H = 14
-- The blue gap between the button and the frame; the width of the window
-- frame.
local TITLE_MARGIN = 2
local FRAME = 4
local function header_rows(): integer
    return whole(math.max(1, (TITLE_TOP - 1 + TITLE_LEAST + whole(unit.h) - 1) // whole(unit.h)))
end
local function title_height(): integer
    local room = header_rows() * whole(unit.h) - (TITLE_TOP - 1)
    return whole(math.max(TITLE_LEAST, math.min(TITLE_HEIGHT, room)))
end
-- A button is four pixels shorter than the bar and two wider than its own
-- height: 16×14 with an 18 bar, 12×10 with 14.
local function button_size(): (integer, integer)
    local h = whole(title_height() - (TITLE_HEIGHT - TITLE_BUTTON_H))
    return h + 2, h
end

function chrome_pixels.use_cell_size(w: any, h: any)
    unit = {w = math.max(1, whole(w)), h = math.max(1, whole(h))}
end

local function taskbar_rows(): integer
    return whole(math.max(1, (28 + whole(unit.h) - 1) // whole(unit.h)))
end

function chrome_pixels.layout(width: any, height: any)
    return {top = 0, bottom = taskbar_rows()}
end

function chrome_pixels.window_insets(window)
    return {top = header_rows(), bottom = 1, left = 1, right = 1}
end

function chrome_pixels.icon_grid()
    local drawn = math.max(3, (68 + whole(unit.h) - 1) // whole(unit.h))
    return {w = math.max(6, (88 + whole(unit.w) - 1) // whole(unit.w)),
            h = drawn, drawn = drawn, left = 2}
end

-- Title buttons: "minimize" and "maximize" stand flush, "close" stands apart,
-- two blue pixels from the frame. All of this is in pixels, while the mouse
-- moves in cells, so every button gets ITS OWN cells and is drawn only inside
-- them: a pixel of one button in its neighbour's cell would press the
-- neighbour.
--
-- Hence the only departure from the original at a 10 px cell: the joined pair
-- is split exactly on the cell boundary, and "close" together with the gap and
-- the frame has to fit into its own two cells — it is two pixels narrower, and
-- the gap before it is four pixels instead of two. At an 8 px cell everything
-- matches pixel for pixel.
function chrome_pixels.title_buttons(window: any): any
    local set = chrome.buttons_for(window)
    local out = {}
    if #set == 0 then return out end
    local cw = whole(unit.w)
    local bw, bh = button_size()
    local span = math.max(1, (bw + cw - 1) // cw)
    -- The last button gives up to two pixels of width before it takes one
    -- more cell.
    local last_span = span
    while last_span * cw - FRAME - TITLE_MARGIN < bw - 2 do last_span = last_span + 1 end
    local last_w = math.min(bw, last_span * cw - FRAME - TITLE_MARGIN)
    local total = (#set - 1) * span + last_span
    local from = whole(window.x) + whole(window.w) - total
    if from <= whole(window.x) + 3 then return out end
    local width = whole(window.w) * cw
    local top = TITLE_TOP + (title_height() - bh) // 2
    for index, button in ipairs(set) do
        local left = from + (index - 1) * span
        local cells = index == #set and last_span or span
        local rect: any
        if index == #set then
            rect = {x = width - FRAME - TITLE_MARGIN - last_w + 1, y = top, w = last_w, h = bh}
        else
            local start = (left - whole(window.x)) * cw + 1
            -- In the joined pair the first is pressed to the right edge of its
            -- cells, the second to the left: this way they meet exactly on
            -- the cell boundary.
            local joined = #set > 2 and index == #set - 1
            rect = {x = joined and start or start + span * cw - bw, y = top, w = bw, h = bh}
        end
        out[#out + 1] = {id = button.id, from = left, to = left + cells - 1, rect = rect,
            row = whole(window.y) + (rect.y - 1) // whole(unit.h),
            bottom_row = whole(window.y) + (rect.y + rect.h - 2) // whole(unit.h)}
    end
    return out
end

function chrome_pixels.title_button_at(window: any, x: any, y: any)
    for _, button in ipairs(chrome_pixels.title_buttons(window)) do
        if y >= button.row and y <= button.bottom_row and x >= button.from and x <= button.to then return button.id end
    end
    return nil
end

-- The compositor calls this immediately before each window's content, in z order.
function chrome_pixels.window_background(canvas, window: any)
    local style = chrome.content_colors(window) and widgets.styles.console
        or (window.window_type == "dialog" and widgets.styles.face or widgets.styles.field)
    local blank = style:render(string.rep(" ", math.max(0, whole(window.w))))
    for row = 0, whole(window.h) - 1 do
        canvas:put(whole(window.x), whole(window.y) + row, blank, whole(window.w))
    end
end

-- ─── fill in cells ───────────────────────────────────────────────────────
--
-- Exactly what `chrome.fill` does in character mode, and NOTHING more: there
-- are no icons here, they are in pixels.
function chrome_pixels.fill(canvas, width: any, height: any, state)
    canvas:clear(widgets.styles.desktop:render(" "))

    local h = whole(height)
    local w = whole(width)
    if h < 1 or w < 1 then return {} end
    if type(state) == "table" and state.bare then return {} end

    -- The taskbar face: there will be spaces under the pictures anyway, but a
    -- row not painted with the face shows the terminal's color in the gaps
    -- between placements.
    for row = math.max(1, h - taskbar_rows() + 1), h do
        canvas:put(1, row, widgets.styles.face:render(string.rep(" ", w)), w)
    end
    return {}
end

-- The farewell screen in pixels: a black fill in cells, the caption as a
-- raster in the theme's bold font. Without a font — the caption in cells, as
-- in the character theme; a black screen without words would read as a hung
-- terminal.
chrome_pixels.FAREWELL_HOLD = chrome.FAREWELL_HOLD

-- farewell_raster(cell, width, height) -> raster, column, row | nil
--
-- The caption in a large font in two or three lines in the center, as in the
-- original. Separate from `farewell`, so that the PNG probe can draw it
-- without a canvas.
function chrome_pixels.farewell_raster(cell: any, width: any, height: any): (any, any, any)
    local fonts: any = chrome_pixels.fonts
    local font: any = type(fonts) == "table" and (fonts.display or fonts.bold or fonts.face) or nil
    if not font then return nil, nil, nil end
    local w, h = whole(width), whole(height)
    local cw, ch = whole(cell.w), whole(cell.h)

    -- Lines are broken by measured width, no wider than two thirds of the
    -- screen: in the original the caption takes the middle, it does not
    -- stretch from edge to edge.
    local room = (w * cw) * 2 // 3
    local lines = pixels.wrap(font, chrome.FAREWELL_TEXT, room, 4)
    if #lines == 0 then return nil, nil, nil end
    local line_h = whole(font:height())
    local widest = 0
    for _, line in ipairs(lines) do
        widest = math.max(widest, whole(font:measure(line)))
    end
    local cols = (widest + cw - 1) // cw + 2
    local rows = (line_h * #lines + ch - 1) // ch + 1
    if cols > w or rows > h then return nil, nil, nil end

    local key = chrome.FAREWELL_TEXT .. "\31" .. tostring(font:size()) .. "\31" .. tostring(cols)
    local raster, dirty = store.take("farewell", cols, rows, cell, key)
    if dirty then
        raster:fill(color.farewell_bg)
        local top = (rows * ch - line_h * #lines) // 2
        for index, line in ipairs(lines) do
            local tw = whole(font:measure(line))
            raster:text((cols * cw - tw) // 2, top + (index - 1) * line_h, line,
                {font = font, color = color.farewell_text})
        end
    end
    return raster, (w - cols) // 2 + 1, math.max(1, (h - rows) // 2 + 1)
end

function chrome_pixels.farewell(canvas, width: any, height: any)
    canvas:clear(widgets.styles.farewell:render(" "))
    store.begin()
    local raster, col, row = chrome_pixels.farewell_raster(unit, width, height)
    if not raster then return chrome.farewell(canvas, width, height) end
    store.place("farewell", col, row)
    return {placements = store.frame(unit), hits = {desktop = {}, bars = {}, menu = {}}}
end

-- ─── desktop icons ───────────────────────────────────────────────────────

local function icon_key(item: any, selected)
    return table.concat({
        tostring(item.id), tostring(item.title or ""), tostring(item.kind or ""),
        tostring(item.icon or ""), tostring(item.image or ""), tostring(item.entry or ""), item.broken and "!" or "",
        selected and "1" or "0",
        -- The desktop color is baked into the icon raster: change the color
        -- and the raster is a different one.
        tostring(color.desktop),
    }, "\30")
end

-- The whole icon: the picture and the caption, each as its own placement.
--
-- Every icon has its own placement on purpose. One raster for the whole
-- desktop would cost forty-three milliseconds and would be resent on every
-- keystroke in a window that covered even one of its rows.
local function paint_icon(cell: any, item: any, selected, grid: any)
    local id = "desk:" .. tostring(item.id)
    local cols = grid.w - 1
    local raster, dirty = store.take(id, cols, grid.drawn, cell, icon_key(item, selected))
    if dirty then
        local box = pixels.box(1, 1, cols, grid.drawn, cell)
        -- The background matches the desktop fill; the parts of the raster
        -- covered by windows are cropped before placement.
        raster:rect(1, 1, box.w, box.h, color.desktop)
        chrome_pixels.draw_icon(raster, box, item, selected)
    end
    return id, raster
end

-- The icon picture TOGETHER WITH ITS CAPTION.
--
-- The caption here is not decoration: an icon without it is a picture about
-- which there is nothing to say. The first screenshot of the whole screen
-- showed exactly that — a row of nameless little squares — and neither the
-- probe nor the pieces separately would have shown it: each of them was
-- correct.
--
-- Selection is an inversion over the TEXT, not over the whole column: in
-- Windows 95 the blue rectangle hugs the caption, and it shows where the
-- caption ends.
function chrome_pixels.draw_icon(raster, box: any, item: any, selected)
    local side = 32
    local left = box.x + (box.w - side) // 2
    local top = box.y + 2
    pixels.icon(raster, left, top, item, 32)
    local fonts: any = chrome_pixels.fonts
    local face: any = type(fonts) == "table" and fonts.face or nil
    if not face then return end
    local lines = pixels.wrap(face, item.title, box.w - 4, 2)
    local at = top + side + 3
    for _, line in ipairs(lines) do
        local width = whole(face:measure(line))
        local from = box.x + (box.w - width) // 2
        if selected then raster:rect(from - 2, at - 1, width + 4, 15, color.select_bg) end
        local tint = selected and color.select_fg or color.desktop_text
        if item.broken and not selected then tint = color.desktop_broken end
        raster:text(from, at, line, {font = face, color = tint})
        at = at + 15
    end
end

-- ─── desktop layout failure ──────────────────────────────────────────────
--
-- "The layout was not read" and "the desktop is empty" are different
-- statements, and the cell theme tells them apart (`chrome.fill`). Here
-- `failure` was not read at all: an unreadable layout looked like an empty
-- desktop, and the person went looking for shortcuts they had never lost.
--
-- The place is the same as in the cell theme: the third column, the row under
-- the top of the desktop, no wider than forty-eight cells. The reason is
-- wrapped by MEASURED width, not cut off: in a database error the most needed
-- part — the table name — stands at the end.
local FAILURE_HEADER = "layout not read:"
local FAILURE_WIDTH = 48
local FAILURE_LINES = 3
local FAILURE_PAD = 8
local LINE_STEP = 15

local function paint_failure(cell: any, view: any): any
    local fonts: any = chrome_pixels.fonts
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face
    local cols = math.min(FAILURE_WIDTH, whole(view.width) - 4)
    if cols < 12 or not face then return nil end
    local cw, ch = whole(cell.w), whole(cell.h)
    local row = math.max(1, whole(view.top)) + 1
    local bottom = whole(view.bottom)
    if bottom < 1 or bottom > whole(view.height) then bottom = whole(view.height) end

    -- Lines of the reason — as many as fit above the taskbar, but no more
    -- than three.
    local fit = ((bottom - row + 1) * ch - FAILURE_PAD * 2) // LINE_STEP - 1
    if fit < 1 then return nil end
    local reason = tostring(view.failure)
    local lines = pixels.wrap(face, reason, cols * cw - FAILURE_PAD * 2, math.min(FAILURE_LINES, fit))
    local rows = (FAILURE_PAD * 2 + LINE_STEP * (#lines + 1) + ch - 1) // ch

    local id = "desk:failure"
    local key = reason .. "\31" .. tostring(cols) .. "x" .. tostring(rows) .. "\31" .. tostring(face:size())
    local raster, dirty = store.take(id, cols, rows, cell, key)
    if dirty then
        pixels.panel(raster, 1, 1, cols * cw, rows * ch)
        local left, top = 1 + FAILURE_PAD, 1 + FAILURE_PAD
        raster:text(left, top, FAILURE_HEADER, {font = bold, color = color.alert})
        for index, line in ipairs(lines) do
            raster:text(left, top + index * LINE_STEP, line, {font = face, color = color.face_text})
        end
    end
    -- The desktop layer: a window that covered the plate crops it, like an
    -- icon.
    return {id = id, raster = raster, x = 3, y = row, cols = cols, rows = rows, layer = 0}
end

-- ─── window frame ────────────────────────────────────────────────────────

-- The content of a view window. A failure of any nature — no library, the
-- view is still waiting for state, the library refused — turns into text on
-- the window's face, not into emptiness: an empty window is indistinguishable
-- from "the view is drawn, but there is no data", and the person will go
-- looking for the breakage in the wrong place.
local function paint_view(cell: any, window: any, fonts: any, out, inner: any)
    local lib: any = VIEWS[tostring(window.render)]
    local state: any = type(window.content_state) == "table" and window.content_state or {}
    local placed: any, why: any = nil, nil
    if not lib then
        why = "no renderer for " .. tostring(window.render)
    elseif window.waiting then
        why = type(state.caption) == "string" and state.caption ~= "" and state.caption
            or "waiting for data…"
    else
        -- WITHOUT `pcall`, and this is not an oversight. An error caught by
        -- `pcall` in go-lua breaks upvalues not only of the frame that
        -- called `pcall`, but also of the frames BELOW (the test in
        -- sdk_test, "go-lua: error under pcall…"). Below here is the base
        -- compositor's loop, whose closures write its locals (`refuse` →
        -- `notice`): were we to catch a view's error, the compositor would
        -- silently diverge from itself. So a view must not throw but refuse:
        -- `render.placement` checks the tree with `ui.problem` and returns
        -- the reason, and that becomes the text below.
        placed, why = lib.placement(window, inner, cell, fonts, store)
    end

    if type(placed) == "table" then
        if placed.raster then
            out[#out + 1] = placed
        else
            for _, item in ipairs(placed) do out[#out + 1] = item end
        end
        return
    end

    local face: any = type(fonts) == "table" and fonts.face or nil
    local id = "win:" .. tostring(window.id) .. ":notice"
    local text = tostring(why or "the view returned nothing")
    local raster, dirty = store.take(id, inner.cols, inner.rows, cell,
        text .. "\31" .. tostring(inner.cols) .. "x" .. tostring(inner.rows))
    if dirty then
        raster:fill(color.face)
        if face then
            local lines = pixels.wrap(face, text, inner.cols * cell.w - 16, 6)
            local top = 8
            for _, line in ipairs(lines) do
                raster:text(8, top, line, {font = face, color = color.face_text})
                top = top + 15
            end
        end
    end
    out[#out + 1] = {id = id, raster = raster, x = inner.x, y = inner.y,
                     cols = inner.cols, rows = inner.rows}
end

local function paint_window(cell: any, window: any, focused, fonts: any, out)
    local id = "win:" .. tostring(window.id)
    local w, h = whole(window.w), whole(window.h)
    local head_rows = header_rows()
    if w < 4 or h <= head_rows + 1 then return end
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face
    local inside = chrome.content_colors(window) and color.console_bg
        or ((window.window_type == "dialog" or window.content == "pixels") and color.face or color.field)
    local buttons = chrome_pixels.title_buttons(window)
    local key = table.concat({tostring(window.title), tostring(window.window_type), tostring(window.entry), tostring(window.image),
        focused and "1" or "0", window.maximized and "1" or "0",
        window.resizable == false and "fixed" or "free"}, "\30")
    local head_id = id .. ":head"
    local head, dirty = store.take(head_id, w, head_rows, cell, key)
    if dirty then
        local width, height = w * cell.w, head_rows * cell.h
        head:fill(inside)
        -- The Windows 95 frame: face and black outside, light and shadow
        -- inside — the order is the reverse of a button's, which has the
        -- light outside.
        head:rect(1, 1, width, TITLE_TOP - 1 + title_height(), color.face)
        head:rect(1, 1, FRAME, height, color.face)
        head:rect(width - FRAME + 1, 1, FRAME, height, color.face)
        head:rect(2, 2, width - 2, 1, color.light)
        head:rect(2, 2, 1, height - 1, color.light)
        head:rect(width - 1, 2, 1, height - 1, color.shadow)
        head:rect(width, 1, 1, height, color.frame)
        local title_top, title_h = TITLE_TOP, title_height()
        head:rect(FRAME + 1, title_top, width - FRAME * 2, title_h,
            focused and color.title_active_bg or color.title_idle_bg)
        -- Reserve actual title-button rectangles before clipping text.
        local text_right = #buttons > 0 and buttons[1].rect.x - 4 or width - FRAME - TITLE_MARGIN
        local caption_x = FRAME + 5
        -- The 16 px icon is there only where it fits in the bar: in 14 px it
        -- would lie on the frame.
        if (window.window_type == nil or window.window_type == "app") and title_h >= 16 then
            pixels.icon(head, FRAME + 3, title_top + (title_h - 16) // 2, {kind = "window", image = window.image}, 16)
            caption_x = FRAME + 3 + 16 + 4
        end
        if bold then
            local caption = pixels.ellipsize(bold, window.title, text_right - caption_x)
            head:text(caption_x, title_top + (title_h - whole(bold:height())) // 2, caption,
                {font = bold, color = focused and color.title_active_fg or color.title_idle_fg})
        end
        for _, button in ipairs(buttons) do
            local rect = button.rect
            pixels.button(head, rect.x, rect.y, rect.w, rect.h, {}, cell)
            pixels.caption_mark(head, button.id, rect.x, rect.y, rect.w, rect.h, color.face_text)
        end
    end
    out[#out + 1] = {id = head_id, raster = head, x = window.x, y = window.y, cols = w, rows = head_rows}
    local body = h - head_rows - 1
    for _, side in ipairs({"left", "right"}) do
        local edge_id = id .. ":" .. side
        local edge, edge_dirty = store.take(edge_id, 1, body, cell, inside)
        if edge_dirty then
            local width, height = cell.w, body * cell.h
            edge:fill(inside)
            if side == "left" then
                edge:rect(1, 1, FRAME, height, color.face)
                edge:rect(2, 1, 1, height, color.light)
            else
                edge:rect(width - FRAME + 1, 1, FRAME, height, color.face)
                edge:rect(width - 1, 1, 1, height, color.shadow)
                edge:rect(width, 1, 1, height, color.frame)
            end
        end
        out[#out + 1] = {id = edge_id, raster = edge,
            x = side == "left" and window.x or window.x + w - 1,
            y = window.y + head_rows, cols = 1, rows = body}
    end
    local foot_id = id .. ":foot"
    local foot, foot_dirty = store.take(foot_id, w, 1, cell, inside)
    if foot_dirty then
        local width, height = w * cell.w, cell.h
        foot:fill(inside)
        foot:rect(1, 1, FRAME, height, color.face)
        foot:rect(width - FRAME + 1, 1, FRAME, height, color.face)
        foot:rect(1, height - FRAME + 1, width, FRAME, color.face)
        foot:rect(2, 1, 1, height - 2, color.light)
        foot:rect(2, height - 1, width - 2, 1, color.shadow)
        foot:rect(width - 1, 1, 1, height - 1, color.shadow)
        foot:rect(1, height, width, 1, color.frame)
        foot:rect(width, 1, 1, height, color.frame)
    end
    out[#out + 1] = {id = foot_id, raster = foot, x = window.x, y = window.y + h - 1, cols = w, rows = 1}

    -- A view window: there is no process inside the frame, the theme puts the
    -- content. The rectangle is the same one an ordinary window's viewport
    -- would get — by the theme's insets.
    if window.content == "pixels" and w > 2 and body > 0 then
        paint_view(cell, window, fonts, out,
            {x = window.x + 1, y = window.y + head_rows, cols = w - 2, rows = body})
    end
end

-- Taskbar measures in pixels: a window button of 16 cells (160 px at a 10 px
-- cell, as in Windows 95), a clock of 9 cells and one cell of gap before it.
-- The layout rules are `chrome.taskbar_layout`'s, shared with the cell theme.
local TASK_SPAN = 16
local CLOCK_SPAN = 9
-- Room around a tray caption inside its cells, in pixels: three on each side
-- plus the rounding up to whole cells.
local TRAY_PAD = 8

local function paint_bars(cell: any, state: any, fonts: any, out, hits)
    local w, h = whole(state.width), whole(state.height)
    local rows = taskbar_rows()
    local top = h - rows + 1
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face
    local status = type(state.status) == "string" and state.status or ""
    local key = {tostring(w), tostring(state.clock or ""), tostring(state.focused_id or ""),
                 (state.menu and not state.menu.anchor) and "open" or "closed", status}
    for _, window in ipairs(state.windows or {}) do
        key[#key + 1] = tostring(window.id) .. ":" .. tostring(window.title)
            .. ":" .. tostring(window.image) .. ":" .. tostring(window.minimized)
    end
    -- Tray captions are measured with the face they are drawn with; the
    -- layout gets whole cells, so a hit never shares a cell with the clock.
    local tray: any = type(state.tray) == "table" and state.tray or {}
    local tray_widths = {}
    local cw = math.max(1, whole(cell.w))
    for index, item in ipairs(tray) do
        local text = tostring(item.text or "")
        local px = face and whole(face:measure(text)) or #text * 7
        tray_widths[index] = (px + TRAY_PAD + cw - 1) // cw
        key[#key + 1] = "tray:" .. text
    end
    local bar, dirty = store.take("bars", w, rows, cell, table.concat(key, "\30"))
    local width, height = w * whole(cell.w), rows * whole(cell.h)
    local button_h = height - 6
    local button_y = 1 + (height - button_h) // 2
    local start_span = math.max(6, (whole(bold and bold:measure("Start") or 28) + 44 + whole(cell.w) - 1) // whole(cell.w))
    local plan: any = chrome.taskbar_layout(w, state.windows or {}, {start = start_span, gap = 0,
        task_min = TASK_SPAN, task_max = TASK_SPAN, clock = CLOCK_SPAN, clock_gap = 1, tray = tray_widths})
    if dirty then
        bar:fill(color.face)
        bar:rect(1, 1, width, 1, color.light)
        bar:rect(1, 2, width, 1, color.face)
        -- The same button as everywhere: pressed while the menu is open.
        pixels.button(bar, 3, button_y, start_span * cell.w - 5, button_h,
            {label = "", pressed = state.menu ~= nil and state.menu.anchor == nil}, cell)
        local shift = (state.menu and not state.menu.anchor) and 1 or 0
        pixels.flag(bar, 9 + shift, button_y + (button_h - 16) // 2 + shift)
        if bold then bar:text(31 + shift, button_y + (button_h - 15) // 2 + shift,
            "Start", {font = bold, color = color.face_text}) end
    end
    hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
        from = plan.start.from, to = plan.start.to, action = "menu"}
    for _, entry in ipairs(plan.tasks) do
        local task: any = entry
        local window: any = task.window
        local span = task.to - task.from + 1
        if dirty then
            local left = (task.from - 1) * cell.w + 1
            local pressed = window.id == state.focused_id and not window.minimized
            local shift = pressed and 1 or 0
            pixels.button(bar, left, button_y, span * cell.w - 2, button_h,
                {id = window.id, label = "", font = face, pressed = pressed}, cell)
            pixels.icon(bar, left + 6 + shift, button_y + (button_h - 16) // 2 + shift,
                {kind = "window", image = window.image}, 16)
            if face then
                bar:text(left + 28 + shift, button_y + (button_h - 15) // 2 + shift,
                    pixels.ellipsize(face, window.title, span * cell.w - 36),
                    {font = face, color = color.face_text})
            end
        end
        hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
            from = task.from, to = task.to, id = window.id}
    end
    -- The status line — in what is left between the window buttons and the
    -- clock, as in the cell theme (`chrome.bars`). Without it the
    -- compositor's messages are lost — "could not open: …", the complaint
    -- about a bad frame from the theme — which are shown nowhere else: the
    -- terminal host's log is muted.
    local room: any = plan.status
    if dirty and face and status ~= "" and room then
        local caption = pixels.ellipsize(face, status, (room.to - room.from + 1) * cell.w - 8)
        if caption ~= "" then
            bar:text((room.from - 1) * cell.w + 5, button_y + (button_h - 15) // 2, caption,
                {font = face, color = color.shadow})
        end
    end
    -- The notification area: one sunken box around the tray items and the
    -- clock, as in Windows 95, with each caption in its own cells.
    local clock: any = plan.clock
    local first: any = plan.tray[1]
    local last: any = plan.tray[#plan.tray]
    if dirty and (first or clock) then
        local from = first and first.from or clock.from
        local to = clock and clock.to or last.to
        pixels.bevel(bar, (from - 1) * cell.w + 1, button_y, (to - from + 1) * cell.w - 4, button_h, false)
    end
    for _, entry in ipairs(plan.tray) do
        local slot: any = entry
        local item: any = tray[slot.index]
        if dirty then
            pixels.label(bar, (slot.from - 1) * cell.w + 1, button_y, (slot.to - slot.from + 1) * cell.w,
                button_h, tostring(item.text or ""), face, color.face_text)
        end
        if type(item.entry) == "string" and item.entry ~= "" then
            hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
                from = slot.from, to = slot.to, entry = item.entry}
        end
    end
    if clock then
        if dirty then
            local x, cw = (clock.from - 1) * cell.w + 1, (clock.to - clock.from + 1) * cell.w - 4
            pixels.label(bar, x, button_y, cw, button_h,
                tostring(state.clock or ""), face, color.face_text)
        end
        if chrome_pixels.clock_entry then
            hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
                from = clock.from, to = clock.to, entry = chrome_pixels.clock_entry}
        end
    end
    out[#out + 1] = {id = "bars", raster = bar, x = 1, y = top, cols = w, rows = rows}
end

-- ─── Start menu ──────────────────────────────────────────────────────────
--
-- The cascade layout is computed by `chrome.menu_layout` — the same function
-- by which the menu is drawn in characters. A second computation would drift
-- from the first, and a click would land on the neighbouring item in one of
-- the two modes, while both frames would look right.
--
-- Every panel is its own placement. The cascade panels share rows with each
-- other, and that is unavoidable: they stand side by side. But the menu is
-- open exactly while the person is looking at it — there is no typing at that
-- time, and nothing to repaint them.
--
-- A closed menu disappears by ABSENCE from the list of placements, not by
-- drawing over it: `store.frame` throws away whatever the frame did not name.

local function menu_key(box: any)
    local parts = {tostring(box.x), tostring(box.y), tostring(box.w), tostring(box.h),
                   tostring(box.banner), box.context and "ctx" or ""}
    for _, entry in ipairs(box.lines) do
        local line: any = entry
        parts[#parts + 1] = table.concat({
            tostring(line.kind), tostring(line.text), tostring(line.tail), tostring(line.rows),
            tostring(line.entry), tostring(line.image), tostring(line.separator_before),
            line.selected and "1" or "0", line.bold and "b" or "",
            line.dim and "d" or "", tostring(line.banner_letter),
        }, "\30")
    end
    return table.concat(parts, "\31")
end

local function paint_menu_panel(cell: any, box: any, id, fonts: any)
    local face: any = type(fonts) == "table" and fonts.face or nil
    -- The type is NAMED, not smoothed over with `any`, and the cast here is
    -- more honest than a stub.
    --
    -- The font arrives as a field of an ordinary table, through `use_fonts`,
    -- so it has no type. Without the type name we would have to declare `any`
    -- on the raster itself — and switch off the COORDINATE check along with
    -- it, and the call below recently had `y = 0`, because of which the line
    -- went off the edge of the raster entirely, silently.
    --
    -- The cast asserts exactly what must be true anyway: `use_fonts` is
    -- called with the result of `gfx.font`, and anything else would crash in
    -- the runtime on the very first call.
    local given: any = type(fonts) == "table" and fonts.bold or face
    local bold = given :: gfx.Font

    local raster, dirty = store.take(id, box.w, box.h, cell, menu_key(box))
    if dirty then
        local area = pixels.box(1, 1, box.w, box.h, cell)
        pixels.panel(raster, 1, 1, area.w, area.h)

        -- The vertical "Windows 95" caption is a ROTATED STRING, not a
        -- column of letters.
        --
        -- In cells it could not be otherwise: there a letter takes a cell,
        -- and the caption was laid out along the panel rows — and when the
        -- panel got shorter than nine rows, the caption vanished SILENTLY, a
        -- letter per row. In pixels it has its own height, unrelated to the
        -- number of menu items.
        --
        -- The text is drawn horizontally into a temporary raster and laid
        -- down rotated by 270°: this way it reads bottom to top, as on the
        -- reference. The temporary raster is not placed on the screen and
        -- lives only inside the repaint — nobody's version moves because of
        -- it.
        if whole(box.banner) > 0 and bold then
            local strip = pixels.box(1, 1, box.banner, box.h, cell)
            raster:rect(2, 2, strip.w - 2, strip.h - 4, color.shadow)

            -- The same text as the cell theme's (`chrome.MENU_BANNER`), just
            -- not in capitals: in pixels the caption is set in a font, not
            -- one letter per row.
            local label = tostring(chrome.MENU_BANNER or "")
            local text_w = whole(bold:measure(label))
            local text_h = 16
            if label ~= "" and text_w > 0 then
                local temp = gfx.raster(text_w, text_h)
                temp:fill(color.shadow)

                -- The pen is taken out into a variable with `any` ON PURPOSE
                -- and pointwise.
                --
                -- `temp` is a real `gfx.Raster`, not a raster from the
                -- store, so its arguments are checked for real; the font,
                -- however, arrives here through `use_fonts`, as a field of an
                -- ordinary table, and has no `gfx.Font` type. Silencing this
                -- by declaring `any` on the raster itself would mean
                -- switching off the COORDINATE check along with it — this
                -- very call recently had `y = 0`, and the line went off the
                -- edge of the raster entirely, silently.
                --
                -- Coordinates are ONE-BASED, and the linter now checks this.
                temp:text(1, 1, label, {font = bold, color = color.select_fg})

                -- After rotation, width and height swap places: the width of
                -- the picture on screen is the height of the line, and vice
                -- versa.
                local room = strip.h - 6
                local at_y = 3
                if text_w < room then at_y = strip.h - 3 - text_w end
                raster:blit(temp, 2 + (strip.w - 2 - text_h) // 2, at_y, {rotate = 270})
            end
        end

        local text_left = pixels.box(whole(box.banner) + 1, 1, 1, 1, cell).x + 8
        for index, entry in ipairs(box.lines) do
            local line: any = entry
            local top = (whole(line.row or (box.y + index)) - box.y) * cell.h + 1
            local line_h = math.max(1, whole(line.rows or 1)) * cell.h
            local inset = line_h >= 28 and 4 or 2

            -- Selection is a strip across the whole list width, as in
            -- Windows 95: in a menu the blue rectangle hugs the whole row,
            -- not the caption, unlike an icon on the desktop.
            local tint = color.face_text
            if line.selected then
                -- The strip goes to the panel's right edge, not to the end
                -- of the "list" in cells: the list width was computed with
                -- the frame cell on the right.
                local list_x = pixels.box(whole(box.banner) + 1, 1, 1, 1, cell).x
                raster:rect(list_x + 2, top + inset, area.w - list_x - 4, line_h - inset * 2, color.select_bg)
                tint = color.select_fg
            elseif line.dim then
                tint = color.shadow
            end

            -- Root entries use their native 32px frame; submenus use 16px.
            local mark_size = whole(box.banner) > 0 and 32 or 16
            local mark_top = top + (line_h - mark_size) // 2
            -- The context menu has no icons, as in Windows 95.
            if box.context then
                mark_size = 0
            elseif line.kind == "group" then
                pixels.icon(raster, text_left, mark_top, {kind = "group", image = "programs"}, mark_size)
            elseif line.kind == "item" then
                pixels.icon(raster, text_left, mark_top,
                    {kind = "program", entry = line.entry, image = line.image}, mark_size)
            elseif line.kind == "user" then
                pixels.icon(raster, text_left, mark_top, {kind = "program", image = line.image or "user"}, mark_size)
            end

            if line.separator_before then
                raster:rect(text_left, top, area.w - text_left - 3, 1, color.shadow)
                raster:rect(text_left, top + 1, area.w - text_left - 3, 1, color.light)
            end
            local font = line.bold and bold or face
            if font then
                local label_left = text_left
                if line.kind ~= "hint" then label_left = text_left + mark_size + (box.context and 6 or 10) end
                raster:text(label_left, top + (line_h - 15) // 2, line.label or line.text,
                    {font = font, color = tint})

                -- The submenu arrow — with the same primitive and at the
                -- right edge of the list, as in Windows 95.
                if line.arrow then
                    -- At the panel's right edge, as in Windows 95: 4 px to the
                    -- edge.
                    pixels.mark_submenu(raster, area.w - 3 - 4 - 8, top + (line_h - 8) // 2, 8, tint)
                end
            end
        end
    end
    return raster
end

-- ─── the whole frame ─────────────────────────────────────────────────────
--
-- paint(state, cell_w, cell_h) -> {placements, hits}
--
-- Hits arrive in GROUPS `{desktop, bars, menu}`, not as a flat list: `id`
-- means different things in the three lists, and a flat one would have to be
-- parsed by guesswork.
-- Subtract higher windows in cell space before handing images to the surface.
-- Otherwise a lower window's border or a desktop icon erases the foreground text.
local function subtract(rect: any, cover: any): any
    local x, y = whole(rect.x), whole(rect.y)
    local right, bottom = x + whole(rect.cols), y + whole(rect.rows)
    local cx, cy = whole(cover.x), whole(cover.y)
    local left = math.max(x, cx)
    local top = math.max(y, cy)
    local far = math.min(right, cx + whole(cover.w))
    local low = math.min(bottom, cy + whole(cover.h))
    if left >= far or top >= low then return {rect} end
    local pieces = {}
    if top > y then pieces[#pieces + 1] = {x = x, y = y, cols = right - x, rows = top - y} end
    if low < bottom then pieces[#pieces + 1] = {x = x, y = low, cols = right - x, rows = bottom - low} end
    if left > x then pieces[#pieces + 1] = {x = x, y = top, cols = left - x, rows = low - top} end
    if far < right then pieces[#pieces + 1] = {x = far, y = top, cols = right - far, rows = low - top} end
    return pieces
end

-- `menus` are the rectangles of the menu panels in cells. The menu is the top
-- layer for EVERYTHING that is not the menu: windows, icons, the failure
-- plate, the taskbar.
--
-- The list order is not enough for this, and that is not a guess but the
-- runtime surface (service/terminal/surface.go, appendPlacements): it resends
-- only what is new, changed, or covers a repainted row, and sixel has no z
-- order at all. An open menu does not change and is not resent; the raster of
-- a window under it is resent on each of its ticks — and lies over the menu.
-- A piece of the window that is not under the menu cannot lie over the menu.
local function visible_placements(placements: any, windows: any, menus: any, cell: any): any
    local out = {}
    for _, source in ipairs(placements) do
        local covers: any = {}
        if source.layer ~= nil then
            for index = whole(source.layer) + 1, #windows do
                local cover = windows[index]
                if not cover.minimized then covers[#covers + 1] = cover end
            end
        end
        if not source.top then
            for _, cover in ipairs(menus) do covers[#covers + 1] = cover end
        end
        local pieces = {source}
        for _, cover in ipairs(covers) do
            local next_pieces = {}
            for _, piece in ipairs(pieces) do
                for _, kept in ipairs(subtract(piece, cover)) do next_pieces[#next_pieces + 1] = kept end
            end
            pieces = next_pieces
        end
        for _, piece in ipairs(pieces) do
            if piece == source then
                out[#out + 1] = source
            else
                local dx, dy = piece.x - source.x, piece.y - source.y
                local id = source.id .. ":crop:" .. dx .. ":" .. dy .. ":" .. piece.cols .. ":" .. piece.rows
                local key = tostring(source.cols) .. ":" .. source.rows .. ":" .. source.raster:version()
                local raster, dirty = store.take(id, piece.cols, piece.rows, cell, key)
                if dirty then raster:blit(source.raster, 1 - dx * cell.w, 1 - dy * cell.h) end
                out[#out + 1] = {id = id, raster = raster, x = piece.x, y = piece.y,
                    cols = piece.cols, rows = piece.rows}
            end
        end
    end
    return out
end

function chrome_pixels.paint(state: any, cell_w: any, cell_h: any)
    chrome_pixels.use_cell_size(cell_w, cell_h)
    local cell = unit
    local view: any = type(state) == "table" and state or {}
    local fonts = chrome_pixels.fonts
    local grid = chrome_pixels.icon_grid()

    store.begin()
    local out = {}
    local hits: any = {desktop = {}, bars = {}, menu = {}}

    -- Desktop icons are under the windows, so they go first: the list order is
    -- the painting order.
    --
    -- The layout failure goes instead of the icons, not next to them as in the
    -- cell theme: nobody promised the icons of an unread layout.
    local items: any = view.items or {}
    if view.failure then
        items = {}
        local plate: any = paint_failure(cell, view)
        if plate then out[#out + 1] = plate end
    end
    for _, entry in ipairs(items) do
        local item: any = entry
        -- The place follows the same clipping rule as in the cell theme.
        local x, y = chrome.desktop_spot(item, view.top, view.bottom, view.width, grid.drawn)
        if x then
            local selected = view.selected ~= nil and item.id == view.selected
            local id, raster = paint_icon(cell, item, selected, grid)
            store.place(id, x, y)
            out[#out + 1] = {id = id, raster = raster, x = x, y = y,
                             cols = grid.w - 1, rows = grid.drawn, layer = 0}
            -- A hit on EVERY row of the icon, not one for the whole height.
            --
            -- The compositor checks `event.y == spot.row` — exactly one row —
            -- and does not know the `bottom_row` field at all. One hit for
            -- three rows would mean an icon that is pressed on the picture
            -- and not pressed on the caption. Silently: a click on the
            -- caption simply does nothing.
            --
            -- The shape is the same as `chrome.fill`'s in character mode, and
            -- that is no coincidence: there is one composer for both modes,
            -- and a hit it cannot read is indistinguishable from a missing
            -- one.
            -- The hit table is `chrome.desktop_hit`'s, one for both themes.
            for row = y, y + grid.drawn - 1 do
                hits.desktop[#hits.desktop + 1] = chrome.desktop_hit(item, row, x, x + grid.w - 2)
            end
        end
    end

    local live_clients: any = {}
    for index, entry in ipairs(view.windows or {}) do
        local window: any = entry
        if clients[window.id] then live_clients[window.id] = clients[window.id] end
        if not window.minimized then
            local first = #out + 1
            paint_window(cell, window, view.focused_id == window.id, fonts, out)
            if clients[window.id] then live_clients[window.id] = clients[window.id] end
            for at = first, #out do out[at].layer = index end
        end
    end

    clients = live_clients
    -- A bare desktop has no taskbar: this is how the logon screen is drawn,
    -- where there is no Start yet, because there is no user yet either.
    if not view.bare then paint_bars(cell, view, fonts, out, hits) end

    -- The menu over everything: on screen it is over everything too, and the
    -- list order is the painting order.
    if view.menu then
        local menu: any = view.menu
        local shown = chrome.menu_layout(view.width, view.height,
            menu.items, menu.failure, menu.open, menu.cursor, {
                compact = true, bottom = taskbar_rows(),
                anchor = menu.anchor, context_rows = 1,
                user = chrome.session.user,
                root_rows = math.max(1, (32 + cell.h - 1) // cell.h),
                item_rows = math.max(1, (24 + cell.h - 1) // cell.h),
                -- The row width in cells, MINUS the two cells `menu_layout`
                -- will add for the frame: in cells the frame is a cell on
                -- each side, in pixels three pixels, and without the
                -- subtraction they lay as emptiness at the panel's right
                -- edge. The terms are the same as the painter's: 8 px to the
                -- icon, the icon (32 on the root, 16 in a submenu, 0 in the
                -- context menu), the gap to the caption, the caption, the
                -- tail (folder arrow 20, otherwise 8), two edges of 3 px.
                measure = function(label, level, kind)
                    local font: any = fonts and fonts.face
                    local text_w = whole(font and font:measure(label) or 0)
                    local depth = whole(level or 1)
                    local mark = depth == 1 and 32 or (depth == 0 and 0 or 16)
                    local gap = depth == 0 and 6 or 10
                    local tail = kind == "group" and 20 or 8
                    local px = 8 + mark + gap + text_w + tail + 6
                    return math.max(1, whole((px + cell.w - 1) // cell.w) - 2)
                end,
            })

        if shown.notice then
            local id = "menu:notice"
            local raster = paint_menu_panel(cell, shown.notice, id, fonts)
            out[#out + 1] = {id = id, raster = raster, x = shown.notice.x,
                             y = shown.notice.y, cols = shown.notice.w, rows = shown.notice.h, top = true}
        end

        for index, entry in ipairs(shown.panels) do
            local box: any = entry
            -- The placement name is by LEVEL, not by order: the level does not
            -- change while the panel is on screen, and the surface recognises
            -- the same picture.
            local id = "menu:" .. tostring(index)
            local raster = paint_menu_panel(cell, box, id, fonts)
            out[#out + 1] = {id = id, raster = raster, x = box.x, y = box.y,
                             cols = box.w, rows = box.h, top = true}
        end

        for _, hit in ipairs(shown.hits) do hits.menu[#hits.menu + 1] = hit end
    end

    -- Placements are declared through the store, so that `sweep` throws away
    -- whatever the frame did not name: a closed menu disappears by absence
    -- from the list, not by drawing over it.
    --
    -- The menu panels (`top`) are subtracted from everything else — see
    -- `visible_placements`: otherwise a window under the menu, resent on its
    -- tick, lies over the unchanged menu.
    local menus: any = {}
    for _, item in ipairs(out) do
        if item.top then menus[#menus + 1] = {x = item.x, y = item.y, w = item.cols, h = item.rows} end
    end
    out = visible_placements(out, view.windows or {}, menus, cell)
    for _, item in ipairs(out) do store.place(item.id, item.x, item.y) end
    store.frame(cell)

    return {placements = out, hits = hits}
end

-- Fonts are brought by whoever can read files: the theme has neither the
-- rights nor the `fs` module, and that is not a blunder — a font arrives AS
-- BYTES, because reading a file is governed by the process's rights, and a
-- module that opens paths itself would be a road around them.
-- `display` is the large bold for the farewell screen; without it the caption
-- is set in the ordinary bold and looks like a caption, not a screen.
function chrome_pixels.use_fonts(face, bold, display)
    chrome_pixels.fonts = {face = face, bold = bold or face, display = display or bold or face}
end

return chrome_pixels
