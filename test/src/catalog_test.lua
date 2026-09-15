-- The program catalog: menu folders from meta.group, order from meta.order.
--
-- The menu layout rule is checked without a live registry — on entries
-- assembled right here. A rule checked only through the registry is checked
-- once, and then never: putting an entry with the needed group into the
-- registry costs more than not checking.
--
-- Separately pinned is the main property of `list`: an empty catalog and an
-- unreadable registry are returned as DIFFERENT values. The same, they send
-- the person to look for the error in their own application, where there is
-- none.
local test = require("test")
local catalog = require("catalog")
local view = require("view")
local chrome = require("chrome")
local model = require("model")

local function record(id, meta)
    return {id = id, kind = "process.lua", meta = meta}
end

local function define_tests()
    test.describe("chicago.shell catalog", function()
    test.it("reads the host's exact clock entry", function()
        local entry, err = catalog.taskbar_clock()
        test.is_nil(err)
        test.eq(entry, "app:grouped_probe")
    end)

        test.it("keeps meta.image all the way to the desktop, the menu and the explorer", function()
            for _, name in ipairs({"printer", "unknown_icon"}) do
                -- `group = ""` keeps the program on the root: the check is
                -- about the icon, and otherwise the first line of the root
                -- would be the default folder.
                local built = catalog.build({record("app:printer", {
                    type = "tui_desktop.window", title = "Print", image = name, group = "",
                })})
                local items = {{id = "print", kind = "shortcut", entry = "app:printer"}}
                test.eq(built.programs[1].image, name)
                test.eq(view.join(items, built)[1].image, name)
                local menu = chrome.menu_layout(100, 30, catalog.menu_items(built.programs), nil, nil, 1, nil)
                test.eq(menu.panels[1].lines[1].image, name)
                test.eq(model.programs(built.programs)[1].image, name)
                test.eq(model.desktop(items, built.programs)[1].image, name)
            end
        end)

        test.it("a stand declaration gives an icon to exactly one entry, keeping the program's meta.image", function()
            local built = catalog.build({
                record("app:a", {title = "Same name"}),
                record("app:b", {title = "Same name", image = "printer"}),
            })
            local ok, why = catalog.assign_images(built.programs, {{data = {images = {
                ["app:a"] = "clock", ["app:b"] = "calculator",
            }}}})
            test.is_nil(why)
            test.is_true(ok)
            test.eq(catalog.find(built.programs, "app:a").image, "clock")
            test.eq(catalog.find(built.programs, "app:b").image, "printer")
            ok, why = catalog.assign_images(built.programs, {
                {data = {images = {["app:a"] = "clock"}}},
                {data = {images = {["app:a"] = "calculator"}}},
            })
            test.is_nil(ok)
            test.not_nil(why)
        end)

        test.it("reads the stand's icons from the registry and passes them identically to the desktop and to Start", function()
            local found, why = catalog.list()
            test.is_nil(why)
            local probe = catalog.find(found.programs, "app:grouped_probe")
            test.eq(probe.image, "clock")
            local menu = catalog.menu_items(found.programs)
            test.eq(catalog.find(menu, probe.entry).image, probe.image)
            local joined = view.join({{id = "probe", kind = "shortcut", entry = probe.entry}}, found)
            test.eq(joined[1].image, probe.image)
            local computer = catalog.find(found.programs, "chicago.shell.explorer:window")
            test.eq(computer.image, "my_computer")
        end)

        test.it("builds menu folders from meta.group", function()
            local built = catalog.build({
                record("app:net", {type = "tui_desktop.window", title = "Network",
                    group = "System Tools/Comms"}),
                record("app:disk", {type = "tui_desktop.window", title = "Disk",
                    group = "System Tools"}),
                record("app:root", {type = "tui_desktop.window", title = "Root", group = ""}),
                record("app:plain", {type = "tui_desktop.window", title = "Unnamed"}),
            })

            -- The root only by an explicit `group = ""`. A program that did not
            -- name a folder lands in DEFAULT_GROUP: otherwise every window from
            -- the workshop (it has nowhere to get `meta.group` from) would grow
            -- as a root.
            test.eq(#built.tree.programs, 1, "only the one that asked for the root is on the root")
            test.eq(built.tree.programs[1].title, "Root")

            test.eq(#built.tree.folders, 2, "a folder comes into being by what was put into it")
            local default = built.tree.folders[1]
            test.eq(default.title, catalog.DEFAULT_GROUP, "the unnamed one goes into the default folder")
            test.eq(default.programs[1].title, "Unnamed")
            local service = built.tree.folders[2]
            test.eq(service.title, "System Tools")
            test.eq(#service.programs, 1)
            test.eq(service.programs[1].title, "Disk")
            test.eq(#service.folders, 1, "the nested folder comes from the path")
            test.eq(service.folders[1].title, "Comms")
            test.eq(service.folders[1].path, "System Tools/Comms")
            test.eq(service.folders[1].programs[1].title, "Network")
        end)

        test.it("collapses a path deeper than three levels to the third instead of losing the program", function()
            -- A deeper menu is not readable in a terminal, but losing a program
            -- is worse than losing a folder: there would be nothing to launch it
            -- with and nowhere to look for it.
            local built = catalog.build({
                record("app:deep", {type = "tui_desktop.window", title = "Deep",
                    group = "A/B/C/D/E"}),
            })
            local program = built.programs[1]
            test.eq(#program.group, 3, "the path is collapsed to three levels")
            test.eq(program.group[3], "C")
        end)

        test.it("throws away empty path segments", function()
            -- "System Tools//Network" is a typo, not a nameless folder in the
            -- middle.
            local built = catalog.build({
                record("app:x", {type = "tui_desktop.window", title = "Ex",
                    group = "System Tools//Network"}),
            })
            test.eq(#built.programs[1].group, 2)
            test.eq(built.programs[1].group[2], "Network")
        end)

        test.it("puts order ahead of the alphabet, and orderless ones alphabetically", function()
            local built = catalog.build({
                record("app:b", {type = "tui_desktop.window", title = "Beta"}),
                record("app:a", {type = "tui_desktop.window", title = "Alpha"}),
                record("app:z", {type = "tui_desktop.window", title = "Zed", order = 1}),
            })
            test.eq(built.programs[1].title, "Zed", "order goes first")
            test.eq(built.programs[2].title, "Alpha")
            test.eq(built.programs[3].title, "Beta")
        end)

        test.it("substitutes an icon and a name when they were not declared", function()
            local built = catalog.build({record("app:bare", {type = "tui_desktop.window"})})
            local program = built.programs[1]
            test.eq(program.title, "app:bare", "without a title the identifier serves as the name")
            test.eq(program.icon, catalog.DEFAULT_ICON)
            test.is_false(program.desktop, "a desktop shortcut is created only on request")
        end)

        test.it("reads desktop as a request, not as a statement", function()
            local built = catalog.build({
                record("app:d", {type = "tui_desktop.window", desktop = true}),
            })
            test.is_true(built.programs[1].desktop)
        end)

        test.it("tells an empty catalog from an unreadable registry", function()
            -- No windows are registered in the harness, so list must return a
            -- TABLE and a nil reason. A failure would look different: nil and a
            -- string. This is acceptance criterion No. 4 at the library level.
            local found, err = catalog.list()
            test.is_nil(err, "an empty catalog is not a failure")
            test.not_nil(found, "an empty catalog is still a table")
            test.not_nil(found.programs, "and it has a list of programs")
            test.not_nil(found.tree, "and a menu root")
        end)

        test.it("does not lose programs when one arrives without an identifier", function()
            -- An entry without an id has nothing to launch it by: it is skipped
            -- silently, but it does not take its neighbors with it either.
            local built = catalog.build({
                {kind = "process.lua", meta = {type = "tui_desktop.window", title = "No id"}},
                record("app:ok", {type = "tui_desktop.window", title = "With id"}),
            })
            test.eq(#built.programs, 1)
            test.eq(built.programs[1].entry, "app:ok")
        end)

        test.it("does not show in the menu one that asked to be hidden", function()
            -- The flag is about the MENU, not about launching: the program
            -- stays in the catalog, and a shortcut to it keeps working. Were
            -- we to filter it out of the catalog, the shortcut on the desktop
            -- would become broken, and the person would read that as "the
            -- program is gone".
            local built = catalog.build({
                {id = "app:visible", meta = {type = "tui_desktop.window", title = "Visible", group = ""}},
                {id = "app:hidden", meta = {type = "tui_desktop.window", title = "Hidden",
                                            group = "", in_menu = false}},
            })
            test.eq(#built.programs, 2, "the catalog keeps both")
            test.eq(#built.tree.programs, 1, "only one in the menu")
            test.eq(built.tree.programs[1].entry, "app:visible")
            test.not_nil(catalog.find(built.programs, "app:hidden"),
                "a shortcut must find the hidden program")

            local listed = catalog.listed(built.programs)
            test.eq(#listed, 1, '"Programs" in "My Computer" is the same choice as the menu')
        end)

        test.it("reads in_menu as a field, not through and-or", function()
            -- The trap is quieter than it seems: `meta.in_menu` via `x and x.f
            -- or nil` gives EXACTLY THE OPPOSITE answer — false goes into the
            -- "no value" branch and turns into the default true, that is, a
            -- window that asked to be hidden is shown.
            local strings = catalog.build({
                {id = "app:yaml", meta = {type = "tui_desktop.window", in_menu = "false"}},
            })
            test.eq(#strings.tree.programs, 0,
                'the string "false" arrives from YAML and means the same thing')
        end)

        test.it("does not create a menu folder whose children are all hidden", function()
            -- An empty folder in "Start" is an item that opens into nothing,
            -- and the first question will be where its contents went. A folder
            -- comes into being by what was put into it; we do not put a hidden
            -- program in — so no folder arises either.
            local built = catalog.build({
                {id = "app:tool", meta = {type = "tui_desktop.window", title = "Utility",
                                          group = "System Tools/Internal", in_menu = false}},
            })
            test.eq(#built.tree.folders, 0, "there is no folder without contents in the menu")
            test.eq(#built.programs, 1, "but the program itself is in the catalog")
        end)

        test.it("names an unknown window type but shows the program", function()
            -- The entry is declared by someone else, and a typo in one field is
            -- no reason to hide a window that is otherwise working. But an
            -- unnamed typo lives forever.
            local built = catalog.build({
                {id = "app:odd", meta = {type = "tui_desktop.window", window_type = "popup"}},
                {id = "app:fine", meta = {type = "tui_desktop.window", window_type = "dialog"}},
            })
            test.eq(#built.tree.folders, 1, "both without a folder go into the default folder")
            test.eq(#built.tree.folders[1].programs, 2, "both are shown")
            test.eq(#built.warnings, 1)
            test.eq(built.warnings[1].entry, "app:odd")
            test.eq(built.warnings[1].window_type, "popup")

            test.eq(catalog.find(built.programs, "app:odd").window_type, "app",
                "an unknown type counts as an ordinary window")
            test.eq(catalog.find(built.programs, "app:fine").window_type, "dialog")
        end)

        test.it("builds a folder from a real registry entry", function()
            -- Until this point the catalog was checked only on made-up tables:
            -- the harness had not a single entry with `meta.group`. The gap
            -- between the registry and the folder tree was green and never
            -- once walked, and the defect lived exactly in it.
            local found, err = catalog.list()
            test.is_nil(err, "the catalog must be readable")
            test.not_nil(found)

            local probe = catalog.find(found.programs, "app:grouped_probe")
            test.not_nil(probe, "the entry with a group must be in the harness catalog")
            test.eq(#probe.group, 2, "the path must arrive PARSED, not as a string")
            test.eq(probe.group[1], "System Tools")
            test.eq(probe.group[2], "Probe")

            local outer = nil
            for _, folder in ipairs(found.tree.folders) do
                if folder.title == "System Tools" then outer = folder end
            end
            test.not_nil(outer, "the folder must appear in the tree")
            test.eq(#outer.folders, 1, "and the one nested in it too")
            test.eq(outer.folders[1].title, "Probe")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
