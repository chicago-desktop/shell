-- The layout, the offered marks and the settings belong to a person.
--
-- Several people use one runtime at once (a terminal.ssh host gives every
-- connection its own desktop): an icon one of them moves must not move on the
-- others' screens, and a color one of them picks must not repaint theirs.
-- Every row gets `user_id`; the rows that exist become the SHARED layout
-- (`''`), the one a desktop without logon shows and the one a person inherits
-- at first use (chicago.shell.persist:repo).
--
-- Settings and marks change their primary key to (user_id, …). PostgreSQL
-- swaps the constraint; SQLite cannot, so those two tables are rebuilt, as
-- migration 02 rebuilt the layout.

local ITEMS = "chicago_shell_desktop_items"
local SETTINGS = "chicago_shell_settings"
local SEEDED = "chicago_shell_desktop_seeded"

local function run(db: any, statement: string, what: string)
    local _, err = db:execute(statement)
    if err then error(what .. ": " .. tostring(err)) end
end

local SQLITE_NOW = "(strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))"

return require("migration").define(function()
    migration("Layout, marks and settings per person", function()
        database("postgres", function()
            up(function(db)
                run(db, "ALTER TABLE " .. ITEMS .. " ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
                    "Failed to add user_id to desktop items")
                run(db, "CREATE INDEX chicago_shell_desktop_items_user_idx ON " .. ITEMS .. " (user_id)",
                    "Failed to index desktop items by person")
                run(db, "ALTER TABLE " .. SETTINGS .. " ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
                    "Failed to add user_id to settings")
                run(db, "ALTER TABLE " .. SETTINGS .. " DROP CONSTRAINT " .. SETTINGS .. "_pkey",
                    "Failed to drop the settings key")
                run(db, "ALTER TABLE " .. SETTINGS .. " ADD PRIMARY KEY (user_id, key)",
                    "Failed to key settings by person")
                run(db, "ALTER TABLE " .. SEEDED .. " ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
                    "Failed to add user_id to offered marks")
                run(db, "ALTER TABLE " .. SEEDED .. " DROP CONSTRAINT " .. SEEDED .. "_pkey",
                    "Failed to drop the offered marks key")
                run(db, "ALTER TABLE " .. SEEDED .. " ADD PRIMARY KEY (user_id, entry)",
                    "Failed to key offered marks by person")
            end)
            down(function(db)
                -- Back to one layout: the shared one stays, the people's go.
                db:execute("DELETE FROM " .. SEEDED .. " WHERE user_id <> ''")
                db:execute("ALTER TABLE " .. SEEDED .. " DROP CONSTRAINT " .. SEEDED .. "_pkey")
                db:execute("ALTER TABLE " .. SEEDED .. " DROP COLUMN user_id")
                db:execute("ALTER TABLE " .. SEEDED .. " ADD PRIMARY KEY (entry)")
                db:execute("DELETE FROM " .. SETTINGS .. " WHERE user_id <> ''")
                db:execute("ALTER TABLE " .. SETTINGS .. " DROP CONSTRAINT " .. SETTINGS .. "_pkey")
                db:execute("ALTER TABLE " .. SETTINGS .. " DROP COLUMN user_id")
                db:execute("ALTER TABLE " .. SETTINGS .. " ADD PRIMARY KEY (key)")
                db:execute("DELETE FROM " .. ITEMS .. " WHERE user_id <> ''")
                db:execute("DROP INDEX IF EXISTS chicago_shell_desktop_items_user_idx")
                db:execute("ALTER TABLE " .. ITEMS .. " DROP COLUMN user_id")
            end)
        end)

        database("sqlite", function()
            up(function(db)
                run(db, "ALTER TABLE " .. ITEMS .. " ADD COLUMN user_id TEXT NOT NULL DEFAULT ''",
                    "Failed to add user_id to desktop items")
                run(db, "CREATE INDEX chicago_shell_desktop_items_user_idx ON " .. ITEMS .. " (user_id)",
                    "Failed to index desktop items by person")

                run(db, "CREATE TABLE " .. SETTINGS .. "_new ("
                    .. " user_id TEXT NOT NULL DEFAULT '', key TEXT NOT NULL, value TEXT NOT NULL,"
                    .. " updated_at TEXT NOT NULL DEFAULT " .. SQLITE_NOW .. ","
                    .. " PRIMARY KEY (user_id, key))", "Failed to create rebuilt settings table")
                run(db, "INSERT INTO " .. SETTINGS .. "_new (user_id, key, value, updated_at)"
                    .. " SELECT '', key, value, updated_at FROM " .. SETTINGS, "Failed to copy settings")
                run(db, "DROP TABLE " .. SETTINGS, "Failed to drop old settings table")
                run(db, "ALTER TABLE " .. SETTINGS .. "_new RENAME TO " .. SETTINGS,
                    "Failed to rename rebuilt settings table")

                run(db, "CREATE TABLE " .. SEEDED .. "_new ("
                    .. " user_id TEXT NOT NULL DEFAULT '', entry TEXT NOT NULL,"
                    .. " seeded_at TEXT NOT NULL DEFAULT " .. SQLITE_NOW .. ","
                    .. " PRIMARY KEY (user_id, entry))", "Failed to create rebuilt offered marks table")
                run(db, "INSERT INTO " .. SEEDED .. "_new (user_id, entry, seeded_at)"
                    .. " SELECT '', entry, seeded_at FROM " .. SEEDED, "Failed to copy offered marks")
                run(db, "DROP TABLE " .. SEEDED, "Failed to drop old offered marks table")
                run(db, "ALTER TABLE " .. SEEDED .. "_new RENAME TO " .. SEEDED,
                    "Failed to rename rebuilt offered marks table")
            end)
            down(function(db)
                db:execute("CREATE TABLE " .. SEEDED .. "_old (entry TEXT PRIMARY KEY,"
                    .. " seeded_at TEXT NOT NULL DEFAULT " .. SQLITE_NOW .. ")")
                db:execute("INSERT INTO " .. SEEDED .. "_old (entry, seeded_at)"
                    .. " SELECT entry, seeded_at FROM " .. SEEDED .. " WHERE user_id = ''")
                db:execute("DROP TABLE " .. SEEDED)
                db:execute("ALTER TABLE " .. SEEDED .. "_old RENAME TO " .. SEEDED)
                db:execute("CREATE TABLE " .. SETTINGS .. "_old (key TEXT PRIMARY KEY, value TEXT NOT NULL,"
                    .. " updated_at TEXT NOT NULL DEFAULT " .. SQLITE_NOW .. ")")
                db:execute("INSERT INTO " .. SETTINGS .. "_old (key, value, updated_at)"
                    .. " SELECT key, value, updated_at FROM " .. SETTINGS .. " WHERE user_id = ''")
                db:execute("DROP TABLE " .. SETTINGS)
                db:execute("ALTER TABLE " .. SETTINGS .. "_old RENAME TO " .. SETTINGS)
                db:execute("DELETE FROM " .. ITEMS .. " WHERE user_id <> ''")
                db:execute("DROP INDEX IF EXISTS chicago_shell_desktop_items_user_idx")
                db:execute("ALTER TABLE " .. ITEMS .. " DROP COLUMN user_id")
            end)
        end)
    end)
end)
