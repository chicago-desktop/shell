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
local render = require("render")
local tty = require("tty")
local process = require("process")
local channel = require("channel")
local time = require("time")

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
    test.describe("Explorer input", function()
        test.it("scrolls a real viewport with wheel and scrollbar arrows", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            local width, height = 22, 9
            local shape = render.shape(width, height, #shown.objects, 0)
            test.is_true(shape.scrolling, "fixture must require scrolling")
            test.is_true(shape.rows > 0)
            local view = assert(tty.viewport({width = width, height = height}))
            local pid, why = process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("butschster.windows.explorer:window", "app:processes")
            test.is_nil(why)
            test.not_nil(pid)
            local state: any = {path = model.ROOT, title = shown.title, objects = shown.objects,
                selected = 0, offset = 0}
            local function wait_frame(offset)
                state.offset = offset
                local canvas = tty.canvas(width, height)
                local hits = render.window(canvas, state, width, height)
                local expected = table.concat(canvas:rows(), "\n")
                local actual = ""
                local deadline = time.now():unix_nano() + 5000000000
                while time.now():unix_nano() < deadline do
                    local snap: any = view:snapshot(-1)
                    actual = snap and table.concat(snap.rows or {}, "\n") or ""
                    if actual == expected then return hits end
                    channel.select({time.after("20ms"):case_receive()})
                end
                test.eq(actual, expected, "viewport did not reach scroll row " .. offset)
                return hits
            end
            local area = render.layout(state, width, height).inner
            wait_frame(0)
            view:send({type = "mouse", action = "wheel", button = "wheel_down", x = area.x, y = area.y})
            wait_frame(1)
            view:send({type = "mouse", action = "wheel", button = "wheel_up", x = area.x, y = area.y})
            wait_frame(0)
            -- The scrollbar arrows are the edges of `plan.scroll`: the window
            -- gives the same geometry to `scroll.pointer`, the bar has no hits
            -- of its own any more.
            local bar: any = render.layout(state, width, height).scroll
            test.not_nil(bar, "the fixture shows a scrollbar")
            for _, arrow in ipairs({{y = bar.y + bar.h - 1, offset = 1}, {y = bar.y, offset = 0}}) do
                view:send({type = "mouse", action = "press", button = "left", x = bar.x, y = arrow.y})
                view:send({type = "mouse", action = "release", button = "left", x = bar.x, y = arrow.y})
                wait_frame(arrow.offset)
            end
            view:send({type = "close"})
            view:close()
            process.terminate(tostring(pid))
        end)
    end)
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

        test.it("shows only FS in the root", function()
            local shown, err = sources.list(model.ROOT, {})
            test.is_nil(err)
            test.not_nil(by_id(shown.objects, PROBE), "the drive must be in the root")
            test.is_nil(by_id(shown.objects, "programs"))
            test.is_nil(by_id(shown.objects, "desktop"))
            test.is_nil(by_id(shown.objects, "windows"))
            for _, object in ipairs(shown.objects) do
                test.eq(object.kind, "drive")
                test.is_true(object.open.path:sub(1, 6) == "drive/")
            end
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
