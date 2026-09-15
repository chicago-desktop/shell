-- Icon pack: every declared name is read and decoded in both sizes. A check
-- of form, not of presence: the raster must be exactly the size that was
-- asked for — otherwise `blit` puts the wrong thing in the wrong place on
-- the desktop.

local test = require("test")
local images = require("images")
local registry = require("registry")
local fs = require("fs")
local gfx = require("gfx")

-- A pack applied to the live registry: the path a module or the application
-- takes to bring pictures while the shell runs.
local function apply_pack(id: string, directory: string?): (any, any)
    local snapshot, serr = registry.snapshot()
    if not snapshot then return nil, serr end
    local changes = snapshot:changes()
    changes:create({id = id, kind = "fs.directory", meta = {type = images.PACK_TYPE},
        data = {base = "project", directory = directory or "./fixtures/images", auto_init = directory ~= nil}})
    return changes:apply()
end

-- A square PNG of one color, made with the same gfx the shell decodes with.
local function png(color: string): string
    local raster = gfx.raster(16, 16)
    raster:fill(color)
    return assert(raster:encode("png"))
end

local function drop_pack(id: string)
    local snapshot = registry.snapshot()
    if not snapshot or not registry.get(id) then return end
    local changes = snapshot:changes()
    changes:delete(id)
    changes:apply()
end

local function define_tests()
    test.describe("image packs of other modules", function()
        test.it("reads a picture from a pack by <entry>/<file> and keeps one raster", function()
            images.forget()
            local raster, why = images.get("app:test_images/smile", 16)
            test.not_nil(raster, tostring(why))
            local w, h = raster:size()
            test.eq(w, 16)
            test.eq(h, 16)
            test.is_true(images.get("app:test_images/smile", 16) == raster, "the raster outlives the frame")
            test.eq(images.name_for({kind = "program", image = "app:test_images/smile"}), "app:test_images/smile")
        end)

        test.it("refuses an fs entry that did not declare itself a pack", function()
            local raster, why = images.get("app:shots/smile", 16)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("not an image pack", 1, true), tostring(why))
        end)

        test.it("names the pack that is not in the registry and the file that is not in the pack", function()
            local raster, why = images.get("app:no_such_pack/smile", 16)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("no image pack app:no_such_pack", 1, true), tostring(why))
            raster, why = images.get("app:test_images/absent", 16)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("16/absent.png", 1, true), tostring(why))
        end)

        test.it("refuses a picture whose size is not its folder's", function()
            local raster, why = images.get("app:test_images/wrong", 16)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("is 8x8, expected 16x16", 1, true), tostring(why))
        end)

        test.it("takes a name, not a path, and a size it can read", function()
            local raster, why = images.get("app:test_images/../smile", 16)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("no such icon", 1, true), tostring(why))
            raster, why = images.get("app:test_images/smile", 0)
            test.is_nil(raster)
            test.not_nil(tostring(why):find("of size 0", 1, true), tostring(why))
        end)

        test.it("draws a pack applied to the live registry without touching the shell", function()
            images.forget()
            local recheck = images.PACK_RECHECK_SECONDS
            images.PACK_RECHECK_SECONDS = 0
            local id = "app:late_images"
            local before, why = images.get(id .. "/smile", 16)
            local applied, aerr = apply_pack(id)
            local after, later = images.get(id .. "/smile", 16)
            drop_pack(id)
            images.PACK_RECHECK_SECONDS = recheck
            test.is_nil(before, "the pack is not there yet")
            test.not_nil(tostring(why):find("no image pack", 1, true), tostring(why))
            test.not_nil(applied, "the pack entry was applied: " .. tostring(aerr))
            test.not_nil(after, "the picture of a pack applied later is drawn: " .. tostring(later))
        end)

        test.it("shows a picture replaced in a pack, and keeps the raster while the file is the same", function()
            images.forget()
            local recheck = images.PACK_RECHECK_SECONDS
            images.PACK_RECHECK_SECONDS = 0
            local id = "app:scratch_images"
            local applied, aerr = apply_pack(id, "./shots/scratch_pack")
            local store: any = applied and fs.get(id)
            local first, same, replaced: any, any, any = nil, nil, nil
            local why: any = aerr
            if store then
                store:mkdir("16")
                store:writefile("16/dot.png", png("#ffff00"))
                first, why = images.get(id .. "/dot", 16)
                same = images.get(id .. "/dot", 16)
                store:writefile("16/dot.png", png("#ff0000"))
                replaced = images.get(id .. "/dot", 16)
                store:remove("16/dot.png")
            end
            drop_pack(id)
            images.PACK_RECHECK_SECONDS = recheck
            test.not_nil(first, "the scratch pack serves its picture: " .. tostring(why))
            test.is_true(same == first, "an unchanged file keeps its raster: the surface resends nothing")
            test.not_nil(replaced, "the replaced file is read")
            test.is_true(replaced ~= first, "a replaced file is a new raster, drawn without a restart")
        end)
    end)

    test.describe("icon pack", function()
        test.it("decodes every icon in both sizes", function()
            images.forget()
            for _, name in ipairs(images.NAMES) do
                for _, size in ipairs(images.SIZES) do
                    local raster, why = images.get(name, size)
                    test.not_nil(raster, name .. "@" .. size .. ": " .. tostring(why))
                    local w, h = raster:size()
                    test.eq(w, size)
                    test.eq(h, size)
                end
            end
        end)

        test.it("returns one and the same raster on a repeated request", function()
            local first = images.get("folder", 32)
            local second = images.get("folder", 32)
            test.not_nil(first)
            test.is_true(first == second)
        end)

        test.it("refuses by name rather than staying silent", function()
            local raster, why = images.get("no_such_icon", 32)
            test.is_nil(raster)
            test.is_true(tostring(why):find("no such icon", 1, true) ~= nil)
        end)

        test.it("refuses a size that is not in the pack", function()
            local raster, why = images.get("folder", 24)
            test.is_nil(raster)
            test.is_true(tostring(why):find("of size 24", 1, true) ~= nil)
        end)

        test.it("resolves the name by kind and by an explicit image", function()
            local name, overlay = images.name_for({kind = "folder"})
            test.eq(name, "folder")
            test.is_nil(overlay)

            name, overlay = images.name_for({kind = "shortcut", entry = "app:x"})
            test.eq(name, "program")
            test.eq(overlay, "shortcut_overlay")

            name = images.name_for({kind = "shortcut", entry = "windows.shell.explorer:window"})
            test.eq(name, "my_computer")
            for _, kind in ipairs({"program", "window"}) do
                name = images.name_for({kind = kind, entry = "windows.shell.explorer:window"})
                test.eq(name, "my_computer")
            end

            name = images.name_for({kind = "folder", image = "printer"})
            test.eq(name, "printer")

            name = images.name_for({kind = "shortcut", entry = "app:x", broken = true})
            test.is_nil(name)
        end)

        test.it("puts the icon and the shortcut overlay into a raster", function()
            local gfx = require("gfx")
            local target = gfx.raster(64, 64)
            target:fill("#008080")
            local before = target:version()
            local ok, why = images.icon(target, 5, 5, {kind = "shortcut", entry = "app:x"}, 32)
            test.is_true(ok, tostring(why))
            test.is_true(target:version() > before)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
