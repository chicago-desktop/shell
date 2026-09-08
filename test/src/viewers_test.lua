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

local function run()
    test.describe("аргумент окна", function()
        test.it("собирается и разбирается одной формой", function()
            local args = files.encode("app:uploads_store", "/папка с пробелом/Фото.PNG")
            local file, why = files.parse(args)
            test.expect(file, tostring(why)).to_be_truthy()
            test.expect(file.drive).to_equal("app:uploads_store")
            test.expect(file.path).to_equal("/папка с пробелом/Фото.PNG")
            test.expect(file.name).to_equal("Фото.PNG")
            test.expect(file.ext).to_equal("png")
        end)

        test.it("отказывает с причиной на мусор и пустоту", function()
            local file, why = files.parse("")
            test.expect(file).to_be_nil()
            test.expect(tostring(why):find("какой файл", 1, true) ~= nil).to_be_true()
            file, why = files.parse("{\"drive\":\"x\"}")
            test.expect(file).to_be_nil()
            test.expect(tostring(why):find("нет диска или пути", 1, true) ~= nil).to_be_true()
        end)

        test.it("расширение — строчными, без точки, только последнее", function()
            test.expect(files.ext("archive.tar.GZ")).to_equal("gz")
            test.expect(files.ext("/a/b/README")).to_equal("")
            test.expect(files.ext(".bashrc")).to_equal("")
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
            test.expect(by_ext.md.entry).to_equal("app:notepad")
            test.expect(by_ext.png.entry).to_equal("app:viewer")
            test.expect(by_ext.png.title).to_equal("Картинки")
            test.expect(by_ext.png.width).to_equal(70)
        end)

        test.it("спор за расширение называет обоих и выбирает устойчиво", function()
            local by_ext, warnings = associations.table(programs)
            test.expect(by_ext.txt.entry).to_equal("app:notepad")
            test.expect(#warnings).to_equal(1)
            test.expect(warnings[1].ext).to_equal("txt")
            test.expect(#warnings[1].entries).to_equal(2)
        end)

        test.it("находит программу по имени файла без учёта регистра", function()
            local program = associations.find(programs, "/x/Photo.JPG")
            test.expect(program.entry).to_equal("app:viewer")
        end)

        test.it("отказывает с причиной, когда открыть нечем", function()
            local program, why = associations.find(programs, "book.pdf")
            test.expect(program).to_be_nil()
            test.expect(tostring(why):find(".pdf", 1, true) ~= nil).to_be_true()
            program, why = associations.find(programs, "Makefile")
            test.expect(program).to_be_nil()
            test.expect(tostring(why):find("нет расширения", 1, true) ~= nil).to_be_true()
        end)

        test.it("заявка на окно несёт запись, размер и аргумент, который разбирается обратно", function()
            local spec, why = associations.open(programs, "app:uploads_store", "/notes/todo.txt")
            test.expect(spec, tostring(why)).to_be_truthy()
            test.expect(spec.action).to_equal("open_window")
            test.expect(spec.entry).to_equal("app:notepad")
            test.expect(spec.w).to_equal(64)
            test.expect(spec.title).to_equal("todo.txt — Блокнот")
            local file = files.parse(spec.args)
            test.expect(file.path).to_equal("/notes/todo.txt")
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
            test.expect(big.w).to_equal(300)
            test.expect(big.h).to_equal(150)
            test.expect(big.y).to_equal(26)
            local small = picture_render.geometry({mode = "fit"}, 32, 32, 300, 200)
            test.expect(small.w).to_equal(32)
            test.expect(small.x).to_equal(135)
        end)

        test.it("в масштабе сдвиг зажат краем картинки", function()
            local box = picture_render.geometry({mode = "zoom", zoom = 2, x = 9999, y = 0}, 100, 100, 50, 50)
            test.expect(box.w).to_equal(200)
            test.expect(box.x).to_equal(1 - 150)
            test.expect(box.y).to_equal(1)
        end)

        test.it("кадр ровно размера окна и один и тот же, пока ничего не менялось", function()
            local state = picture_state(40, 20)
            local first, why = picture_render.frame("w1", state, 100, 60)
            test.expect(first, tostring(why)).to_be_truthy()
            local w, h = first:size()
            test.expect(w).to_equal(100)
            test.expect(h).to_equal(60)
            local version = first:version()
            local second = picture_render.frame("w1", state, 100, 60)
            test.expect(second == first).to_be_true()
            test.expect(second:version()).to_equal(version)
            -- Смена способа показа перерисовывает ТОТ ЖЕ растр: версия
            -- сдвигается, тождество остаётся — поверхность переотправит.
            state.mode, state.zoom = "zoom", 2
            local third = picture_render.frame("w1", state, 100, 60)
            test.expect(third == first).to_be_true()
            test.expect(third:version() > version).to_be_true()
        end)

        test.it("размещение накрывает ровно внутренний прямоугольник", function()
            local window = {id = "w2", content_state = picture_state(40, 20), waiting = false}
            local placed, why = picture_render.placement(window, {x = 5, y = 3, cols = 20, rows = 6}, {w = 10, h = 20})
            test.expect(placed, tostring(why)).to_be_truthy()
            test.expect(placed.id).to_equal("win:w2:content")
            test.expect(placed.x).to_equal(5)
            test.expect(placed.cols).to_equal(20)
            local w, h = placed.raster:size()
            test.expect(w).to_equal(200)
            test.expect(h).to_equal(120)
        end)

        test.it("ждущее окно и отказ поставщика называются, а не рисуются", function()
            local placed, why = picture_render.placement({id = "w3", waiting = true}, {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.expect(placed).to_be_nil()
            test.expect(tostring(why):find("не доехала", 1, true) ~= nil).to_be_true()
            placed, why = picture_render.placement({id = "w4", content_state = {failure = "диск закрыт"}},
                {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.expect(placed).to_be_nil()
            test.expect(why).to_equal("диск закрыт")
        end)
    end)
end

return {run = run}
