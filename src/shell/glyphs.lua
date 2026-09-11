-- The shell's graphic elements, gathered in one place.
--
-- The characters are pulled out of the drawing code on purpose. Scattered
-- through the code, they get edited one at a time: someone changes the frame
-- corner in a window and does not find the same corner in the menu, and two
-- parts of one shell start to look like they come from different programs.
--
-- WIDTH RULE. Every character here takes EXACTLY ONE cell. A character two
-- cells wide (emoji, CJK characters, ⌚ and similar "clocks") shifts
-- everything to its right on that line, and the window frame falls apart on
-- every line where it occurs, and it looks like an arithmetic error, not like
-- an unlucky character. Checked against EastAsianWidth: the whole set is
-- class N or A, that is, one cell everywhere except an East Asian locale.
-- Hence also `glyphs.all()`: the set on which the test measures width and
-- keeps a wide character out of the set.
--
-- Windows 95 depth is two one-pixel edges: light on top and left, dark on
-- the bottom and right. A terminal cell holds one edge, so the edges are
-- split across different cells of the frame rather than drawn inside one.

local glyphs = {}

-- Edges of the bevelled frame. Block eighths give a thin line at the very
-- edge of the cell, unlike halves (▀ ▄ ▌ ▐), which fill half of it and turn
-- the frame into a fat stripe.
glyphs.bevel = {
    top = "▔",      -- top edge
    bottom = "▁",   -- bottom edge
    left = "▏",     -- left edge
    right = "▕",    -- right edge
    -- Corners. Two edges meet in a corner cell, and a thin line cannot show
    -- them both: block quadrants are the only form where both are visible.
    corner_light = "▛",   -- light corner: top and left
    corner_shadow = "▟",  -- dark corner: bottom and right; also the size grip
}

-- Fills. `▒` is the "busy" background and the scrollbar, `░` is that very
-- speckled fill of a pressed Windows 95 button.
--
-- The block halves here are not for filling but for the etched separator.
-- The real Windows 95 separator is two one-pixel edges, dark above light; a
-- terminal cell holds one edge, but not one BOUNDARY: a block half paints
-- the top of the cell with the text color and the bottom with the background
-- color, and both edges fit in one line.
glyphs.shade = {
    light = "░",
    medium = "▒",
    dark = "▓",
    full = "█",
    half_top = "▀",
    half_bottom = "▄",
}

-- Title buttons. Minimize is a bar at the bottom edge, maximize is an empty
-- square, close is a diagonal cross. Three signs that read in Windows 95
-- without a caption.
glyphs.buttons = {
    minimize = "▁",
    maximize = "☐",
    close = "✕",
    -- The dialog's "What's this?". A question mark, not an icon: context help
    -- has no other universally understood sign.
    help = "?",
}

-- Scrollbar: arrows at the ends, speckled track, solid thumb.
glyphs.scrollbar = {
    up = "▲",
    down = "▼",
    left = "◀",
    right = "▶",
    track = "░",
    thumb = "█",
}

-- Icons. One character per icon: two no longer fit into a taskbar button
-- next to the window name, and a shortcut with a truncated name is useless.
glyphs.icons = {
    -- The "Start" logo. Not a four-color flag: it cannot be assembled in one
    -- cell; `⊞` reads as "windows" and holds up in any font.
    start = "⊞",
    program = "▣",       -- program
    unknown = "▢",       -- program without its own icon (default from the FR)
    folder = "▤",        -- menu or desktop folder
    folder_open = "▥",   -- the same folder, opened
    broken = "▨",        -- shortcut to a vanished entry
    clock = "◷",         -- taskbar clock
    user = "☺",          -- logged-in user in "Start"
    submenu = "▸",       -- the item has a submenu
    bullet = "▪",        -- line marker
    check = "✓",         -- checked item
    divider = "─",       -- menu separator
}

-- The full set as one table, for the width test. The order does not matter;
-- what matters is that no character is left out of the check: a set you can
-- forget to add a line to does not check what is drawn.
function glyphs.all()
    local out = {}
    for _, group in ipairs({glyphs.bevel, glyphs.shade, glyphs.buttons, glyphs.scrollbar, glyphs.icons}) do
        for _, char in pairs(group) do
            out[#out + 1] = char
        end
    end
    return out
end

return glyphs
