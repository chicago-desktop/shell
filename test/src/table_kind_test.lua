-- A table cell's picture from its kind, and the frame meta of an SDK window.
--
-- A cell without `image` but with a `kind` gets that kind's picture by the one
-- rule an icon's comes from — `images.name_for` in pixels, `icons.glyph` in
-- cells — so Details shows a folder without the window naming a file. And
-- `app.frame_meta`: `definition.title` and `definition.image`, as strings or
-- functions of the model, are what a native frame says beside its tree.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local glyphs = require("glyphs")
local app = require("app")

local CELL = {w = 10, h = 20}
local W, H = 24, 3

local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end

local function tree(cell: any): any
    return {kind = "column", children = {
        {kind = "table", id = "t", header = false, columns = {{title = "Name", weight = 1}},
            rows = {{id = "r", cells = {cell}}}},
    }}
end

local function drawn_row(cell: any): string
    local interaction = ui.interaction()
    local plan = ui.plan(tree(cell), W, H, interaction)
    return plain(cells.rows(plan, interaction, W, H)[1])
end

local function face_font(): any
    local files = assert(fs.get("chicago.shell.theme:fonts"))
    return assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
end

local function painted(cell: any, fonts: any): string
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "kind", state_revision = 1, content_state = {sdk = 1, revision = 1,
        ui = tree(cell), interaction = ui.interaction()}}, {x = 1, y = 1, cols = W, rows = H}, CELL, fonts, store))
    return assert(placed.raster:encode("png"))
end

local function define_tests()
    test.describe("SDK table cell pictures and frame meta", function()
        test.it("cells: a cell with a kind and no icon gets the kind's glyph; its own icon still wins", function()
            local row = drawn_row({text = "docs", kind = "folder"})
            test.is_true(row:find(glyphs.icons.folder .. " docs", 1, true) ~= nil, "the folder glyph: " .. row)
            test.is_nil(drawn_row({text = "docs"}):find(glyphs.icons.folder, 1, true), "no kind, no glyph")
            row = drawn_row({text = "docs", kind = "folder", icon = "▣"})
            test.is_true(row:find("▣ docs", 1, true) ~= nil, "an explicit icon: " .. row)
        end)

        test.it("pixels: a cell's kind draws that kind's picture — the same as naming it", function()
            local fonts = {face = face_font()}
            local by_kind = painted({text = "docs", kind = "folder"}, fonts)
            test.eq(by_kind, painted({text = "docs", kind = "folder", image = "folder"}, fonts),
                "a folder row shows the folder picture")
            test.is_true(by_kind ~= painted({text = "docs"}, fonts), "a cell with neither draws none")
            test.eq(painted({text = "a.txt", kind = "file"}, fonts), painted({text = "a.txt", kind = "file", image = "document"}, fonts),
                "a file without a program picture is a document")
        end)

        test.it("frame meta: title and image as strings or functions of the model; empty keeps the window's own", function()
            local context = app.context({width = 10, height = 5})
            local title, image = app.frame_meta({title = "Run", image = "run"}, {}, context)
            test.eq(title, "Run")
            test.eq(image, "run")
            title, image = app.frame_meta({
                title = function(model: any): any return model.caption end,
                image = function(model: any): any return model.picture end,
            }, {caption = "docs", picture = "drive"}, context)
            test.eq(title, "docs")
            test.eq(image, "drive")
            title, image = app.frame_meta({title = "", image = ""}, {}, context)
            test.is_nil(title)
            test.is_nil(image, "an empty picture keeps the window's own")
            title, image = app.frame_meta({}, {}, context)
            test.is_nil(title)
            test.is_nil(image)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
