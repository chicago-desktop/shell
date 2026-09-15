-- Image viewer: pure drawing.
--
-- This is the `render` of a view window (FR-005 §4b): a library with no
-- runtime and no permissions, called by the THEME in the compositor process.
-- The data is brought by the provider `picture_state` — the window state
-- holds the picture itself (base64), the file name, and how to show it: fit
-- into the window or at a zoom with panning.
--
-- Why the picture travels in the state instead of being read here: the
-- compositor has no permission on drives and must not have one — "drawing in
-- the compositor, permissions outside". Why base64: the message body passes
-- through a transcoder, and a string of arbitrary bytes is exactly what it
-- will one day break on silently.
--
-- Rasters live between frames (FR-005 §4): ONE frame raster is kept per
-- window, and it is redrawn in place only when the picture, the window size
-- or the display mode changed. Otherwise the surface would resend the whole
-- window on every key press in a neighbouring one.

local base64 = require("base64")
local gfx = require("gfx")

local picture_render = {}

-- The entry identifier by which the theme learns that the window is drawn here.
picture_render.ID = "windows.shell.viewers:picture_render"

-- The background around the picture is the grey face, as in dialogs; a
-- picture smaller than the window lies centred, as in Imaging.
picture_render.BACKGROUND = "#c0c0c0"

local geometry = require("geometry")
local whole = geometry.whole

-- Decoded sources, by file key. The key is drive, path and size in bytes:
-- the same file overwritten with other content changes its size almost
-- always, whereas re-decoding base64 every frame is not an option.
local sources = {}
local SOURCE_LIMIT = 8

local function source_key(state: any): string
    return tostring(state.drive) .. "|" .. tostring(state.path) .. "|" .. tostring(state.data)
end

local function remember(key, entry)
    local count = 0
    for _ in pairs(sources) do count = count + 1 end
    if count >= SOURCE_LIMIT then
        -- The oldest — by the access counter; there is no point storing time.
        local oldest, oldest_at = nil, math.huge
        for other, kept in pairs(sources) do
            if kept.at < oldest_at then oldest, oldest_at = other, kept.at end
        end
        if oldest then sources[oldest] = nil end
    end
    sources[key] = entry
end

local tick = 0

-- source(state) -> source raster | nil, reason
function picture_render.source(state: any): (any, any)
    if type(state) ~= "table" then return nil, "no state yet" end
    if state.failure then return nil, tostring(state.failure) end
    local key = source_key(state)
    local kept = sources[key]
    tick = tick + 1
    if kept then
        kept.at = tick
        return kept.raster, nil
    end
    if type(state.data) ~= "string" or state.data == "" then
        return nil, "the picture has not arrived yet"
    end
    local bytes, err = base64.decode(state.data)
    if err or type(bytes) ~= "string" then
        return nil, "picture not decoded: " .. tostring(err)
    end
    local raster, why = gfx.image(bytes :: string)
    if not raster then
        return nil, "picture not opened: " .. tostring(why)
    end
    local w, h = raster:size()
    remember(key, {raster = raster, w = w, h = h, at = tick})
    return raster, nil
end

-- Frames per window: one raster per window, living between frames.
local frames = {}

local function frame_for(window_id: any, px_w: integer, px_h: integer): (any, boolean)
    local kept = frames[window_id]
    if kept and kept.w == px_w and kept.h == px_h then return kept, false end
    local raster = gfx.raster(px_w, px_h)
    kept = {raster = raster, w = px_w, h = px_h, signature = ""}
    frames[window_id] = kept
    return kept, true
end

