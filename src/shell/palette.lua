-- The shell palette: two sets of the same names.
--
-- `exact` is the exact Windows 95 colors, as hexadecimal RGB. This is the
-- default set, and here is why the choice changed. While the goal was "in the
-- spirit of Windows", the base indexes 0-15 won: the terminal takes them from
-- its theme, and the shell settled into it without arguing. The goal is
-- different now: match the frame to a reference screenshot. The terminal
-- theme is then not a helper but a hindrance: its "blue" is exactly the
-- quantity that differs from theme to theme, and we paint every cell
-- ourselves, so there is nothing left to adapt to.
--
-- `basic` is the same set as indexes, the fallback path: a terminal without
-- truecolor support will show the exact RGB as an approximation from its
-- palette, and on a 16-color one that is worse than honest indexes. It is
-- switched with one line in chrome.lua (`local color = palette.basic`).
--
-- THE NAMES IN BOTH SETS MUST MATCH. A key forgotten in `basic` shows up not
-- as a failure but as `nil` in a style, that is, as a color "whatever
-- happens" on one part out of twenty, and it gets noticed a week later. It
-- is checked by comparing keys: `palette.names()` hands out the list for the
-- test.
--
--   0 black     4 blue       8  dark gray     12 bright blue
--   1 maroon    5 purple     9  red           13 pink
--   2 green     6 teal       10 bright green  14 light blue
--   3 olive     7 silver     11 yellow        15 white

local palette = {}

palette.exact = {
    console_bg = "#000000",
    console_text = "#c0c0c0",
    -- Farewell screen: black with orange text, like "It's now safe to turn
    -- off your computer" in Windows 95.
    farewell_bg = "#000000",
    farewell_text = "#ff8800",
    -- Desktop.
    desktop = "#008080",
    desktop_text = "#ffffff",
    -- Caption of a broken shortcut: yellow is visible even where the icon
    -- cannot be made out.
    desktop_broken = "#ffff00",

    -- Face of the window, the taskbar and buttons.
    face = "#c0c0c0",
    face_text = "#000000",

    -- List field: white with black text. Icons inside a window lie on it,
    -- not on the face: in the Windows 95 explorer these are different
    -- surfaces, and an icon caption on gray looks like a label on a button.
    field = "#ffffff",
    field_text = "#000000",

    -- Bevel edges. The light one goes on top and left, the dark one on the
    -- bottom and right; swapping them gives a sunken part with the same code.
    light = "#ffffff",
    shadow = "#808080",
    -- The second dark edge of large frames and the outline of the default
    -- button. Windows 95 has two of them, and telling them apart matters:
    -- #808080 is depth, #000000 is the object's boundary.
    frame = "#000000",

    -- Window title. Active is dark blue with bold white, inactive is gray:
    -- the difference is in the background, not in text brightness, otherwise
    -- both titles merge on a dark terminal theme.
    title_active_bg = "#000080",
    title_active_fg = "#ffffff",
    title_idle_bg = "#808080",
    title_idle_fg = "#c0c0c0",

    -- Selection: the caption of the selected icon, the menu item under the
    -- cursor. The same color as the active title: in Windows 95 it is one
    -- quantity.
    select_bg = "#000080",
    select_fg = "#ffffff",

    -- Failure. Maroon, not red: red on gray glares and reads as "on fire",
    -- although the message merely names the reason.
    alert = "#800000",
}

palette.basic = {
    console_bg = "0",
    console_text = "7",
    farewell_bg = "0",
    farewell_text = "208",
    desktop = "6",
    desktop_text = "15",
    desktop_broken = "11",

    face = "7",
    face_text = "0",

    field = "15",
    field_text = "0",

    light = "15",
    shadow = "8",
    frame = "0",

    title_active_bg = "4",
    title_active_fg = "15",
    title_idle_bg = "8",
    title_idle_fg = "7",

    select_bg = "4",
    select_fg = "15",

    alert = "1",
}

-- The default set.
palette.active = palette.exact

-- Color names as a list, so the test can compare the sets with each other
-- rather than rely on both having been edited at the same time.
function palette.names()
    local out = {}
    for name in pairs(palette.exact) do out[#out + 1] = name end
    table.sort(out)
    return out
end

return palette
