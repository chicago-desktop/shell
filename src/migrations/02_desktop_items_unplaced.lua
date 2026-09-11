-- An icon whose place nobody named.
--
-- The shell lays out icons before the terminal has reported its size, so a
-- place it chose could end up past the edge of the screen — and an icon past
-- the edge is not clipped, it disappears entirely and silently. That is
-- exactly the failure the FR forbids for a broken shortcut: a vanished icon
-- reads as "I deleted it by accident".
--
-- Relaying everything that did not fit is not possible: then what the person
-- dragged by hand would move too, and "moved it and restarted — the icon is
-- in the same place" would stop being true. Only what the person did not
-- place may be rearranged.
--
-- There is deliberately NO separate "placed by a person" flag here. A flag
-- next to the columns it describes is a second source of truth, and the
-- schema would allow it to contradict them: "placed" with empty coordinates
-- and "not placed" with coordinates set by hand. Sorting that out would fall
-- to whoever finds the icon in the wrong place.
--
-- Therefore the marker is the coordinates themselves. Empty = nobody named a
-- place, and the compositor is free to put the icon into a free cell, knowing
-- the screen width at the moment of the frame. Filled = a person named the
-- place, and it is inviolable, even if it went past the edge: in real
-- Windows 95 an icon that went past the edge does not come back by itself.
--
-- Existing rows have coordinates, so after the migration they count as
-- placed and will not be rearranged. That is the conservative outcome, and it
-- comes about by itself, not through a choice of default that would later
-- have to be explained.

return require("migration").define(function()
    migration("Allow desktop items without coordinates", function()
        database("postgres", function()
            up(function(db)
                for _, column in ipairs({"x", "y"}) do
                    local _, err = db:execute(
                        "ALTER TABLE butschster_windows_desktop_items ALTER COLUMN "
                        .. column .. " DROP NOT NULL")
                    if err then error("Failed to drop NOT NULL on " .. column .. ": " .. err) end

                    -- The default is removed together with the NOT NULL: a
                    -- column with a default value will never turn out empty,
                    -- and the "no place named" marker would exist only in
                    -- words.
                    local _, derr = db:execute(
                        "ALTER TABLE butschster_windows_desktop_items ALTER COLUMN "
                        .. column .. " DROP DEFAULT")
                    if derr then error("Failed to drop default on " .. column .. ": " .. derr) end
                end
            end)
            down(function(db)
                db:execute("UPDATE butschster_windows_desktop_items SET x = 0 WHERE x IS NULL")
                db:execute("UPDATE butschster_windows_desktop_items SET y = 0 WHERE y IS NULL")
                db:execute("ALTER TABLE butschster_windows_desktop_items ALTER COLUMN x SET NOT NULL")
                db:execute("ALTER TABLE butschster_windows_desktop_items ALTER COLUMN y SET NOT NULL")
            end)
        end)

        database("sqlite", function()
            up(function(db)
                -- SQLite cannot drop NOT NULL from a column, so the table is
                -- rebuilt. The index goes away together with the old table and
                -- is created anew after the rename.
                local _, err = db:execute([[
                    CREATE TABLE butschster_windows_desktop_items_new (
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        entry TEXT,
                        parent_id TEXT,
                        title TEXT NOT NULL,
                        x INTEGER,
                        y INTEGER,
                        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    )
                ]])
                if err then error("Failed to create rebuilt desktop items table: " .. err) end

                local _, cerr = db:execute([[
                    INSERT INTO butschster_windows_desktop_items_new
                        (id, kind, entry, parent_id, title, x, y, created_at, updated_at)
                    SELECT id, kind, entry, parent_id, title, x, y, created_at, updated_at
                    FROM butschster_windows_desktop_items
                ]])
                if cerr then error("Failed to copy desktop items: " .. cerr) end

                local _, derr = db:execute("DROP TABLE butschster_windows_desktop_items")
                if derr then error("Failed to drop old desktop items table: " .. derr) end

                local _, rerr = db:execute([[
                    ALTER TABLE butschster_windows_desktop_items_new
                        RENAME TO butschster_windows_desktop_items
                ]])
                if rerr then error("Failed to rename rebuilt desktop items table: " .. rerr) end

                local _, ierr = db:execute([[
                    CREATE INDEX butschster_windows_desktop_items_parent_idx
                        ON butschster_windows_desktop_items (parent_id)
                ]])
                if ierr then error("Failed to reindex desktop items: " .. ierr) end
            end)
            down(function(db)
                db:execute("UPDATE butschster_windows_desktop_items SET x = 0 WHERE x IS NULL")
                db:execute("UPDATE butschster_windows_desktop_items SET y = 0 WHERE y IS NULL")
            end)
        end)
    end)
end)
