-- The sources of "My Computer" on the live registry and the live database.
--
-- Checked here is exactly what the pure assembly of objects cannot check:
-- that a drive really comes from the registry, that the contents are really
-- read by the `fs` module, and that a closed door differs from an empty room.
--
-- The harness declares its own `fs.directory` — `app:probe_fs`. It is the
-- whole point of this suite: were we wrong about the filter name or the entry
-- shape, a test on made-up tables would stay green, and the window on the
-- running system would show emptiness.
local test = require("test")
local model = require("model")
local repo = require("repo")
local sources = require("sources")

local PROBE = "app:probe_fs"

local function by_id(objects, id)
    for _, object in ipairs(objects or {}) do
        if object.id == id then return object end
    end
    return nil
end

local function by_title(objects, title)
    for _, object in ipairs(objects or {}) do
        if object.title == title then return object end
    end
    return nil
end

local function define_tests()
    test.describe("butschster.windows explorer sources", function()
        test.it("takes drives from the registry, not from its own table", function()
            -- A drive declared by an installed module must appear by itself.
            -- The harness declared one — and here it is, without a single
            -- line about it in the shell.
            local records, err = sources.drives()
            test.is_nil(err, "the registry must be read")
            test.not_nil(records)
            local seen = {}
            for _, record in ipairs(records) do
                test.is_true(record.kind == "fs.directory" or record.kind == "fs.embed",
                    "the registry returned something that is not FS: " .. tostring(record.id))
                test.is_nil(seen[record.id], "each FS is shown once")
                seen[record.id] = true
            end

            local drives = model.drives(records)
            local probe = by_id(drives, PROBE)
            test.not_nil(probe, "a declared filesystem must become a drive")
            test.eq(probe.kind, "drive")
            test.eq(probe.open.path, "drive/" .. PROBE,
                "a double click must lead into this drive, not into a neighbouring one")
        end)

        test.it("shows the drives and the Control Panel at the root", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            test.not_nil(by_id(shown.objects, PROBE), "the drive must be in the root")
            test.is_nil(by_id(shown.objects, "programs"))
            test.is_nil(by_id(shown.objects, "desktop"))
            test.is_nil(by_id(shown.objects, "windows"))
            local control = by_id(shown.objects, model.CONTROL)
            test.not_nil(control, "the Control Panel is at the root")
            test.eq(control.open.path, "control")
            for _, object in ipairs(shown.objects) do
                if object ~= control then
                    test.eq(object.kind, "drive")
                    test.is_true(object.open.path:sub(1, 6) == "drive/")
                end
            end
        end)

        test.it("lists the catalog's Settings programs in the Control Panel, with their comments", function()
            local shown, err = sources.list("control", {})
            test.is_nil(err)
            test.eq(shown.title, "Control Panel")
            local display = by_id(shown.objects, "butschster.windows.display:window")
            test.not_nil(display, "Display Properties is a Settings program")
            test.not_nil(by_id(shown.objects, "butschster.windows.taskman:window"), "so is the Task Manager")
            test.is_nil(by_id(shown.objects, "butschster.windows.explorer:window"), "My Computer is not a Settings program")
            test.eq(display.open.action, "open_window")
            test.eq(display.open.entry, "butschster.windows.display:window")
            test.is_true(type(display.comment) == "string" and display.comment ~= "",
                "the Comment column is the entry's meta.comment")
            test.eq(display.detail, display.comment)
            local previous = ""
            for _, object in ipairs(shown.objects) do
                test.eq(object.kind, "program")
                local title = tostring(object.title):lower()
                test.is_true(title >= previous, "sorted by title: " .. title .. " after " .. previous)
                previous = title
            end
        end)

        test.it("reads each file's size and date with a stat, and names its type", function()
            local shown, err = sources.list("drive/" .. PROBE, {})
            test.is_nil(err)
            local self_file = by_title(shown.objects, "sources_test.lua")
            test.not_nil(self_file)
            test.is_true(tonumber(self_file.size) ~= nil and self_file.size > 1000,
                "this file is a few kilobytes: " .. tostring(self_file.size))
            test.is_true(tonumber(self_file.modified) ~= nil and self_file.modified > 1700000000,
                "modified is Unix seconds: " .. tostring(self_file.modified))
            local cells = model.details(self_file)
            test.is_true(cells.size:match("^[%d,]+KB$") ~= nil, cells.size)
            test.eq(cells.type, "Text Document", "Notepad names its documents (meta.file_type)")
            test.is_true(cells.modified ~= "")
        end)

        test.it("keeps the browse mode in the shell's settings and refuses an unknown one", function()
            local ok, err = sources.set_browse("single")
            test.is_nil(err)
            test.is_true(ok == true)
            test.eq(sources.browse(), "single")
            ok, err = sources.set_browse("sideways")
            test.is_nil(ok)
            test.not_nil(err)
            test.eq(sources.browse(), "single", "a refused mode is not stored")
            test.is_true(sources.set_browse("separate") == true)
            local mode, why = sources.browse()
            test.eq(mode, "separate")
            test.is_nil(why)
        end)

        test.it("reads the drive contents with the fs module", function()
            -- The test suite directory is certainly not empty, and it
            -- certainly holds this very file. Checking "something was read"
            -- is not enough: an empty list is "something" too.
            local shown, err = sources.list("drive/" .. PROBE, {})
            test.is_nil(err, "a declared drive must open")
            test.is_true(#shown.objects > 0, "the test suite directory is not empty")

            local self_file = by_title(shown.objects, "sources_test.lua")
            test.not_nil(self_file, "the file that writes this must be visible")
            test.eq(self_file.kind, "file")
            -- A file is opened by a program from the file type registry: .lua
            -- is declared by Notepad, and the request must carry its entry and
            -- an argument with the drive and the path inside the drive —
            -- otherwise the window opens empty.
            test.not_nil(self_file.open, "a file with a declared extension must open")
            test.eq(self_file.open.action, "open_window")
            test.eq(self_file.open.entry, "butschster.windows.viewers:notepad")
            test.is_true(tostring(self_file.open.args):find(PROBE, 1, true) ~= nil,
                "the argument must name the drive")
            test.is_true(tostring(self_file.open.args):find("/sources_test.lua", 1, true) ~= nil,
                "the argument must name the path inside the drive")
            test.eq(self_file.image, "text_document", "the file icon is the Notepad icon")
        end)

        test.it("answers with a reason, not emptiness, for a drive that does not exist", function()
            -- An empty directory and a closed door are different things.
            -- Merged into one, they send a person looking for missing files.
            local shown, err = sources.list("drive/app:no_such_fs", {})
            test.is_nil(shown)
            test.not_nil(err, "the failure must be named in words")
        end)

        test.it("does not show folder contents on the top level of the desktop", function()
            -- Otherwise a nested icon is visible twice: both in the folder and
            -- next to it.
            local folder, ferr = repo.create({
                kind = repo.KIND_FOLDER, title = "Box " .. tostring(os.time()),
            })
            test.is_nil(ferr)
            local inside, ierr = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "app:probe_fs",
                title = "Nested", parent_id = folder.id,
            })
            test.is_nil(ierr)

            local top = sources.list("desktop", {})
            test.is_nil(by_id(top.objects, inside.id),
                "a nested icon is not shown on the top level")
            test.not_nil(by_id(top.objects, folder.id), "the folder itself is shown")

            local opened, oerr = sources.list("desktop/" .. folder.id, {})
            test.is_nil(oerr)
            test.eq(opened.title, folder.title,
                "the title must name the opened folder, not \"Desktop\"")
            test.not_nil(by_id(opened.objects, inside.id),
                "inside the folder lies what was put into it")

            repo.delete(inside.id)
            repo.delete(folder.id)
        end)

        test.it("answers with a reason for a desktop folder that does not exist", function()
            -- Silence would turn a typo into a successfully opened emptiness.
            local shown, err = sources.list("desktop/no-such-folder", {})
            test.is_nil(shown)
            test.not_nil(err)
        end)

        test.it("does not pass an unknown path off as the root", function()
            local shown, err = sources.list("somewhere", {})
            test.is_nil(shown)
            test.not_nil(err)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
