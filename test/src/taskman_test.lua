-- Диспетчер задач: модель проверяется прямо — график, история, форматы,
-- раскладка и попадания по вкладкам.

local test = require("test")
local model = require("model")
local ui = require("ui")
local taskman = require("taskman_window")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local function receive(stream, predicate)
    local deadline = time.after("8s")
    while true do
        local picked = channel.select({stream:case_receive(), deadline:case_receive()})
        test.is_true(picked.channel ~= deadline and picked.ok, "Task Manager did not reach expected state")
        local value: any = picked.value:payload()
        if type(value) == "userdata" then value = value:data() end
        if type(value) == "table" and value[1] then value = value[1] end
        if predicate(value) then return value end
    end
end


local function define_tests()

    test.describe("Task Manager on the SDK", function()
        local function fixture(tab: any): any
            local state: any = {tab = tab, selected_id = nil, heap_history = {}, goroutine_history = {},
                windows = {{id = "one", title = "Bash", image = "program", ready = true},
                    {id = "two", title = "Блокнот", image = "text_document", ready = true, minimized = true}},
                snapshot = {taken = 1788858300, goroutines = 428, cpu_count = 8, max_procs = 8, pid = "1", hostname = "host",
                    memory = {alloc = 100, heap_in_use = 200, heap_sys = 300, heap_released = 10, num_gc = 5},
                    processes = {}, hosts = {{id = "app:processes", workers = 4, processes = 64, executed = 1000}}}}
            for index = 1, 80 do
                state.snapshot.processes[index] = {pid = "p" .. index, source = "app:w" .. index, state = "waiting", steps = index, started = 1788850100}
            end
            for index = 1, 50 do
                state.goroutine_history[index] = 400 + index
                state.heap_history[index] = (200 + index) * 1024 * 1024
            end
            return state
        end
        test.it("lays out tabs, tables, groups and the refresh button without overlaps at several sizes", function()
            for tab = 1, 4 do
                for _, dims in ipairs({{76, 25}, {58, 22}, {40, 16}}) do
                    local plan = ui.plan(taskman.definition.view(fixture(tab), {width = dims[1], height = dims[2]}), dims[1], dims[2], ui.interaction())
                    test.not_nil(plan.by_id.pages)
                    test.not_nil(plan.by_id.refresh)
                    for index, item in ipairs(plan.items) do
                        test.is_true(item.rect.x >= 1 and item.rect.y >= 1)
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
            local plan = ui.plan(taskman.definition.view(fixture(2), {width = 76, height = 25}), 76, 25, ui.interaction())
            test.eq(#plan.by_id.procs.node.rows, 80)
            test.eq(plan.by_id.procs.node.columns[4].align, "right")
        end)
        test.it("keeps the selected task by id when sampling reorders rows and switches tabs", function()
            local state = fixture(2)
            local context = {width = 76, height = 25, close = function() end}
            taskman.definition.update(state, {type = "select", id = "procs", index = 80, value = {id = "p80"}}, context)
            test.eq(state.selected_id, "p80")
            table.remove(state.snapshot.processes, 1)
            local plan = ui.plan(taskman.definition.view(state, context), 76, 25, ui.interaction())
            test.eq(plan.by_id.procs.node.selected, 79, "после сдвига строк выделен тот же процесс")
            state.snapshot.processes = {{pid = "new", source = "x", state = "waiting", steps = 1}}
            plan = ui.plan(taskman.definition.view(state, context), 76, 25, ui.interaction())
            test.eq(plan.by_id.procs.node.selected, 0, "исчезнувший процесс не выделяет чужую строку")
            test.eq(taskman.definition.update(state, {type = "key", key_type = "runes", key = "x"}, context), false, "чужая клавиша не перерисовывает")
        end)
        test.it("opens the real native window, handles tabs and refresh, and keeps sampling", function()
            local replies = process.listen("desktop.reply", {message = true})
            local frames = process.listen("taskman.frame", {message = true})
            local service = "butschster.windows.test.taskman"
            local view = assert(tty.viewport({width = 110, height = 36}))
            local pid = assert(process.with_options({terminal = assert(view:grant())})
                :spawn_monitored("app:taskman_composer", "app:processes", service, tostring(process.pid())))
            local deadline = time.now():unix_nano() + 5000000000
            while not process.registry.lookup(service) and time.now():unix_nano() < deadline do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.not_nil(process.registry.lookup(service))
            assert(process.send(service, "desktop.open", {entry = "butschster.windows.taskman:window", reply_to = tostring(process.pid())}))
            local opened = receive(replies, function(value) return value.command == "desktop.open" end)
            test.is_true(opened.ok)
            test.eq(opened.window.content, "pixels")
            local function plan_of(frame: any): any
                return ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
            end
            local function active(frame: any): any
                return plan_of(frame).by_id.pages.node.active
            end
            local function graph_len(frame: any): any
                local plan = plan_of(frame)
                for _, item in ipairs(plan.items) do
                    if item.node.kind == "graph" then return #(item.node.values or {}) end
                end
                return -1
            end
            local frame = receive(frames, function(value) return value.state.sdk == 1 and active(value) == 3 end)
            local before = graph_len(frame)
            frame = receive(frames, function(value) return active(value) == 3 and graph_len(value) > before end)
            local function click(x, y)
                assert(view:send({type = "mouse", action = "press", button = "left", x = x, y = y}))
                assert(view:send({type = "mouse", action = "release", button = "left", x = x, y = y}))
            end
            local tabs = plan_of(frame).by_id.pages
            local span = tabs.spans[2]
            click(frame.x + tabs.rect.x + span.x, frame.y + tabs.rect.y)
            frame = receive(frames, function(value) return active(value) == 2 end)
            local procs = plan_of(frame).by_id.procs
            test.is_true(#procs.node.rows > 0)
            click(frame.x + procs.rect.x, frame.y + procs.rect.y + 1)
            frame = receive(frames, function(value) return active(value) == 2 and plan_of(value).by_id.procs.node.selected == 1 end)
            local refresh = plan_of(frame).by_id.refresh.rect
            local status_before = plan_of(frame).by_id.pages
            click(frame.x + refresh.x, frame.y + refresh.y)
            frame = receive(frames, function(value) return active(value) == 2 and value.state.revision > frame.state.revision end)
            span = plan_of(frame).by_id.pages.spans[1]
            click(frame.x + tabs.rect.x + span.x, frame.y + tabs.rect.y)
            frame = receive(frames, function(value) return active(value) == 1 end)
            local apps = plan_of(frame).by_id.apps
            test.is_true(#apps.node.rows > 0)
            test.is_true(tostring(apps.node.rows[1].cells[1]):find("Task Manager", 1, true) ~= nil, "окно видит себя в списке задач")
            assert(view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true}))
            process.terminate(pid)
            view:close()
        end)
    end)
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
            test.eq(model.megabytes(670 * 1024 * 1024), "670 MB")
            test.eq(model.megabytes(512 * 1024), "0.5 MB")
            test.eq(model.uptime(8 * 60 + 21), "0:08:21")
            test.eq(model.uptime(3 * 86400 + 4 * 3600 + 15 * 60 + 2), "3d 04:15:02")
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

end

-- Форма раннера — как у shell_test. `return {run = run}` с describe внутри
-- run считался и был зелёным, НЕ выполняя ни одной проверки: мутация
-- round_ceiling(7) == 999 проходила. Проверка, которую никто не запускает,
-- хуже отсутствующей — на неё ссылаются.
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
