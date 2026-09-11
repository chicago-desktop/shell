-- Icon pack: every declared name is read and decoded in both sizes. A check
-- of form, not of presence: the raster must be exactly the size that was
-- asked for — otherwise `blit` puts the wrong thing in the wrong place on
-- the desktop.

local test = require("test")
local images = require("images")

local function define_tests()
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

            name = images.name_for({kind = "shortcut", entry = "butschster.windows.explorer:window"})
            test.eq(name, "my_computer")
            for _, kind in ipairs({"program", "window"}) do
                name = images.name_for({kind = kind, entry = "butschster.windows.explorer:window"})
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
