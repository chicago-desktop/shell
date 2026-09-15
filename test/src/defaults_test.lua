-- Desktop furniture: what stands on the desktop at first launch and why it
-- does not come back when it was thrown away.
--
-- The costliest thing here is not "the icon appeared" but "the icon appeared
-- a SECOND time". The first is visible at once, the second only after a
-- restart, and it looks like broken deletion, not like a rule.
local test = require("test")
local repo = require("repo")
local chrome = require("chrome")
local defaults = require("defaults")
local seed = require("seed")

local function define_tests()
    test.describe("chicago.shell desktop furniture", function()
        test.it("does not put on the desktop an icon with nothing behind it", function()
            -- The Recycle Bin and "Network Neighborhood" are absent from the
            -- declaration on purpose: a prop icon looks like a working part of
            -- the system, and the first thing people will ask about it is why
            -- it does not work.
            for _, item in ipairs(defaults.ITEMS) do
                test.is_true(item.kind == "folder" or type(item.entry) == "string",
                    item.title .. ": the shortcut must reference a registry entry")
            end
        end)

        test.it("gives furniture names that fit under the icon", function()
            -- It is checked by THE SAME function the theme uses to draw the
            -- caption, not by a copy of it here. A copy of the rule would
            -- diverge from the original on the first edit, and silently: the
            -- test would stay green, while on screen the caption would slide.
            --
            -- The furniture will grow, and a bad name is caught either here or
            -- by eye on a frame a week later. It is caught by the name: a
            -- caption that does not fit into the column is cut — "My Computer
            -- and everything else" comes out as "My Computer" / "and" and ends
            -- there. An empty declaration would pass this loop silently, having
            -- checked nothing — the same trap as with any check by list.
            test.is_true(#defaults.ITEMS > 0, "the furniture must not be empty")

            -- The check must be able to fail: a name that certainly does not
            -- fit must be raised as overflow. Otherwise green means nothing.
            local _, too_long = chrome.caption_lines("My Computer and everything else")
            test.is_true(too_long, "a long name must be raised as not fitting")

            for _, item in ipairs(defaults.ITEMS) do
                local _, overflow = chrome.caption_lines(item.title)
                test.is_false(overflow,
                    item.title .. ": the caption does not fit under the icon")
            end
        end)

        test.it("skips a shortcut to a program that is not in the catalog", function()
            -- Creating it broken would mean putting a broken icon at the very
            -- first launch. A skipped one will be created when the program
            -- appears — and that is the only reason not to mark it here.
            local without = defaults.resolve({})
            for _, item in ipairs(without) do
                test.eq(item.kind, "folder", item.title .. ": without a catalog only folders remain")
            end

            -- The entry is taken from the furniture itself, not copied here: a
            -- name copied into a test survives the program moving and keeps
            -- checking what no longer exists.
            local wanted = {}
            for _, item in ipairs(defaults.ITEMS) do
                if item.kind == "shortcut" then
                    wanted[#wanted + 1] = {entry = item.entry, title = item.title}
                end
            end
            test.is_true(#wanted > 0, "there must be at least one shortcut in the furniture")

            local with = defaults.resolve(wanted)
            test.is_true(#with > #without, "with the program in the catalog there is more furniture")
        end)

        test.it("creates furniture once and does not bring back what was thrown away", function()
            local objects = {
                {key = "!furniture:probe", kind = repo.KIND_FOLDER, title = "Probe"},
            }

            local created, err = seed.furnish(objects)
            test.is_nil(err)
            test.eq(#created, 1, "furniture must appear at first launch")
            local id = created[1].id
            test.eq(created[1].kind, "folder")
            test.is_nil(created[1].entry, "no registry entry stands behind a desktop folder")

            local again, aerr = seed.furnish(objects)
            test.is_nil(aerr)
            test.eq(#again, 0, "a second launch does not duplicate furniture")

            -- The main thing. The person threw the icon away — and it does not
            -- come back on any later startup.
            test.is_true(repo.delete(id).existed)
            local third, terr = seed.furnish(objects)
            test.is_nil(terr)
            test.eq(#third, 0, "furniture thrown away does not come back")
        end)

        test.it("creates furniture before programs", function()
            -- The shell does not choose places — the compositor will choose
            -- them — but it does choose the order: the compositor puts icons in
            -- the order the layout returns them, and "My Computer" must take
            -- the head of the column rather than land under whatever happened
            -- to come along.
            local furniture, ferr = seed.furnish({
                {key = "!furniture:first", kind = repo.KIND_FOLDER, title = "First"},
            })
            test.is_nil(ferr)

            local program, perr = seed.ensure({
                {entry = "chicago.shell.test:second", title = "Second", desktop = true},
            })
            test.is_nil(perr)

            local items = repo.list()
            local at_furniture, at_program = nil, nil
            for index, item in ipairs(items or {}) do
                if item.id == furniture[1].id then at_furniture = index end
                if item.id == program[1].id then at_program = index end
            end
            test.is_true(at_furniture < at_program, "furniture comes before the program")

            repo.delete(furniture[1].id)
            repo.delete(program[1].id)
        end)

        test.it("keeps the furniture key in a form a registry entry cannot have", function()
            -- Furniture keys and program keys lie in the same column
            -- `desktop_seeded`. Were they to coincide, deleting a program's
            -- shortcut would extinguish the furniture, or vice versa.
            --
            -- What must be guarded is the PROPERTY, not today's convention.
            -- That we write "!" is an agreement, it can be changed tomorrow.
            -- What protects is something else: a registry entry identifier is
            -- always `namespace:name` made of letters, digits, dot and
            -- underscore, and a key that does not match this form can NEVER be
            -- an entry. That is what we check.
            for _, item in ipairs(defaults.ITEMS) do
                test.is_nil(item.key:match("^[%w_.]+:[%w_.]+$"),
                    item.title .. ": a furniture key must not look like an entry identifier")
            end
        end)

        test.it("does not assign furniture a place at all", function()
            -- The layout does not know the screen width at startup, so any
            -- place it chooses is a guess, and a guess past the edge costs an
            -- icon that vanished silently. The place is assigned by the
            -- compositor, which has the width.
            local created, err = seed.furnish({
                {key = "!furniture:noplace", kind = repo.KIND_FOLDER, title = "No place"},
            })
            test.is_nil(err)
            test.is_nil(created[1].x, "furniture is created without coordinates")
            test.is_nil(created[1].y)
            repo.delete(created[1].id)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
