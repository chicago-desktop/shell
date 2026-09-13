-- The desktop widget kit (FR-006 §8): every builder gives a plain, passive
-- tree that `ui.plan` lays out, at the rows the kit promises; the weather and
-- the monitor widgets composed from it lay out inside a widget's panel
-- without a single overlap, in cells and at two pixel cells.
local test = require("test")
local gadget = require("gadget")
local gadgets = require("gadgets")
local ui = require("ui")
local charts = require("charts")

-- impurity(value, path) -> nil | where a value that is not plain data sits.
-- A tree crosses a process boundary (`desktop.state`): tables, strings,
-- numbers and booleans only.
local function impurity(value: any, path: string): any
    local kind = type(value)
    if kind == "table" then
        for key, item in pairs(value) do
            local found = impurity(item, path .. "." .. tostring(key))
            if found then return found end
        end
        return nil
    end
    if kind == "string" or kind == "number" or kind == "boolean" then return nil end
    return path .. " is a " .. kind
end

-- ids(tree) -> every `id` in the tree: a widget's tree is passive and names none.
local function ids(tree: any, out: any): any
    local found: any = out or {}
    if type(tree) ~= "table" then return found end
    if tree.id ~= nil then found[#found + 1] = tostring(tree.id) end
    for _, child in ipairs(type(tree.children) == "table" and tree.children or {}) do ids(child, found) end
    return found
end

-- overlap(plan) -> nil | the kinds of the first two items drawn over each
-- other. A group holds its children inside its frame and is left out, as in
-- taskman_test.
local function overlap(plan: any): any
    for index, item in ipairs(plan.items) do
        if item.node.kind ~= "group" then
            for other = index + 1, #plan.items do
                local b = plan.items[other]
                if b.node.kind ~= "group" then
                    local r = item.rect
                    if not (r.x + r.w <= b.rect.x or b.rect.x + b.rect.w <= r.x
                        or r.y + r.h <= b.rect.y or b.rect.y + b.rect.h <= r.y) then
                        return tostring(item.node.kind) .. "/" .. tostring(b.node.kind)
                    end
                end
            end
        end
    end
    return nil
end

local function kinds(plan: any): string
    local out = {}
    for _, item in ipairs(plan.items) do out[#out + 1] = tostring(item.node.kind) end
    return table.concat(out, ",")
end

local function weather(): any
    return gadget.stack{
        gadget.stat{caption = "Feels like +19", value = "+21", unit = " °C", image = "clock", icon = "☼"},
        gadget.lines{lines = {"Samara", "Partly cloudy"}},
    }
end

local function monitor(): any
    local values = {}
    for index = 1, 60 do values[index] = 250 + index end
    return gadget.stack{
        gadget.meter{caption = "Heap", value = 312, ceiling = 500, unit = " MB"},
        gadget.history{caption = "Heap in use", values = values, unit = " MB"},
    }
end

local function define_tests()
    test.describe("butschster.windows.sdk gadget kit", function()
        test.it("every builder gives a plain, passive tree ui.problem accepts", function()
            local built: any = {
                stat = gadget.stat{caption = "Heap", value = 38, unit = " MB"},
                stat_image = gadget.stat{caption = "Samara", value = "+21", unit = " °C", image = "clock", icon = "☼"},
                meter = gadget.meter{caption = "Heap", value = 312, ceiling = 500, unit = " MB"},
                history = gadget.history{caption = "Heap in use", values = {1, 2, 3}},
                lines = gadget.lines{lines = {"Samara", "Partly cloudy"}},
                empty = gadget.stack{},
            }
            built.stack = gadget.stack{built.stat, built.meter, built.history, built.lines}
            for name, tree in pairs(built) do
                test.is_nil(ui.problem(tree), name .. ": " .. tostring(ui.problem(tree)))
                test.is_nil(impurity(tree, name), name)
                test.eq(#ids(tree), 0, name .. ": a passive tree names no id")
            end
        end)

        test.it("takes the rows the kit promises, and a history takes the rest of a stack", function()
            test.eq(gadget.stat{caption = "Heap", value = 1}.size, 3)
            test.eq(gadget.meter{caption = "Heap", value = 1, ceiling = 2}.size, 2)
            test.is_nil(gadget.history{values = {}}.size, "a history takes what the stack leaves")
            local many = gadget.lines{lines = {"1", "2", "3", "4", "5", "6"}}
            test.eq(many.size, gadget.MAX_LINES)
            test.eq(#many.children, 4)
            -- A stat, then a history in the rest: at 18×7 the history has four
            -- rows, its caption one and its graph three.
            local plan = ui.plan(gadget.stack{gadget.stat{caption = "Now", value = 428},
                gadget.history{caption = "History", values = {1, 2}}}, 18, 7, ui.interaction())
            local graph: any = nil
            for _, item in ipairs(plan.items) do if item.node.kind == "graph" then graph = item end end
            test.not_nil(graph)
            test.eq(tostring(graph.rect.y) .. ":" .. tostring(graph.rect.h), "5:3", "the graph under its caption, below the stat")
        end)

        test.it("scales a history to charts.ceiling_of when no ceiling is named, and keeps one that is", function()
            local values = {120, 312, 280}
            local graph = gadget.history{values = values, unit = " MB"}.children[1]
            test.eq(graph.kind, "graph")
            test.eq(graph.ceiling, charts.ceiling_of(values))
            test.eq(graph.ceiling, 500)
            test.eq(graph.unit, " MB")
            test.eq(gadget.history{values = values, ceiling = 800}.children[1].ceiling, 800)
            local titled = gadget.history{caption = "Heap", values = values}
            test.eq(titled.children[1].text, "Heap")
            test.eq(titled.children[2].kind, "graph")
        end)

        test.it("writes a value as text: a whole number bare, a fraction to one place, the unit as given", function()
            test.eq(gadget.amount(38), "38")
            test.eq(gadget.amount(38.0), "38")
            test.eq(gadget.amount(37.5), "37.5")
            test.eq(gadget.amount(312, " MB"), "312 MB")
            test.eq(gadget.amount("+21", " °C"), "+21 °C")
            test.eq(gadget.amount(nil), "")
        end)

        test.it("puts a stat's picture on its left in four columns, and leaves it out without one", function()
            local pictured = gadget.stat{caption = "Samara", value = "+21", image = "clock", icon = "☼"}
            test.eq(pictured.children[1].kind, "image")
            test.eq(pictured.children[1].size, 4)
            test.eq(pictured.children[1].image, "clock")
            test.eq(pictured.children[1].icon, "☼")
            test.eq(pictured.children[2].children[1].text, "+21")
            test.eq(pictured.children[2].children[2].text, "Samara")
            test.is_true(pictured.children[2].children[2].disabled == true, "the caption is dimmed")
            local bare = gadget.stat{caption = "Heap", value = 38}
            test.eq(#bare.children, 1)
            test.eq(bare.children[1].kind, "column")
        end)

        test.it("lays a meter out as the caption, the gauge and the value on one line", function()
            local plan = ui.plan(gadget.meter{caption = "Heap", value = 312, ceiling = 500, unit = " MB"}, 18, 2, ui.interaction())
            local order = {}
            for _, item in ipairs(plan.items) do
                order[#order + 1] = tostring(item.node.kind) .. "@" .. tostring(item.rect.x) .. "+" .. tostring(item.rect.w)
            end
            test.eq(table.concat(order, " "), "label@1+5 gauge@7+4 label@12+7")
            test.eq(plan.items[2].node.value, 312)
            test.eq(plan.items[2].node.ceiling, 500)
            test.eq(plan.items[2].node.caption, "", "the gauge draws no text of its own: the value stands beside it")
            test.eq(plan.items[3].node.text, "312 MB")
        end)

        test.it("lays the weather and the monitor out inside a widget's panel without overlaps, at 20×6 and 20×8", function()
            for _, case in ipairs({{"weather", weather()}, {"monitor", monitor()}}) do
                local name: string, tree: any = case[1], case[2]
                for _, h in ipairs({6, 8}) do
                    for _, cell in ipairs({false, {w = 10, h = 20}, {w = 8, h = 16}}) do
                        local where = name .. " 20x" .. h .. (cell and (" @" .. cell.w .. "x" .. cell.h) or " cells")
                        local framed, problem = gadgets.framed({content_state = {sdk = 1, ui = tree}})
                        test.is_nil(problem, where)
                        local plan = ui.plan(framed, 20, h, ui.interaction(), cell and {cell = cell} or nil)
                        for _, item in ipairs(plan.items) do
                            local r = item.rect
                            test.is_true(r.x >= 2 and r.y >= 2 and r.x + r.w <= 20 and r.y + r.h <= h,
                                where .. ": " .. tostring(item.node.kind) .. " outside the body")
                        end
                        test.is_nil(overlap(plan), where)
                        local seen = kinds(plan)
                        local expected = name == "weather" and "image,label,label,label" or "label,gauge,label,label,graph"
                        test.is_true(seen:find(expected, 1, true) == 1, where .. ": " .. seen)
                    end
                end
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
