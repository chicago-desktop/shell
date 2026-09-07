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
            local folder = repo.create({kind = repo.KIND_FOLDER, title = "Папка", x = 0, y = 0})
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
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
