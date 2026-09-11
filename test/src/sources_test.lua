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
local render = require("render")
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")

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
    test.describe("Explorer input", function()
        test.it("scrolls a real viewport with wheel and scrollbar arrows", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            local width, height = 22, 9
            local shape = render.shape(width, height, #shown.objects, 0)
            test.is_true(shape.scrolling, "fixture must require scrolling")
            test.is_true(shape.rows > 0)
            local view = assert(tty.viewport({width = width, height = height}))
            local pid, why = process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("butschster.windows.explorer:window", "app:processes")
            test.is_nil(why)
            test.not_nil(pid)
            local state: any = {path = model.ROOT, title = shown.title, objects = shown.objects,
                selected = 0, offset = 0}
            local function wait_frame(offset)
                state.offset = offset
                local canvas = tty.canvas(width, height)
                local hits = render.window(canvas, state, width, height)
                local expected = table.concat(canvas:rows(), "\n")
                local actual = ""
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    local snap: any = view:snapshot(-1)
                    actual = snap and table.concat(snap.rows or {}, "\n") or ""
                    if actual == expected then return hits end
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.eq(actual, expected, "viewport did not reach scroll row " .. offset)
                return hits
            end
            local area = render.layout(state, width, height).inner
            wait_frame(0)
            view:send({type = "mouse", action = "wheel", button = "wheel_down", x = area.x, y = area.y})
            wait_frame(1)
            view:send({type = "mouse", action = "wheel", button = "wheel_up", x = area.x, y = area.y})
            wait_frame(0)
            -- Стрелки полосы — края `plan.scroll`: ту же геометрию окно отдаёт
            -- `scroll.pointer`, своих попаданий у полосы больше нет.
            local bar: any = render.layout(state, width, height).scroll
            test.not_nil(bar, "the fixture shows a scrollbar")
            for _, arrow in ipairs({{y = bar.y + bar.h - 1, offset = 1}, {y = bar.y, offset = 0}}) do
                view:send({type = "mouse", action = "press", button = "left", x = bar.x, y = arrow.y})
                view:send({type = "mouse", action = "release", button = "left", x = bar.x, y = arrow.y})
                wait_frame(arrow.offset)
            end
            view:send({type = "close"})
            view:close()
            process.terminate(tostring(pid))
        end)
    end)
    test.describe("butschster.windows explorer sources", function()
        test.it("берёт диски из реестра, а не из своей таблицы", function()
            -- Диск, объявленный установленным модулем, обязан появиться сам.
            -- Харнесс объявил один — и вот он, без единой строки про него в
            -- оболочке.
            local records, err = sources.drives()
            test.is_nil(err, "реестр обязан прочитаться")
            test.not_nil(records)
            local seen = {}
            for _, record in ipairs(records) do
                test.is_true(record.kind == "fs.directory" or record.kind == "fs.embed",
                    "реестр вернул не FS: " .. tostring(record.id))
                test.is_nil(seen[record.id], "каждая FS показывается один раз")
                seen[record.id] = true
            end

            local drives = model.drives(records)
            local probe = by_id(drives, PROBE)
            test.not_nil(probe, "объявленная файловая система обязана стать диском")
            test.eq(probe.kind, "drive")
            test.eq(probe.open.path, "drive/" .. PROBE,
                "двойной щелчок обязан вести в этот диск, а не в соседний")
        end)

        test.it("показывает в корне только FS", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            test.not_nil(by_id(shown.objects, PROBE), "диск обязан быть в корне")
            test.is_nil(by_id(shown.objects, "programs"))
            test.is_nil(by_id(shown.objects, "desktop"))
            test.is_nil(by_id(shown.objects, "windows"))
            for _, object in ipairs(shown.objects) do
                test.eq(object.kind, "drive")
                test.is_true(object.open.path:sub(1, 6) == "drive/")
            end
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
            -- Файл открывает программа из реестра типов: .lua объявлен у
            -- Блокнота, и заявка обязана нести его запись и аргумент с
            -- диском и путём внутри диска — иначе окно откроется пустым.
            test.not_nil(self_file.open, "файл с объявленным расширением обязан открываться")
            test.eq(self_file.open.action, "open_window")
            test.eq(self_file.open.entry, "butschster.windows.viewers:notepad")
            test.is_true(tostring(self_file.open.args):find(PROBE, 1, true) ~= nil,
                "аргумент обязан называть диск")
            test.is_true(tostring(self_file.open.args):find("/sources_test.lua", 1, true) ~= nil,
                "аргумент обязан называть путь внутри диска")
            test.eq(self_file.image, "text_document", "значок файла — значок Блокнота")
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
