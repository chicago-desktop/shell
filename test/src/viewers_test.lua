-- Просмотрщики: реестр типов, аргумент окна, отрисовка картинки.
--
-- Реестр типов и аргумент — чистые таблицы, проверяются прямо. Отрисовка —
-- настоящим gfx: растр кодируется в PNG, едет base64, как из поставщика,
-- и кадр обязан быть ровно размера окна, а повтор — тем же растром.

local test = require("test")
local gfx = require("gfx")
local base64 = require("base64")

local files = require("files")
local associations = require("associations")
local picture_render = require("picture_render")

local function define_tests()
    test.describe("аргумент окна", function()
        test.it("собирается и разбирается одной формой", function()
            local args = files.encode("app:uploads_store", "/папка с пробелом/Фото.PNG")
            local file, why = files.parse(args)
            test.not_nil(file, tostring(why))
            test.eq(file.drive, "app:uploads_store")
            test.eq(file.path, "/папка с пробелом/Фото.PNG")
            test.eq(file.name, "Фото.PNG")
            test.eq(file.ext, "png")
        end)

        test.it("отказывает с причиной на мусор и пустоту", function()
            local file, why = files.parse("")
            test.is_nil(file)
            test.is_true(tostring(why):find("which file", 1, true) ~= nil)
            file, why = files.parse("{\"drive\":\"x\"}")
            test.is_nil(file)
            test.is_true(tostring(why):find("no drive or path", 1, true) ~= nil)
        end)

        test.it("расширение — строчными, без точки, только последнее", function()
            test.eq(files.ext("archive.tar.GZ"), "gz")
            test.eq(files.ext("/a/b/README"), "")
            test.eq(files.ext(".bashrc"), "")
        end)
    end)

    test.describe("реестр типов файлов", function()
        local programs = {
            {entry = "app:notepad", title = "Блокнот", width = 64, height = 20, opens = {"txt", ".MD"}},
            {id = "app:viewer", meta = {title = "Картинки", width = 70, height = 22, opens = {"png", "jpg"}}},
            {entry = "app:other", title = "Другой", opens = {"txt"}},
            {entry = "app:mute", title = "Без типов"},
        }

        test.it("собирает таблицу из обеих форм записи", function()
            local by_ext = associations.table(programs)
            test.eq(by_ext.md.entry, "app:notepad")
            test.eq(by_ext.png.entry, "app:viewer")
            test.eq(by_ext.png.title, "Картинки")
            test.eq(by_ext.png.width, 70)
        end)

        test.it("спор за расширение называет обоих и выбирает устойчиво", function()
            local by_ext, warnings = associations.table(programs)
            test.eq(by_ext.txt.entry, "app:notepad")
            test.eq(#warnings, 1)
            test.eq(warnings[1].ext, "txt")
            test.eq(#warnings[1].entries, 2)
        end)

        test.it("находит программу по имени файла без учёта регистра", function()
            local program = associations.find(programs, "/x/Photo.JPG")
            test.eq(program.entry, "app:viewer")
        end)

        test.it("отказывает с причиной, когда открыть нечем", function()
            local program, why = associations.find(programs, "book.pdf")
            test.is_nil(program)
            test.is_true(tostring(why):find(".pdf", 1, true) ~= nil)
            program, why = associations.find(programs, "Makefile")
            test.is_nil(program)
            test.is_true(tostring(why):find("has no extension", 1, true) ~= nil)
        end)

        test.it("значок файла — значок программы, которая его открывает", function()
            local with_images = {
                {entry = "app:notepad", title = "Блокнот", image = "text_document", opens = {"txt"}},
                {entry = "app:viewer", meta = {title = "Картинки", image = "document", opens = {"png"}}},
                {entry = "app:mute", title = "Без значка", opens = {"dat"}},
            }
            test.eq(associations.image_for(with_images, "readme.TXT"), "text_document")
            test.eq(associations.image_for(with_images, "a.png"), "document")
            test.is_nil(associations.image_for(with_images, "a.dat"))
            test.is_nil(associations.image_for(with_images, "a.pdf"))
        end)

        test.it("заявка на окно несёт запись, размер и аргумент, который разбирается обратно", function()
            local spec, why = associations.open(programs, "app:uploads_store", "/notes/todo.txt")
            test.not_nil(spec, tostring(why))
            test.eq(spec.action, "open_window")
            test.eq(spec.entry, "app:notepad")
            test.eq(spec.w, 64)
            test.eq(spec.title, "todo.txt — Блокнот")
            local file = files.parse(spec.args)
            test.eq(file.path, "/notes/todo.txt")
        end)
    end)

    test.describe("отрисовка картинки", function()
        local function picture_state(w, h, extra)
            local source = gfx.raster(w, h)
            source:fill("#ff0000")
            local png = assert(source:encode("png"))
            local state = {drive = "d", path = "/p.png", name = "p.png", size = #png,
                data = base64.encode(png), mode = "fit", zoom = 1, x = 0, y = 0}
            for key, value in pairs(extra or {}) do state[key] = value end
            return state
        end

        test.it("вписывает большую картинку в окно, не увеличивает маленькую", function()
            local big = picture_render.geometry({mode = "fit"}, 1000, 500, 300, 200)
            test.eq(big.w, 300)
            test.eq(big.h, 150)
            test.eq(big.y, 26)
            local small = picture_render.geometry({mode = "fit"}, 32, 32, 300, 200)
            test.eq(small.w, 32)
            test.eq(small.x, 135)
        end)

        test.it("в масштабе сдвиг зажат краем картинки", function()
            local box = picture_render.geometry({mode = "zoom", zoom = 2, x = 9999, y = 0}, 100, 100, 50, 50)
            test.eq(box.w, 200)
            test.eq(box.x, 1 - 150)
            test.eq(box.y, 1)
        end)

        test.it("кадр ровно размера окна и один и тот же, пока ничего не менялось", function()
            local state = picture_state(40, 20)
            local first, why = picture_render.frame("w1", state, 100, 60)
            test.not_nil(first, tostring(why))
            local w, h = first:size()
            test.eq(w, 100)
            test.eq(h, 60)
            local version = first:version()
            local second = picture_render.frame("w1", state, 100, 60)
            test.is_true(second == first)
            test.eq(second:version(), version)
            -- Смена способа показа перерисовывает ТОТ ЖЕ растр: версия
            -- сдвигается, тождество остаётся — поверхность переотправит.
            state.mode, state.zoom = "zoom", 2
            local third = picture_render.frame("w1", state, 100, 60)
            test.is_true(third == first)
            test.is_true(third:version() > version)
        end)

        test.it("размещение накрывает ровно внутренний прямоугольник", function()
            local window = {id = "w2", content_state = picture_state(40, 20), waiting = false}
            local placed, why = picture_render.placement(window, {x = 5, y = 3, cols = 20, rows = 6}, {w = 10, h = 20})
            test.not_nil(placed, tostring(why))
            test.eq(placed.id, "win:w2:content")
            test.eq(placed.x, 5)
            test.eq(placed.cols, 20)
            local w, h = placed.raster:size()
            test.eq(w, 200)
            test.eq(h, 120)
        end)

        test.it("ждущее окно и отказ поставщика называются, а не рисуются", function()
            local placed, why = picture_render.placement({id = "w3", waiting = true}, {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.is_nil(placed)
            test.is_true(tostring(why):find("has not arrived", 1, true) ~= nil)
            placed, why = picture_render.placement({id = "w4", content_state = {failure = "диск закрыт"}},
                {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.is_nil(placed)
            test.eq(why, "диск закрыт")
        end)
    end)
end

-- Форма раннера — как у shell_test. `return {run = run}` с describe внутри
-- run считался и был зелёным, НЕ выполняя ни одной проверки: мутация
-- round_ceiling(7) == 999 проходила. Проверка, которую никто не запускает,
-- хуже отсутствующей — на неё ссылаются.
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
