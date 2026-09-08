-- «Свойства: Система»: дерево устройств собирается по префиксу вида,
-- пустые группы остаются с пометкой, раскладка трёх вкладок без пересечений,
-- дерево раскрывается и выбирается, «ОК» закрывает.
local test = require("test")
local model = require("model")
local ui = require("ui")
local sysprops = require("sysprops_window")

local function fixture(tab: any): any
    local snap: any = {hostname = "stand", pid = "42", cwd = "/srv/app", node_id = "node-1", node_role = "leader",
        goroutines = 428, cpu_count = 8, max_procs = 8,
        memory = {alloc = 100 * 1024 * 1024, heap_in_use = 200 * 1024 * 1024, heap_sys = 300 * 1024 * 1024,
            heap_released = 10 * 1024 * 1024, num_gc = 5, sys = 320 * 1024 * 1024},
        hosts = {{id = "app:processes", workers = 4, processes = 64, executed = 1000}},
        modules = {{name = "gfx", description = "пиксели"}, {name = "tty", description = "терминал"}}}
    local records = {
        {id = "app:db", kind = "db.sql.sqlite"}, {id = "app:fs", kind = "fs.directory"},
        {id = "app:api", kind = "http.service"}, {id = "app:router", kind = "http.router"},
        {id = "app:cron", kind = "cron.schedule"},
    }
    local tree = model.tree(snap, records)
    return {tab = tab, snapshot = snap, records = records, tree = tree, expanded = model.expanded_all(tree), selected = nil}
end

local function define_tests()
    test.describe("System Properties model", function()
        test.it("раскладывает записи реестра по префиксу вида, пустые группы помечает", function()
            local state = fixture(2)
            local rows = model.flatten(state.tree, state.expanded)
            local labels = {}
            for _, row in ipairs(rows) do labels[#labels + 1] = tostring(row.label) end
            test.eq(labels[1], "stand")
            test.eq(labels[2], "Хосты процессов (1)")
            test.eq(labels[3], "app:processes")
            test.eq(labels[4], "Файловые системы (1)")
            test.eq(labels[6], "Базы данных (1)")
            test.eq(labels[8], "HTTP (2)")
            test.eq(labels[11], "Терминалы (нет)")
            test.eq(labels[12], "Модули Lua (2)")
            test.eq(#rows, 14, "cron не попадает ни в одну группу и не теряет соседей")
            test.eq(rows[3].depth, 2)
            test.is_true(rows[3].detail:find("рабочих 4", 1, true) ~= nil)
            -- Свёрнутая группа прячет детей, но остаётся сама.
            state.expanded.http = nil
            local folded = model.flatten(state.tree, state.expanded)
            test.eq(#folded, 12)
        end)
    end)
    test.describe("System Properties on the SDK", function()
        test.it("раскладывает три вкладки без пересечений и держит кнопки", function()
            for tab = 1, 3 do
                for _, dims in ipairs({{58, 22}, {50, 18}}) do
                    local plan = ui.plan(sysprops.definition.view(fixture(tab), {width = dims[1], height = dims[2]}), dims[1], dims[2], ui.interaction())
                    test.not_nil(plan.by_id.pages)
                    test.not_nil(plan.by_id.ok)
                    test.not_nil(plan.by_id.cancel)
                    for index, item in ipairs(plan.items) do
                        test.is_true(item.rect.x + item.rect.w <= dims[1] + 1)
                        test.is_true(item.rect.y + item.rect.h <= dims[2] + 1)
                        if item.node.kind ~= "group" then
                            for other = index + 1, #plan.items do
                                local b = plan.items[other]
                                if b.node.kind ~= "group" then
                                    local r = item.rect
                                    test.is_true(r.x + r.w <= b.rect.x or b.rect.x + b.rect.w <= r.x
                                        or r.y + r.h <= b.rect.y or b.rect.y + b.rect.h <= r.y,
                                        "пересечение " .. tostring(item.node.kind) .. "/" .. tostring(b.node.kind) .. " на вкладке " .. tab)
                                end
                            end
                        end
                    end
                end
            end
            local plan = ui.plan(sysprops.definition.view(fixture(2), {width = 58, height = 22}), 58, 22, ui.interaction())
            test.is_true(#plan.by_id.devices.node.rows >= 12)
        end)
        test.it("дерево раскрывается и выбирается, ОК закрывает", function()
            local state = fixture(2)
            local closed = 0
            local context = {width = 58, height = 22, close = function() closed = closed + 1 end}
            local rows = model.flatten(state.tree, state.expanded)
            sysprops.definition.update(state, {type = "toggle", id = "devices", index = 2, value = rows[2]}, context)
            test.is_true(not state.expanded.hosts, "группа свёрнута")
            sysprops.definition.update(state, {type = "select", id = "devices", index = 3, value = rows[3]}, context)
            test.eq(state.selected, "host:app:processes")
            local plan = ui.plan(sysprops.definition.view(state, context), 58, 22, ui.interaction())
            test.eq(plan.by_id.devices.node.selected, "host:app:processes")
            sysprops.definition.update(state, {type = "select", id = "pages", index = 3}, context)
            test.eq(state.tab, 3)
            test.eq(sysprops.definition.update(state, {type = "key", key_type = "runes", key = "x"}, context), false)
            sysprops.definition.update(state, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