-- geometry(state, source_w, source_h, px_w, px_h) -> {scale, x, y, w, h}
--
-- Fitting does not enlarge: a 32×32 icon in a 600×400 window stays an icon,
-- not a blurry square. Enlarging is zoom, and it is asked for explicitly.
function picture_render.geometry(state: any, source_w: any, source_h: any, px_w: any, px_h: any): any
    local sw, sh = whole(source_w), whole(source_h)
    local fw, fh = whole(px_w), whole(px_h)
    if sw < 1 or sh < 1 or fw < 1 or fh < 1 then return nil end

    local scale = 1.0
    if state.mode == "zoom" then
        scale = tonumber(state.zoom) or 1
        if scale <= 0 then scale = 1 end
    else
        scale = math.min(fw / sw, fh / sh, 1)
    end

    local w = math.max(1, whole(math.floor(sw * scale + 0.5)))
    local h = math.max(1, whole(math.floor(sh * scale + 0.5)))

    -- Smaller than the window — centred. Larger than the window — the offset
    -- from the state, clamped so that no emptiness is left past the edge of
    -- the picture.
    local x = (fw - w) // 2 + 1
    local y = (fh - h) // 2 + 1
    if w > fw then
        local max_shift = w - fw
        local shift = math.max(0, math.min(max_shift, whole(state.x)))
        x = 1 - shift
    end
    if h > fh then
        local max_shift = h - fh
        local shift = math.max(0, math.min(max_shift, whole(state.y)))
        y = 1 - shift
    end
    return {scale = scale, x = x, y = y, w = w, h = h}
end

-- frame(window_id, state, px_w, px_h) -> frame raster | nil, reason
--
-- Returns ONE AND THE SAME raster as long as nothing has changed: its
-- version does not move, and the surface does not resend it.
function picture_render.frame(window_id: any, state: any, px_w: any, px_h: any): (any, any)
    local fw, fh = whole(px_w), whole(px_h)
    if fw < 1 or fh < 1 then return nil, "the window has no room for the picture" end

    local source, why = picture_render.source(state)
    if not source then return nil, why end
    local kept: any = sources[source_key(state)]
    if not kept then return nil, "the source did not stay in the cache" end

    local box = picture_render.geometry(state, kept.w, kept.h, fw, fh)
    if not box then return nil, "picture with no size" end

    local signature = table.concat({source_key(state), tostring(box.scale),
        tostring(box.x), tostring(box.y), tostring(box.w), tostring(box.h)}, "|")

    local frame, fresh = frame_for(window_id, fw, fh)
    if not fresh and frame.signature == signature then
        return frame.raster, nil
    end

    frame.raster:fill(picture_render.BACKGROUND)
    local shown = source
    if box.w ~= kept.w or box.h ~= kept.h then
        -- Shrinking is smoothed — otherwise a photograph turns into a moiré
        -- mush of pixels; enlarging is stepped — otherwise pixel art gets
        -- blurred, and pixel art is exactly what gets enlarged.
        shown = source:scaled(box.w, box.h, {smooth = box.scale < 1})
    end
    frame.raster:blit(shown, box.x, box.y)
    frame.signature = signature
    return frame.raster, nil
end

-- placement(window, inner, cell) -> placement | nil, reason
--
-- The theme's entry point. `inner` is the rectangle inside the frame in
-- CELLS ({x, y, cols, rows}), `cell` is the cell size in pixels. The
-- placement covers exactly inner, and the compositor erases the characters
-- under it by itself.
function picture_render.placement(window: any, inner: any, cell: any): (any, any)
    if type(window) ~= "table" or type(inner) ~= "table" or type(cell) ~= "table" then
        return nil, "placement needs a window, a rectangle and a cell size"
    end
    local cols, rows = whole(inner.cols), whole(inner.rows)
    local cw, ch = whole(cell.w), whole(cell.h)
    if cols < 1 or rows < 1 or cw < 1 or ch < 1 then
        return nil, "the window has no room for the picture"
    end
    if window.waiting then return nil, "the picture has not arrived yet" end
    local raster, why = picture_render.frame(window.id, window.content_state, cols * cw, rows * ch)
    if not raster then return nil, why end
    return {
        id = "win:" .. tostring(window.id) .. ":content",
        raster = raster,
        x = whole(inner.x), y = whole(inner.y), cols = cols, rows = rows,
    }, nil
end

-- forget(window_id) — the window is closed, the frame is no longer needed.
function picture_render.forget(window_id: any)
    frames[window_id] = nil
end

return picture_render
