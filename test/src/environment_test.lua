-- Reading the environment: a permission denial is distinguishable from "not
-- set", and a default does not hide it.
--
-- A real permission denial cannot be obtained in the suite: tests run under
-- broad permissions. So env is a stand-in — with the same `get_all` and `get`
-- as the module: `get_all` puts in only permitted keys, `get` answers with a
-- value or an error.
--
-- The error, however, is REAL, from `errors.new`, as in the runtime. A table
-- with a `kind` field would also pass the old check `type(err) == "table" and
-- err.kind`, which a real error (userdata with a `kind()` method) never
-- passes: a test on a table would be green exactly where the code is blind.
local test = require("test")
local environment = require("environment")

local function fake(all: any, value: any, err: any): any
    return {
        get_all = function() return all end,
        get = function(_) return value, err end,
    }
end

local DENIED = errors.new({message = "permission denied", kind = errors.PERMISSION_DENIED})
local MISSING = errors.new({message = "environment variable not found", kind = errors.NOT_FOUND})

local function define_tests()
    test.describe("reading the environment", function()
        test.it("a permission denial is called a denial, not 'not set'", function()
            local value, source, denied = environment.read("X", fake({}, nil, DENIED))
            test.is_nil(value)
            test.eq(source, environment.DENIED)
            test.is_true(denied == true)

            local fallback, why, refused = environment.read_or("X", "app:db", fake({}, nil, DENIED))
            test.eq(fallback, "app:db", "the default is substituted")
            test.eq(why, environment.DENIED, "but the reason remains a denial")
            test.is_true(refused == true)
        end)

        test.it("a missing variable is 'not set' and is not called a denial", function()
            local value, source, denied = environment.read("X", fake({}, nil, MISSING))
            test.is_nil(value)
            test.eq(source, "not set")
            test.is_true(denied == false)

            local fallback, why, refused = environment.read_or("X", "app:db", fake({}, nil, MISSING))
            test.eq(fallback, "app:db")
            test.eq(why, "not set")
            test.is_true(refused == false)
        end)

        test.it("the process environment outranks the store, an empty string is not a value", function()
            local value, source, denied = environment.read("X", fake({X = "app:other"}, nil, DENIED))
            test.eq(value, "app:other", "a non-empty get_all proves the permission")
            test.eq(source, "process environment")
            test.is_true(denied == false)

            value, source = environment.read("X", fake({}, "app:stored", nil))
            test.eq(value, "app:stored")
            test.eq(source, "file store")

            value, source = environment.read("X", fake({X = ""}, "", nil))
            test.is_nil(value)
            test.eq(source, "not set")

            local kept = environment.read_or("X", "app:db", fake({}, "app:stored", nil))
            test.eq(kept, "app:stored", "a named value is not replaced by the default")
        end)

        test.it("reads the error kind, not its text", function()
            -- The text changes, the kind is declared as a constant: the string
            -- "permission denied" without a kind is not proof of a denial.
            local _, source, denied = environment.read("X", fake({}, nil, "permission denied"))
            test.eq(source, "not set")
            test.is_true(denied == false)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
