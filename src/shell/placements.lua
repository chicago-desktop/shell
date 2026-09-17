-- Rectangle geometry of the pixel theme's placements.
--
-- Moved out of `chrome_pixels.lua` (review, 2026-09-11). Pure: rectangles in
-- cells in, pieces out; the rasters and the store stay with the theme.
local geometry = require("geometry")

local whole = geometry.whole

local placements = {}

-- subtract(rect, cover) -> pieces: what is left of `rect` ({x, y, cols, rows})
-- once `cover` ({x, y, w, h}) is taken away — up to four pieces, or `{rect}`
-- itself when they do not overlap.
--
-- Subtract higher windows in cell space before handing images to the surface.
-- Otherwise a lower window's border or a desktop icon erases the foreground text.
function placements.subtract(rect: any, cover: any): any
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

-- visible(list, windows, menus) -> {{source, piece?}, …} in the order of
-- `list`: `piece` is absent when the source is shown whole.
--
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
function placements.visible(list: any, windows: any, menus: any): any
    local out = {}
    -- The covers depend only on the layer and on whether the source is the
    -- menu: built once per kind, not once per picture. A wallpaper cut in
    -- pieces is hundreds of pictures on one layer.
    local cached: any = {}
    local function covers_of(source: any): any
        local key = (source.layer ~= nil and tostring(whole(source.layer)) or "-") .. (source.top and "t" or "")
        local found: any = cached[key]
        if found ~= nil then return found end
        found = {}
        if source.layer ~= nil then
            for index = whole(source.layer) + 1, #windows do
                local cover = windows[index]
                if not cover.minimized then
                    found[#found + 1] = {x = whole(cover.x), y = whole(cover.y), w = whole(cover.w), h = whole(cover.h)}
                end
            end
        end
        if not source.top then
            for _, cover in ipairs(menus) do
                found[#found + 1] = {x = whole(cover.x), y = whole(cover.y), w = whole(cover.w), h = whole(cover.h)}
            end
        end
        cached[key] = found
        return found
    end
    for _, source in ipairs(list) do
        local covers = covers_of(source)
        -- Most pictures are covered by nothing: no pieces, no tables.
        local x, y = whole(source.x), whole(source.y)
        local right, bottom = x + whole(source.cols), y + whole(source.rows)
        local hit = false
        for _, cover in ipairs(covers) do
            if cover.x < right and x < cover.x + cover.w and cover.y < bottom and y < cover.y + cover.h then
                hit = true
                break
            end
        end
        if not hit then
            out[#out + 1] = {source = source}
        else
            local pieces = {source}
            for _, cover in ipairs(covers) do
                local next_pieces = {}
                for _, piece in ipairs(pieces) do
                    for _, kept in ipairs(placements.subtract(piece, cover)) do next_pieces[#next_pieces + 1] = kept end
                end
                pieces = next_pieces
            end
            for _, piece in ipairs(pieces) do
                -- A piece that is the source itself (nothing covered it) is
                -- shown whole; any other is a crop. Identity, not equality:
                -- `subtract` returns the very rectangle it was given when the
                -- cover misses it.
                if piece == source then
                    out[#out + 1] = {source = source}
                else
                    out[#out + 1] = {source = source, piece = piece}
                end
            end
        end
    end
    return out
end

-- The crop rule. A piece is its own placement, named after the source and its
-- offset and size, so the same crop of the same picture keeps its name between
-- frames; its raster is keyed by the source's size and version, so it is cut
-- again exactly when the source's pixels change.
function placements.crop_id(source: any, piece: any): string
    local dx, dy = piece.x - source.x, piece.y - source.y
    return source.id .. ":crop:" .. dx .. ":" .. dy .. ":" .. piece.cols .. ":" .. piece.rows
end

function placements.crop_key(source: any): string
    return tostring(source.cols) .. ":" .. source.rows .. ":" .. source.raster:version()
end

return placements
