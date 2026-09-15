-- The desktop layout on a live database.
--
-- What is checked is what would make a defect invisible: the round "created
-- — read — moved — deleted", a broken shortcut that must stay, and a deleted
-- shortcut that must not come back. The last is the only way to make sure
-- that deleting an icon works at all: an icon that comes back on every
-- startup looks not like a rule but like broken deletion.
local test = require("test")
local repo = require("repo")
local catalog = require("catalog")
local seed = require("seed")
local view = require("view")
local sql = require("sql")
local desktop_body = require("desktop_body")

local GHOST = "windows.shell.test:ghost"

local function define_tests()
    test.describe("windows.shell layout", function()
        test.it("survives the round created — read — moved — deleted", function()
            local item, cerr = repo.create({
                kind = repo.KIND_SHORTCUT,
                entry = "windows.shell.test:probe",
                title = "Probe",
                x = 2, y = 3,
            })
            test.is_nil(cerr)
            test.not_nil(item, "the created shortcut must be returned")
            test.eq(item.kind, "shortcut")
            test.eq(item.x, 2)
            test.eq(item.y, 3)

            local read, gerr = repo.get(item.id)
            test.is_nil(gerr)
            test.not_nil(read, "the shortcut must read back")
            test.eq(read.title, "Probe")
            test.eq(read.entry, "windows.shell.test:probe")

            local moved, uerr = repo.update(item.id, {x = 5, y = 1, title = "Renamed"})
            test.is_nil(uerr)
            test.not_nil(moved, "a move must return the row")
            test.eq(moved.x, 5)
            test.eq(moved.y, 1)
            test.eq(moved.title, "Renamed")

            -- The place survives a read, not just the handler's answer: the
            -- criterion "the icon ends up in the same place" is checked from
            -- the database.
            local again = repo.get(item.id)
            test.eq(again.x, 5)
            test.eq(again.y, 1)

            local gone, derr = repo.delete(item.id)
            test.is_nil(derr)
            test.is_true(gone.existed, "deleting an existing shortcut answers existed")
            test.is_nil(repo.get(item.id), "a deleted shortcut does not read")
        end)

        test.it('answers whether the row EXISTED, not just "deleted"', function()
            -- Otherwise a typo in the identifier looks like a successful
            -- deletion, and the person leaves sure they removed an icon that
            -- is still in place.
            local result, err = repo.delete("no-such-identifier")
            test.is_nil(err)
            test.is_false(result.existed, "deleting a nonexistent row does not pass itself off as success")
        end)

        test.it("moves the contents of a deleted folder to the desktop instead of deleting them along with it", function()
            local folder = repo.create({kind = repo.KIND_FOLDER, title = "Folder", x = 0, y = 0})
            local inside = repo.create({
                kind = repo.KIND_SHORTCUT,
                entry = "windows.shell.test:inside",
                title = "Inside",
                parent_id = folder.id,
            })
            test.eq(repo.get(inside.id).parent_id, folder.id)

            local result = repo.delete(folder.id)
            test.is_true(result.existed)
            test.eq(result.promoted, 1, "the folder must say how many icons it moved out")

            local orphan = repo.get(inside.id)
            test.not_nil(orphan, "a cascade would carry away the icons the user put in")
            test.is_nil(orphan.parent_id, "the moved-out icon lies on the desktop")

            repo.delete(inside.id)
        end)

        test.it("keeps a shortcut to a vanished entry and marks it broken", function()
            -- A vanished icon reads as "I deleted it by accident", a broken
            -- one as "the program is gone". These are different statements.
            local item = repo.create({
                kind = repo.KIND_SHORTCUT, entry = GHOST, title = "Ghost", x = 9, y = 9,
            })

            local found, cerr = catalog.list()
            test.is_nil(cerr, "the harness catalog reads, even if empty")
            test.is_nil(catalog.find(found.programs, GHOST), "there is no entry in the registry")

            local rows = view.join({repo.get(item.id)}, found)
            test.eq(#rows, 1, "the shortcut must stay in the layout")
            test.is_true(rows[1].broken, "and be marked broken")
            test.eq(rows[1].entry, GHOST)

            -- An unreadable catalog does not make a working program broken:
            -- accusing it on the basis of an unread catalog is worse than
            -- keeping silent.
            local blind = view.join({repo.get(item.id)}, nil)
            test.is_nil(blind[1].broken, "without a catalog the broken marker is not set")

            repo.delete(item.id)
        end)
    end)

    test.describe("windows.shell desktop seeding", function()
        test.it("puts a program with desktop true on the desktop once and does not bring back a deleted shortcut", function()
            local program = {
                entry = "windows.shell.test:seeded",
                title = "Auto icon",
                desktop = true,
            }

            local created, err = seed.ensure({program})
            test.is_nil(err)
            test.eq(#created, 1, "a program with desktop true must get a shortcut")
            local id = created[1].id
            test.eq(created[1].entry, program.entry)

            -- Idempotence: a repeated call with the same catalog writes
            -- nothing. Otherwise every menu opening would duplicate icons.
            local again, aerr = seed.ensure({program})
            test.is_nil(aerr)
            test.eq(#again, 0, "a second pass does not duplicate the icon")

            -- The main thing. The user removed the icon — and it does not come
            -- back on any later startup. The mark of the offer lives
            -- separately and is not touched by deleting the shortcut.
            local removed = repo.delete(id)
            test.is_true(removed.existed)

            local third, terr = seed.ensure({program})
            test.is_nil(terr)
            test.eq(#third, 0, "a deleted shortcut does not come back")
            test.is_nil(repo.get(id), "and the old row is gone too")
        end)

        test.it("does not touch a program without desktop true", function()
            local created, err = seed.ensure({
                {entry = "windows.shell.test:quiet", title = "Quiet"},
            })
            test.is_nil(err)
            test.eq(#created, 0, "a shortcut is created only at the program's request")
        end)

        test.it("creates an automatic icon WITHOUT coordinates", function()
            -- Places are not chosen here: the shell lays out icons before the
            -- terminal has reported its size, and a place it chose could end
            -- up past the edge — and an icon past the edge is not clipped, it
            -- disappears entirely and silently.
            --
            -- Zero instead of emptiness would be the worst outcome: it is a
            -- PLACE, and the icon would become placed in the top-left corner,
            -- that is, inviolable for the compositor.
            local created, err = seed.ensure({
                {entry = "windows.shell.test:unplaced", title = "No place", desktop = true},
            })
            test.is_nil(err)
            test.eq(#created, 1)
            test.is_nil(created[1].x, "an automatic icon's coordinates are empty")
            test.is_nil(created[1].y)

            local read = repo.get(created[1].id)
            test.is_nil(read.x, "and stay empty after reading from the database")
            test.is_nil(read.y)

            repo.delete(created[1].id)
        end)

        test.it("makes an icon placed when a place is named", function()
            -- A named place is inviolable: from this moment on the compositor
            -- does not relay the icon, even if the screen got narrower and the
            -- icon went past the edge. So it is in real Windows 95 too — an
            -- icon that went past the edge does not come back by itself.
            local created = seed.ensure({
                {entry = "windows.shell.test:tobeplaced", title = "To be placed", desktop = true},
            })
            local id = created[1].id
            test.is_nil(repo.get(id).x, "until a place is named, it is empty")

            local moved, err = repo.update(id, {x = 45, y = 9})
            test.is_nil(err)
            test.eq(moved.x, 45)
            test.eq(moved.y, 9)
            test.eq(repo.get(id).x, 45, "the place survived the write")

            repo.delete(id)
        end)

        test.it("returns placed icons before those whose place was not named", function()
            -- The order is set explicitly because dialects sort empty
            -- coordinates differently: SQLite puts NULL at the start,
            -- PostgreSQL at the end. Without an explicit rule the icon layout
            -- would depend on which database the stand runs on.
            local placed = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:order_placed",
                title = "Placed", x = 30, y = 5,
            })
            local unplaced = repo.create({
                kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:order_unplaced",
                title = "No place",
            })

            local items = repo.list()
            local seen_placed, seen_unplaced = nil, nil
            for index, item in ipairs(items or {}) do
                if item.id == placed.id then seen_placed = index end
                if item.id == unplaced.id then seen_unplaced = index end
            end
            test.not_nil(seen_placed)
            test.not_nil(seen_unplaced)
            test.is_true(seen_placed < seen_unplaced,
                "an icon with a place comes before an icon without one")

            repo.delete(placed.id)
            repo.delete(unplaced.id)
        end)
    end)

    -- The desktop POST and PATCH body (windows.shell.api:desktop_body):
    -- what the handlers accepted and the desktop then did not draw.
    test.describe("desktop request bodies", function()
        test.it("broken JSON and a non-object are a failure with a reason, not an empty successful PATCH", function()
            local patch, why = desktop_body.update('{"title": ')
            test.is_nil(patch)
            test.is_true(tostring(why):find("body is not JSON", 1, true) == 1, tostring(why))
            patch, why = desktop_body.update("[1, 2]")
            test.is_nil(patch)
            test.eq(why, "body: a JSON object")
            local spec, cwhy = desktop_body.create("")
            test.is_nil(spec)
            test.is_true(tostring(cwhy):find("body is not JSON", 1, true) == 1, tostring(cwhy))
        end)

        test.it("a coordinate is a finite integer from 1 to 10000, and the database does not glue infinity to the corner", function()
            local cases = {
                {'{"x": 1.5}', "x: a whole number"},
                {'{"x": 0}', "x: between 1 and 10000"},
                {'{"y": 10001}', "y: between 1 and 10000"},
                {'{"x": "left"}', "x: a number"},
                -- The string "1e999" is not a number at all in go-lua:
                -- tonumber gives nil.
                {'{"x": "1e999"}', "x: a number"},
            }
            for _, case in ipairs(cases) do
                local patch, why = desktop_body.update(case[1])
                test.is_nil(patch, case[1])
                test.eq(why, case[2], case[1])
            end
            -- Infinity arrives as a NUMBER: JSON 1e999 or a call from Lua.
            local _, huge = desktop_body.coordinate(math.huge)
            test.eq(huge, "a finite number")
            local _, nan = desktop_body.coordinate(0 / 0)
            test.eq(nan, "a finite number")
            local spec, why = desktop_body.create('{"kind": "shortcut", "entry": "app:x", "x": 1e999, "y": 2}')
            test.is_nil(spec, "1e999 as a number does not pass: " .. tostring(why))
            local ok = desktop_body.update('{"x": 10000, "y": "7"}')
            test.eq(ok.x, 10000)
            test.eq(ok.y, 7)
            local item = repo.create({kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:inf",
                title = "Inf", x = math.huge, y = 3})
            test.is_nil(item.x, "infinity becomes no place, not a zero")
            repo.delete(item.id)
        end)

        test.it("a folder does not nest into a folder — neither on creation nor by moving", function()
            local spec, why = desktop_body.create('{"kind": "folder", "title": "A", "parent_id": "p1"}')
            test.is_nil(spec)
            test.eq(why, desktop_body.FOLDER_IN_FOLDER)
            test.eq(desktop_body.nest(repo.KIND_FOLDER, {id = "p1", kind = repo.KIND_FOLDER}), desktop_body.FOLDER_IN_FOLDER)
            test.eq(desktop_body.nest(repo.KIND_SHORTCUT, nil), "parent_id: no such folder")
            test.eq(desktop_body.nest(repo.KIND_SHORTCUT, {id = "s", kind = repo.KIND_SHORTCUT}),
                "parent_id: only a desktop folder can hold items")
            test.is_nil(desktop_body.nest(repo.KIND_SHORTCUT, {id = "p1", kind = repo.KIND_FOLDER}))
        end)

        test.it("parent_id: null is only a top-level key, not a substring of the body", function()
            test.eq(desktop_body.update('{"parent_id": null}').parent_id, false, "move to the desktop")
            test.is_nil(desktop_body.update('{"title": "A", "meta": {"parent_id": null}}').parent_id,
                "a nested key is not ours")
            test.is_nil(desktop_body.update('{"title": "\\"parent_id\\": null"}').parent_id,
                "text inside a string is not a key")
            test.is_nil(desktop_body.update('{"title": "A"}').parent_id, "a missing field means leave alone")
        end)

        test.it("entry and title are at most 256 and 512 characters", function()
            local spec, why = desktop_body.create('{"kind": "shortcut", "entry": "' .. string.rep("e", 257) .. '"}')
            test.is_nil(spec)
            test.eq(why, "entry: at most 256 characters")
            local patch, twhy = desktop_body.update('{"title": "' .. string.rep("t", 513) .. '"}')
            test.is_nil(patch)
            test.eq(twhy, "title: at most 512 characters")
            -- The ceiling is in characters: 512 Cyrillic ones (1024 bytes)
            -- pass.
            local cyrillic = string.rep("я", 512)
            test.eq(desktop_body.update('{"title": "' .. cyrillic .. '"}').title, cyrillic)
        end)

        test.it("a full PATCH passes validation and reaches the database", function()
            local folder = repo.create({kind = repo.KIND_FOLDER, title = "Box"})
            local item = repo.create({kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:full_patch", title = "Before"})
            local patch, why = desktop_body.update(string.format(
                '{"title": "After", "x": 12, "y": 3, "parent_id": "%s"}', folder.id))
            test.not_nil(patch, tostring(why))
            test.is_nil(desktop_body.nest(item.kind, repo.get(patch.parent_id)))
            local moved = repo.update(item.id, patch)
            test.eq(moved.title, "After")
            test.eq(moved.x, 12)
            test.eq(moved.y, 3)
            test.eq(moved.parent_id, folder.id)
            local out = repo.update(item.id, desktop_body.update('{"parent_id": null}'))
            test.is_nil(out.parent_id, "null moves it to the desktop")
            repo.delete(item.id)
            repo.delete(folder.id)
        end)
    end)

    -- A second writer and a failure in the middle: what, without transactions
    -- and ON CONFLICT, gave a key error, an extra icon or half a table.
    test.describe("persistence under a second writer", function()
        test.it("offering one icon twice gives one shortcut and not a single error", function()
            local key = "windows.shell.test:offer_twice"
            local first, ferr = repo.offer(key, {kind = repo.KIND_SHORTCUT, entry = key, title = "Once"})
            test.is_nil(ferr, tostring(ferr))
            test.not_nil(first)
            local second, serr = repo.offer(key, {kind = repo.KIND_SHORTCUT, entry = key, title = "Once"})
            test.is_nil(serr, tostring(serr))
            test.eq(second, false, 'the second time is "already offered", not a key error')
            local count = 0
            for _, item in ipairs(repo.list() or {}) do
                if item.entry == key then count = count + 1 end
            end
            test.eq(count, 1, "one icon")
            local again, merr = repo.mark_seeded(key)
            test.is_nil(merr, tostring(merr))
            test.eq(again, false, "a repeated mark is false, not an error")
            repo.delete(first.id)
        end)

        test.it("a setting is written and read with placeholders of one dialect", function()
            local _, err = repo.set_setting("test.dialect", "a")
            test.is_nil(err, tostring(err))
            repo.set_setting("test.dialect", "b")
            test.eq(repo.setting("test.dialect"), "b")
        end)

        test.it("migration 02: rebuilding the table inside a transaction rolls back entirely", function()
            -- The wippy/migration runner calls `up(tx)` inside its own
            -- transaction and rolls it back on any error (migration.lua,
            -- execute_migration). What is checked here is that on this driver
            -- SQLite DDL rolls back together with it: a failure after DROP
            -- does not leave a lone `_new`, and a rerun starts from the
            -- original table.
            local db = assert(sql.get("app:db"))
            local kind = db:type()
            if kind ~= "sqlite" then db:release(); return end
            local function count(): any
                local rows = assert(db:query("SELECT COUNT(*) AS n FROM windows_shell_desktop_items", {}))
                return tonumber(rows[1].n)
            end
            local marker = repo.create({kind = repo.KIND_FOLDER, title = "Survives the rollback"})
            local before = count()
            local tx = assert(db:begin())
            local _, cerr = tx:execute([[
                CREATE TABLE windows_shell_desktop_items_new (
                    id TEXT PRIMARY KEY, kind TEXT NOT NULL, entry TEXT, parent_id TEXT,
                    title TEXT NOT NULL, x INTEGER, y INTEGER,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL)
            ]], {})
            test.is_nil(cerr, tostring(cerr))
            local _, ierr = tx:execute("INSERT INTO windows_shell_desktop_items_new SELECT id, kind, entry, parent_id, title, x, y, created_at, updated_at FROM windows_shell_desktop_items", {})
            test.is_nil(ierr, tostring(ierr))
            local _, derr = tx:execute("DROP TABLE windows_shell_desktop_items", {})
            test.is_nil(derr, tostring(derr))
            -- Here the migration would fail before RENAME — and the runner
            -- rolls back.
            tx:rollback()
            test.eq(count(), before, "the original table is intact with all rows")
            local leftovers = assert(db:query(
                "SELECT name FROM sqlite_master WHERE name = 'windows_shell_desktop_items_new'", {}))
            test.eq(#leftovers, 0, "`_new` did not stay behind")
            db:release()
            repo.delete(marker.id)
        end)
    end)

    -- Several people use one runtime at once (a terminal.ssh host gives every
    -- connection a desktop): an icon or a color one of them changes must not
    -- change on the others' screens.
    test.describe("layouts of people", function()
        test.it("two people's layouts and settings do not mix, and the shared one stays", function()
            local alice, bob = repo.of("test:alice"), repo.of("test:bob")
            local mine, cerr = alice.create({kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:alice", title = "Alice's"})
            test.is_nil(cerr, tostring(cerr))
            local function has(list: any, id: any): boolean
                for _, item in ipairs(list or {}) do if item.id == id then return true end end
                return false
            end
            test.is_true(has(alice.list(), mine.id), "the owner sees the icon")
            test.is_false(has(bob.list(), mine.id), "another person does not")
            test.is_false(has(repo.list(), mine.id), "the shared layout does not")
            test.is_nil(bob.get(mine.id), "another person's icon does not read")
            test.eq(bob.update(mine.id, {x = 9, y = 9}), false, "another person's icon is no such row")
            test.is_false(bob.delete(mine.id).existed, "another person cannot delete it")
            test.eq(alice.get(mine.id).x, nil, "and it did not move")

            alice.set_setting("test.color", "#112233")
            bob.set_setting("test.color", "#445566")
            test.eq(alice.setting("test.color"), "#112233")
            test.eq(bob.setting("test.color"), "#445566")
            test.is_nil(repo.setting("test.color"), "the shared settings stay untouched")
            test.eq(repo.of(nil).user, repo.SHARED, "nobody is the shared layout")
            alice.delete(mine.id)
        end)

        test.it("a person inherits the shared layout once, folders with their contents, marks and settings", function()
            local folder = assert(repo.create({kind = repo.KIND_FOLDER, title = "Shared folder"}))
            local inside = assert(repo.create({kind = repo.KIND_SHORTCUT, entry = "windows.shell.test:shared_inside",
                title = "Inside", parent_id = folder.id}))
            repo.set_setting("test.inherited", "yes")
            repo.mark_seeded("windows.shell.test:shared_mark")

            local carol = repo.of("test:carol")
            local copied_folder: any, copied_inside: any = nil, nil
            for _, item in ipairs(carol.list() or {}) do
                if item.title == "Shared folder" then copied_folder = item end
                if item.entry == "windows.shell.test:shared_inside" then copied_inside = item end
            end
            test.not_nil(copied_folder, "the shared folder came along")
            test.not_nil(copied_inside, "and its contents")
            test.is_true(copied_folder.id ~= folder.id, "as a row of her own, not the shared one")
            test.eq(copied_inside.parent_id, copied_folder.id, "the contents follow her copy of the folder")
            test.eq(carol.setting("test.inherited"), "yes")
            local marks = carol.seeded() or {}
            test.is_true(marks["windows.shell.test:shared_mark"] == true, "what was offered stays offered")
            test.is_true(marks[repo.INHERITED] == true, "the inheritance is marked, among marks never deleted")

            -- A second process of the same person (another desktop) asks the
            -- database again: the mark keeps it to once.
            repo.forget("test:carol")
            local folders = 0
            for _, item in ipairs(carol.list() or {}) do
                if item.title == "Shared folder" then folders = folders + 1 end
            end
            test.eq(folders, 1, "a second desktop of the same person does not copy the shared layout again")

            -- After the inheritance the layouts are apart.
            local later = assert(repo.create({kind = repo.KIND_FOLDER, title = "Shared later"}))
            for _, item in ipairs(carol.list() or {}) do
                test.is_true(item.title ~= "Shared later", "a later shared icon does not reach her")
            end
            carol.delete(copied_inside.id)
            test.not_nil(repo.get(inside.id), "her deletion leaves the shared icon")

            repo.delete(inside.id)
            repo.delete(folder.id)
            repo.delete(later.id)
        end)

        test.it("a process without a logged-on person is the shared layout", function()
            test.eq(repo.person(), repo.SHARED)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
