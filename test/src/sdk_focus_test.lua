-- A window that loses the keyboard drops what it held.
--
-- The compositor sends `{type = "focus", focused = false}` when another window
-- takes the keyboard or this one is minimized (the base's library.lua). The
-- SDK then releases an armed button and a captured drag: the release they wait
-- for goes elsewhere now, and a release arriving later must not activate a
-- button pressed before the window lost focus (sdk-review A11).
local test = require("test")
local app = require("app")
local ui = require("ui")

local function tree(): any
    return {kind = "column", padding = 1, gap = 0, children = {
        {kind = "label", size = 1, text = "Save the changes?"},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "ok", size = 10, text = "OK", default = true},
        }},
    }}
end

local function press_and_release(lose_focus: boolean): any
    local interaction = ui.interaction()
    local plan = ui.plan(tree(), 40, 6, interaction)
    local rect: any = plan.by_id.ok.rect
    ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = rect.x, y = rect.y})
    local armed = interaction.armed ~= nil
    local redraw = nil
    if lose_focus then redraw = app.focus(interaction, {type = "focus", focused = false}) end
    local action = ui.event(plan, interaction, {type = "mouse", action = "release", button = "left", x = rect.x, y = rect.y})
    return {armed = armed, redraw = redraw, action = action, left = interaction.armed}
end

local function define_tests()
    test.describe("Window SDK focus", function()
        test.it("a release after the window lost the keyboard does not press the button", function()
            local kept = press_and_release(false)
            test.is_true(kept.armed, "a left press arms the button")
            test.not_nil(kept.action, "control: without a focus change the release activates")
            test.eq(kept.action.type, "activate")

            local lost = press_and_release(true)
            test.is_true(lost.armed, "the press armed it the same way")
            test.is_true(lost.redraw == true, "something was held, so the frame changes")
            test.is_nil(lost.left, "focus loss released the armed button")
            test.is_nil(lost.action, "the later release activates nothing")
        end)

        test.it("drops a captured drag too, and redraws only when something was held", function()
            local interaction = ui.interaction()
            interaction.capture = {id = "list", kind = "scroll"}
            test.is_true(app.focus(interaction, {type = "focus", focused = false}))
            test.is_nil(interaction.capture, "a scrollbar drag ends with the keyboard")
            test.is_true(app.focus(interaction, {type = "focus", focused = false}) == false,
                "nothing held any more: no frame for nothing")
        end)

        test.it("gaining the keyboard and other events leave the interaction alone", function()
            local interaction = ui.interaction()
            interaction.armed = {id = "ok", inside = true}
            test.is_true(app.focus(interaction, {type = "focus", focused = true}) == false)
            test.not_nil(interaction.armed, "gaining focus releases nothing")
            test.is_true(app.focus(interaction, {type = "key", key = "a"}) == false)
            test.not_nil(interaction.armed, "a key is not a focus change")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
