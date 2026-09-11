-- Desktop furniture: what stands on the desktop at first launch.
--
-- It differs from `desktop: true` by WHO asks. There, the program itself
-- asks, declaring it in its entry; here, the shell asks, because an empty
-- desktop at first launch does not explain what to do with it.
--
-- Only what has something behind it is created. A prop icon ("Recycle Bin")
-- looks like a working part of the system, and the first thing people will
-- ask about it is why it does not work; the answer "it is just painted on"
-- costs more than a missing icon. "Network Neighborhood" is not here for a
-- different reason: there is a window behind it, and it asks for the desktop
-- itself — `desktop: true` in its own entry.
--
-- The mark that the furniture has already been offered lives in the same
-- table `butschster_windows_desktop_seeded` as the programs' marks, so an
-- icon the person threw away does not come back — on any later startup.
-- Keys here start with "!", which cannot appear in a registry entry
-- identifier (that is always `namespace:name`): so a furniture key is
-- guaranteed not to collide with a program key in the same column.

local catalog = require("catalog")

local defaults = {}

-- "My Computer" is the shell's own window, not the base's browser. It shows
-- what the stand consists of: drives from the registry, catalog programs,
-- the desktop and open windows.
--
-- This used to be `butschster.tui_desktop.apps:commander` — a window built by
-- the base's workshop. A shortcut to it would leave together with someone
-- else's workshop, and "My Computer" would stop being created SILENTLY: a
-- missing program is skipped here, not marked.
local MY_COMPUTER = "butschster.windows.explorer:window"

defaults.ITEMS = {
    {
        key = "!furniture:my_computer",
        kind = "shortcut",
        entry = MY_COMPUTER,
        -- The name is its own, not the program's, even when they coincide:
        -- the shortcut's own name lives in the layout row and survives the
        -- program being renamed, while one taken from the entry would change
        -- along with it.
        title = "My Computer",
    },
    -- There is no "Programs" folder on the desktop any more — the owner's
    -- decision of 2026-09-09: programs live in "Start", and the folder on the
    -- desktop duplicated it and stood empty. Where it already stands, the
    -- `!furniture:programs` key stays among the offered marks, and it will
    -- not be created back.
}

-- resolve(programs) -> list to create
--
-- A shortcut to a program that is NOT in the catalog is skipped and not
-- marked as offered. Creating it broken would mean putting a broken icon on
-- the desktop at the very first launch with nothing to explain it by;
-- skipping it means creating it when the program appears.
--
-- A folder has nothing to check: it is a state object, no entry stands
-- behind it.
function defaults.resolve(programs: any)
    local out = {}
    for _, item in ipairs(defaults.ITEMS) do
        if item.kind == "folder" then
            out[#out + 1] = item
        elseif catalog.find(programs, item.entry) then
            out[#out + 1] = item
        end
    end
    return out
end

return defaults
