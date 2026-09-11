-- Viewers: the type registry, the window argument, picture drawing.
--
-- The type registry and the argument are pure tables, checked directly.
-- Drawing — with real gfx: the raster is encoded into PNG, travels as base64,
-- as from the provider, and the frame must be exactly the size of the
-- window, and a repeat — the same raster.

local test = require("test")
local gfx = require("gfx")
local base64 = require("base64")

local files = require("files")
local associations = require("associations")
local picture_render = require("picture_render")

local function define_tests()
    test.describe("window argument", function()
        test.it("is assembled and parsed with one form", function()
            local args = files.encode("app:uploads_store", "/папка с пробелом/Фото.PNG")
            local file, why = files.parse(args)
            test.not_nil(file, tostring(why))
            test.eq(file.drive, "app:uploads_store")
            test.eq(file.path, "/папка с пробелом/Фото.PNG")
            test.eq(file.name, "Фото.PNG")
            test.eq(file.ext, "png")
        end)

        test.it("refuses with a reason on garbage and emptiness", function()
            local file, why = files.parse("")
            test.is_nil(file)
            test.is_true(tostring(why):find("which file", 1, true) ~= nil)
            file, why = files.parse("{\"drive\":\"x\"}")
            test.is_nil(file)
            test.is_true(tostring(why):find("no drive or path", 1, true) ~= nil)
        end)

        test.it("extension — lower case, without the dot, only the last one", function()
            test.eq(files.ext("archive.tar.GZ"), "gz")
            test.eq(files.ext("/a/b/README"), "")
            test.eq(files.ext(".bashrc"), "")
        end)
    end)

    test.describe("file-type registry", function()
        local programs = {
            {entry = "app:notepad", title = "Notepad", width = 64, height = 20, opens = {"txt", ".MD"}},
            {id = "app:viewer", meta = {title = "Pictures", width = 70, height = 22, opens = {"png", "jpg"}}},
            {entry = "app:other", title = "Other", opens = {"txt"}},
            {entry = "app:mute", title = "No types"},
        }

        test.it("assembles the table from both entry forms", function()
            local by_ext = associations.table(programs)
            test.eq(by_ext.md.entry, "app:notepad")
            test.eq(by_ext.png.entry, "app:viewer")
            test.eq(by_ext.png.title, "Pictures")
            test.eq(by_ext.png.width, 70)
        end)

        test.it("a dispute over an extension names both and chooses stably", function()
            local by_ext, warnings = associations.table(programs)
            test.eq(by_ext.txt.entry, "app:notepad")
            test.eq(#warnings, 1)
            test.eq(warnings[1].ext, "txt")
            test.eq(#warnings[1].entries, 2)
        end)

        test.it("finds the program by file name regardless of case", function()
            local program = associations.find(programs, "/x/Photo.JPG")
            test.eq(program.entry, "app:viewer")
        end)

        test.it("refuses with a reason when there is nothing to open it with", function()
            local program, why = associations.find(programs, "book.pdf")
            test.is_nil(program)
            test.is_true(tostring(why):find(".pdf", 1, true) ~= nil)
            program, why = associations.find(programs, "Makefile")
            test.is_nil(program)
            test.is_true(tostring(why):find("has no extension", 1, true) ~= nil)
        end)

        test.it("a file's icon is the icon of the program that opens it", function()
            local with_images = {
                {entry = "app:notepad", title = "Notepad", image = "text_document", opens = {"txt"}},
                {entry = "app:viewer", meta = {title = "Pictures", image = "document", opens = {"png"}}},
                {entry = "app:mute", title = "No icon", opens = {"dat"}},
            }
            test.eq(associations.image_for(with_images, "readme.TXT"), "text_document")
            test.eq(associations.image_for(with_images, "a.png"), "document")
            -- `file_image` is the icon of the files, separate from the
            -- program's icon: Notepad in the menu is a notepad, its .txt in
            -- the explorer is a document.
            local split = {
                {entry = "app:notepad", title = "Notepad", image = "notepad", file_image = "text_document", opens = {"txt"}},
                {entry = "app:viewer", meta = {title = "Pictures", image = "document", file_image = "", opens = {"png"}}},
            }
            test.eq(associations.image_for(split, "a.txt"), "text_document")
            test.eq(associations.image_for(split, "a.png"), "document", "an empty file_image is the same as an absent one")
            test.eq(associations.table(split).txt.image, "text_document")
            test.is_nil(associations.image_for(with_images, "a.dat"))
            test.is_nil(associations.image_for(with_images, "a.pdf"))
        end)

        test.it("a window request carries the entry, the size and an argument that parses back", function()
            local spec, why = associations.open(programs, "app:uploads_store", "/notes/todo.txt")
            test.not_nil(spec, tostring(why))
            test.eq(spec.action, "open_window")
            test.eq(spec.entry, "app:notepad")
            test.eq(spec.w, 64)
            test.eq(spec.title, "todo.txt — Notepad")
            local file = files.parse(spec.args)
            test.eq(file.path, "/notes/todo.txt")
        end)
    end)

    test.describe("picture drawing", function()
        local function picture_state(w, h, extra)
            local source = gfx.raster(w, h)
            source:fill("#ff0000")
            local png = assert(source:encode("png"))
            local state = {drive = "d", path = "/p.png", name = "p.png", size = #png,
                data = base64.encode(png), mode = "fit", zoom = 1, x = 0, y = 0}
            for key, value in pairs(extra or {}) do state[key] = value end
            return state
        end

        test.it("fits a large picture into the window, does not enlarge a small one", function()
            local big = picture_render.geometry({mode = "fit"}, 1000, 500, 300, 200)
            test.eq(big.w, 300)
            test.eq(big.h, 150)
            test.eq(big.y, 26)
            local small = picture_render.geometry({mode = "fit"}, 32, 32, 300, 200)
            test.eq(small.w, 32)
            test.eq(small.x, 135)
        end)

        test.it("at a zoom the offset is clamped by the edge of the picture", function()
            local box = picture_render.geometry({mode = "zoom", zoom = 2, x = 9999, y = 0}, 100, 100, 50, 50)
            test.eq(box.w, 200)
            test.eq(box.x, 1 - 150)
            test.eq(box.y, 1)
        end)

        test.it("the frame is exactly the window size and one and the same while nothing changed", function()
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
            -- Changing the display mode redraws THE SAME raster: the version
            -- moves, the identity stays — the surface will resend it.
            state.mode, state.zoom = "zoom", 2
            local third = picture_render.frame("w1", state, 100, 60)
            test.is_true(third == first)
            test.is_true(third:version() > version)
        end)

        test.it("the placement covers exactly the inner rectangle", function()
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

        test.it("a waiting window and a provider failure are named, not drawn", function()
            local placed, why = picture_render.placement({id = "w3", waiting = true}, {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.is_nil(placed)
            test.is_true(tostring(why):find("has not arrived", 1, true) ~= nil)
            placed, why = picture_render.placement({id = "w4", content_state = {failure = "drive closed"}},
                {x = 1, y = 1, cols = 10, rows = 5}, {w = 10, h = 20})
            test.is_nil(placed)
            test.eq(why, "drive closed")
        end)
    end)
end

-- The runner form is as in shell_test. `return {run = run}` with describe
-- inside run was counted and was green WITHOUT running a single check: the
-- mutation round_ceiling(7) == 999 passed. A check nobody runs is worse than
-- an absent one — people refer to it.
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
