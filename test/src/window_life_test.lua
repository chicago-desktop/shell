-- Program windows stay alive after launch.
--
-- The compositor opens a window, the window dies on its first frame — and from outside this is
-- "clicked, nothing opened": the reason goes into the muted log. Here
-- the window is launched directly, with a viewport grant, and its exit event
-- is read as text. That is how both `utf8.codes` were found.
--
-- A window counts as alive when it has drawn its first frame and has not
-- exited within GRACE after it. The earlier form waited four seconds and took
-- silence for life: slow, and a window that never drew passed as alive. The
-- deaths this test exists for happen while the first frame is built or right
-- after it; a window that dies much later is not caught here — nor was it by
-- the four-second wait.
local test = require("test")
local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local FIRST_FRAME_NS = 3000000000
local GRACE = "300ms"

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

-- Something is on the viewport: any byte that is not a blank, escapes included.
local function drawn(view: any): boolean
    local snap: any = view:snapshot(-1)
    for _, row in ipairs(snap and snap.rows or {}) do
        if tostring(row):find("[^ ]") then return true end
    end
    return false
end

local function exit_of(entry: string, argument: any): string
    local lifecycle = assert(process.events())
    local view = assert(tty.viewport({width = 60, height = 20}))
    local grant = assert(view:grant())
    local pid, err = process.with_options({terminal = grant})
        :with_context({["tui_desktop.service"] = "butschster.windows.shell"})
        :spawn_monitored(entry, "app:processes", argument)
    if not pid then return "spawn: " .. tostring(err) end
    local deadline = time.now():unix_nano() + FIRST_FRAME_NS
    local grace: any = nil
    while true do
        local cases = {lifecycle:case_receive(), time.after("20ms"):case_receive()}
        if grace then cases[#cases + 1] = grace:case_receive() end
        local picked = channel.select(cases)
        if picked.channel == lifecycle then
            if not picked.ok then return "event channel closed" end
            local event: any = picked.value
            if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
                view:close()
                return "EXIT: " .. dump(event, 0)
            end
        elseif grace and picked.channel == grace then
            process.terminate(tostring(pid))
            view:close()
            return "alive after its first frame (ok)"
        elseif not grace then
            if drawn(view) then
                grace = time.after(GRACE)
            elseif time.now():unix_nano() > deadline then
                process.terminate(tostring(pid))
                view:close()
                return "no first frame within 3 s"
            end
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
