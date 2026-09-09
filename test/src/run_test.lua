local test = require("test")
local process = require("process")
local channel = require("channel")
local time = require("time")
local tty = require("tty")
local model = require("model")
local ui = require("ui")
local run_window = require("run_window")
local RUN = "butschster.windows.run:window"
-- Текст метки из дерева SDK по совпадению: так проверка не зависит от
-- положения строки в колонке.
local function find_text(node: any, needle: string): any
    if type(node) ~= "table" then return nil end
    if type(node.text) == "string" and node.text:find(needle, 1, true) then return node.text end
    for _, child in ipairs(node.children or {}) do
        local found = find_text(child, needle)
        if found then return found end
    end
    return nil
end
local function body(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then value = value:data() end
    if type(value) == "table" and value[1] then value = value[1] end
    return value
end
local function receive(stream, predicate)
    local deadline = time.after("8s")
    while true do
        local picked = channel.select({stream:case_receive(), deadline:case_receive()})
        test.is_true(picked.channel ~= deadline and picked.ok, "Run did not reach expected state")
        local value = body(picked.value)
        if predicate(value) then return value end
    end
end
local function pause()
    channel.select({time.after("20ms"):case_receive()})
end
local function key(desk, name, ctrl, alt)
    desk.view:send({type = "key", action = "press", key = name,
        key_type = #name == 1 and "runes" or name, ctrl = ctrl, alt = alt})
end
local function click(desk, x, y)
    desk.view:send({type = "mouse", action = "press", button = "left", x = x, y = y})
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end
local function boot(mode)
    local service = "butschster.windows.test.run." .. mode
    local view = assert(tty.viewport({width = 100, height = 34}))
    local pid, spawn_error = process.with_options({terminal = assert(view:grant())})
        :spawn_monitored("app:run_composer", "app:processes", service, tostring(process.pid()), mode)
    test.not_nil(pid, tostring(spawn_error))
    local deadline = time.now():unix_nano() + 5000000000
    while time.now():unix_nano() < deadline and not process.registry.lookup(service) do pause() end
    test.not_nil(process.registry.lookup(service))
    return {view = view, pid = pid, service = service}
end
local function ask(desk, replies, topic, data)
    data = data or {}
    data.reply_to = tostring(process.pid())
    assert(process.send(desk.service, topic, data))
    return receive(replies, function(value) return value.command == topic end)
end
local function eventually(check)
    local deadline = time.now():unix_nano() + 8000000000
    while time.now():unix_nano() < deadline do
        local value = check()
        if value then return value end
        pause()
    end
    error("timed out waiting for PTY/window")
end
local function define_tests()
    test.describe("Run", function()
        test.it("builds a Bash launch spec and rejects empty commands", function()
            local spec = model.spec("top -d 2")
            test.eq(spec.entry, model.PTY)
            test.eq(spec.title, "top -d 2")
            test.is_true(spec.command:find("top -d 2", 1, true) ~= nil)
            test.is_nil(model.spec(" \t "))
        end)
        test.it("lays out the dialog on the SDK: input, OK by default, Cancel, no overlaps", function()
            local state = run_window.definition.init(nil, {})
            local tree = run_window.definition.view(state, {width = 48, height = 7})
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 48, 7, interaction)
            test.not_nil(plan.by_id.command)
            test.not_nil(plan.by_id.ok)
            test.not_nil(plan.by_id.cancel)
            test.not_nil(plan.by_id.browse, "«Обзор…» — третья кнопка, как в Windows 95")
            test.eq(interaction.focus, "command", "фокус — в поле команды")
            test.is_true(ui.default_look(plan, plan.by_id.ok.node, false), "«ОК» по умолчанию, пока фокус в поле")
            interaction.focus = "cancel"
            plan = ui.plan(tree, 48, 7, interaction)
            test.is_false(ui.default_look(plan, plan.by_id.ok.node, false), "фокус на «Отмене» забирает контур у «ОК»")
            test.is_true(ui.default_look(plan, plan.by_id.cancel.node, true))
            -- Подсказка — две строки одной меткой, пока отказа нет.
            test.not_nil(find_text(tree, "Windows will open it for you"))
            -- Пустая команда — причина в дереве, а не в никуда: отказ встаёт
            -- на место подсказки, а не отдельной строкой под кнопками.
            run_window.definition.update(state, {type = "activate", id = "ok"}, {close = function() end})
            local failed = run_window.definition.view(state, {width = 48, height = 7})
            test.not_nil(find_text(failed, "Type the name of a program or command."))
            test.is_nil(find_text(failed, "Windows will open it for you"), "отказ занимает место подсказки")
            test.eq(run_window.definition.title, "Run", "заголовок окна — без многоточия, оно у пункта меню")
        end)
        test.it("Browse… asks for My Computer and does not close the dialog on the reply", function()
            local asked: any = nil
            local closed = false
            local state: any = {text = "", pending = false, browsing = false, answers = "replies"}
            local context: any = {close = function() closed = true end}
            -- Подмена запроса: проверяется форма просьбы и разбор ответа, а
            -- не композитор — его проверяет живой прогон ниже.
            local real_request = run_window.definition.request
            run_window.definition.request = function(command, body) asked = {command = command, body = body}; return true, nil end
            run_window.definition.update(state, {type = "activate", id = "browse"}, context)
            test.not_nil(asked)
            test.eq(asked.command, "desktop.open")
            test.eq(asked.body.entry, "butschster.windows.explorer:window")
            test.is_true(state.browsing)
            run_window.definition.update(state, {type = "channel", channel = "replies", ok = true,
                value = {command = "desktop.open", ok = true}}, context)
            test.is_false(state.browsing)
            test.is_false(closed, "ответ на проводник не закрывает «Выполнить»")
            test.is_nil(state.failure)
            -- Отказ проводника называется в диалоге.
            run_window.definition.update(state, {type = "activate", id = "browse"}, context)
            run_window.definition.update(state, {type = "channel", channel = "replies", ok = true,
                value = {command = "desktop.open", ok = false, error = "no such window"}}, context)
            test.eq(state.failure, "no such window")
            run_window.definition.request = real_request
        end)
        test.it("opens Bash and Run from Start and keeps the launched shell after Run closes", function()
            local menus = process.listen("run.menu", {message = true})
            local frames = process.listen("run.frame", {message = true})
            local replies = process.listen("desktop.reply", {message = true})
            local desk = boot("pixels")
            key(desk, "o", false, true)
            local menu = receive(menus, function(value) return value.spots[RUN] ~= nil end)
            local group = menu.spots["Programs"]
            test.not_nil(group)
            click(desk, group.from, group.row)
            menu = receive(menus, function(value) return value.spots[model.PTY] ~= nil end)
            click(desk, menu.spots[model.PTY].from, menu.spots[model.PTY].row)
            local bash = eventually(function()
                local list = ask(desk, replies, "desktop.list")
                if #list.windows == 1 and list.windows[1].ready then return list.windows[1] end
            end)
            test.eq(bash.title, "Bash")
            ask(desk, replies, "desktop.close", {id = bash.id})
            eventually(function() return #ask(desk, replies, "desktop.list").windows == 0 end)
            key(desk, "o", false, true)
            menu = receive(menus, function(value) return value.spots[RUN] ~= nil end)
            click(desk, menu.spots[RUN].from, menu.spots[RUN].row)
            local frame = receive(frames, function() return true end)
            key(desk, "enter")
            frame = receive(frames, function(value) return find_text(value.state.ui, "Type the name of a program") ~= nil end)
            local command = "printf 'RUN_RESULT:%s\\n' \"it's ready\""
            ask(desk, replies, "desktop.type", {id = frame.id, text = command})
            frame = receive(frames, function(value)
                local plan = ui.plan(value.state.ui, value.width, value.height, value.state.interaction)
                return plan.by_id.command.node.text == command end)
            local plan = ui.plan(frame.state.ui, frame.width, frame.height, frame.state.interaction)
            local ok = plan.by_id.ok.rect
            click(desk, frame.x + ok.x + ok.w - 1, frame.y + ok.y + ok.h - 1)
            local launched = eventually(function()
                local list = ask(desk, replies, "desktop.list")
                if #list.windows == 1 and list.windows[1].entry == model.PTY and list.windows[1].ready then return list.windows[1] end
            end)
            test.eq(launched.title, command)
            eventually(function()
                local screen = ask(desk, replies, "desktop.screen", {id = launched.id})
                return table.concat(screen.rows or {}, "\n"):find("RUN_RESULT:it's ready", 1, true) ~= nil
            end)
            ask(desk, replies, "desktop.type", {id = launched.id, text = "printf 'STILL_%s\\n' IN_BASH", enter = true})
            eventually(function()
                local screen = ask(desk, replies, "desktop.screen", {id = launched.id})
                return table.concat(screen.rows or {}, "\n"):find("STILL_IN_BASH", 1, true) ~= nil
            end)
            ask(desk, replies, "desktop.close", {id = launched.id})
            eventually(function() return #ask(desk, replies, "desktop.list").windows == 0 end)
            key(desk, "q", true)
            eventually(function() return not process.registry.lookup(desk.service) end)
            desk.view:close()
        end)
        test.it("keeps a usable cell dialog with Escape cancellation", function()
            local replies = process.listen("desktop.reply", {message = true})
            local desk = boot("cells")
            local opened = ask(desk, replies, "desktop.open", {entry = RUN})
            test.is_true(opened.ok)
            test.eq(opened.window.content, "cells")
            eventually(function()
                local screen = ask(desk, replies, "desktop.screen", {id = opened.window.id})
                return screen.ready and table.concat(screen.rows or {}, "\n"):find("Open:", 1, true)
            end)
            ask(desk, replies, "desktop.key", {id = opened.window.id, key = "esc", key_type = "esc"})
            eventually(function() return #ask(desk, replies, "desktop.list").windows == 0 end)
            key(desk, "q", true)
            eventually(function() return not process.registry.lookup(desk.service) end)
            desk.view:close()
        end)
    end)
end
local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
