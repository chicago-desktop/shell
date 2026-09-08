-- Настройки оболочки: то, что человек выбрал в окнах свойств и что должно
-- пережить перезапуск. Пока одна — цвет стола (`desktop_color`).
--
-- Таблица «ключ — значение», а не колонка на настройку: колонка на каждую
-- следующую настройку означала бы миграцию на каждый флажок в диалоге.
-- Значение — текст; кто пишет, тот и проверяет форму, кто читает — тоже:
-- строка из базы не доказательство того, что она корректна.
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
