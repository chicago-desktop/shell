-- Shell settings: what the person chose in properties windows and what must
-- survive a restart. So far just one — the desktop color (`desktop_color`).
--
-- A "key — value" table, not a column per setting: a column for every next
-- setting would mean a migration for every checkbox in a dialog.
-- The value is text; whoever writes it checks its form, and so does whoever
-- reads it: a string from the database is no proof that it is correct.
return require("migration").define(function()
    migration("Create butschster_windows settings table", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE butschster_windows_settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL,
                        updated_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                    );
                ]])
                if err then error("Failed to create butschster_windows_settings: " .. err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS butschster_windows_settings;")
                if err then error("Failed to drop butschster_windows_settings: " .. err) end
            end)
        end)
        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE butschster_windows_settings (
                        key TEXT PRIMARY KEY,
                        value TEXT NOT NULL,
                        updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    );
                ]])
                if err then error("Failed to create butschster_windows_settings: " .. err) end
            end)
            down(function(db)
                local _, err = db:execute("DROP TABLE IF EXISTS butschster_windows_settings;")
                if err then error("Failed to drop butschster_windows_settings: " .. err) end
            end)
        end)
    end)
end)
