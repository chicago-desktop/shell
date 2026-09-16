-- The folder window on the SDK (FR-008 §1–§4, §6, §8).
--
-- `update` for every menu item, open-vs-focus, Backspace in both browse
-- modes, the toolbar and status bar toggles, the context menus and the
-- Options sheet — against stand-ins for the compositor and the readers
-- (`definition.deps`), so what is checked is what the window ASKED for. Then
-- the four views laid out at 48×16 and 72×22 in cells and at two pixel cells
-- without overlaps, and the real window alive in a viewport.
local test = require("test")
local ui = require("ui")
local app = require("app")
local model = require("model")
local explorer = require("explorer_window")
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")
local render = require("render")
local rasters = require("rasters")
local gfx = require("gfx")
local fs = require("fs")

local definition: any = explorer.definition
local REAL: any = definition.deps
local EXPLORER = model.EXPLORER

local PROGRAMS = {
    {entry = "app:np", title = "Notepad", opens = {"txt"}, file_type = "Text Document", width = 60, height = 20},
}
local RECORDS = {{id = "app:docs", kind = "fs.directory"}, {id = "app:other", kind = "fs.embed"}}

-- A filesystem declared as a disk of its own: it stands at the root beside
-- the D: collection, and its paths carry the letter.
local DISKS = {{id = "app.c:c", kind = "registry.entry",
    meta = {type = "chicago.drive", title = "C:", comment = "the running system"},
    data = {fs = "app:docs", letter = "C"}}}

local function listing(path: any): any
    if path == "" then return {objects = model.root(RECORDS), title = "My Computer"} end
    if path == model.WIPPY then return {objects = model.wippy(RECORDS), title = model.WIPPY_TITLE} end
    if path == "drive/app:docs" then
        return {objects = model.files({
            {name = "readme.txt", type = "file", size = 2048, modified = 804850200},
            {name = "photo.png", type = "file", size = 5000, modified = 804850100},
            {name = "letters", type = "directory", modified = 804850000},
        }, "drive/app:docs", "app:docs", nil, PROGRAMS), title = "app:docs"}
    end
    if path == "drive/app:docs/letters" then
        return {objects = model.files({{name = "a.txt", type = "file", size = 10}},
            "drive/app:docs/letters", "app:docs", "letters", PROGRAMS), title = "app:docs/letters"}
    end
    if path == "drive/app:docs/many" then
        local names = {}
        for index = 1, 18 do
            names[index] = {name = string.format("letter %02d.txt", index), type = "file", size = index * 100,
                modified = 804850000 + index}
        end
        return {objects = model.files(names, "drive/app:docs/many", "app:docs", "many", PROGRAMS), title = "app:docs/many"}
    end
    -- The same filesystem reached as a lettered disk: the bytes come back
    -- the same way, only the address differs.
    if path == "disk/C/app:docs" then
        return {objects = model.files({
            {name = "readme.txt", type = "file", size = 2048, modified = 804850200},
            {name = "letters", type = "directory", modified = 804850000},
        }, "disk/C/app:docs", "app:docs", nil, PROGRAMS), title = "C:\\"}
    end
    if path == "control" then
        return {objects = model.control({{entry = "app:display", title = "Display", group = {"Settings"},
            comment = "Screen colours."}}), title = "Control Panel"}
    end
    return nil
end

