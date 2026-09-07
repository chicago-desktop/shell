-- Раскладка рабочего стола оболочки.
--
-- Здесь лежит только то, что двигает пользователь: где значок, как он назван,
-- в какой папке стола. Список программ здесь НЕ лежит — его объявляет реестр,
-- и хранить его копию значило бы, что установленный модуль не появится, пока
-- кто-то не нажмёт «обновить».
--
-- Таблицы две, и это не дробление одной.
--
-- `desktop_items` — раскладка: строку создаёт и удаляет пользователь.
-- `desktop_seeded` — история предложений: строку создаёт оболочка, когда
-- впервые выносит на стол программу с `desktop: true`, и НИКОГДА не удаляет.
-- Именно из-за этого удаление значка работает: ярлык ушёл из раскладки, а
-- отметка «эту программу мы уже предлагали» осталась, и на следующем старте
-- значок не возвращается.
--
-- Слить их в одну таблицу отметкой «удалён» нельзя без цены: тогда каждый
-- запрос раскладки обязан фильтровать надгробия, и один пропущенный фильтр
-- рисует на столе значок-призрак. Из отдельной таблицы надгробие в раскладку
-- не просочится.
--
-- ВАЖНО ТОМУ, КТО БУДЕТ ЧИСТИТЬ БАЗУ: `desktop_seeded` — НЕ кэш. Её нельзя
-- опустошить «чтобы освежить»: очистка вернёт человеку все ярлыки, которые он
-- когда-либо выбросил, и выглядеть это будет не как чужая уборка, а как
-- сломанное удаление значков. Строки здесь маленькие и не растут ни от чего,
-- кроме появления новых программ.

return require("migration").define(function()
    migration("Create butschster_windows desktop layout tables", function()
        database("postgres", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE butschster_windows_desktop_items (
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
                if err then error("Failed to create butschster_windows_desktop_items: " .. err) end

                local _, ierr = db:execute([[
                    CREATE INDEX butschster_windows_desktop_items_parent_idx
                        ON butschster_windows_desktop_items (parent_id);
                ]])
                if ierr then error("Failed to index butschster_windows_desktop_items: " .. ierr) end

                local _, serr = db:execute([[
                    CREATE TABLE butschster_windows_desktop_seeded (
                        entry TEXT PRIMARY KEY,
                        seeded_at TEXT NOT NULL DEFAULT (to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'))
                    );
                ]])
                if serr then error("Failed to create butschster_windows_desktop_seeded: " .. serr) end
            end)
            down(function(db)
                db:execute("DROP TABLE butschster_windows_desktop_seeded")
                db:execute("DROP TABLE butschster_windows_desktop_items")
            end)
        end)

        database("sqlite", function()
            up(function(db)
                local _, err = db:execute([[
                    CREATE TABLE butschster_windows_desktop_items (
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
                if err then error("Failed to create butschster_windows_desktop_items: " .. err) end

                local _, ierr = db:execute([[
                    CREATE INDEX butschster_windows_desktop_items_parent_idx
                        ON butschster_windows_desktop_items (parent_id)
                ]])
                if ierr then error("Failed to index butschster_windows_desktop_items: " .. ierr) end

                local _, serr = db:execute([[
                    CREATE TABLE butschster_windows_desktop_seeded (
                        entry TEXT PRIMARY KEY,
                        seeded_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    )
                ]])
                if serr then error("Failed to create butschster_windows_desktop_seeded: " .. serr) end
            end)
            down(function(db)
                db:execute("DROP TABLE butschster_windows_desktop_seeded")
                db:execute("DROP TABLE butschster_windows_desktop_items")
            end)
        end)
    end)
end)
