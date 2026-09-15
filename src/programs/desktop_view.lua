-- The layout, supplemented by the catalog: what is visible on the desktop.
--
-- The one place where a layout row meets a registry entry. It is used both
-- by the shell (to draw the icon and know what to open) and by the
-- `GET /chicago/desktop` handler. Were these two joins to diverge, the
-- screen and the handler's answer would show different desktops, and there
-- would be nothing to explain the discrepancy by.
--
-- A shortcut stores only a reference, so the name, the icon and the window
-- size are taken from the registry: the program got updated — the shortcut
-- leads to the new version. A custom name, if the user set one, survives the
-- update: it is in the row.

local catalog = require("catalog")

local view = {}

-- join(items, found) -> list
--
-- `found` is the result of catalog.list() or nil if the catalog was not read.
-- In the second case the broken marker is NOT set at all: saying "the
-- shortcut is broken" on the basis of an unread catalog means accusing a
-- working program.
function view.join(items: any, found: any)
    local programs = type(found) == "table" and found.programs or nil
    local out = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        local row: any = {
            id = item.id,
            kind = item.kind,
            entry = item.entry,
            parent_id = item.parent_id,
            title = item.title,
            x = item.x,
            y = item.y,
            created_at = item.created_at,
            updated_at = item.updated_at,
        }
        if item.kind == "shortcut" and programs then
            local program = catalog.find(programs, item.entry)
            row.broken = program == nil
            if program then
                row.icon = program.icon
                row.image = program.image
                row.program_title = program.title
                row.w = program.width
                row.h = program.height
                row.width = program.width
                row.height = program.height
                row.args = program.args
                row.properties = program.properties
            end
            -- What a broken icon looks like is decided by the theme: it draws,
            -- so it knows how to tell it apart. The layout asserts only the
            -- fact — there is no entry. An icon chosen here would take this
            -- decision away from the theme silently.
        end
        out[#out + 1] = row
    end
    return out
end

return view
