-- The Windows 95 Open / Save As sheet (`chicago.shell.sdk:filedialog`):
-- the layout at 44×16 in cells and at two pixel cells, every action of
-- `update`, the Save As captions, a folder that was not read, and a PNG shot
-- `test/shots/filedialog.png`.

local test = require("test")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local fs = require("fs")
local gfx = require("gfx")
local filedialog = require("filedialog")

local W, H = filedialog.W, filedialog.H
local IDS = filedialog.IDS

local DRIVES = {
    {id = "app:docs", title = "docs", kind = "drive"},
    {id = "app:notes", title = "notes", kind = "drive"},
}

-- Three folders and four files, two of them text; one has its extension in
-- capitals, because the filter goes by `files.ext`, which drops the case.
-- The files come FIRST here: folders-first is the sheet's rule, not the
-- reader's order.
local function objects(): any
    return {
        {id = "notes.md", kind = "file", title = "notes.md"},
        {id = "photo.png", kind = "file", title = "photo.png", image = "document"},
        {id = "readme.txt", kind = "file", title = "readme.txt", image = "text_document"},
        {id = "archive", kind = "directory", title = "archive"},
        {id = "letters", kind = "directory", title = "letters"},
        {id = "todo.TXT", kind = "file", title = "todo.TXT", image = "text_document"},
        {id = "recipes", kind = "directory", title = "recipes"},
    }
end

local function dialog(button: any?): any
    return {
        title = button == "Save" and "Save As" or "Open", button = button or "Open",
        place = {drive = "app:docs", path = "/work"}, objects = objects(), drives = DRIVES,
        name = "", types = filedialog.TYPES, type = "txt",
    }
end

