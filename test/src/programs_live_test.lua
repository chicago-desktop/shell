-- New programs are opened by the live shell, not just declared.
--
-- The whole chain is checked: the shell is brought up on the test's
-- viewport, the `desktop.open` command with a real entry, the answer is a
-- window description. A failure here names the reason as text: on the stand
-- it goes into the muted log, and "clicked — nothing opened" is
-- indistinguishable from outside from a mouse miss.

local test = require("test")
local channel = require("channel")
local control = require("control")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function boot_shell()
    local view = tty.viewport({width = 100, height = 30})
    test.not_nil(view, "the viewport was not created")
    local grant = view:grant()
    test.not_nil(grant, "the viewport grant was not issued")
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("windows.shell:shell", "app:processes", "test")
    test.is_nil(err)
    test.not_nil(pid, "the shell did not start")
    local deadline = time.now():unix_nano() + 15000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(control.SERVICE_NAME) then return {pid = pid, view = view} end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "the shell did not register under the name " .. control.SERVICE_NAME)
    return {pid = pid, view = view}
end

local function define_tests()
    test.describe("new programs are opened by the shell", function()
        test.it("Task Manager, Notepad and the picture viewer answer with a window description", function()
            local shell: any = boot_shell()

            local answer, err = control.call("desktop.open", {entry = "windows.shell.sysprops:window"})
            test.is_nil(err, "Task Manager did not open: " .. tostring(err))
            test.not_nil(answer and answer.window, "the answer must describe the Task Manager window")

            local args = '{"drive":"windows.shell.theme:icon_files","path":"/SOURCE.md"}'
            answer, err = control.call("desktop.open", {entry = "windows.shell.viewers:notepad", args = args})
            test.is_nil(err, "Notepad did not open: " .. tostring(err))
            test.not_nil(answer and answer.window, "the answer must describe the Notepad window")

            local png = '{"drive":"windows.shell.theme:icon_files","path":"/32/my_computer.png"}'
            answer, err = control.call("desktop.open", {entry = "windows.shell.viewers:picture", args = png})
            test.is_nil(err, "the picture viewer did not open: " .. tostring(err))
            test.not_nil(answer and answer.window, "the answer must describe the viewer window")
            test.eq(answer.window.content, "pixels", "a picture is a view window")

            -- The three windows are listed as soon as they are open, and the picture
            -- provider is done when its window stops `waiting`. Asked every 100 ms
            -- up to a deadline instead of a fixed pause of 1.5 s; then asked once
            -- more after a grace, because a window that dies right after opening
            -- drops out of the list, and the first answer would not show it.
            local function settled(): (any, any)
                local answer: any, failure = control.call("desktop.list", {})
                if not answer then return nil, failure end
                if #(answer.windows or {}) ~= 3 then return nil, "not all three are listed yet" end
                for _, window in ipairs(answer.windows) do
                    if window.content == "pixels" and window.waiting ~= false then return nil, "the picture is still waiting" end
                end
                return answer, nil
            end
            local deadline = time.now():unix_nano() + 5000000000
            local ready: any, why = settled()
            while not ready and time.now():unix_nano() < deadline do
                channel.select({time.after("100ms"):case_receive()})
                ready, why = settled()
            end
            test.not_nil(ready, "the windows did not settle within 5 s: " .. tostring(why))
            channel.select({time.after("300ms"):case_receive()})
            local listed, lerr = control.call("desktop.list", {})
            test.is_nil(lerr)
            local names = {}
            for _, window in ipairs(listed.windows or {}) do names[#names + 1] = tostring(window.entry) end
            test.eq(#(listed.windows or {}), 3, "three windows must be open; remaining: " .. table.concat(names, ", "))
            for _, window in ipairs(listed.windows or {}) do
                if window.content == "pixels" then
                    test.is_true(window.waiting == false, "the picture provider must send its state")
                end
            end

            process.terminate(shell.pid)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
