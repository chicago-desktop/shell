-- Раскладка рабочего стола на живой базе.
--
-- Проверяется то, из-за чего дефект был бы незаметен: круг «создал —
-- прочитал — подвинул — удалил», битый ярлык, который обязан остаться, и
-- удалённый ярлык, который обязан не вернуться. Последнее — единственный
-- способ убедиться, что удаление значка вообще работает: значок, приходящий
-- обратно каждый старт, выглядит не как правило, а как сломанное удаление.
local test = require("test")
local repo = require("repo")
local catalog = require("catalog")
local seed = require("seed")
local view = require("view")
local sql = require("sql")
local desktop_body = require("desktop_body")

local GHOST = "butschster.windows.test:ghost"

local function define_tests()
    test.describe("butschster.windows layout", function()
        test.it("переживает круг создал — прочитал — подвинул — удалил", function()
            local item, cerr = repo.create({
                kind = repo.KIND_SHORTCUT,
                entry = "butschster.windows.test:probe",
                title = "Проба",
                x = 2, y = 3,
            })
            test.is_nil(cerr)
            test.not_nil(item, "созданный ярлык должен вернуться")
            test.eq(item.kind, "shortcut")
            test.eq(item.x, 2)
            test.eq(item.y, 3)

            local read, gerr = repo.get(item.id)
            test.is_nil(gerr)
            test.not_nil(read, "ярлык должен читаться обратно")
            test.eq(read.title, "Проба")
            test.eq(read.entry, "butschster.windows.test:probe")

            local moved, uerr = repo.update(item.id, {x = 5, y = 1, title = "Переименован"})
            test.is_nil(uerr)
            test.not_nil(moved, "перемещение должно вернуть строку")
            test.eq(moved.x, 5)
            test.eq(moved.y, 1)
            test.eq(moved.title, "Переименован")

            -- Место переживает чтение, а не только ответ ручки: критерий
            -- «значок оказывается там же» проверяется из базы.
            local again = repo.get(item.id)
            test.eq(again.x, 5)
            test.eq(again.y, 1)

            local gone, derr = repo.delete(item.id)
            test.is_nil(derr)
            test.is_true(gone.existed, "удаление существующего ярлыка отвечает existed")
            test.is_nil(repo.get(item.id), "удалённый ярлык не читается")
        end)

        test.it("отвечает, БЫЛА ли строка, а не просто «удалено»", function()
            -- Иначе опечатка в идентификаторе выглядит успешным удалением, и
            -- человек уходит уверенным, что убрал значок, который на месте.
            local result, err = repo.delete("такого-идентификатора-нет")
            test.is_nil(err)
            test.is_false(result.existed, "удаление несуществующего не выдаёт себя за успех")
        end)

        test.it("выносит содержимое удалённой папки на стол, а не удаляет следом", function()
            local folder = repo.create({kind = repo.KIND_FOLDER, title = "Folder", x = 0, y = 0})
            local inside = repo.create({
                kind = repo.KIND_SHORTCUT,
                entry = "butschster.windows.test:inside",
                title = "Внутри",
                parent_id = folder.id,
            })
            test.eq(repo.get(inside.id).parent_id, folder.id)

            local result = repo.delete(folder.id)
            test.is_true(result.existed)
            test.eq(result.promoted, 1, "папка обязана сказать, сколько значков вынесла")

            local orphan = repo.get(inside.id)
            test.not_nil(orphan, "каскад унёс бы значки, которые складывал пользователь")
            test.is_nil(orphan.parent_id, "вынесенный значок лежит на столе")

            repo.delete(inside.id)
        end)

        test.it("оставляет ярлык на исчезнувшую запись и помечает его битым", function()
            -- Пропавший значок читается как «я его случайно удалил», битый —
            -- как «программы больше нет». Это разные утверждения.
            local item = repo.create({
                kind = repo.KIND_SHORTCUT, entry = GHOST, title = "Призрак", x = 9, y = 9,
            })

            local found, cerr = catalog.list()
            test.is_nil(cerr, "каталог харнесса читается, пусть и пустым")
            test.is_nil(catalog.find(found.programs, GHOST), "записи в реестре нет")

            local rows = view.join({repo.get(item.id)}, found)
            test.eq(#rows, 1, "ярлык обязан остаться в раскладке")
            test.is_true(rows[1].broken, "и быть помечен битым")
            test.eq(rows[1].entry, GHOST)

            -- Нечитаемый каталог не делает исправную программу битой: обвинить
            -- её на основании непрочитанного каталога хуже, чем промолчать.
            local blind = view.join({repo.get(item.id)}, nil)
            test.is_nil(blind[1].broken, "без каталога признак битости не выставляется")

            repo.delete(item.id)
        end)
    end)

    test.describe("butschster.windows desktop seeding", function()
        test.it("выносит программу с desktop true один раз и не возвращает удалённый ярлык", function()
            local program = {
                entry = "butschster.windows.test:seeded",
                title = "Автозначок",
                desktop = true,
            }

            local created, err = seed.ensure({program})
            test.is_nil(err)
            test.eq(#created, 1, "программа с desktop true обязана получить ярлык")
            local id = created[1].id
            test.eq(created[1].entry, program.entry)

            -- Идемпотентность: повторный вызов при том же каталоге не пишет
            -- ничего. Иначе каждое открытие меню задваивало бы значки.
            local again, aerr = seed.ensure({program})
            test.is_nil(aerr)
            test.eq(#again, 0, "второй проход не задваивает значок")

            -- Главное. Пользователь убрал значок — и он не возвращается ни на
            -- одном последующем старте. Отметка о предложении живёт отдельно
            -- и удалением ярлыка не трогается.
            local removed = repo.delete(id)
            test.is_true(removed.existed)

            local third, terr = seed.ensure({program})
            test.is_nil(terr)
            test.eq(#third, 0, "удалённый ярлык не возвращается")
            test.is_nil(repo.get(id), "и старой строки тоже нет")
        end)

        test.it("не трогает программу без desktop true", function()
            local created, err = seed.ensure({
                {entry = "butschster.windows.test:quiet", title = "Тихая"},
            })
            test.is_nil(err)
            test.eq(#created, 0, "ярлык заводится только по просьбе программы")
        end)

        test.it("заводит автоматический значок БЕЗ координат", function()
            -- Место здесь не выбирают: оболочка раскладывает значки раньше,
            -- чем терминал сообщил размер, и выбранное ею место могло бы
            -- оказаться за краем — а значок за краем не обрезается, он
            -- исчезает целиком и молча.
            --
            -- Ноль вместо пустоты был бы худшим исходом: это МЕСТО, и значок
            -- стал бы поставленным в левый верхний угол, то есть
            -- неприкосновенным для композитора.
            local created, err = seed.ensure({
                {entry = "butschster.windows.test:unplaced", title = "Без места", desktop = true},
            })
            test.is_nil(err)
            test.eq(#created, 1)
            test.is_nil(created[1].x, "координаты автоматического значка пусты")
            test.is_nil(created[1].y)

            local read = repo.get(created[1].id)
            test.is_nil(read.x, "и остаются пустыми после чтения из базы")
            test.is_nil(read.y)

            repo.delete(created[1].id)
        end)

        test.it("делает значок поставленным, когда место названо", function()
            -- Названное место неприкосновенно: с этого момента композитор
            -- значок не перекладывает, даже если экран сузился и значок ушёл
            -- за край. Так и в настоящей Windows 95 — ушедший за край значок
            -- сам не возвращается.
            local created = seed.ensure({
                {entry = "butschster.windows.test:tobeplaced", title = "Поставят", desktop = true},
            })
            local id = created[1].id
            test.is_nil(repo.get(id).x, "пока места не назвали, оно пусто")

            local moved, err = repo.update(id, {x = 45, y = 9})
            test.is_nil(err)
            test.eq(moved.x, 45)
            test.eq(moved.y, 9)
            test.eq(repo.get(id).x, 45, "место пережило запись")

            repo.delete(id)
        end)

        test.it("отдаёт поставленные значки раньше тех, чьё место не назвали", function()
            -- Порядок задан явно, потому что пустые координаты диалекты
            -- сортируют по-разному: SQLite кладёт NULL в начало, PostgreSQL —
            -- в конец. Без явного правила раскладка значков зависела бы от
            -- того, на какой базе стоит стенд.
            local placed = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "butschster.windows.test:order_placed",
                title = "Поставленный", x = 30, y = 5,
            })
            local unplaced = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "butschster.windows.test:order_unplaced",
                title = "Без места",
            })

            local items = repo.list()
            local seen_placed, seen_unplaced = nil, nil
            for index, item in ipairs(items or {}) do
                if item.id == placed.id then seen_placed = index end
                if item.id == unplaced.id then seen_unplaced = index end
            end
            test.not_nil(seen_placed)
            test.not_nil(seen_unplaced)
            test.is_true(seen_placed < seen_unplaced,
                "значок с местом идёт раньше значка без места")

            repo.delete(placed.id)
            repo.delete(unplaced.id)
        end)
    end)

    -- Тело POST и PATCH стола (butschster.windows.api:desktop_body): то, что
    -- ручки принимали, а стол потом не рисовал.
    test.describe("desktop request bodies", function()
        test.it("битый JSON и не-объект — отказ с причиной, а не пустой успешный PATCH", function()
            local patch, why = desktop_body.update('{"title": ')
            test.is_nil(patch)
            test.is_true(tostring(why):find("body is not JSON", 1, true) == 1, tostring(why))
            patch, why = desktop_body.update("[1, 2]")
            test.is_nil(patch)
            test.eq(why, "body: a JSON object")
            local spec, cwhy = desktop_body.create("")
            test.is_nil(spec)
            test.is_true(tostring(cwhy):find("body is not JSON", 1, true) == 1, tostring(cwhy))
        end)

        test.it("координата — конечное целое от 1 до 10000, и база не клеит бесконечность к углу", function()
            local cases = {
                {'{"x": 1.5}', "x: a whole number"},
                {'{"x": 0}', "x: between 1 and 10000"},
                {'{"y": 10001}', "y: between 1 and 10000"},
                {'{"x": "left"}', "x: a number"},
                -- Строка «1e999» в go-lua не число вовсе: tonumber даёт nil.
                {'{"x": "1e999"}', "x: a number"},
            }
            for _, case in ipairs(cases) do
                local patch, why = desktop_body.update(case[1])
                test.is_nil(patch, case[1])
                test.eq(why, case[2], case[1])
            end
            -- Бесконечность приходит ЧИСЛОМ: JSON 1e999 или вызов из Lua.
            local _, huge = desktop_body.coordinate(math.huge)
            test.eq(huge, "a finite number")
            local _, nan = desktop_body.coordinate(0 / 0)
            test.eq(nan, "a finite number")
            local spec, why = desktop_body.create('{"kind": "shortcut", "entry": "app:x", "x": 1e999, "y": 2}')
            test.is_nil(spec, "1e999 числом не проходит: " .. tostring(why))
            local ok = desktop_body.update('{"x": 10000, "y": "7"}')
            test.eq(ok.x, 10000)
            test.eq(ok.y, 7)
            local item = repo.create({kind = repo.KIND_SHORTCUT, entry = "butschster.windows.test:inf",
                title = "Inf", x = math.huge, y = 3})
            test.is_nil(item.x, "бесконечность — не место, а не ноль")
            repo.delete(item.id)
        end)

        test.it("папка в папку не вкладывается — ни при создании, ни переносом", function()
            local spec, why = desktop_body.create('{"kind": "folder", "title": "A", "parent_id": "p1"}')
            test.is_nil(spec)
            test.eq(why, desktop_body.FOLDER_IN_FOLDER)
            test.eq(desktop_body.nest(repo.KIND_FOLDER, {id = "p1", kind = repo.KIND_FOLDER}), desktop_body.FOLDER_IN_FOLDER)
            test.eq(desktop_body.nest(repo.KIND_SHORTCUT, nil), "parent_id: no such folder")
            test.eq(desktop_body.nest(repo.KIND_SHORTCUT, {id = "s", kind = repo.KIND_SHORTCUT}),
                "parent_id: only a desktop folder can hold items")
            test.is_nil(desktop_body.nest(repo.KIND_SHORTCUT, {id = "p1", kind = repo.KIND_FOLDER}))
        end)

        test.it("parent_id: null — только ключ верхнего уровня, а не подстрока тела", function()
            test.eq(desktop_body.update('{"parent_id": null}').parent_id, false, "вынести на стол")
            test.is_nil(desktop_body.update('{"title": "A", "meta": {"parent_id": null}}').parent_id,
                "вложенный ключ — не наш")
            test.is_nil(desktop_body.update('{"title": "\\"parent_id\\": null"}').parent_id,
                "текст внутри строки — не ключ")
            test.is_nil(desktop_body.update('{"title": "A"}').parent_id, "отсутствие поля — не трогать")
        end)

        test.it("entry и title — не длиннее 256 и 512 символов", function()
            local spec, why = desktop_body.create('{"kind": "shortcut", "entry": "' .. string.rep("e", 257) .. '"}')
            test.is_nil(spec)
            test.eq(why, "entry: at most 256 characters")
            local patch, twhy = desktop_body.update('{"title": "' .. string.rep("t", 513) .. '"}')
            test.is_nil(patch)
            test.eq(twhy, "title: at most 512 characters")
            -- Потолок в символах: 512 кириллических (1024 байта) проходят.
            local cyrillic = string.rep("я", 512)
            test.eq(desktop_body.update('{"title": "' .. cyrillic .. '"}').title, cyrillic)
        end)

        test.it("полный PATCH проходит проверку и доезжает до базы", function()
            local folder = repo.create({kind = repo.KIND_FOLDER, title = "Box"})
            local item = repo.create({kind = repo.KIND_SHORTCUT, entry = "butschster.windows.test:full_patch", title = "Before"})
            local patch, why = desktop_body.update(string.format(
                '{"title": "After", "x": 12, "y": 3, "parent_id": "%s"}', folder.id))
            test.not_nil(patch, tostring(why))
            test.is_nil(desktop_body.nest(item.kind, repo.get(patch.parent_id)))
            local moved = repo.update(item.id, patch)
            test.eq(moved.title, "After")
            test.eq(moved.x, 12)
            test.eq(moved.y, 3)
            test.eq(moved.parent_id, folder.id)
            local out = repo.update(item.id, desktop_body.update('{"parent_id": null}'))
            test.is_nil(out.parent_id, "null выносит на стол")
            repo.delete(item.id)
            repo.delete(folder.id)
        end)
    end)

    -- Второй писатель и отказ посередине: то, что без транзакций и
    -- ON CONFLICT давало ошибку ключа, лишний значок или полтаблицы.
    test.describe("persistence under a second writer", function()
        test.it("двойное предложение одного значка — один ярлык и ни одной ошибки", function()
            local key = "butschster.windows.test:offer_twice"
            local first, ferr = repo.offer(key, {kind = repo.KIND_SHORTCUT, entry = key, title = "Once"})
            test.is_nil(ferr, tostring(ferr))
            test.not_nil(first)
            local second, serr = repo.offer(key, {kind = repo.KIND_SHORTCUT, entry = key, title = "Once"})
            test.is_nil(serr, tostring(serr))
            test.eq(second, false, "второй раз — «уже предлагали», а не ошибка ключа")
            local count = 0
            for _, item in ipairs(repo.list() or {}) do
                if item.entry == key then count = count + 1 end
            end
            test.eq(count, 1, "значок один")
            local again, merr = repo.mark_seeded(key)
            test.is_nil(merr, tostring(merr))
            test.eq(again, false, "повторная отметка — false, а не ошибка")
            repo.delete(first.id)
        end)

        test.it("настройка пишется и читается плейсхолдерами одного диалекта", function()
            local _, err = repo.set_setting("test.dialect", "a")
            test.is_nil(err, tostring(err))
            repo.set_setting("test.dialect", "b")
            test.eq(repo.setting("test.dialect"), "b")
        end)

        test.it("миграция 02: пересборка таблицы в транзакции откатывается целиком", function()
            -- Раннер wippy/migration зовёт `up(tx)` внутри своей транзакции
            -- и откатывает её на любой ошибке (migration.lua, execute_migration).
            -- Здесь проверяется, что на этом драйвере DDL SQLite откатывается
            -- вместе с ней: отказ после DROP не оставляет одну `_new`, и
            -- повторный прогон начинается с исходной таблицы.
            local db = assert(sql.get("app:db"))
            local kind = db:type()
            if kind ~= "sqlite" then db:release(); return end
            local function count(): any
                local rows = assert(db:query("SELECT COUNT(*) AS n FROM butschster_windows_desktop_items", {}))
                return tonumber(rows[1].n)
            end
            local marker = repo.create({kind = repo.KIND_FOLDER, title = "Survives the rollback"})
            local before = count()
            local tx = assert(db:begin())
            local _, cerr = tx:execute([[
                CREATE TABLE butschster_windows_desktop_items_new (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, entry TEXT, parent_id TEXT,
                    title TEXT NOT NULL, x INTEGER, y INTEGER,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            ]], {})
            test.is_nil(cerr, tostring(cerr))
            local _, ierr = tx:execute("INSERT INTO butschster_windows_desktop_items_new SELECT id, kind, entry, parent_id, title, x, y, created_at, updated_at FROM butschster_windows_desktop_items", {})
            test.is_nil(ierr, tostring(ierr))
            local _, derr = tx:execute("DROP TABLE butschster_windows_desktop_items", {})
            test.is_nil(derr, tostring(derr))
            -- Здесь миграция упала бы до RENAME — и раннер откатывает.
            tx:rollback()
            test.eq(count(), before, "исходная таблица цела со всеми строками")
            local leftovers = assert(db:query(
                "SELECT name FROM sqlite_master WHERE name = 'butschster_windows_desktop_items_new'", {}))
            test.eq(#leftovers, 0, "`_new` не осталась")
            db:release()
            repo.delete(marker.id)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
