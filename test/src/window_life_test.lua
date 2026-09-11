-- Program windows stay alive after launch.
--
-- The compositor opens a window, the window dies on its first frame — and from outside this is
-- "clicked, nothing opened": the reason goes into the muted log. Here
-- the window is launched directly, with a viewport grant, and its exit event
-- is read as text. That is how both `utf8.codes` were found.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local function dump(value: any, depth: integer): string
    if type(value) ~= "table" then return tostring(value) end
    if depth > 3 then return "{…}" end
    local parts = {}
    for key, item in pairs(value) do
        parts[#parts + 1] = tostring(key) .. "=" .. dump(item, depth + 1)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function exit_of(entry: string, argument: any): string
    local lifecycle = assert(process.events())
    local view = assert(tty.viewport({width = 60, height = 20}))
    local grant = assert(view:grant())
    local pid, err = process.with_options({terminal = grant})
        :with_context({["tui_desktop.service"] = "butschster.windows.shell"})
        :spawn_monitored(entry, "app:processes", argument)
    if not pid then return "spawn: " .. tostring(err) end
    local deadline = time.after("4s")
    while true do
        local picked = channel.select({lifecycle:case_receive(), deadline:case_receive()})
        if picked.channel == deadline then return "alive after 4 s (ok)" end
        if not picked.ok then return "event channel closed" end
        local event: any = picked.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
            return "EXIT: " .. dump(event, 0)
        end
    end
end

local function define_tests()
    test.describe("program windows stay alive after launch", function()
        test.it("Task Manager does not die on the first frame", function()
            local outcome = exit_of("butschster.windows.taskman:window", nil)
            test.is_true(outcome:find("alive", 1, true) ~= nil, "Task Manager: " .. outcome)
        end)
        test.it("Notepad does not die on the first frame", function()
            local outcome = exit_of("butschster.windows.viewers:notepad",
                '{"drive":"butschster.windows.shell:icon_files","path":"/SOURCE.md"}')
            test.is_true(outcome:find("alive", 1, true) ~= nil, "Notepad: " .. outcome)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
