-- Reading the environment — one per module.
--
-- Three different things, and all of them look like "the variable is not
-- there".
--
-- THE FIRST. `env.get` sees ONLY the file store. For a variable from the
-- process environment it answers "environment variable not found" — that is,
-- `WINDOWS_PIXELS=1 wippy run …` does not work without `get_all`.
-- The process environment is returned by `env.get_all`.
--
-- THE SECOND, and it is quieter. A declared module without a granted
-- permission looks like a module that has nothing to say: `get_all` puts only
-- permitted keys into the table and does not complain about the denial at
-- all. An empty answer here is indistinguishable from "there are no
-- variables". Only `env.get` tells them apart: on a permission denial it
-- answers with an error of kind `PermissionDenied`.
--
-- THE THIRD, found while merging four copies into one (2026-09-11). A runtime
-- error is not a table but userdata with methods: the kind is read with
-- `err:kind()`. All the copies that distinguished the denial checked
-- `type(err) == "table" and err.kind == …` — a condition a real error never
-- satisfies, so a permission denial was called "not set" everywhere. That is
-- why the test builds the error with the same `errors.new` as the runtime,
-- not with a table with a field.
--
-- A permission denial must be called a permission denial: it is the only
-- reason a person CANNOT fix by setting the variable.

local env = require("env")
local logger = require("logger")

local environment = {}

environment.DENIED = "NO env.get PERMISSION — a policy denial, not a missing variable"
environment.NOT_SET = "not set"

-- The error kind, not its text: the text changes, the kind is declared as a
-- constant. A string or a table instead of a runtime error has no kind and
-- does not get as far as `pcall`: an error caught by `pcall` in go-lua tears
-- the upvalues of the whole stack below it (sdk_test, "go-lua: an error under
-- pcall…"), and this is called from the shell's `main`.
local function kind_of(err: any): any
    if type(err) ~= "userdata" then return nil end
    local ok, kind = pcall(function() return err:kind() end)
    if ok then return kind end
    return nil
end

-- read(name, from?) -> value | nil, where from or why not, permission denial
--
-- The second value is "process environment" or "file store" when there is a
-- value, and NOT_SET or DENIED when there is not. The third is true exactly
-- on a permission denial: the caller does not need to compare strings.
-- `from` is a stand-in env with the same `get_all` and `get`, for tests.
function environment.read(name: string, from: any?): (any, string, boolean)
    local store: any = from or env
    -- Emptiness of `get_all` proves nothing, but its non-emptiness does.
    local all = store.get_all()
    if type(all) == "table" then
        local value: any = all[name]
        if type(value) == "string" and value ~= "" then return value, "process environment", false end
    end
    local stored, err = store.get(name)
    if type(stored) == "string" and stored ~= "" then return stored, "file store", false end
    if kind_of(err) == "PermissionDenied" then return nil, environment.DENIED, true end
    return nil, environment.NOT_SET, false
end

-- read_or(name, default, from?) -> value or default, where from or why not, permission denial
--
-- The default is substituted, but the permission denial is not swallowed: it
-- is named in the log. `read(...) or "app:db"` turned a denial into "the
-- person did not override anything", and an application that asked to keep
-- the layout in another database silently kept it in the default.
function environment.read_or(name: string, default: string, from: any?): (string, string, boolean)
    local value, source, denied = environment.read(name, from)
    if value ~= nil then return tostring(value), source, false end
    if denied then
        logger:named("windows.environment"):warn("policy denies env.get for " .. name .. ", using default",
            {name = name, default = tostring(default)})
    end
    return default, source, denied
end

return environment
