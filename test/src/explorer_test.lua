-- The objects of "My Computer".
--
-- What is checked is the rule, not the picture: that the window shows the
-- running system itself, that drives are taken from the registry as they
-- are, that a double click is described by an intent rather than carried out
-- along the way, and that "empty" nowhere stands in for "not read".
--
-- Only the pure assembly here — neither database nor registry. That `fs.*`
-- entries are really found and their contents are really read is checked by
-- sources_test on the live registry.
local test = require("test")
local model = require("model")

local function by_id(objects, id)
    for _, object in ipairs(objects) do
        if object.id == id then return object end
    end
    return nil
end

local function define_tests()
    test.describe("butschster.windows explorer", function()
        test.it("leaves only the Control Panel at the root when there are no filesystems", function()
            local root = model.root({})
            test.eq(#root, 1)
            test.eq(root[1].id, model.CONTROL)
        end)

        test.it("makes a drive of every fs entry without creating anything itself", function()
            -- A drive declared by an installed module must appear by itself.
            -- A table of drives of our own would mean that it does not
            -- appear until someone writes it in by hand.
            local drives = model.drives({
                {id = "wippy.facade:public_files", kind = "fs.directory"},
                {id = "keeper:ui_static_fs", kind = "fs.embed"},
            })
            test.eq(#drives, 2)

            local first = by_id(drives, "keeper:ui_static_fs")
            test.eq(first.kind, "drive")
            test.eq(first.title, "ui_static_fs", "the entry name serves as the caption")
            test.eq(first.open.path, "drive/keeper:ui_static_fs")
            test.is_true(first.detail:find("fs.embed", 1, true) ~= nil,
                "the entry kind is the answer to \"why is it read-only\"")
        end)

        test.it("captions with the full name the drives that cannot be told apart otherwise", function()
            -- Two identical icons side by side are not a caption but a riddle.
            -- BOTH get the full name: a caption that depends on the order the
            -- registry is read in would change by itself.
            local drives = model.drives({
                {id = "keeper:ui_static_fs", kind = "fs.directory"},
                {id = "vlad.doom:ui_static_fs", kind = "fs.directory"},
                {id = "app:one_of_a_kind", kind = "fs.directory"},
            })
            -- With a space, not a colon: the caption wraps at spaces, and
            -- "keeper ui_static_fs" lays out as two lines where the first
            -- reads in full, while "keeper:ui_static_fs" is cut to
            -- "keeper:ui_st" — exactly where the difference begins.
            test.eq(by_id(drives, "keeper:ui_static_fs").title, "keeper ui_static_fs")
            test.eq(by_id(drives, "vlad.doom:ui_static_fs").title, "vlad.doom ui_static_fs")
            test.eq(by_id(drives, "app:one_of_a_kind").title, "one_of_a_kind",
                "there is no point in lengthening an unambiguous name")
        end)

        test.it("has the drives and the Control Panel at the root, without the shell's pseudo-folders", function()
            local root = model.root({{id = "app:probe", kind = "fs.directory"}})
            test.eq(#root, 2)
            test.eq(root[1].id, "app:probe")
            test.eq(root[1].kind, "drive")
            local control = root[2]
            test.eq(control.id, model.CONTROL, "the Control Panel comes after the drives")
            test.eq(control.kind, "folder")
            test.eq(control.title, "Control Panel")
            test.eq(control.image, "control_panel", "the pack has its own picture")
            test.eq(control.open.action, "folder")
            test.eq(control.open.path, "control")
            for _, name in ipairs({"programs", "desktop", "windows"}) do
                test.is_nil(by_id(root, name), "Windows 95 had no " .. name .. " folder in My Computer")
            end
        end)

        test.it("reads a path the same way for a click and for the \"Up\" button", function()
            -- Were they to diverge, "Up" would lead somewhere other than where
            -- a double click leads, and they would diverge silently.
            test.eq(model.parse(model.ROOT).view, "root")
            test.eq(model.parse("desktop").view, "desktop")
            test.eq(model.parse("desktop/f1").id, "f1")
            test.eq(model.parse("drive/app:fs").id, "app:fs",
                "the colon belongs to the entry id, not to the path")
            test.is_nil(model.parse("drive/app:fs").sub)
            test.eq(model.parse("drive/app:fs/ui/dist").sub, "ui/dist")
            test.eq(model.parse("something else").view, "unknown",
                "a silent fallback to the root would turn a typo into a navigation")
            test.eq(model.parse("control").view, "control")
            test.eq(model.address("control"), "My Computer\\Control Panel")
        end)

        test.it("goes one level up, not straight to the root", function()
            test.is_nil(model.parent(model.ROOT), "there is nowhere above the root")
            test.eq(model.parent("programs"), model.ROOT)
            test.eq(model.parent("control"), model.ROOT)
            test.eq(model.parent("desktop/f1"), "desktop")
            test.eq(model.parent("drive/app:fs"), model.ROOT)
            test.eq(model.parent("drive/app:fs/ui"), "drive/app:fs")
            test.eq(model.parent("drive/app:fs/ui/dist"), "drive/app:fs/ui")
        end)

        test.it("does not promise to open a file that has nothing to open it with", function()
            -- There is no file viewer. An intent to "open" would be a promise
            -- that nobody can keep, and a double click on it would be
            -- inaction indistinguishable from an unnoticed click.
            local objects = model.files({
                {name = "app.js", type = "file"},
                {name = "ui", type = "directory"},
                {name = "README.md", type = "file"},
            }, "drive/app:fs")

            test.eq(objects[1].title, "ui", "folders before files, as in Explorer")
            test.eq(objects[1].open.path, "drive/app:fs/ui")
            test.eq(objects[2].title, "README.md", "then by name")
            test.is_nil(objects[2].open)
            test.is_nil(objects[3].open)
        end)

        test.it("does not turn registry processes and data into drives", function()
            local root = model.root({
                {id = "app:files", kind = "fs.directory"},
                {id = "app:embedded", kind = "fs.embed"},
                {id = "app:program", kind = "process.lua"},
                {id = "app:settings", kind = "registry.entry"},
                {id = "app:database", kind = "db.sql.sqlite"},
            })
            test.eq(#root, 3, "two drives and the Control Panel")
            test.not_nil(by_id(root, "app:files"))
            test.not_nil(by_id(root, "app:embedded"))
        end)

        test.it("describes a double click by an intent, not by an action", function()
            -- The window does not spawn processes and does not open its
            -- neighbours by itself: it asks the compositor to do it. An
            -- intent gathered in one place keeps the window from deciding
            -- along the way what "open" means.
            local programs = model.programs({
                {entry = "app:clock", title = "Clock", icon = "◷", width = 30, height = 6},
            })
            test.eq(#programs, 1)
            local open = programs[1].open
            test.eq(open.action, "open_window")
            test.eq(open.entry, "app:clock")
            test.eq(open.w, 30)
            test.eq(open.h, 6)
        end)

        test.it("raises an open window rather than opening a second one of the same kind", function()
            -- The list shows what is already on screen; "open" here means
            -- "show". A second window of the same kind would not be what was
            -- asked for by a double click on a row of the list.
            local windows = model.windows({
                {id = "w1", title = "bash"},
                {id = "w2", title = "Clock", minimized = true},
            })
            test.eq(windows[1].open.action, "raise")
            test.eq(windows[1].open.id, "w1")
            test.eq(windows[1].detail, "on screen")
            test.eq(windows[2].detail, "minimized")
        end)

        test.it("shows a broken shortcut as broken and does not let it be opened", function()
            -- A missing row reads as "I deleted it by accident", a broken one
            -- as "the program is gone". And there is nothing to open: there
            -- is no entry, and an intent to open would be a promise that
            -- nobody can keep.
            local objects = model.desktop({
                {id = "s1", kind = "shortcut", entry = "app:ghost", title = "Ghost"},
            }, {})
            test.eq(#objects, 1)
            test.eq(objects[1].icon, model.BROKEN_ICON)
            test.is_nil(objects[1].open, "a broken shortcut has nothing to open")
            test.is_true(objects[1].detail:find("no program", 1, true) ~= nil,
                "the reason is named in text, not left to guessing")
        end)

        test.it("does not pass a working shortcut off as broken when the catalog is not read", function()
            -- Accusing a working program on the basis of an unread catalog
            -- is worse than staying silent. But opening blindly is not
            -- allowed either: there is nowhere to take the window size from.
            local blind = model.desktop({
                {id = "s1", kind = "shortcut", entry = "app:real", title = "Real"},
            }, nil)
            test.eq(#blind, 1)
            test.eq(blind[1].title, "Real")
        end)

        test.it("opens a desktop folder in its own window", function()
            local objects = model.desktop({
                {id = "f1", kind = "folder", title = "Programs"},
            }, {})
            test.eq(objects[1].kind, "folder")
            test.eq(objects[1].open.action, "folder")
            test.is_true(objects[1].open.path:find("f1", 1, true) ~= nil,
                "the path must name the folder itself, otherwise the wrong one opens")
        end)
    end)

    -- FR-008: the model half of the folder windows — the Control Panel, the
    -- start path, the folder window intents, Details cells, sorting,
    -- selection and the browse mode.
    test.describe("folder windows (FR-008)", function()
        local PROGRAMS = {
            {entry = "app:display", title = "Display", group = {"Settings"}, image = "display_properties", width = 46, height = 24},
            {entry = "app:calc", title = "Calculator", group = {"Programs"}, image = "calculator"},
            {entry = "app:add", title = "Add/Remove Programs", group = {"Settings"}, image = "appwizard", width = 50, height = 20},
            {entry = "app:root_one", title = "Run", group = {}},
        }

        test.it("the Control Panel holds the Settings programs, sorted by title, each opening its window", function()
            local objects = model.control(PROGRAMS, {["app:display"] = "Desktop colour and screen."})
            test.eq(#objects, 2, "only the Settings group")
            test.eq(objects[1].title, "Add/Remove Programs")
            test.eq(objects[2].title, "Display")
            local display = objects[2]
            test.eq(display.kind, "program")
            test.eq(display.image, "display_properties")
            test.eq(display.open.action, "open_window")
            test.eq(display.open.entry, "app:display")
            test.eq(display.open.title, "Display")
            test.eq(display.open.w, 46)
            test.eq(display.open.h, 24)
            test.eq(display.detail, "Desktop colour and screen.", "the detail is the entry's comment")
            test.eq(model.details(display).type, "Control Panel item")
            test.eq(model.details(display).comment, "Desktop colour and screen.")
            test.eq(objects[1].detail, "app:add", "without a comment the entry id says what it is")
            test.eq(model.details(objects[1]).comment, "")
        end)

        test.it("a window starts at its args path; none is the root, an unknown path is the root with a notice", function()
            test.eq(model.start(nil), model.ROOT)
            test.eq(model.start(""), model.ROOT)
            local path, notice = model.start("drive/app:fs/ui")
            test.eq(path, "drive/app:fs/ui")
            test.is_nil(notice)
            test.eq(model.start("control"), "control")
            path, notice = model.start("nowhere/at/all")
            test.eq(path, model.ROOT)
            test.is_true(tostring(notice):find("nowhere/at/all", 1, true) ~= nil, "the notice names the path: " .. tostring(notice))
            path, notice = model.start(42)
            test.eq(path, model.ROOT)
            test.not_nil(notice)
        end)

        test.it("a folder window is titled and pictured by its folder", function()
            test.eq(model.folder_title(""), "My Computer")
            test.eq(model.folder_title("control"), "Control Panel")
            test.eq(model.folder_title("drive/app:fs"), "fs")
            test.eq(model.folder_title("drive/app:fs/ui/dist"), "dist")
            test.eq(model.folder_image(""), "my_computer")
            test.eq(model.folder_image("control"), "control_panel")
            test.eq(model.folder_image("drive/app:fs"), "drive")
            test.eq(model.folder_image("drive/app:fs/ui"), "folder_open")
        end)

        test.it("opening a folder focuses the window already open for it, else opens one with the path in args", function()
            local listing = {
                {id = "w1", entry = model.EXPLORER, args = "drive/app:fs"},
                {id = "w2", entry = "app:other", args = "drive/app:fs/ui"},
                {id = "w3", entry = model.EXPLORER},
            }
            local focus = model.open_folder("drive/app:fs", listing)
            test.eq(focus.action, "focus")
            test.eq(focus.id, "w1")
            local opened = model.open_folder("drive/app:fs/ui", listing)
            test.eq(opened.action, "open_window", "another entry's window for the path is not a folder window")
            test.eq(opened.entry, model.EXPLORER)
            test.eq(opened.args, "drive/app:fs/ui")
            test.eq(opened.title, "ui")
            test.eq(opened.image, "folder_open")
            test.eq(model.open_folder("", listing).id, "w3", "a window opened without args is the root's")
            test.eq(model.open_folder("drive/app:x", {}, "keeper ui_static_fs").title, "keeper ui_static_fs",
                "the caller's caption wins over the path's")
            test.eq(model.open_folder("control", nil).image, "control_panel")
        end)

        test.it("Details cells: sizes in whole kilobytes, the Type text, the US short date", function()
            test.eq(model.size_text(nil), "")
            test.eq(model.size_text(0), "0KB")
            test.eq(model.size_text(1), "1KB")
            test.eq(model.size_text(1024), "1KB")
            test.eq(model.size_text(1025), "2KB")
            test.eq(model.size_text(136192), "133KB")
            test.eq(model.size_text(1500000 * 1024), "1,500,000KB")
            test.eq(model.date_text({year = 1995, month = 7, day = 11, hour = 9, min = 50}), "7/11/95 9:50 AM")
            test.eq(model.date_text({year = 2026, month = 12, day = 3, hour = 0, min = 5}), "12/3/26 12:05 AM")
            test.eq(model.date_text({year = 2026, month = 1, day = 30, hour = 12, min = 0}), "1/30/26 12:00 PM")
            test.eq(model.date_text({year = 2026, month = 9, day = 13, hour = 21, min = 7}), "9/13/26 9:07 PM")
            test.is_true(model.date_text(804850200):match("^%d+/%d+/%d%d %d+:%d%d [AP]M$") ~= nil,
                "seconds are read as a local date: " .. model.date_text(804850200))
            test.eq(model.date_text(nil), "")

            local objects = model.files({
                {name = "notes.MD", type = "file", size = 2048, modified = 804850200},
                {name = "Makefile", type = "file", size = 10},
                {name = "ui", type = "directory", modified = 804850200},
            }, "drive/app:fs", "app:fs", nil, nil)
            local folder, notes, make = model.details(objects[1]), model.details(objects[3]), model.details(objects[2])
            test.eq(folder.name, "ui")
            test.eq(folder.size, "", "a folder has no size")
            test.eq(model.details({id = "big", kind = "directory", title = "big", size = 4096}).size, "",
                "not even when the reader gave one")
            test.eq(folder.type, "File Folder")
            test.eq(notes.name, "notes.MD")
            test.eq(notes.size, "2KB")
            test.eq(notes.type, "MD File", "an unknown type is its extension")
            test.is_true(notes.modified ~= "")
            test.eq(make.type, "File", "no extension, no letters")
            test.eq(make.modified, "", "an unknown date is empty, not the epoch")
            test.eq(model.details(model.drives({{id = "app:fs", kind = "fs.directory"}})[1]).type, "Local Disk")
            test.eq(model.details(model.drives({{id = "app:em", kind = "fs.embed"}})[1]).type, "Read-only Disk")
        end)

        test.it("sorts by name, type, size and date with the folders always first, stable for ties", function()
            local objects = {
                {id = "b.txt", kind = "file", title = "b.txt", size = 300, modified = 30, type_name = "Notepad Document"},
                {id = "Zed", kind = "directory", title = "Zed", modified = 10},
                {id = "a.png", kind = "file", title = "a.png", size = 100, modified = 20, type_name = "Picture Document"},
                {id = "c.md", kind = "file", title = "c.md", size = 200, modified = 10, type_name = "MD File"},
                {id = "apps", kind = "directory", title = "apps", modified = 40},
                {id = "twin", kind = "file", title = "same", size = 1},
                {id = "twin2", kind = "file", title = "same", size = 1},
            }
            local function order(key: any): string
                local out = {}
                for _, item in ipairs(model.sort(objects, key)) do out[#out + 1] = (item :: any).id end
                return table.concat(out, ",")
            end
            test.eq(order(nil), "apps,Zed,a.png,b.txt,c.md,twin,twin2", "by name, case aside")
            test.eq(order("name"), order(nil))
            test.eq(order("type"), "apps,Zed,twin,twin2,c.md,b.txt,a.png", "by the Type text: File, MD File, Notepad…, Picture…")
            test.eq(order("size"), "apps,Zed,twin,twin2,a.png,c.md,b.txt")
            test.eq(order("date"), "Zed,apps,twin,twin2,c.md,a.png,b.txt")
            test.eq(order("colour"), order(nil), "an unknown key is by name")
            test.eq(objects[1].id, "b.txt", "the input is not reordered")
            test.eq(#model.SORT_KEYS, 4)
        end)

        test.it("selection: click, Ctrl toggles, Shift ranges from the anchor, all, invert, and the summary", function()
            local objects = {
                {id = "a", kind = "file", title = "a", size = 1024, detail = "file a"},
                {id = "b", kind = "file", title = "b", size = 2048, detail = "file b"},
                {id = "c", kind = "directory", title = "c", detail = "folder", size = 4096},
                {id = "d", kind = "file", title = "d", size = 1, detail = "file d"},
                {id = "e", kind = "file", title = "e", detail = "file e"},
            }
            local function ids(set: any): string
                local out = {}
                for _, item in ipairs(objects) do if set[item.id] then out[#out + 1] = item.id end end
                return table.concat(out, ",")
            end
            local set, anchor = model.select({}, objects, 2, {})
            test.eq(ids(set), "b")
            test.eq(anchor, 2)
            set, anchor = model.select(set, objects, 4, {ctrl = true})
            test.eq(ids(set), "b,d", "Ctrl adds")
            test.eq(anchor, 4)
            set, anchor = model.select(set, objects, 1, {shift = true, anchor = anchor})
            test.eq(ids(set), "a,b,c,d", "Shift selects the range from the anchor")
            test.eq(anchor, 4, "the anchor stays")
            test.eq(ids(model.select({e = true}, objects, 1, {shift = true, anchor = 3})), "a,b,c",
                "and drops what lies outside it")
            set = model.select({e = true}, objects, 2, {shift = true, ctrl = true, anchor = 4})
            test.eq(ids(set), "b,c,d,e", "Ctrl+Shift adds the range")
            set = model.select(set, objects, 3, {ctrl = true})
            test.eq(ids(set), "b,d,e", "Ctrl toggles off")
            test.eq(ids(model.select(set, objects, 0, {ctrl = true})), "b,d,e", "Ctrl on the empty field keeps")
            set, anchor = model.select(set, objects, 0, {})
            test.eq(ids(set), "", "a click on the empty field clears")
            test.is_nil(anchor)
            test.eq(ids(model.select({}, objects, 5, {shift = true})), "e", "Shift without an anchor is a click")
            test.eq(ids(model.select_all(objects)), "a,b,c,d,e")
            test.eq(ids(model.invert({b = true, d = true}, objects)), "a,c,e")

            test.eq(model.selected_summary({}, objects), "")
            test.eq(model.selected_summary({b = true}, objects), "file b", "one object: its detail")
            test.eq(model.selected_summary({a = true, b = true, c = true}, objects), "3 object(s) selected, 3KB",
                "the folder adds no size")
            test.eq(model.selected_summary({c = true, e = true}, objects), "2 object(s) selected",
                "nothing with a known size, no size")
            test.eq(model.selected_summary({ghost = true}, objects), "", "only the listed objects count")
        end)

        test.it("the browse mode is separate unless single was chosen", function()
            test.eq(model.BROWSE[1], "separate")
            test.eq(model.browse_mode(nil), "separate")
            test.eq(model.browse_mode("single"), "single")
            test.eq(model.browse_mode("sideways"), "separate")
            test.is_true(model.is_browse("separate") and model.is_browse("single"))
            test.is_true(not model.is_browse("sideways"))
        end)
    end)

    -- The window has one reply channel. The base refuses commands without
    -- waiting — open, focus, state — over the same channel, marked
    -- `unsolicited`. A window that read everything as a reply to
    -- `desktop.list` put a refusal to open a program into the "Open Windows"
    -- folder and erased the list, and there was nothing on screen.
    test.describe("compositor replies", function()
        test.it("an unsolicited refusal does not touch the window list and goes to the status bar", function()
            local listed = {{id = "w1", title = "bash"}}
            local state: any = {windows = listed}
            test.eq(model.take_reply(state, {ok = false, error = "no such entry: app:gone",
                command = "desktop.open", unsolicited = true}), "notice")
            test.eq(state.windows, listed, "the window list is the same")
            test.is_nil(state.windows_error, "a refusal to open is not a refusal to give the list")
            test.eq(state.notice, "did not open: no such entry: app:gone")
            model.take_reply(state, {ok = false, error = "no window w9",
                command = "desktop.focus", unsolicited = true})
            test.eq(state.notice, "did not start: no window w9", "the same form as for an immediate refusal")
            model.take_reply(state, {ok = false, error = "gone", command = "desktop.state", unsolicited = true})
            test.eq(state.notice, "desktop.state refused: gone")
            test.eq(state.windows, listed)
            test.eq(model.refusal("desktop.open", "x"), "did not open: x",
                "the window calls the same function when the refusal comes immediately")
        end)

        test.it("a reply to desktop.list still fills the list", function()
            local state: any = {windows_error = "old"}
            test.eq(model.take_reply(state, {ok = true, command = "desktop.list",
                windows = {{id = "w1", title = "bash"}}}), "list")
            test.eq(#state.windows, 1)
            test.is_nil(state.windows_error)
            test.eq(model.take_reply(state, {ok = false, command = "desktop.list", error = "busy"}), "list")
            test.is_nil(state.windows)
            test.eq(state.windows_error, "busy")
        end)

        test.it("someone else's reply is not passed off as the list", function()
            local listed = {{id = "w1"}}
            local state: any = {windows = listed}
            test.is_nil(model.take_reply(state, {ok = true, command = "desktop.open", window = {id = "w2"}}))
            test.is_nil(model.take_reply(state, {ok = true, windows = {}}), "without command it is not a reply to list")
            test.is_nil(model.take_reply(state, nil))
            test.eq(state.windows, listed)
            test.is_nil(state.notice)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
