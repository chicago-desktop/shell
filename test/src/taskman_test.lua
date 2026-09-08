-- Диспетчер задач: модель проверяется прямо — график, история, форматы,
-- раскладка и попадания по вкладкам.

local test = require("test")
local model = require("model")

local function run()
    test.describe("история и график", function()
        test.it("держит историю не длиннее потолка, старое уходит первым", function()
            local history = {}
            for value = 1, 10 do history = model.push(history, value, 4) end
            test.expect(#history).to_equal(4)
            test.expect(history[1]).to_equal(7)
            test.expect(history[4]).to_equal(10)
        end)

        test.it("рисует столбцы снизу вверх, последнее измерение справа", function()
            local rows, top = model.graph({0, 4, 8}, 3, 1, 8)
            test.expect(top).to_equal(8)
            test.expect(#rows).to_equal(1)
            test.expect(rows[1]).to_equal(" ▄█")
        end)

        test.it("делит высокий столбец на строки: полные снизу, дробная сверху", function()
            local rows = model.graph({12}, 1, 2, 16)
            -- 12 из 16 при двух строках по 8: нижняя полная, верхняя наполовину.
            test.expect(rows[2]).to_equal("█")
            test.expect(rows[1]).to_equal("▄")
        end)

        test.it("недостающие измерения слева — пустота, а не ноль", function()
            local rows = model.graph({5}, 4, 1, 5)
            test.expect(rows[1]).to_equal("   █")
        end)

        test.it("потолок круглый и не ниже максимума", function()
            test.expect(model.round_ceiling(7)).to_equal(10)
            test.expect(model.round_ceiling(23)).to_equal(25)
            test.expect(model.round_ceiling(100)).to_equal(100)
            test.expect(model.round_ceiling(0)).to_equal(0)
            local _, top = model.graph({0, 0}, 2, 1)
            test.expect(top).to_equal(1)
        end)
    end)

    test.describe("форматы", function()
        test.it("память в мегабайтах, время работы часами", function()
            test.expect(model.megabytes(670 * 1024 * 1024)).to_equal("670 МБ")
            test.expect(model.megabytes(512 * 1024)).to_equal("0.5 МБ")
            test.expect(model.uptime(8 * 60 + 21)).to_equal("0:08:21")
            test.expect(model.uptime(3 * 86400 + 4 * 3600 + 15 * 60 + 2)).to_equal("3 д 04:15:02")
        end)

        test.it("секунды из числа любой размерности", function()
            local now = 1788850000
            test.expect(model.epoch_seconds(now)).to_equal(now)
            test.expect(math.floor(model.epoch_seconds(now * 1000))).to_equal(now)
            test.expect(math.floor(model.epoch_seconds(now * 1e9))).to_equal(now)
        end)

        test.it("процессы отсортированы устойчиво, по записи и pid", function()
            local rows = model.processes({
                {pid = "b", source = "app:z", state = "running", steps = 5, started_at = 1788850000},
                {pid = "a", source = "app:a", state = "waiting", steps = 9, started_at = 1788849000},
                {pid = "c", source = "app:a", state = "waiting", steps = 1, started_at = 1788849500},
            })
            test.expect(rows[1].pid).to_equal("a")
            test.expect(rows[2].pid).to_equal("c")
            test.expect(rows[3].source).to_equal("app:z")
            test.expect(model.oldest_start(rows)).to_equal(1788849000)
        end)
    end)

    test.describe("раскладка", function()
        test.it("вкладки над статусной строкой, страница внутри рамки", function()
            local plan = model.layout(72, 24)
            test.expect(plan.status_row).to_equal(24)
            test.expect(plan.tabs.h).to_equal(23)
            test.expect(plan.page.x).to_equal(3)
            test.expect(plan.page.w).to_equal(68)
        end)

        test.it("на быстродействии четыре ящика не выходят за страницу", function()
            local plan = model.layout(72, 24)
            local perf = plan.perf
            test.expect(perf ~= nil).to_be_true()
            test.expect(perf.graph_a.x + perf.graph_a.w - 1).to_equal(plan.page.x + plan.page.w - 1)
            test.expect(perf.right.x + perf.right.w - 1).to_equal(plan.page.x + plan.page.w - 1)
            test.expect(perf.right.y + perf.right.h - 1).to_equal(plan.page.y + plan.page.h - 1)
        end)

        test.it("в маленьком окне графиков нет, а не графики в никуда", function()
            test.expect(model.layout(30, 10).perf).to_be_nil()
        end)

        test.it("щелчок попадает в ту вкладку, что нарисована", function()
            local hits = {{row = 1, from = 1, to = 14, index = 1}, {row = 1, from = 15, to = 26, index = 2}}
            test.expect(model.tab_at(hits, 15, 1)).to_equal(2)
            test.expect(model.tab_at(hits, 14, 1)).to_equal(1)
            test.expect(model.tab_at(hits, 5, 2)).to_be_nil()
        end)
    end)
end

return {run = run}
