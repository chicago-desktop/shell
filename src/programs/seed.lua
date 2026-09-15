-- What appears on the desktop by itself, and why it does not appear twice.
--
-- There are two reasons to create an icon, and they differ by WHO asks:
--   `ensure`  — a program declared `desktop: true` in its registry entry;
--   `furnish` — the shell puts out first-run furniture (see `defaults`).
--
-- They have one thing in common, and it is the main one: the mark that the
-- icon has already been offered lives in a separate table and is NEVER
-- deleted. The user removed the icon — the shortcut left the layout, the mark
-- stayed, and on the next startup the icon does not come back. Without the
-- mark, deleting an icon would not work at all: it would come back on every
-- startup, and the person would decide that deletion is broken.
--
-- PLACES ARE NOT CHOSEN HERE. The row is written without coordinates, and
-- that is a statement, not an omission: the shell lays out icons before the
-- terminal has reported its size, so a place it chose could end up past the
-- edge of the screen — and an icon past the edge is not clipped, it
-- disappears entirely and silently. The place is chosen by the compositor at
-- the moment of the frame, when the width is known.
--
-- The mark and the shortcut are written in one transaction (`repo.offer`),
-- the mark first and `ON CONFLICT DO NOTHING`: the second writer gets
-- "already offered", not a key error and an extra icon, and a failure to
-- write the shortcut rolls back the mark as well — an icon will not stay
-- marked as offered but not offered.

local repo = require("repo")

local seed = {}

-- place(wanted, store) -> (created, nil) | (nil, reason)
--
-- `wanted` is a list of {key, kind, entry, title}. `key` is what "already
-- offered" is counted by: for a program it is its entry, for furniture — the
-- shell's own key. `store` is whose layout (repo.of); none is the shared one.
local function place(wanted: any, store: any)
    local layout: any = store or repo
    local seeded, serr = layout.seeded()
    if serr then return nil, "offered marks: " .. tostring(serr) end

    -- The traversal order is the one the list came in, so two startups in a
    -- row create icons the same way, and the compositor puts them into the
    -- same cells.
    local created = {}
    for _, want in ipairs(type(wanted) == "table" and wanted or {}) do
        -- The marks read here are a cheap filter, not the decision: `offer`
        -- decides inside a transaction, and a late writer gets `false`.
        if not (seeded :: any)[want.key] then
            local item, cerr = layout.offer(want.key, {
                kind = want.kind,
                entry = want.entry,
                title = want.title,
            })
            if cerr then return nil, tostring(want.key) .. ": " .. tostring(cerr) end
            if item then created[#created + 1] = item end
        end
    end

    return created, nil
end

-- furnish(objects) -> (created, nil) | (nil, reason)
--
-- First-run furniture. It is created FIRST, before programs: the compositor
-- lays out icons in the order the layout returns them, and the furniture
-- must take the head of the column, as on a real desktop.
function seed.furnish(objects: any, store: any?)
    local wanted = {}
    for _, object in ipairs(type(objects) == "table" and objects or {}) do
        wanted[#wanted + 1] = {
            key = object.key,
            kind = object.kind,
            entry = object.entry,
            title = object.title,
        }
    end
    local created, err = place(wanted, store)
    return created, err
end

-- ensure(programs, store?) -> (created, nil) | (nil, reason)
--
-- Idempotent: a repeated call with an unchanged catalog writes nothing.
-- Therefore it can be called not only at startup — a window built by the
-- workshop while the shell is running gets its icon without waiting for a
-- restart.
function seed.ensure(programs: any, store: any?)
    local wanted = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        if program.desktop then
            wanted[#wanted + 1] = {
                key = program.entry,
                kind = repo.KIND_SHORTCUT,
                entry = program.entry,
                title = program.title,
            }
        end
    end
    local created, err = place(wanted, store)
    return created, err
end

return seed
