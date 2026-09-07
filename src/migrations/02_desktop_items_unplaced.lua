-- Значок, чьё место никто не называл.
--
-- Оболочка раскладывает значки раньше, чем терминал сообщил свой размер,
-- поэтому место, выбранное ею, может оказаться за краем экрана — а значок за
-- краем не обрезается, он исчезает целиком и молча. Это ровно тот отказ,
-- который FR запрещает для битого ярлыка: пропавший значок читается как «я его
-- случайно удалил».
--
-- Переложить всё, что не поместилось, нельзя: тогда поедет и то, что человек
-- перетащил руками, а «подвинул и перезапустил — значок там же» перестанет
-- быть правдой. Переставлять можно только то, что человек не ставил.
--
-- Отдельного флага «поставлено человеком» здесь НЕТ намеренно. Флаг рядом с
-- колонками, которые он описывает, — второй источник истины, и схема
-- допускала бы его противоречие: «поставлено» при пустых координатах и
-- «не поставлено» при координатах, выставленных руками. Разбирать это пришлось
-- бы тому, кто найдёт значок не там.
--
-- Поэтому признак — сами координаты. Пусто = места никто не называл, и
-- композитор вправе положить значок в свободную ячейку, зная ширину экрана в
-- момент кадра. Заполнено = место назвал человек, и оно неприкосновенно, даже
-- если ушло за край: в настоящей Windows 95 ушедший за край значок сам не
-- возвращается.
--
-- Существующие строки координаты имеют, поэтому после миграции они считаются
-- поставленными и переставляться не будут. Это консервативный исход, и он
-- получается сам, а не выбором умолчания, который потом пришлось бы объяснять.

return require("migration").define(function()
    migration("Allow desktop items without coordinates", function()
        database("postgres", function()
            up(function(db)
                for _, column in ipairs({"x", "y"}) do
                    local _, err = db:execute(
                        "ALTER TABLE butschster_windows_desktop_items ALTER COLUMN "
                        .. column .. " DROP NOT NULL")
                    if err then error("Failed to drop NOT NULL on " .. column .. ": " .. err) end

                    -- Умолчание снимается вместе с обязательностью: колонка со
                    -- значением по умолчанию никогда не окажется пустой, и
                    -- признак «место не назвали» существовал бы только на
                    -- словах.
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
                -- SQLite не умеет снять NOT NULL с колонки, поэтому таблица
                -- пересобирается. Индекс уходит вместе со старой таблицей и
                -- создаётся заново после переименования.
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