local function titles(state: any): string
    local out = {}
    for _, object in ipairs(filedialog.visible(state)) do out[#out + 1] = tostring((object :: any).title) end
    return table.concat(out, ",")
end

-- The list's row for an id, as the sheet draws it: what a click hands back.
local function row(state: any, id: string): any
    local plan = ui.plan(filedialog.sheet(state), W, H, ui.interaction())
    for _, line in ipairs(plan.by_id[IDS.list].node.rows) do
        if line.id == id then return line end
    end
    return nil
end

local function click(state: any, id: string): (any, any)
    return filedialog.update(state, {type = "select", id = IDS.list, index = 1, value = row(state, id), pointer = true})
end

local function plain(text: any): string
    return (tostring(text):gsub("\27%[[%d;]*m", ""))
end

-- The text of rows `from`..`to` of the cells rendering, joined: a one-line
-- caption in a two-row control stands in either row.
local function band(lines: any, from: integer, to: integer): string
    local out = {}
    for index = from, to do out[#out + 1] = plain(lines[index] or "") end
    return table.concat(out, "\n")
end

local function define_tests()
    test.describe("SDK file dialog", function()
        test.it("lays out at 44×16 in cells and pixels without overlaps, rows as in the original", function()
            local tree = filedialog.sheet(dialog())
            test.is_nil(ui.problem(tree), tostring(ui.problem(tree)))
            for _, cell in ipairs({false, {w = 10, h = 20}, {w = 8, h = 16}}) do
                local where = cell and ("@" .. cell.w .. "x" .. cell.h) or "cells"
                local plan = ui.plan(tree, W, H, ui.interaction(), cell and {cell = cell} or nil)
                for index, item in ipairs(plan.items) do
                    local r = item.rect
                    local kind = tostring(item.node.kind)
                    test.is_true(r.w >= 1 and r.h >= 1 and r.x >= 1 and r.y >= 1
                        and r.x + r.w - 1 <= W and r.y + r.h - 1 <= H, where .. ": " .. kind .. " outside the sheet")
                    for other = index + 1, #plan.items do
                        local b = plan.items[other].rect
                        test.is_true(r.x + r.w <= b.x or b.x + b.w <= r.x or r.y + r.h <= b.y or b.y + b.h <= r.y,
                            where .. ": overlap " .. kind .. "/" .. tostring(plan.items[other].node.kind))
                    end
                end
                local at = plan.by_id
                local look, up, list = at[IDS.look].rect, at[IDS.up].rect, at[IDS.list].rect
                local name, kind, accept, cancel = at[IDS.name].rect, at[IDS.type].rect, at[IDS.accept].rect, at[IDS.cancel].rect
                test.eq(look.y, 2, where .. ": Look in is the top row")
                test.eq(up.y, look.y, where .. ": Up One Level beside it")
                test.is_true(up.x > look.x + look.w - 1, where .. ": Up One Level at its right")
                test.is_true(list.y > look.y + look.h - 1 and list.y + list.h - 1 < name.y, where .. ": the list between")
                test.is_true(list.h >= 5, where .. ": the list keeps its rows: " .. list.h)
                test.eq(kind.y, name.y + name.h, where .. ": Files of type right under File name")
                test.eq(kind.y + kind.h - 1, H, where .. ": Files of type is the bottom row")
                test.eq(accept.y, name.y, where .. ": Open in the File name row")
                test.eq(cancel.y, kind.y, where .. ": Cancel in the Files of type row")
                test.eq(accept.x + accept.w - 1, W - 1, where .. ": the buttons at the right edge")
                test.eq(cancel.x, accept.x, where .. ": one above the other")
                test.is_true(at[IDS.accept].node.default == true, where .. ": Open is the default")
                test.is_true(at[IDS.cancel].node.default ~= true, where .. ": Cancel is not")
            end
        end)

        test.it("the list: folders first, then the files of the type with their pictures; cells draw every row", function()
            local state = dialog()
            local plan = ui.plan(filedialog.sheet(state), W, H, ui.interaction())
            local rows = plan.by_id[IDS.list].node.rows
            local names, kinds = {}, {}
            for _, line in ipairs(rows) do
                names[#names + 1] = line.label
                kinds[#kinds + 1] = line.kind
            end
            test.eq(table.concat(names, ","), "archive,letters,recipes,readme.txt,todo.TXT")
            test.eq(table.concat(kinds, ","), "folder,folder,folder,entry,entry")
            test.eq(rows[4].image, "text_document", "a file keeps the explorer's picture")
            test.is_nil(rows[1].image, "a folder is drawn by its kind")
            test.eq(rows[1].depth, 0)
            test.is_true(rows[1].has_children == false, "no expander box in a list")

            local lines = cells.rows(plan, ui.interaction(), W, H)
            local at = plan.by_id
            test.is_true(band(lines, 2, 3):find("Look in:", 1, true) ~= nil, band(lines, 2, 3))
            test.is_true(band(lines, 2, 3):find("work", 1, true) ~= nil, "Look in shows the place: " .. band(lines, 2, 3))
            local list = at[IDS.list].rect
            test.is_true(plain(lines[list.y]):find("archive", 1, true) ~= nil, plain(lines[list.y]))
            test.is_true(plain(lines[list.y + 4]):find("todo.TXT", 1, true) ~= nil, plain(lines[list.y + 4]))
            local name_rows = band(lines, at[IDS.name].rect.y, at[IDS.name].rect.y + 1)
            test.is_true(name_rows:find("File name:", 1, true) ~= nil and name_rows:find("Open", 1, true) ~= nil, name_rows)
            local type_rows = band(lines, at[IDS.type].rect.y, at[IDS.type].rect.y + 1)
            test.is_true(type_rows:find("Files of type:", 1, true) ~= nil and type_rows:find("Cancel", 1, true) ~= nil
                and type_rows:find("Text Documents", 1, true) ~= nil, type_rows)
        end)

        test.it("Save As names its rows as Windows 95 did", function()
            local state = dialog("Save")
            local plan = ui.plan(filedialog.sheet(state), W, H, ui.interaction())
            local texts = {}
            for _, item in ipairs(plan.items) do
                if item.node.kind == "label" then texts[#texts + 1] = item.node.text end
            end
            test.eq(table.concat(texts, ","), "Save in:,File name:,Save as type:")
            test.eq(plan.by_id[IDS.accept].node.text, "Save")
            test.is_true(plan.by_id[IDS.accept].node.default == true)
            test.eq(filedialog.title(state), "Save As")
            test.eq(filedialog.title({button = "Save"}), "Save As", "the caption follows the button without a title")
            test.eq(filedialog.title({}), "Open")
        end)

        test.it("a click on a file puts its name into File name; a click on a folder only selects it", function()
            local state = dialog()
            local _, result = click(state, "readme.txt")
            test.is_nil(result)
            test.eq(state.name, "readme.txt")
            test.eq(state.selected, "readme.txt")
            _, result = click(state, "archive")
            test.is_nil(result)
            test.eq(state.selected, "archive")
            test.eq(state.name, "readme.txt", "a folder does not replace the name")
        end)

        test.it("a double click on a folder asks to read it; only a click counts as the second one", function()
            local state = dialog()
            click(state, "archive")
            -- ↑ or Home on the first row select it again, without `pointer`.
            local _, result = filedialog.update(state, {type = "select", id = IDS.list, index = 1, value = row(state, "archive")})
            test.is_nil(result, "a key reselecting the row does not open it")
            _, result = click(state, "archive")
            test.not_nil(result and result.read, "the second click opens")
            test.eq(result.read.drive, "app:docs")
            test.eq(result.read.path, "/work/archive")
            -- Enter on a row is the same as the double click.
            _, result = filedialog.update(dialog(), {type = "activate", id = IDS.list, index = 2, value = row(state, "letters")})
            test.eq(result.read.path, "/work/letters")
            -- On a file it is the answer.
            local file = dialog()
            click(file, "todo.TXT")
            _, result = click(file, "todo.TXT")
            test.not_nil(result and result.accept)
            test.eq(result.accept.drive, "app:docs")
            test.eq(result.accept.path, "/work/todo.TXT")
        end)

        test.it("Up One Level asks for the parent; at a drive's root it is disabled and asks nothing", function()
            local state = dialog()
            state.place.path = "/work/2026/may"
            local _, result = filedialog.update(state, {type = "activate", id = IDS.up})
            test.eq(result.read.drive, "app:docs")
            test.eq(result.read.path, "/work/2026")
            state.place.path = "/work"
            _, result = filedialog.update(state, {type = "activate", id = IDS.up})
            test.eq(result.read.path, "/")
            state.place.path = "/"
            local plan = ui.plan(filedialog.sheet(state), W, H, ui.interaction())
            test.is_true(plan.by_id[IDS.up].node.disabled == true, "nothing above the root")
            _, result = filedialog.update(state, {type = "activate", id = IDS.up})
            test.is_nil(result)
        end)

        test.it("Look in lists every drive with the way to the place, and choosing one asks to read it", function()
            local state = dialog()
            state.place.path = "/work/2026"
            local labels = {}
            for _, spot in ipairs(filedialog.places(state)) do labels[#labels + 1] = (spot :: any).label end
            test.eq(table.concat(labels, "|"), "docs|  work|    2026|notes")
            local plan = ui.plan(filedialog.sheet(state), W, H, ui.interaction())
            test.eq(plan.by_id[IDS.look].node.value, "3", "the current place is chosen")
            local _, result = filedialog.update(state, {type = "change", id = IDS.look, value = "4"})
            test.eq(result.read.drive, "app:notes")
            test.eq(result.read.path, "/")
            _, result = filedialog.update(state, {type = "change", id = IDS.look, value = "2"})
            test.eq(result.read.drive, "app:docs")
            test.eq(result.read.path, "/work")
            _, result = filedialog.update(state, {type = "change", id = IDS.look, value = "9"})
            test.is_nil(result, "an option that is not there asks nothing")
            -- A place on a drive the list did not bring is still offered first.
            state.drives = {}
            labels = {}
            for _, spot in ipairs(filedialog.places(state)) do labels[#labels + 1] = (spot :: any).label end
            test.eq(table.concat(labels, "|"), "app:docs|  work|    2026")
        end)

        test.it("the type filter hides the files of other types and the selection they carried", function()
            local state = dialog()
            test.eq(titles(state), "archive,letters,recipes,readme.txt,todo.TXT")
            local _, result = filedialog.update(state, {type = "change", id = IDS.type, value = "all"})
            test.is_nil(result)
            test.eq(titles(state), "archive,letters,recipes,notes.md,photo.png,readme.txt,todo.TXT")
            click(state, "photo.png")
            test.eq(state.selected, "photo.png")
            filedialog.update(state, {type = "change", id = IDS.type, value = "txt"})
            test.eq(titles(state), "archive,letters,recipes,readme.txt,todo.TXT")
            test.is_nil(state.selected, "a hidden row is not selected")
            -- A hidden file cannot be picked by a stale action either.
            _, result = filedialog.update(state, {type = "activate", id = IDS.list, value = {id = "photo.png"}})
            test.is_nil(result)
        end)

        test.it("Open resolves the File name against the place; Enter in the field is Open", function()
            local function answer(name: string, how: any?): any
                local state = dialog()
                state.name = name
                local _, result = filedialog.update(state, how or {type = "activate", id = IDS.accept})
                return result
            end
            test.eq(answer("draft.txt").accept.path, "/work/draft.txt")
            test.eq(answer("draft.txt").accept.drive, "app:docs")
            test.eq(answer("sub/new.txt").accept.path, "/work/sub/new.txt")
            test.eq(answer("..\\top.txt").accept.path, "/top.txt")
            test.eq(answer("../../../above.txt").accept.path, "/above.txt", "never above the drive's root")
            test.eq(answer("/abs/x.txt").accept.path, "/abs/x.txt")
            test.eq(answer("  spaced.txt  ").accept.path, "/work/spaced.txt")
            test.is_nil(answer("   "), "an empty name answers nothing")
            test.eq(answer("letters").read.path, "/work/letters", "a folder's name enters it")
            test.eq(answer("draft.txt", {type = "activate", id = IDS.name, value = "draft.txt"}).accept.path, "/work/draft.txt")
            -- Typing goes into the state.
            local state = dialog()
            filedialog.update(state, {type = "change", id = IDS.name, value = "typed.txt"})
            test.eq(state.name, "typed.txt")
        end)

        test.it("Cancel and Esc cancel; an action that is not the sheet's asks nothing", function()
            local _, result = filedialog.update(dialog(), {type = "activate", id = IDS.cancel})
            test.is_true(result ~= nil and result.cancel == true)
            _, result = filedialog.update(dialog(), {type = "key", key_type = "esc"})
            test.is_true(result ~= nil and result.cancel == true)
            _, result = filedialog.update(dialog(), {type = "activate", id = "somebody_else"})
            test.is_nil(result)
            _, result = filedialog.update(dialog(), {type = "key", key_type = "f5"})
            test.is_nil(result)
        end)

        test.it("arrive shows the place read; a folder that was not read shows its reason, not an empty list", function()
            local state = dialog()
            click(state, "readme.txt")
            filedialog.arrive(state, {drive = "app:notes", path = "/"}, {{id = "a.txt", kind = "file", title = "a.txt"}})
            test.eq(state.place.drive, "app:notes")
            test.eq(state.place.path, "/")
            test.is_nil(state.selected, "the old folder's selection goes")
            test.eq(state.name, "readme.txt", "File name stays")
            test.eq(titles(state), "a.txt")
            filedialog.arrive(state, {drive = "app:docs", path = "/locked"}, nil, "drive not opened: permission denied")
            local tree = filedialog.sheet(state)
            test.is_nil(ui.problem(tree))
            local plan = ui.plan(tree, W, H, ui.interaction())
            test.is_nil(plan.by_id[IDS.list], "no list")
            local found = nil
            for _, item in ipairs(plan.items) do
                if item.node.kind == "label" and item.node.alert then found = item.node.text end
            end
            test.eq(found, "drive not opened: permission denied")
            test.eq(filedialog.address(state.place), "drive/app:docs/locked")
            test.eq(filedialog.address({drive = "app:docs", path = "/"}), "drive/app:docs")
        end)

        test.it("draws in pixels: the shot test/shots/filedialog.png", function()
            local font_files = assert(fs.get("chicago.shell.theme:fonts"))
            local font = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local state = dialog()
            click(state, "readme.txt")
            local sheet = {sdk = 1, revision = 1, ui = filedialog.sheet(state), interaction = ui.interaction()}
            local window = {id = "filedialog", state_revision = 1, content_state = sheet}
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement(window, {x = 1, y = 1, cols = W, rows = H}, {w = 10, h = 20}, {face = font}, store))
            local bytes = assert(placed.raster:encode("png"))
            test.is_true(#bytes > 0)
            assert(assert(fs.get("app:shots")):writefile("filedialog.png", bytes))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
