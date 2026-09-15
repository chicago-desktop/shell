-- SDK format: pure, so every case runs on plain values.
local test = require("test")
local format = require("format")
local errors = require("errors")

-- A clock at +04.
local OFFSET = 4 * 3600

local function define_tests()
    test.describe("SDK format: time", function()
        test.it("parses RFC3339 to unix seconds, honouring the zone and dropping fractions", function()
            test.eq(format.parse_time("1970-01-01T00:00:00Z"), 0)
            test.eq(format.parse_time("2000-01-01T00:00:00Z"), 946684800)
            test.eq(format.parse_time("2024-02-29T12:00:00Z"), 1709208000, "a leap day")
            test.eq(format.parse_time("2000-01-01T04:00:00+04:00"), 946684800, "an offset is east of UTC")
            test.eq(format.parse_time("2000-01-01T00:00:00.250Z"), 946684800)
            test.is_nil(format.parse_time("next monday"))
            test.is_nil(format.parse_time("2000-01-01T00:00:00 CET"))
            test.is_nil(format.parse_time(nil))
        end)

        test.it("reads the clock's offset", function()
            test.eq(format.parse_offset("+04:00"), 14400)
            test.eq(format.parse_offset("-03:30"), -12600)
            test.eq(format.parse_offset("+0530"), 19800)
            test.eq(format.parse_offset("Z"), 0)
        end)

        test.it("shows local time, across midnight and the new year", function()
            test.eq(format.format_time(format.parse_time("2026-09-14T07:00:00Z") :: number, OFFSET), "2026-09-14 11:00")
            test.eq(format.format_time(format.parse_time("2026-09-13T22:30:00Z") :: number, OFFSET), "2026-09-14 02:30")
            test.eq(format.format_time(format.parse_time("2026-01-01T01:05:00Z") :: number, -3 * 3600), "2025-12-31 22:05")
            test.eq(format.format_time(format.parse_time("2024-02-29T12:00:00Z") :: number, 0), "2024-02-29 12:00",
                "January and February count in the previous year inside the algorithm")
            test.eq(format.when(nil, OFFSET, "Never"), "Never")
            test.eq(format.when("", OFFSET, "-"), "-")
            test.eq(format.when("soon", OFFSET, "Never"), "soon", "a value that does not parse is shown, not hidden")
        end)
    end)

    test.describe("SDK format: numbers", function()
        test.it("prints whole numbers and pads to two digits", function()
            test.eq(format.digits(2026.0), "2026", "a whole float prints without .0")
            test.eq(format.digits(7.9), "7")
            test.eq(format.two(7), "07")
            test.eq(format.two(12), "12")
        end)
    end)

    test.describe("SDK format: names", function()
        test.it("shows a user by the full name, else the e-mail, else the id", function()
            test.eq(format.display_name({user_id = "u1", email = "root@example.com", full_name = "Pavel B."}), "Pavel B.")
            test.eq(format.display_name({user_id = "u2", email = "noname@example.com", full_name = ""}), "noname@example.com",
                "an empty full name falls back to the e-mail")
            test.eq(format.display_name({user_id = "u3", email = "x@example.com"}), "x@example.com", "no full name at all")
            test.eq(format.display_name({user_id = "u4", email = "y@example.com", full_name = 42}), "y@example.com",
                "a full name that is not text is not a name")
            test.eq(format.display_name({user_id = "u7"}), "u7", "neither name nor e-mail: the id")
        end)

        test.it("the full name wins over the e-mail, the e-mail over the id", function()
            local row = {user_id = "u9", email = "mail@example.com", full_name = "Named"}
            test.eq(format.display_name(row), "Named")
            row.full_name = nil
            test.eq(format.display_name(row), "mail@example.com")
            row.email = nil
            test.eq(format.display_name(row), "u9")
        end)
    end)

    test.describe("SDK format: refusals", function()
        test.it("words a refusal by its kind", function()
            local denied = errors.new({message = "no actor", kind = errors.PERMISSION_DENIED})
            local missing = errors.new({message = "gone", kind = errors.NOT_FOUND})
            test.eq(format.explain("list", denied), "list: permission denied — no actor")
            test.eq(format.explain("get", missing), "get: not found — gone")
            test.eq(format.explain("list", "boom"), "list: boom")
            test.eq(format.explain("list", nil), "list failed")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
