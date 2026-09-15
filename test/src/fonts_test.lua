-- The shell's own fonts: the pixel theme reads Liberation Sans and Liberation
-- Mono from the module's `chicago.shell.theme:fonts`, so a machine without a
-- font package still gets captions. The harness declares NO app:system_fonts
-- — every face here comes from the module's store — and CHICAGO_FONTS still
-- names another store.
local test = require("test")
local gfx = require("gfx")
local registry = require("registry")
local font_set = require("font_set")

-- An env stand-in with the module's `get_all` and `get`, as environment_test
-- has it: `get_all` answers the permitted keys, `get` a value or an error.
local MISSING = errors.new({message = "environment variable not found", kind = errors.NOT_FOUND})
local function env_with(all: any): any
    return {
        get_all = function() return all end,
        get = function(_) return nil, MISSING end,
    }
end

-- caption(font) -> a white strip with "Welcome to Chicago" set in `font`, and
-- the same strip untouched, both as PNG bytes: gfx has no pixel read, so a
-- face that drew nothing gives the blank strip's bytes.
local function caption(font: any): (string, string)
    local blank = gfx.raster(200, 24)
    blank:fill("#ffffff")
    local written = gfx.raster(200, 24)
    written:fill("#ffffff")
    written:text(2, 2, "Welcome to Chicago", {font = font, color = "#000000"})
    return assert(written:encode("png")), assert(blank:encode("png"))
end

local function define_tests()
    test.describe("the shell's own fonts", function()
        test.it("the module declares its font store, and the harness has no system font folder", function()
            test.is_nil(registry.get("app:system_fonts"), "the suites must not lean on a system font folder")
            local entry: any = registry.get(font_set.STORE)
            test.not_nil(entry, font_set.STORE .. " is in the registry")
            test.eq(tostring(entry.kind), "fs.directory")
        end)

        test.it("regular, bold, display and fixed-pitch faces load from the module's store and each draws a caption", function()
            local fonts, err = font_set.load(font_set.STORE, 20)
            test.not_nil(fonts, "the module's fonts load: " .. tostring(err))
            local faces: any = fonts or {}
            for _, name in ipairs({"face", "bold", "display", "mono"}) do
                test.not_nil(faces[name], name .. " is made")
                local written, blank = caption(faces[name])
                test.is_true(written ~= blank, name .. " draws a caption, not an empty strip")
            end
        end)

        test.it("without CHICAGO_FONTS the store is the module's own", function()
            local id, source, denied = font_set.store(env_with({}))
            test.eq(id, "chicago.shell.theme:fonts")
            test.eq(source, "not set")
            test.is_true(denied == false)
        end)

        test.it("CHICAGO_FONTS names another store, and that store is the one read", function()
            local id, source = font_set.store(env_with({CHICAGO_FONTS = "app:override_fonts"}))
            test.eq(id, "app:override_fonts")
            test.eq(source, "process environment")
            local fonts, err = font_set.load(id, 20)
            test.not_nil(fonts, "the named store loads: " .. tostring(err))

            local missing, why = font_set.load("app:no_such_fonts", 20)
            test.is_nil(missing, "a named store that does not exist is not replaced by the module's own")
            test.not_nil(string.find(tostring(why), "app:no_such_fonts", 1, true), tostring(why))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
