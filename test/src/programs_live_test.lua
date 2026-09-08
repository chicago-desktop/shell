-- Новые программы открываются живой оболочкой, а не только объявлены.
--
-- Проверяется вся цепочка: оболочка поднята на viewport теста, команда
-- `desktop.open` с настоящей записью, ответ — описание окна. Отказ здесь
-- называет причину текстом: на стенде он уходит в заглушённый лог, и
-- «щёлкнул — ничего не открылось» снаружи неотличимо от промаха мышью.

local test = require("test")
local channel = require("channel")
local control = require("control")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function boot_shell()
    local view = tty.viewport({width = 100, height = 30})
    test.not_nil(view, "viewport не создался")
    local grant = view:grant()
    test.not_nil(grant, "грант на viewport не выдался")
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("butschster.windows:shell", "app:processes", "test")
    test.is_nil(err)
    test.not_nil(pid, "оболочка не запустилась")
    local deadline = time.now():unix_nano() + 15000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(control.SERVICE_NAME) then return {pid = pid, view = view} end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "оболочка не зарегистрировалась под именем " .. control.SERVICE_NAME)
    return {pid = pid, view = view}
end

local function define_tests()
    test.describe("новые программы открываются оболочкой", function()
        test.it("Диспетчер задач, Блокнот и просмотр картинок отвечают описанием окна", function()
            local shell: any = boot_shell()

            local answer, err = control.call("desktop.open", {entry = "butschster.windows.taskman:window"})
            test.is_nil(err, "Диспетчер задач не открылся: " .. tostring(err))
            test.not_nil(answer and answer.window, "ответ обязан описывать окно диспетчера")

            local args = '{"drive":"butschster.windows.shell:icon_files","path":"/SOURCE.md"}'
            answer, err = control.call("desktop.open", {entry = "butschster.windows.viewers:notepad", args = args})
            test.is_nil(err, "Блокнот не открылся: " .. tostring(err))
            test.not_nil(answer and answer.window, "ответ обязан описывать окно блокнота")

            local png = '{"drive":"butschster.windows.shell:icon_files","path":"/32/my_computer.png"}'
            answer, err = control.call("desktop.open", {entry = "butschster.windows.viewers:picture", args = png})
            test.is_nil(err, "просмотр картинок не открылся: " .. tostring(err))
            test.not_nil(answer and answer.window, "ответ обязан описывать окно просмотра")
            test.eq(answer.window.content, "pixels", "картинка — окно-вид")

            -- Дать окнам нарисоваться и поставщику состояния — прислать картинку.
            channel.select({time.after("1500ms"):case_receive()})
            local listed, lerr = control.call("desktop.list", {})
            test.is_nil(lerr)
            local names = {}
            for _, window in ipairs(listed.windows or {}) do names[#names + 1] = tostring(window.entry) end
            test.eq(#(listed.windows or {}), 3, "три окна обязаны быть открыты; остались: " .. table.concat(names, ", "))
            for _, window in ipairs(listed.windows or {}) do
                if window.content == "pixels" then
                    test.is_true(window.waiting == false, "поставщик картинки обязан прислать состояние")
                end
            end

            process.terminate(shell.pid)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
