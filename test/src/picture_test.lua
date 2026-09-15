-- The SDK's `picture`: a pack's `pictures/<file>.png` of any width and height.
--
-- Checked where it can go wrong silently: the loader (the square sizes must
-- stay as they were), the two plans (the window's and the compositor's must
-- give the same rows, so the height travels with the tree), the pixels (1:1,
-- cut to the rect — compared with a raster built by hand, byte for byte), the
-- text a missing picture leaves (bold, never a hole), and the rows of a
-- picture whose file was replaced (painted again, not kept).
local test = require("test")
local images = require("images")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local app = require("app")
local palette = require("palette")
local pixels = require("pixels")
local registry = require("registry")
local fs = require("fs")
local gfx = require("gfx")

-- test/fixtures/images/pictures/banner.png: 40×24, no two neighbours alike.
local BANNER = "app:test_images/banner"
local ABSENT = "app:test_images/absent"
local CELL = {w = 8, h = 16}
local FACE = palette.exact.face

local function fonts(): any
    local files = assert(fs.get("chicago.shell.theme:fonts"))
    local face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
    local bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
    return {face = face, bold = bold}
end

-- A pack applied to the live registry, as images_test does it.
local function apply_pack(id: string, directory: string): (any, any)
    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, serr end
    local changes = snapshot:changes()
    changes:create({id = id, kind = "fs.directory", meta = {type = images.PACK_TYPE},
        data = {base = "project", directory = directory, auto_init = true}})
    return changes:apply()
end

local function drop_pack(id: string)
    local snapshot = registry.snapshot()
    if not snapshot or not registry.get(id) then return end
    local changes = snapshot:changes()
    changes:delete(id)
    changes:apply()
end

local function png(w: integer, h: integer, color: string): string
    local raster = gfx.raster(w, h)
    raster:fill(color)
    return assert(raster:encode("png"))
end

local function rect_of(plan: any, node: any): any
    for _, item in ipairs(plan.items) do
        if (item :: any).node == node then return (item :: any).rect end
    end
    return {x = 0, y = 0, w = 0, h = 0}
end

local function drawn(tree: any, cols: integer, rows: integer, face: any?): string
    local store = rasters.store()
    store.begin()
    local placed = assert(render.placement({id = "picture", content_state = {sdk = 1, revision = 1, ui = tree}},
        {x = 1, y = 1, cols = cols, rows = rows}, CELL, face or {}, store))
    return assert(placed.raster:encode("png"))
end

-- The face with the banner cut to cut_w × cut_h at the top left.
local function expected(cols: integer, rows: integer, cut_w: integer, cut_h: integer): string
    local banner = assert(images.picture(BANNER))
    local out = gfx.raster(cols * CELL.w, rows * CELL.h)
    out:fill(FACE)
    local cut = gfx.raster(cut_w, cut_h)
    cut:fill(FACE)
    cut:blit(banner, 1, 1)
    out:blit(cut, 1, 1)
    return assert(out:encode("png"))
end

local function plain(text: any): string
    return (tostring(text):gsub("\27%[[%d;]*m", ""))
end

