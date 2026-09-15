-- The shell's desktop layout.
--
-- Only what the user moves lives here: where an icon is, what it is called,
-- which desktop folder it is in. The list of programs does NOT live here — it
-- is declared by the registry, and keeping a copy of it would mean that an
-- installed module does not appear until someone presses "refresh".
--
-- There are two tables, and this is not one table split up.
--
-- `desktop_items` is the layout: the user creates and deletes rows.
-- `desktop_seeded` is the history of offers: the shell creates a row when it
-- first puts a program with `desktop: true` on the desktop, and NEVER deletes
-- it. This is exactly why deleting an icon works: the shortcut left the
-- layout, but the mark "we have already offered this program" stayed, and on
-- the next startup the icon does not come back.
--
-- Merging them into one table with a "deleted" mark is not possible without
-- a price: then every layout query has to filter out tombstones, and one
-- missed filter draws a ghost icon on the desktop. From a separate table a
-- tombstone will not leak into the layout.
--
-- IMPORTANT FOR WHOEVER CLEANS THE DATABASE: `desktop_seeded` is NOT a cache.
-- It must not be emptied "to refresh things": clearing it will give the
-- person back every shortcut they have ever thrown away, and it will look not
-- like someone else's cleanup but like broken icon deletion. The rows here
-- are small and grow from nothing except the appearance of new programs.

return require("migration").define(function()
    migration("Create windows_shell desktop layout tables", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE windows_shell_desktop_items (
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        entry TEXT,
                        parent_id TEXT,
                        title TEXT NOT NULL,
                        x INTEGER NOT NULL DEFAULT 0,
                        y INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')),
                        updated_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                    );
                ]])
                if err then error("Failed to create windows_shell_desktop_items: " .. err) end

                local _, ierr = db:execute([[
                    CREATE INDEX windows_shell_desktop_items_parent_idx
                        ON windows_shell_desktop_items (parent_id);
                ]])
                if ierr then error("Failed to index windows_shell_desktop_items: " .. ierr) end

                local _, serr = db:execute([[
                    CREATE TABLE windows_shell_desktop_seeded (
                        entry TEXT PRIMARY KEY,
                        seeded_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                    );
                ]])
                if serr then error("Failed to create windows_shell_desktop_seeded: " .. serr) end
            end)
            down(function(db)
                db:execute("DROP TABLE windows_shell_desktop_seeded")
                db:execute("DROP TABLE windows_shell_desktop_items")
            end)
        end)

        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE windows_shell_desktop_items (
                        id TEXT PRIMARY KEY,
                        kind TEXT NOT NULL,
                        entry TEXT,
                        parent_id TEXT,
                        title TEXT NOT NULL,
                        x INTEGER NOT NULL DEFAULT 0,
                        y INTEGER NOT NULL DEFAULT 0,
                        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
                        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    )
                ]])
                if err then error("Failed to create windows_shell_desktop_items: " .. err) end

                local _, ierr = db:execute([[
                    CREATE INDEX windows_shell_desktop_items_parent_idx
                        ON windows_shell_desktop_items (parent_id)
                ]])
                if ierr then error("Failed to index windows_shell_desktop_items: " .. ierr) end

                local _, serr = db:execute([[
                    CREATE TABLE windows_shell_desktop_seeded (
                        entry TEXT PRIMARY KEY,
                        seeded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    )
                ]])
                if serr then error("Failed to create windows_shell_desktop_seeded: " .. serr) end
            end)
            down(function(db)
                db:execute("DROP TABLE windows_shell_desktop_seeded")
                db:execute("DROP TABLE windows_shell_desktop_items")
            end)
        end)
    end)
end)
