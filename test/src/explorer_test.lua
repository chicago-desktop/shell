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
        test.it("leaves the root empty when there are no filesystems", function()
            test.eq(#model.root({}), 0)
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

        test.it("has only FS in the root, without shell folders", function()
            local root = model.root({{id = "app:probe", kind = "fs.directory"}})
            test.eq(#root, 1)
            test.eq(root[1].id, "app:probe")
            test.eq(root[1].kind, "drive")
            for _, name in ipairs({"programs", "desktop", "windows"}) do
                test.is_nil(by_id(root, name))
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
        end)

        test.it("goes one level up, not straight to the root", function()
            test.is_nil(model.parent(model.ROOT), "there is nowhere above the root")
            test.eq(model.parent("programs"), model.ROOT)
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
            test.eq(#root, 2)
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