-- Whether a row carries the SGR bold attribute; the parameters of a 256 or a
-- true color are stepped over, so a color component of 1 is not taken for it.
local function has_bold(row: any): boolean
    for params in tostring(row):gmatch("\27%[([%d;]*)m") do
        local list: any = {}
        for part in (params .. ";"):gmatch("(%d*);") do list[#list + 1] = part end
        local index = 1
        while index <= #list do
            local part = list[index]
            if (part == "38" or part == "48" or part == "58") and list[index + 1] == "2" then index = index + 5
            elseif (part == "38" or part == "48" or part == "58") and list[index + 1] == "5" then index = index + 3
            else
                if part == "1" then return true end
                index = index + 1
            end
        end
    end
    return false
end

local function define_tests()
    test.describe("picture — the pack's pictures folder", function()
        test.it("reads a picture of any size from pictures/, beside the square sizes, and names what is missing", function()
            images.forget()
            local banner, why = images.picture(BANNER)
            test.not_nil(banner, tostring(why))
            local w, h = banner:size()
            test.eq(w, 40)
            test.eq(h, 24)
            test.is_true(images.picture(BANNER) == banner, "the raster outlives the frame")

            local smile, serr = images.get("app:test_images/smile", 16)
            test.not_nil(smile, "the size folders read as before: " .. tostring(serr))
            local sized, swhy = images.get(BANNER, 24)
            test.is_nil(sized, "pictures/ is not a size")
            test.is_true(tostring(swhy):find("24/banner.png", 1, true) ~= nil, tostring(swhy))

            local none, nwhy = images.picture(ABSENT)
            test.is_nil(none)
            test.is_true(tostring(nwhy):find("pictures/absent.png", 1, true) ~= nil, tostring(nwhy))
            local bare, bwhy = images.picture("banner")
            test.is_nil(bare)
            test.is_true(tostring(bwhy):find("no such picture", 1, true) ~= nil, tostring(bwhy))
            local foreign, fwhy = images.picture("app:shots/banner")
            test.is_nil(foreign)
            test.is_true(tostring(fwhy):find("not an image pack", 1, true) ~= nil, tostring(fwhy))
        end)

        test.it("reads a replaced picture again, and keeps the raster while the file is the same", function()
            images.forget()
            local recheck = images.PACK_RECHECK_SECONDS
            images.PACK_RECHECK_SECONDS = 0
            local id = "app:scratch_pictures"
            local applied, aerr = apply_pack(id, "./shots/scratch_pack")
            local store: any = applied and fs.get(id)
            local first: any = nil
            local same: any = nil
            local replaced: any = nil
            local why: any = aerr
            if store then
                store:mkdir(images.PICTURES)
                store:writefile("pictures/wide.png", png(30, 10, "#ffff00"))
                first, why = images.picture(id .. "/wide")
                same = images.picture(id .. "/wide")
                store:writefile("pictures/wide.png", png(30, 10, "#ff0000"))
                replaced = images.picture(id .. "/wide")
                store:remove("pictures/wide.png")
            end
            drop_pack(id)
            images.PACK_RECHECK_SECONDS = recheck
            test.not_nil(first, "the scratch pack serves its picture: " .. tostring(why))
            if first then
                local w, h = first:size()
                test.eq(w, 30)
                test.eq(h, 10)
            end
            test.is_true(same == first, "an unchanged file keeps its raster: the surface resends nothing")
            test.not_nil(replaced, "the replaced file is read")
            test.is_true(replaced ~= first, "a replaced file is a new raster, drawn without a restart")
        end)
    end)

    test.describe("picture — the layout", function()
        test.it("the window measures its pictures and publishes the size with the tree", function()
            images.forget()
            local shown = {kind = "picture", image = BANNER, text = "Banner"}
            local gone: any = {kind = "picture", image = ABSENT, text = "Gone", natural_w = 99, natural_h = 99}
            local tree = {kind = "column", children = {{kind = "row", children = {shown}}, gone}}
            app.measure(tree)
            test.eq(shown.natural_w, 40)
            test.eq(shown.natural_h, 24)
            test.is_nil(gone.natural_w, "a measure left from a picture that is not there is cleared")
            test.is_nil(gone.natural_h)
        end)

        test.it("takes the natural height, size_px, or one row; in cells its text", function()
            images.forget()
            local natural = {kind = "picture", image = BANNER, text = "Natural"}
            local sized = {kind = "picture", image = BANNER, text = "Sized", size_px = 40}
            local missing = {kind = "picture", image = ABSENT, text = "Missing"}
            local ok = {kind = "button", id = "ok", text = "OK", size = 2}
            local tree = {kind = "column", children = {natural, sized, missing, ok}}
            app.measure(tree)

            local plan = ui.plan(tree, 20, 12, ui.interaction(), {cell = CELL})
            test.eq(rect_of(plan, natural).y, 1)
            test.eq(rect_of(plan, natural).h, 2, "24 px at a 16 px cell is two rows")
            test.eq(rect_of(plan, sized).h, 3, "size_px 40 at a 16 px cell is three rows")
            test.eq(rect_of(plan, missing).h, 1, "an unmeasured picture is its text, one row")
            test.eq(rect_of(plan, ok).y, 7, "the button stands under the pictures in the window's plan")

            local text_plan = ui.plan(tree, 20, 12, ui.interaction())
            test.eq(rect_of(text_plan, natural).h, 1, "in cells a picture is its text")
            test.eq(rect_of(text_plan, sized).h, 1, "size_px is pixels; cells take size")
            test.eq(rect_of(text_plan, ok).y, 4)

            local tall = {kind = "picture", image = BANNER, text = "Tall", size = 3}
            test.eq(rect_of(ui.plan({kind = "column", children = {tall}}, 20, 6, ui.interaction()), tall).h, 3)

            local wide = {kind = "picture", image = BANNER, text = "Wide"}
            local row = {kind = "row", children = {wide, {kind = "label", text = "beside"}}}
            app.measure(row)
            test.eq(rect_of(ui.plan(row, 20, 2, ui.interaction(), {cell = CELL}), wide).w, 5,
                "across a row it is its natural width, 40 px at an 8 px cell")
        end)
    end)

    test.describe("picture — the renderers", function()
        test.it("pixels draw it at 1:1, left-aligned at the top and cut to its rect", function()
            images.forget()
            local natural = {kind = "column", children = {{kind = "picture", image = BANNER}}}
            app.measure(natural)
            test.eq(drawn(natural, 6, 3), expected(6, 3, 40, 24), "the whole picture at the top left, not scaled")

            local short = {kind = "column", children = {{kind = "picture", image = BANNER, size_px = 16}}}
            app.measure(short)
            test.eq(drawn(short, 6, 3), expected(6, 3, 40, 16), "cut to one row, not squeezed into it")

            local narrow = {kind = "row", children = {{kind = "picture", image = BANNER, size = 3},
                {kind = "column", children = {}}}}
            app.measure(narrow)
            test.eq(drawn(narrow, 6, 3), expected(6, 3, 24, 24), "cut to its three columns, nothing on the neighbour's")

            local unmeasured = {kind = "column", children = {{kind = "picture", image = BANNER}}}
            test.eq(drawn(unmeasured, 6, 3), expected(6, 3, 40, 16),
                "the compositor lays out only what the window measured: one row, and the picture cut to it")
        end)

        test.it("a missing picture is its text in bold, at the top left, never a hole", function()
            images.forget()
            local face = fonts()
            local tree = {kind = "column", children = {{kind = "picture", image = ABSENT, text = "Welcome"}}}
            app.measure(tree)
            local shown = drawn(tree, 12, 2, face)
            test.is_true(shown ~= drawn({kind = "column", children = {}}, 12, 2, face), "never an empty hole")
            test.is_true(shown ~= drawn(tree, 12, 2, {face = face.face}), "the text is bold, not the regular face")
            local out = gfx.raster(12 * CELL.w, 2 * CELL.h)
            out:fill(FACE)
            out:text(1, 1 + math.max(0, (CELL.h - 15) // 2), pixels.ellipsize(face.bold, "Welcome", 12 * CELL.w),
                {font = face.bold, color = palette.exact.face_text})
            test.eq(shown, assert(out:encode("png")), "the bold text at the top left of the rect")
        end)

        test.it("cells show the text, bold, where pixels put the picture", function()
            local tree = {kind = "column", children = {{kind = "picture", image = BANNER, text = "Welcome to Chicago"}}}
            local interaction = ui.interaction()
            local rows = cells.rows(ui.plan(tree, 30, 3, interaction), interaction, 30, 3)
            test.eq(plain(rows[1]):sub(1, 18), "Welcome to Chicago")
            test.is_true(has_bold(rows[1]), "the text is bold: " .. tostring(rows[1]))
            local label = {kind = "column", children = {{kind = "label", text = "Welcome to Chicago", size = 1}}}
            local plain_interaction = ui.interaction()
            local label_rows = cells.rows(ui.plan(label, 30, 3, plain_interaction), plain_interaction, 30, 3)
            test.is_false(has_bold(label_rows[1]), "a label of the same text is not: the check tells them apart")
        end)

        test.it("paints a picture's rows again when its file is replaced", function()
            images.forget()
            local recheck = images.PACK_RECHECK_SECONDS
            images.PACK_RECHECK_SECONDS = 0
            local id = "app:scratch_picture_rows"
            local applied, aerr = apply_pack(id, "./shots/scratch_pack")
            local store_fs: any = applied and fs.get(id)
            local before: any = nil
            local after: any = nil
            if store_fs then
                store_fs:mkdir(images.PICTURES)
                store_fs:writefile("pictures/dot.png", png(16, 16, "#ffff00"))
                local tree = {kind = "column", children = {{kind = "picture", image = id .. "/dot", text = "dot"}}}
                app.measure(tree)
                local store = rasters.store()
                store.begin()
                local window: any = {id = "picture-rows", state_revision = 1, content_state = {sdk = 1, revision = 1, ui = tree}}
                local inner = {x = 1, y = 1, cols = 4, rows = 2}
                local placed = assert(render.rows(window, inner, CELL, {}, store))
                before = placed[1].raster:version()
                store_fs:writefile("pictures/dot.png", png(16, 16, "#ff0000"))
                window.state_revision = 2
                store.begin()
                local again = assert(render.rows(window, inner, CELL, {}, store))
                after = again[1].raster:version()
                store_fs:remove("pictures/dot.png")
            end
            drop_pack(id)
            images.PACK_RECHECK_SECONDS = recheck
            test.not_nil(before, "the scratch pack serves its picture: " .. tostring(aerr))
            test.is_true(after ~= before, "the row holding the replaced picture is painted again")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