-- A stand-in world: what the window asked the compositor, what it read, what
-- it saved. `opts.browse` is the stored mode, `opts.no_replies` a window with
-- no reply channel.
local function start(args: any, opts: any?): (any, any, any, any)
    local given: any = opts or {}
    local log: any = {calls = {}, reads = 0, browse = given.browse or "separate", saved = nil}
    local replies: any = {name = "replies"}
    definition.deps = {
        desktop = {
            replies = function(): (any, any)
                if given.no_replies then return nil, "no channel" end
                return replies, nil
            end,
            request = function(topic: any): (any, any)
                log.calls[#log.calls + 1] = {topic = topic}
                return true, nil
            end,
            open = function(spec: any): (any, any)
                log.calls[#log.calls + 1] = {topic = "desktop.open", spec = spec}
                return true, nil
            end,
            focus = function(id: any): (any, any)
                log.calls[#log.calls + 1] = {topic = "desktop.focus", id = id}
                return true, nil
            end,
        },
        sources = {
            list = function(path: any): (any, any)
                log.reads = log.reads + 1
                local shown = listing(path)
                if shown then return shown, nil end
                return nil, "unknown folder: " .. tostring(path)
            end,
            browse = function(): (any, any) return log.browse, nil end,
            set_browse = function(mode: any): (any, any)
                if mode ~= "separate" and mode ~= "single" then return nil, "unknown browse mode" end
                log.saved, log.browse = mode, mode
                return true, nil
            end,
            drives = function(): (any, any) return RECORDS, nil end,
            disks = function(): (any, any) return DISKS, nil end,
        },
    }
    local context = app.context({width = 48, height = 16})
    local state = definition.init(args, context)
    return state, log, context, replies
end

local function finish()
    definition.deps = REAL
end

local function act(state: any, context: any, action: any): any
    return definition.update(state, action, context)
end
local function menu(id: string): any return {type = "activate", id = id, menu = "bar"} end
local function listed(replies: any, windows: any): any
    return {type = "channel", channel = replies, ok = true,
        value = {payload = function(): any return {command = "desktop.list", ok = true, windows = windows} end}}
end
local function titles(state: any): string
    local out = {}
    for _, object in ipairs(state.objects) do out[#out + 1] = tostring((object :: any).title) end
    return table.concat(out, ",")
end
local function object_of(state: any, title: string): any
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        if object.title == title then return {id = tostring(object.id), title = object.title} end
    end
    return nil
end
local function selected(state: any): string
    local out = {}
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        if state.selection[tostring(object.id)] then out[#out + 1] = tostring(object.title) end
    end
    return table.concat(out, ",")
end
-- The menu row with this id, wherever it lies in the bar (submenus too).
local function row_of(tree: any, id: string): any
    local function walk(items: any): any
        for _, entry in ipairs(items or {}) do
            local item: any = entry
            if item.id == id then return item end
            local inner = walk(item.items)
            if inner then return inner end
        end
        return nil
    end
    for _, node in ipairs(tree.children or {}) do
        if node.kind == "menu" then
            for _, title in ipairs(node.entries or {}) do
                local found = walk((title :: any).items)
                if found then return found end
            end
            local found = walk(node.items)
            if found then return found end
        end
    end
    return nil
end
local function node_of(tree: any, id: string): any
    local function walk(node: any): any
        if type(node) ~= "table" then return nil end
        if node.id == id then return node end
        for _, child in ipairs(node.children or {}) do
            local found = walk(child)
            if found then return found end
        end
        return nil
    end
    return walk(tree)
end
local function last(log: any): any return log.calls[#log.calls] or {} end

local function define_tests()
    test.describe("folder window (FR-008)", function()
        test.it("starts at its args path, titled by it; an unknown path is My Computer with a notice", function()
            local state, _, context = start(nil)
            test.eq(state.path, "")
            test.eq(definition.title(state), "My Computer")
            test.eq(definition.image(state), "my_computer", "the title bar's picture")
            test.eq(titles(state), "Wippy (D:),Control Panel", "My Computer lists its disks, then the Control Panel")
            test.eq(#context.watched, 1, "the compositor's reply channel is watched")
            test.eq(#state.drives, 2)
            state = start("drive/app:docs")
            test.eq(definition.title(state), "docs")
            test.eq(titles(state), "letters,photo.png,readme.txt")
            state = start("nowhere")
            test.eq(state.path, "")
            test.is_true(tostring(state.notice):find("nowhere", 1, true) ~= nil, tostring(state.notice))
            finish()
        end)

        test.it("the menus are Windows 95's, verbatim, with the disabled items greyed and doing nothing", function()
            local state, log, context = start("drive/app:docs")
            local tree = definition.view(state, context)
            local bar = tree.children[1]
            local names = {}
            for _, entry in ipairs(bar.entries) do names[#names + 1] = (entry :: any).title end
            test.eq(table.concat(names, ","), "File,Edit,View,Help")
            for _, id in ipairs({"file_shortcut", "file_delete", "file_rename", "edit_undo", "edit_cut", "edit_copy",
                "edit_paste", "edit_paste_shortcut", "arrange_auto", "view_lineup"}) do
                test.is_true(row_of(tree, id).disabled == true, id .. " is disabled")
            end
            test.is_true(row_of(tree, "file_open").disabled == true, "Open needs a selection")
            test.eq(row_of(tree, "edit_select_all").shortcut, "Ctrl+A")
            test.eq(row_of(tree, "view_refresh").shortcut, "F5")
            test.eq(row_of(tree, "view_options").text, "Options...")
            test.is_true(row_of(tree, "arrange_auto").checked == true, "Auto Arrange is checked")
            test.eq(#row_of(tree, "view_arrange").items, 6, "Arrange Icons is a submenu")
            test.is_false(act(state, context, menu("file_delete")), "a disabled item does nothing")
            test.eq(#log.calls, 0)
            finish()
        end)

        test.it("Select All, Invert Selection and Open", function()
            local state, log, context = start("drive/app:docs")
            act(state, context, menu("edit_select_all"))
            test.eq(selected(state), "letters,photo.png,readme.txt")
            state.selection = {[object_of(state, "letters").id] = true}
            act(state, context, menu("edit_invert"))
            test.eq(selected(state), "photo.png,readme.txt")
            test.is_true(row_of(definition.view(state, context), "file_open").disabled ~= true, "Open with a selection")
            state.selection = {[object_of(state, "readme.txt").id] = true}
            act(state, context, menu("file_open"))
            test.eq(last(log).topic, "desktop.open", "a file opens its program")
            test.eq(last(log).spec.entry, "app:np")
            finish()
        end)

        test.it("View: toolbar and status bar toggle, one of four views is bulleted, Arrange sorts", function()
            local state, _, context = start("drive/app:docs")
            local tree = definition.view(state, context)
            test.is_nil(node_of(tree, "tb_places"), "no toolbar by default")
            test.eq(tree.children[#tree.children].kind, "statusbar", "the status bar is on by default")
            test.is_true(row_of(tree, "view_toolbar").checked ~= true)
            act(state, context, menu("view_toolbar"))
            tree = definition.view(state, context)
            test.not_nil(node_of(tree, "tb_places"), "View → Toolbar shows it")
            test.is_true(row_of(tree, "view_toolbar").checked == true)
            act(state, context, menu("view_statusbar"))
            tree = definition.view(state, context)
            test.is_true(tree.children[#tree.children].kind ~= "statusbar", "View → Status Bar hides it")
            test.is_true(row_of(tree, "view_statusbar").checked ~= true)
            local expect: any = {large = "icons", small = "icons", list = "icons", details = "table"}
            for _, view in ipairs(definition.VIEWS) do
                act(state, context, menu("view_" .. view))
                tree = definition.view(state, context)
                local body = node_of(tree, "objects")
                test.eq(body.kind, expect[view], view)
                test.eq(body.small == true, view == "small" or view == "list", view .. ": small icons")
                for _, other in ipairs(definition.VIEWS) do
                    test.eq(row_of(tree, "view_" .. other).bullet == true, other == view, view .. ": bullet on " .. other)
                end
            end
            act(state, context, menu("arrange_size"))
            test.eq(titles(state), "letters,readme.txt,photo.png", "by size, the folder first")
            act(state, context, menu("arrange_date"))
            test.eq(titles(state), "letters,photo.png,readme.txt", "by date")
            finish()
        end)

        test.it("Details: the cells of the model, a picture in the Name cell, the Control Panel's own columns", function()
            local state, _, context = start("drive/app:docs")
            act(state, context, menu("view_details"))
            local table_node = node_of(definition.view(state, context), "objects")
            local heads = {}
            for _, column in ipairs(table_node.columns) do heads[#heads + 1] = (column :: any).title end
            test.eq(table.concat(heads, ","), "Name,Size,Type,Modified")
            local readme: any = nil
            for _, row in ipairs(table_node.rows) do
                if (row :: any).cells[1].text == "readme.txt" then readme = row end
            end
            test.eq(readme.cells[2], "2KB")
            test.eq(readme.cells[3], "Text Document")
            -- The Name cell is the picture's cell: its kind (the pixel icon falls
            -- back to the kind's picture when no program named one) and its
            -- glyph for cells.
            test.eq(readme.cells[1].kind, "file")
            test.eq(readme.cells[1].icon, model.FILE_ICON)
            state = start("control")
            act(state, context, menu("view_details"))
            table_node = node_of(definition.view(state, context), "objects")
            heads = {}
            for _, column in ipairs(table_node.columns) do heads[#heads + 1] = (column :: any).title end
            test.eq(table.concat(heads, ","), "Name,Type,Comment")
            test.eq(table_node.rows[1].cells[3], "Screen colours.")
            finish()
        end)

        test.it("Refresh re-reads, Close closes, Help Topics and About are sheets", function()
            local state, log, context = start("drive/app:docs")
            local before = log.reads
            act(state, context, menu("view_refresh"))
            test.eq(log.reads, before + 1)
            act(state, context, {type = "key", key_type = "f5", key = "f5", action = "press"})
            test.eq(log.reads, before + 2, "F5 is Refresh")
            act(state, context, menu("help_topics"))
            local tree = definition.view(state, context)
            local text = {}
            local function walk(node: any)
                if type(node) ~= "table" then return end
                if node.kind == "label" then text[#text + 1] = tostring(node.text) end
                for _, child in ipairs(node.children or {}) do walk(child) end
            end
            walk(tree)
            test.is_true(table.concat(text, "|"):find("Help is not available.", 1, true) ~= nil, table.concat(text, "|"))
            act(state, context, {type = "activate", id = "sheet_ok"})
            test.is_nil(state.sheet)
            act(state, context, menu("help_about"))
            test.eq(state.sheet.spec.title, "About Chicago")
            act(state, context, {type = "key", key_type = "esc", key = "esc", action = "press"})
            test.is_nil(state.sheet, "Esc closes a sheet")
            act(state, context, menu("file_close"))
            test.is_true(context.closing == true)
            finish()
        end)

        test.it("Properties: System Properties for My Computer and a drive, a sheet for a file", function()
            local state, log, context = start(nil)
            act(state, context, menu("file_properties"))
            test.eq(last(log).spec.entry, definition.SYSPROPS, "nothing selected at the root")
            state.selection = {[model.WIPPY] = true}
            act(state, context, {type = "key", key_type = "enter", key = "enter", alt = true, action = "press"})
            test.eq(#log.calls, 2)
            test.eq(last(log).spec.entry, definition.SYSPROPS, "Alt+Enter on a drive")
            state = start("drive/app:docs")
            state.selection = {[object_of(state, "readme.txt").id] = true}
            act(state, context, menu("file_properties"))
            local lines = table.concat(state.sheet.spec.lines, "|")
            test.eq(state.sheet.spec.title, "readme.txt")
            test.is_true(lines:find("Type: Text Document", 1, true) ~= nil, lines)
            test.is_true(lines:find("Size: 2KB", 1, true) ~= nil, lines)
            test.is_true(lines:find("Location: D:\\app:docs", 1, true) ~= nil, lines)
            finish()
        end)

        test.it("opening a folder asks what is open, then focuses that window or opens one with the path", function()
            local state, log, context, replies = start(model.WIPPY)
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "docs")})
            test.eq(last(log).topic, "desktop.list", "first it asks what is open")
            act(state, context, listed(replies, {{id = "w7", entry = EXPLORER, args = "drive/app:docs"},
                {id = "w8", entry = "app:other_program", args = "drive/app:docs"}}))
            test.eq(last(log).topic, "desktop.focus")
            test.eq(last(log).id, "w7", "the folder window already showing it is raised")
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "docs")})
            act(state, context, listed(replies, {{id = "w8", entry = "app:other_program", args = "drive/app:docs"}}))
            local opened = last(log)
            test.eq(opened.topic, "desktop.open", "none open: a new window")
            test.eq(opened.spec.entry, EXPLORER)
            test.eq(opened.spec.args, "drive/app:docs")
            test.eq(opened.spec.title, "docs")
            test.eq(opened.spec.image, "folder_open")
            test.eq(state.path, model.WIPPY, "this window stays where it is")
            state, log, context = start(nil, {no_replies = true})
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "Control Panel")})
            test.eq(last(log).topic, "desktop.open", "without a reply channel it opens straight away")
            test.eq(last(log).spec.args, "control")
            finish()
        end)

        test.it("the single-window mode navigates in place and asks the compositor nothing", function()
            local state, log, context = start(nil, {browse = "single"})
            act(state, context, {type = "activate", id = "objects", value = object_of(state, model.WIPPY_TITLE)})
            test.eq(state.path, model.WIPPY)
            test.eq(titles(state), "docs,other")
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "docs")})
            test.eq(state.path, "drive/app:docs")
            test.eq(definition.title(state), "docs", "the caption follows the folder")
            test.eq(definition.image(state), "folder_open", "and so does the title bar's picture")
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "letters")})
            test.eq(state.path, "drive/app:docs/letters")
            test.eq(definition.image(state), "folder_open", "a folder inside the drive")
            test.eq(#log.calls, 0)
            finish()
        end)

        test.it("Backspace and Up One Level go to the parent in both modes; at the root they do nothing", function()
            local state, log, context, replies = start("drive/app:docs/letters")
            act(state, context, {type = "key", key_type = "backspace", key = "backspace", action = "press"})
            test.eq(last(log).topic, "desktop.list")
            act(state, context, listed(replies, {}))
            test.eq(last(log).spec.args, "drive/app:docs", "separate: the parent's window")
            test.eq(state.path, "drive/app:docs/letters")
            state, log, context = start("drive/app:docs/letters", {browse = "single"})
            act(state, context, {type = "key", key_type = "backspace", key = "backspace", action = "press"})
            test.eq(state.path, "drive/app:docs", "single: in place")
            act(state, context, menu("view_toolbar"))
            act(state, context, {type = "activate", id = "tb_up"})
            test.eq(state.path, model.WIPPY, "Up from an FS root opens C:")
            act(state, context, {type = "activate", id = "tb_up"})
            test.eq(state.path, "", "Up from C: opens My Computer")
            test.is_false(act(state, context, {type = "key", key_type = "backspace", key = "backspace", action = "press"}))
            test.eq(#log.calls, 0)
            finish()
        end)

        test.it("a double click is a second CLICK on the same object; the arrows reselecting do not open", function()
            local state, log, context = start("drive/app:docs")
            local readme = object_of(state, "readme.txt")
            act(state, context, {type = "select", id = "objects", value = readme, pointer = true})
            test.eq(selected(state), "readme.txt")
            act(state, context, {type = "select", id = "objects", value = readme})
            act(state, context, {type = "select", id = "objects", value = readme})
            test.eq(#log.calls, 0, "keys reselecting the row open nothing")
            act(state, context, {type = "select", id = "objects", value = readme, pointer = true})
            act(state, context, {type = "select", id = "objects", value = readme, pointer = true})
            test.eq(last(log).topic, "desktop.open")
            act(state, context, {type = "select", id = "objects", value = readme, pointer = true,
                selected = {[readme.id] = true, [object_of(state, "letters").id] = true}})
            test.eq(selected(state), "letters,readme.txt", "the SDK's selection set is kept")
            finish()
        end)

        test.it("context menus: on an object Open and Properties, on the field View, Arrange, Refresh, Properties", function()
            local state, log, context = start("drive/app:docs")
            local readme = object_of(state, "readme.txt")
            act(state, context, {type = "context", id = "objects", index = 3, value = readme, x = 10, y = 5})
            test.eq(state.popup.target, "object")
            test.eq(selected(state), "readme.txt", "a right click selects what it is on")
            local tree = definition.view(state, context)
            local popup = node_of(tree, "context")
            test.eq(popup.kind, "menu", "the SDK's floating menu (ui.context_menu)")
            test.eq(popup.popup.x, 10)
            test.eq(popup.popup.y, 5)
            test.is_nil(ui.problem(tree), tostring(ui.problem(tree)))
            local plan = ui.plan(tree, 48, 16, ui.interaction())
            test.not_nil(plan.by_id.objects, "the open menu takes no room from the view")
            test.eq(popup.items[1].id, "file_open")
            test.eq(popup.items[3].id, "file_properties")
            act(state, context, {type = "activate", id = "file_open", menu = "context"})
            test.is_nil(state.popup, "a choice closes it")
            test.eq(last(log).spec.entry, "app:np")

            act(state, context, {type = "context", id = "objects", index = 0, x = 20, y = 8})
            test.eq(state.popup.target, "field")
            popup = node_of(definition.view(state, context), "context")
            local ids = {}
            for _, item in ipairs(popup.items) do ids[#ids + 1] = tostring((item :: any).id or "-") end
            test.eq(table.concat(ids, ","), "ctx_view,ctx_arrange,-,view_refresh,-,field_properties")
            test.eq(#popup.items[1].items, 4, "View holds the four views")
            test.is_true(popup.items[1].items[1].bullet == true, "the current one bulleted")
            act(state, context, {type = "activate", id = "view_details", menu = "context"})
            test.eq(state.view, "details")
            act(state, context, {type = "context", id = "objects", index = 0, x = 20, y = 8})
            -- Esc, F10 and a press outside reach the window as `dismiss`.
            test.is_true(act(state, context, {type = "dismiss", id = "context"}) == true)
            test.is_nil(state.popup, "dismiss drops it")
            act(state, context, {type = "context", id = "objects", index = 0, x = 20, y = 8})
            test.is_false(act(state, context, {type = "dismiss", id = "someone_else"}), "another menu's dismiss is not ours")
            test.not_nil(state.popup)
            act(state, context, {type = "key", key_type = "esc", key = "esc", action = "press"})
            test.is_nil(state.popup, "an Esc that reaches the window drops it too")
            act(state, context, {type = "context", id = "objects", index = 0, x = 20, y = 8})
            act(state, context, {type = "select", id = "objects", value = readme, pointer = true})
            test.is_nil(state.popup, "a click elsewhere closes it")
            state, log, context = start(nil)
            act(state, context, {type = "context", id = "objects", index = 0, x = 3, y = 3})
            act(state, context, {type = "activate", id = "field_properties", menu = "context"})
            test.eq(last(log).spec.entry, definition.SYSPROPS)
            finish()
        end)

        test.it("the toolbar: places open a folder, the view buttons switch and show the current one pressed", function()
            local state, log, context, replies = start("drive/app:docs")
            act(state, context, menu("view_toolbar"))
            local tree = definition.view(state, context)
            local values = {}
            for _, option in ipairs(node_of(tree, "tb_places").options) do values[#values + 1] = (option :: any).value end
            -- The way here (My Computer, D:, this folder), then the lettered
            -- disks, then the folders of the collection: a person standing in
            -- C:\PROGRAMS gets back to both disks from the same list.
            test.eq(table.concat(values, "|"),
                "|wippy|drive/app:docs|disk/C/app:docs|drive/app:other",
                "the way here, then the disks, then the drives")
            test.is_true(node_of(tree, "tb_large").pressed == true)
            for _, id in ipairs({"tb_cut", "tb_copy", "tb_paste", "tb_undo", "tb_delete"}) do
                test.is_true(node_of(tree, id).disabled == true, id)
            end
            act(state, context, {type = "activate", id = "tb_details"})
            test.eq(state.view, "details")
            test.is_true(node_of(definition.view(state, context), "tb_details").pressed == true)
            act(state, context, {type = "change", id = "tb_places", value = ""})
            act(state, context, listed(replies, {}))
            test.eq(last(log).spec.args, "", "My Computer's window")
            test.eq(last(log).spec.title, "My Computer")
            finish()
        end)

        test.it("Options: the two browse modes as radio buttons; OK stores the choice, Cancel does not", function()
            local state, log, context = start(model.WIPPY)
            act(state, context, menu("view_options"))
            local tree = definition.view(state, context)
            test.is_true(node_of(tree, "browse_separate").checked == true)
            test.eq(node_of(tree, "browse_single").text, definition.BROWSE_TEXT.single)
            act(state, context, {type = "change", id = "browse_single", value = true})
            act(state, context, {type = "activate", id = "options_cancel"})
            test.is_nil(log.saved, "Cancel stores nothing")
            test.eq(state.browse, "separate")
            act(state, context, menu("view_options"))
            act(state, context, {type = "change", id = "browse_single", value = true})
            test.is_true(node_of(definition.view(state, context), "browse_single").checked == true)
            act(state, context, {type = "activate", id = "options_ok"})
            test.eq(log.saved, "single")
            test.eq(state.browse, "single")
            test.is_nil(state.sheet)
            act(state, context, {type = "activate", id = "objects", value = object_of(state, "docs")})
            test.eq(state.path, "drive/app:docs", "the next folder opens in place")
            finish()
        end)

        test.it("the status bar counts the objects and names the selection or the drive", function()
            local state, _, context = start("drive/app:docs")
            local bar = definition.view(state, context).children[3]
            test.eq(bar.fields[1].text, " 3 object(s)")
            test.eq(bar.fields[2].text, " app:docs · fs.directory", "a drive's root: what the reader knows")
            state.selection = {[object_of(state, "readme.txt").id] = true, [object_of(state, "photo.png").id] = true}
            bar = definition.view(state, context).children[3]
            test.eq(bar.fields[2].text, " 2 object(s) selected, 7KB")
            finish()
        end)

        test.it("the four views lay out at 48×16 and 72×22 in cells and pixels without overlaps", function()
            for _, path in ipairs({"", model.WIPPY, "drive/app:docs", "control"}) do
                local state, _, context = start(path)
                for _, toolbar in ipairs({false, true}) do
                    state.toolbar = toolbar
                    for _, view in ipairs(definition.VIEWS) do
                        state.view = view
                        local tree = definition.view(state, context)
                        test.is_nil(ui.problem(tree), view .. ": " .. tostring(ui.problem(tree)))
                        for _, size in ipairs({{48, 16}, {72, 22}}) do
                            for _, cell in ipairs({false, {w = 10, h = 20}, {w = 8, h = 16}}) do
                                local where = path .. " " .. view .. (toolbar and "+toolbar " or " ") .. size[1] .. "x" .. size[2]
                                    .. (cell and (" @" .. cell.w .. "x" .. cell.h) or " cells")
                                local plan = ui.plan(tree, size[1], size[2], ui.interaction(),
                                    cell and {cell = cell, scroll_cols = 2} or nil)
                                test.not_nil(plan.by_id.objects, where .. ": the view is laid out")
                                for index, item in ipairs(plan.items) do
                                    local r = item.rect
                                    test.is_true(r.x >= 1 and r.y >= 1 and r.x + r.w - 1 <= size[1] and r.y + r.h - 1 <= size[2],
                                        where .. ": " .. tostring(item.node.kind) .. " outside")
                                    for other = index + 1, #plan.items do
                                        local b = plan.items[other].rect
                                        test.is_true(r.x + r.w <= b.x or b.x + b.w <= r.x or r.y + r.h <= b.y or b.y + b.h <= r.y,
                                            where .. ": overlap " .. tostring(item.node.kind) .. "/" .. tostring(plan.items[other].node.kind))
                                    end
                                end
                            end
                        end
                    end
                end
            end
            finish()
        end)

        test.it("List is the SDK's column-filled icons: objects run down a column, then the next; shot folder-list.png", function()
            local state, _, context = start("drive/app:docs/many")
            act(state, context, menu("view_list"))
            test.eq(state.view, "list")
            local tree = definition.view(state, context)
            local objects = node_of(tree, "objects")
            test.eq(objects and objects.flow, "columns", "List asks the SDK for columns")
            test.eq(objects and objects.small, true, "of small icons")
            local plan = ui.plan(tree, 48, 16, ui.interaction(), {cell = {w = 10, h = 20}, scroll_cols = 2})
            local item = plan.by_id.objects
            test.is_true(item.flow == true and item.columns_total >= 2, "18 objects take more than one column")
            for _, cell in ipairs(item.cells) do
                local column = (cell.index - 1) // item.lines - item.offset
                test.eq(cell.x .. "," .. cell.y, (item.rect.x + column * item.column) .. "," .. (item.rect.y + (cell.index - 1) % item.lines),
                    "top to bottom, then the next column: " .. tostring(cell.index))
            end
            local font_files = assert(fs.get("chicago.shell.theme:fonts"))
            local fonts = {face = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))}
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "folder", state_revision = 1, content_state = {sdk = 1, revision = 1,
                interaction = ui.interaction(), ui = tree}}, {x = 1, y = 1, cols = 48, rows = 16}, {w = 10, h = 20}, fonts, store))
            assert(assert(fs.get("app:shots")):writefile("folder-list.png", assert(placed.raster:encode("png"))))
            finish()
        end)

        test.it("the real window comes up in a viewport and shows My Computer with its menu and status bar", function()
            local view = assert(tty.viewport({width = 48, height = 16}))
            local pid, why = process.with_options({terminal = assert(view:grant())})
                :spawn_monitored(EXPLORER, "app:processes")
            test.is_nil(why)
            local shown = ""
            local deadline = time.now():unix_nano() + 8000000000
            while time.now():unix_nano() < deadline do
                local snap: any = view:snapshot(-1)
                shown = snap and table.concat(snap.rows or {}, "\n") or ""
                if shown:find("Wippy", 1, true) and shown:find("object(s)", 1, true) then break end
                channel.select({time.after("50ms"):case_receive()})
            end
            test.is_true(shown:find("File", 1, true) ~= nil and shown:find("Help", 1, true) ~= nil, "the menu bar:\n" .. shown)
            -- The logical disk is visible in the real cell renderer.
            test.is_true(shown:find("D:", 1, true) ~= nil and shown:find("Wippy", 1, true) ~= nil,
                "the root's Wippy disk:\n" .. shown)
            test.is_true(shown:find("object(s)", 1, true) ~= nil, "the status bar:\n" .. shown)
            view:send({type = "close"})
            view:close()
            if pid then process.terminate(tostring(pid)) end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
