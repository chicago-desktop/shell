-- Storage for rasters between frames.
--
-- This is the mechanism without which the pixel theme looks flawless and at
-- the same time runs four times slower than it should (FR-005 §4).
--
-- ─── Why the mistake is invisible ───────────────────────────────────────
--
-- A placement is resent when the raster's `version` changes, and the version
-- moves on every write. A theme that creates a raster in its draw function
-- gets a NEW raster every frame, and resends everything every frame.
--
-- The screen is CORRECT meanwhile. The same picture, the same colors,
-- nothing flickers. It is just that every keypress in a window with bash
-- costs forty-seven milliseconds instead of one, and over ssh you feel it,
-- but in the code you do not see it. Slowness has no stack trace.
--
-- ─── How it works ───────────────────────────────────────────────────────
--
-- A raster is taken by name and by KEY, a fingerprint of the state it was
-- drawn from. If the key and the size match, the raster is returned as is,
-- and drawing into it is FORBIDDEN: any write moves the version and sends
-- the picture again. That is why `take` returns a "must draw" flag as its
-- second value rather than leaving it to the caller's conscience.
--
--     local raster, dirty = store:take("win:w1:title", 60, 1, cell, key)
--     if dirty then draw_title(raster, …) end
--     store:place("win:w1:title", x, y)
--
-- The key is a string, and whoever draws builds it: only they know what
-- their picture depends on. A title depends on text, width and focus; the
-- desktop on the icon layout. A key that forgot a field gives a picture that
-- does not update, and that is exactly the mistake you can see by eye,
-- unlike the opposite one.
--
-- ─── The list is complete ───────────────────────────────────────────────
--
-- A placement that is not in the frame is removed from the screen (FR-005
-- §5). That is why a frame is opened with `begin`, and `sweep` throws out
-- everything not named in it: this is how a closed menu disappears, not by
-- drawing over it but by being absent from the list.

local gfx = require("gfx")

local rasters = {}

local geometry = require("geometry")
local whole = geometry.whole

-- store() -> storage
function rasters.store(): any
    local kept: any = {}
    local used: any = {}
    local order: any = {}
    local self: any = {}

    -- Start of a frame. The list of named rasters is reset; whatever is not
    -- named will leave the screen.
    function self.begin()
        used = {}
        order = {}
    end

    -- take(id, cols, rows, cell, key) -> raster, whether it must be drawn
    --
    -- Size in CELLS, not in pixels: the placement lands on the grid anyway,
    -- and a raster whose height is not a multiple of a cell leaves a strip of
    -- foreign background at the bottom. Pixels are computed here, in one
    -- place.
    function self.take(id, cols: any, rows: any, cell: any, key)
        local unit: any = type(cell) == "table" and cell or {}
        local cw = math.max(1, whole(unit.w))
        local ch = math.max(1, whole(unit.h))
        local width = math.max(1, whole(cols)) * cw
        local height = math.max(1, whole(rows)) * ch
        local stamp = tostring(key or "")

        local slot: any = kept[id]
        if slot and slot.width == width and slot.height == height and slot.key == stamp then
            used[id] = slot
            return slot.raster, false
        end

        -- The size changed: a new buffer is needed, a raster does not stretch.
        -- Only the key changed: the buffer is the same, and that matters:
        -- recreating it for a redraw would throw away the one thing all of
        -- this is stored for.
        local raster = (slot and slot.width == width and slot.height == height)
            and slot.raster or gfx.raster(width, height)

        slot = {raster = raster, width = width, height = height, key = stamp}
        kept[id] = slot
        used[id] = slot
        return raster, true
    end

    -- Where to lie. Coordinates in CELLS, one-based, as everywhere here.
    function self.place(id, col: any, row: any)
        local slot: any = used[id]
        if not slot then return false, "raster not taken in this frame: " .. tostring(id) end
        slot.col = whole(col)
        slot.row = whole(row)
        order[#order + 1] = id
        return true, nil
    end

    -- The whole frame: placements in the order they were named.
    --
    -- `sweep` throws out everything not named in the frame. A raster left in
    -- storage from a closed menu would cost nothing on screen, but it would
    -- cost memory and would one day come back when the menu was opened again
    -- with the same key and different contents.
    function self.frame(cell: any)
        local unit: any = type(cell) == "table" and cell or {}
        local cw = math.max(1, whole(unit.w))
        local ch = math.max(1, whole(unit.h))

        local out = {}
        for _, id in ipairs(order) do
            local slot: any = used[id]
            if slot and slot.col then
                out[#out + 1] = {
                    id = id, raster = slot.raster,
                    x = slot.col, y = slot.row,
                    cols = slot.width // cw, rows = slot.height // ch,
                }
            end
        end

        for id in pairs(kept) do
            if not used[id] then kept[id] = nil end
        end
        return out
    end

    -- How many rasters are stored. For checks: storage that only grows is a
    -- leak, and it shows up not as a failure but as memory.
    function self.size(): integer
        local count = 0
        for _ in pairs(kept) do count = count + 1 end
        return count
    end

    return self
end

return rasters
