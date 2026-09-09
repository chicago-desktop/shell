-- `reveal` у списка: подводит к строке один раз на значение и не спорит с
-- колесом человека, пока значение не изменилось.
local test = require("test")
local ui = require("ui")

local function items(count: any): any
    local out = {}
    for index = 1, count do out[index] = "строка " .. index end
    return out
end

local function define_tests()
    test.describe("SDK list reveal", function()
        test.it("показывает названную строку и не сбивает прокрутку, пока значение прежнее", function()
            local interaction = ui.interaction()
            local plan = ui.plan({kind = "list", id = "log", items = items(50), reveal = 50}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, 40)
            -- Человек крутит вверх.
            ui.event(plan, interaction, {type = "mouse", action = "wheel", button = "wheel_up", x = 2, y = 2})
            local before = interaction.offsets["log"]
            test.is_true(before < 40, "колесо не сдвинуло список")
            -- Тот же reveal — прокрутка человека остаётся.
            plan = ui.plan({kind = "list", id = "log", items = items(50), reveal = 50}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, before)
            -- Новое значение — снова вниз.
            plan = ui.plan({kind = "list", id = "log", items = items(52), reveal = 52}, 40, 10, interaction)
            test.eq(plan.by_id["log"].offset, 42)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
