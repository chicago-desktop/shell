-- Диспетчер задач: модель проверяется прямо — график, история, форматы,
-- раскладка и попадания по вкладкам.

local test = require("test")
local model = require("model")

local function define_tests()
    test.describe("история и график", function()
        test.it("держит историю не длиннее потолка, старое уходит первым", function()
            local history = {}
            for value = 1, 10 do history = model.push(history, value, 4) end
            test.eq(#history, 4)
            test.eq(history[1], 7)
            test.eq(history[4], 10)
        end)

        test.it("рисует столбцы снизу вверх, последнее измерение справа", function()
            local rows, top = model.graph({0, 4, 8}, 3, 1, 8)
            test.eq(top, 8)
            test.eq(#rows, 1)
            test.eq(rows[1], " ▄█")
        end)

        test.it("делит высокий столбец на строки: полные снизу, дробная сверху", function()
            local rows = model.graph({12}, 1, 2, 16)
            -- 12 из 16 при двух строках по 8: нижняя полная, верхняя наполовину.
            test.eq(rows[2], "█")
            test.eq(rows[1], "▄")
        end)

        test.it("недостающие измерения слева — пустота, а не ноль", function()
            local rows = model.graph({5}, 4, 1, 5)
            test.eq(rows[1], "   █")
        end)

        test.it("потолок круглый и не ниже максимума", function()
            test.eq(model.round_ceiling(7), 10)
            test.eq(model.round_ceiling(23), 25)
            test.eq(model.round_ceiling(100), 100)
            test.eq(model.round_ceiling(493), 500)
            test.eq(model.round_ceiling(1673), 2000)
            test.eq(model.round_ceiling(0), 0)
            local _, top = model.graph({0, 0}, 2, 1)
            test.eq(top, 1)
        end)
    end)

    test.describe("форматы", function()
        test.it("память в мегабайтах, время работы часами", function()
            test.eq(model.megabytes(670 * 1024 * 1024), "670 МБ")
            test.eq(model.megabytes(512 * 1024), "0.5 МБ")
            test.eq(model.uptime(8 * 60 + 21), "0:08:21")
            test.eq(model.uptime(3 * 86400 + 4 * 3600 + 15 * 60 + 2), "3 д 04:15:02")
        end)

        test.it("секунды из числа любой размерности", function()
            local now = 1788850000
            test.eq(model.epoch_seconds(now), now)
            test.eq(math.floor(model.epoch_seconds(now * 1000)), now)
            test.eq(math.floor(model.epoch_seconds(now * 1e9)), now)
        end)

        test.it("процессы отсортированы устойчиво, по записи и pid", function()
            local rows = model.processes({
                {pid = "b", source = "app:z", state = "running", steps = 5, started_at = 1788850000},
                {pid = "a", source = "app:a", state = "waiting", steps = 9, started_at = 1788849000},
                {pid = "c", source = "app:a", state = "waiting", steps = 1, started_at = 1788849500},
            })
            test.eq(rows[1].pid, "a")
            test.eq(rows[2].pid, "c")
            test.eq(rows[3].source, "app:z")
            test.eq(model.oldest_start(rows), 1788849000)
        end)
    end)

    test.describe("раскладка", function()
        test.it("вкладки над статусной строкой, страница внутри рамки", function()
            local plan = model.layout(72, 24)
            test.eq(plan.status_row, 24)
            test.eq(plan.tabs.h, 23)
            test.eq(plan.page.x, 3)
            test.eq(plan.page.w, 68)
        end)

        test.it("на быстродействии четыре ящика не выходят за страницу", function()
            local plan = model.layout(72, 24)
            local perf = plan.perf
            test.is_true(perf ~= nil)
            test.eq(perf.graph_a.x + perf.graph_a.w - 1, plan.page.x + plan.page.w - 1)
            test.eq(perf.right.x + perf.right.w - 1, plan.page.x + plan.page.w - 1)
            test.eq(perf.right.y + perf.right.h - 1, plan.page.y + plan.page.h - 1)
        end)

        test.it("в маленьком окне графиков нет, а не графики в никуда", function()
            test.is_nil(model.layout(30, 10).perf)
        end)

        test.it("щелчок попадает в ту вкладку, что нарисована", function()
            local hits = {{row = 1, from = 1, to = 14, index = 1}, {row = 1, from = 15, to = 26, index = 2}}
            test.eq(model.tab_at(hits, 15, 1), 2)
            test.eq(model.tab_at(hits, 14, 1), 1)
            test.is_nil(model.tab_at(hits, 5, 2))
        end)
    end)
end

-- Форма раннера — как у shell_test. `return {run = run}` с describe внутри
-- run считался и был зелёным, НЕ выполняя ни одной проверки: мутация
-- round_ceiling(7) == 999 проходила. Проверка, которую никто не запускает,
-- хуже отсутствующей — на неё ссылаются.
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
