-- Пакет значков: каждое объявленное имя читается и декодируется в обоих
-- размерах. Проверка формы, а не наличия: растр обязан быть ровно того
-- размера, что просили, — иначе `blit` положит на стол не то и не туда.

local test = require("test")
local images = require("images")

local function run()
    test.describe("пакет значков", function()
        test.it("декодирует каждый значок в обоих размерах", function()
            images.forget()
            for _, name in ipairs(images.NAMES) do
                for _, size in ipairs(images.SIZES) do
                    local raster, why = images.get(name, size)
                    test.expect(raster, name .. "@" .. size .. ": " .. tostring(why)).to_be_truthy()
                    local w, h = raster:size()
                    test.expect(w).to_equal(size)
                    test.expect(h).to_equal(size)
                end
            end
        end)

        test.it("отдаёт один и тот же растр на повторный запрос", function()
            local first = images.get("folder", 32)
            local second = images.get("folder", 32)
            test.expect(first == second).to_be_true()
        end)

        test.it("отказывает по имени, а не молчит", function()
            local raster, why = images.get("no_such_icon", 32)
            test.expect(raster).to_be_nil()
            test.expect(tostring(why):find("нет такого значка", 1, true) ~= nil).to_be_true()
        end)

        test.it("отказывает на размер, которого в пакете нет", function()
            local raster, why = images.get("folder", 24)
            test.expect(raster).to_be_nil()
            test.expect(tostring(why):find("размера 24", 1, true) ~= nil).to_be_true()
        end)

        test.it("решает имя по виду и по явному image", function()
            local name, overlay = images.name_for({kind = "folder"})
            test.expect(name).to_equal("folder")
            test.expect(overlay).to_be_nil()

            name, overlay = images.name_for({kind = "shortcut", entry = "app:x"})
            test.expect(name).to_equal("program")
            test.expect(overlay).to_equal("shortcut_overlay")

            name = images.name_for({kind = "shortcut", entry = "butschster.windows.explorer:window"})
            test.expect(name).to_equal("my_computer")

            name = images.name_for({kind = "folder", image = "printer"})
            test.expect(name).to_equal("printer")

            name = images.name_for({kind = "shortcut", entry = "app:x", broken = true})
            test.expect(name).to_equal("program")
        end)

        test.it("кладёт значок и накладку ярлыка в растр", function()
            local gfx = require("gfx")
            local target = gfx.raster(64, 64)
            target:fill("#008080")
            local before = target:version()
            local ok, why = images.icon(target, 5, 5, {kind = "shortcut", entry = "app:x"}, 32)
            test.expect(ok, tostring(why)).to_be_truthy()
            test.expect(target:version() > before).to_be_true()
        end)
    end)
end

return {run = run}
