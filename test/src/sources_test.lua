-- Источники «Моего компьютера» на живом реестре и живой базе.
--
-- Здесь проверяется ровно то, чего чистая сборка объектов проверить не может:
-- что диск действительно приходит из реестра, что содержимое действительно
-- читается модулем `fs`, и что закрытая дверь отличается от пустой комнаты.
--
-- Харнесс объявляет свою `fs.directory` — `app:probe_fs`. Она и есть весь
-- смысл этого набора: ошибись мы в имени фильтра или в форме записи, тест на
-- выдуманных таблицах остался бы зелёным, а окно на стенде показало бы
-- пустоту.
local test = require("test")
local model = require("model")
local repo = require("repo")
local sources = require("sources")

local PROBE = "app:probe_fs"

local function by_id(objects, id)
    for _, object in ipairs(objects or {}) do
        if object.id == id then return object end
    end
    return nil
end

local function by_title(objects, title)
    for _, object in ipairs(objects or {}) do
        if object.title == title then return object end
    end
    return nil
end

local function define_tests()
    test.describe("butschster.windows explorer sources", function()
        test.it("берёт диски из реестра, а не из своей таблицы", function()
            -- Диск, объявленный установленным модулем, обязан появиться сам.
            -- Харнесс объявил один — и вот он, без единой строки про него в
            -- оболочке.
            local records, err = sources.drives()
            test.is_nil(err, "реестр обязан прочитаться")
            test.not_nil(records)

            local drives = model.drives(records)
            local probe = by_id(drives, PROBE)
            test.not_nil(probe, "объявленная файловая система обязана стать диском")
            test.eq(probe.kind, "drive")
            test.eq(probe.open.path, "drive/" .. PROBE,
                "двойной щелчок обязан вести в этот диск, а не в соседний")
        end)

        test.it("показывает диски в корне вместе с папками оболочки", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            test.not_nil(by_id(shown.objects, PROBE), "диск обязан быть в корне")
            test.not_nil(by_id(shown.objects, "programs"))
            test.not_nil(by_id(shown.objects, "desktop"))
            test.not_nil(by_id(shown.objects, "windows"))
            test.eq(shown.objects[1].kind, "drive",
                "диски идут первыми — как в настоящем «Моём компьютере»")
        end)

        test.it("читает содержимое диска модулем fs", function()
            -- Каталог набора тестов заведомо не пуст, и в нём заведомо лежит
            -- этот самый файл. Проверять «прочиталось хоть что-то» мало:
            -- пустой список тоже «хоть что-то».
            local shown, err = sources.list("drive/" .. PROBE, {})
            test.is_nil(err, "объявленный диск обязан открыться")
            test.is_true(#shown.objects > 0, "каталог набора тестов не пуст")

            local self_file = by_title(shown.objects, "sources_test.lua")
            test.not_nil(self_file, "файл, который это пишет, обязан быть виден")
            test.eq(self_file.kind, "file")
            test.is_nil(self_file.open,
                "просмотрщика файлов нет, и обещать открытие нечем")
        end)

        test.it("отвечает причиной на диск, которого нет, а не пустотой", function()
            -- Пустой каталог и закрытая дверь — разные вещи. Слитые в одно,
            -- они отправляют человека искать пропавшие файлы.
            local shown, err = sources.list("drive/app:no_such_fs", {})
            test.is_nil(shown)
            test.not_nil(err, "отказ обязан быть назван словами")
        end)

        test.it("не показывает содержимое папок на верхнем уровне стола", function()
            -- Иначе вложенный значок виден дважды: и в папке, и рядом с ней.
            local folder, ferr = repo.create({
                kind = repo.KIND_FOLDER, title = "Ящик " .. tostring(os.time()),
            })
            test.is_nil(ferr)
            local inside, ierr = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "app:probe_fs",
                title = "Вложенный", parent_id = folder.id,
            })
            test.is_nil(ierr)

            local top = sources.list("desktop", {})
            test.is_nil(by_id(top.objects, inside.id),
                "вложенный значок на верхнем уровне не показывается")
            test.not_nil(by_id(top.objects, folder.id), "сама папка — показывается")

            local opened, oerr = sources.list("desktop/" .. folder.id, {})
            test.is_nil(oerr)
            test.eq(opened.title, folder.title,
                "заголовок обязан называть открытую папку, а не «Рабочий стол»")
            test.not_nil(by_id(opened.objects, inside.id),
                "внутри папки лежит то, что в неё положили")

            repo.delete(inside.id)
            repo.delete(folder.id)
        end)

        test.it("отвечает причиной на папку стола, которой нет", function()
            -- Молчание превратило бы опечатку в успешно открытую пустоту.
            local shown, err = sources.list("desktop/no-such-folder", {})
            test.is_nil(shown)
            test.not_nil(err)
        end)

        test.it("не выдаёт неизвестный путь за корень", function()
            local shown, err = sources.list("куда-то", {})
            test.is_nil(shown)
            test.not_nil(err)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
