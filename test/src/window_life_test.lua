-- Окна-программы живут после запуска.
--
-- Композитор открывает окно, окно умирает на первом кадре — и снаружи это
-- «щёлкнул, ничего не открылось»: причина уходит в заглушённый лог. Здесь
-- окно запускается напрямую, с грантом на viewport, и событие его выхода
-- читается как текст. Так нашлись оба `utf8.codes`.
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
        if picked.channel == deadline then return "жив через 4 с (ок)" end
        if not picked.ok then return "канал событий закрылся" end
        local event: any = picked.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
            return "EXIT: " .. dump(event, 0)
        end
    end
end

local function define_tests()
    test.describe("окна-программы живут после запуска", function()
        test.it("Диспетчер задач не умирает на первом кадре", function()
            local outcome = exit_of("butschster.windows.taskman:window", nil)
            test.is_true(outcome:find("жив", 1, true) ~= nil, "Диспетчер задач: " .. outcome)
        end)
        test.it("Блокнот не умирает на первом кадре", function()
            local outcome = exit_of("butschster.windows.viewers:notepad",
                '{"drive":"butschster.windows.shell:icon_files","path":"/SOURCE.md"}')
            test.is_true(outcome:find("жив", 1, true) ~= nil, "Блокнот: " .. outcome)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
