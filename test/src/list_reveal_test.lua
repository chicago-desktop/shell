-- `reveal` on a list: brings a row into view once per value and does not fight
-- the person's wheel as long as the value has not changed.
local test = require("test")
local ui = require("ui")

local function items(count: any): any
    local out = {}
    for index = 1, count do out[index] = "row " .. index end
    return out
end

local function define_tests()
    test.describe("SDK list reveal", function()
        test.it("shows the named row and does not knock the scroll off while the value stays the same", function()
            local interaction = ui.interaction()
            local plan = ui.plan({kind = "list", id = "log", items = items(50), reveal = 50}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, 40)
            -- The person scrolls up.
            ui.event(plan, interaction, {type = "mouse", action = "wheel", button = "wheel_up", x = 2, y = 2})
            local before = interaction.offsets["log"]
            test.is_true(before < 40, "the wheel did not move the list")
            -- The same reveal: the person's scrolling stays.
            plan = ui.plan({kind = "list", id = "log", items = items(50), reveal = 50}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, before)
            -- A new value: down again.
            plan = ui.plan({kind = "list", id = "log", items = items(52), reveal = 52}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, 42)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
