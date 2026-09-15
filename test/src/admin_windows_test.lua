-- The windows that change the system open only for an administrator.
--
-- Each runs under its entry's own broad policy — ending any process, running
-- builds on the server, editing the application's dependencies, reading the
-- whole registry — whoever logged on. Under a terminal.ssh host anyone with
-- an account logs on, so each entry names `meta.requires`, and the base's
-- compositor asks the logged-on person's scope before opening it (the base's
-- desktop_requires_test checks the asking). What is checked here is that the
-- entries name it: an entry without the field opens for everyone, silently.
local test = require("test")
local registry = require("registry")

local ADMIN_ONLY = {
    "butschster.windows.taskman:window",
    "butschster.windows.antibug:window",
    "butschster.windows.appwiz:window",
    "butschster.windows.regedit:window",
}

local function define_tests()
    test.describe("butschster.windows administrator windows", function()
        test.it("Task Manager, AntiBug, Add/Remove Programs and the Registry Editor require windows.admin", function()
            for _, id in ipairs(ADMIN_ONLY) do
                local entry, err = registry.get(id)
                test.is_nil(err, id .. ": " .. tostring(err))
                local record: any = entry
                local meta: any = record and type(record.meta) == "table" and record.meta or {}
                test.eq(meta.requires, "windows.admin", id .. " must name windows.admin in meta.requires")
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
