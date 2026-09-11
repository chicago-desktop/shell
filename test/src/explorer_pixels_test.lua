local test = require("test")
local process = require("process")
local channel = require("channel")
local tty = require("tty")
local time = require("time")

local function body(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then value = value:data() end
    if type(value) == "table" and value[1] then value = value[1] end
    return value
end

local function receive(stream, predicate)
    local deadline = time.after("5s")
    while true do
        local picked = channel.select({stream:case_receive(), deadline:case_receive()})
        test.is_true(picked.channel ~= deadline and picked.ok, "window did not reach the expected state")
        local value = body(picked.value)
        if predicate(value) then return value end
    end
end

local function boot(mode)
    local service = "butschster.windows.test.explorer." .. mode
    local view = assert(tty.viewport({width = 100, height = 34}))
    local pid = assert(process.with_options({terminal = assert(view:grant())})
        :spawn_monitored("app:explorer_composer", "app:processes", service, tostring(process.pid()), mode))
    local deadline = time.now():unix_nano() + 5000000000
    while time.now():unix_nano() < deadline and not process.registry.lookup(service) do
        channel.select({time.after("20ms"):case_receive()})
    end
    test.not_nil(process.registry.lookup(service))
    return {pid = pid, view = view, service = service}
end

local function send(desk, command, data)
    test.is_true(process.send(desk.service, command, data) == true)
end

local function click(desk, x, y)
    desk.view:send({type = "mouse", action = "press", button = "left", x = x, y = y})
    desk.view:send({type = "mouse", action = "release", button = "left", x = x, y = y})
end

local function define_tests()
    test.describe("live native Explorer", function()
        test.it("paints its provider and keeps wheel, arrows, folders and resize working", function()
            local frames = process.listen("explorer.painted", {message = true})
            local desk = boot("pixels")
            send(desk, "desktop.open", {entry = "butschster.windows.explorer:window", x = 5, y = 4, w = 22, h = 14})
            -- Пять размещений: меню, панель, адресная строка, поле, статус.
            local shown = receive(frames, function(value) return value.clients == 5 end)
            test.eq(shown.image, "my_computer")
            test.eq(shown.content, "pixels")
            test.eq(shown.width, 20)
            -- Заголовок в одну строку: клиенту достаётся на строку больше.
            test.eq(shown.height, 12)
            test.eq(shown.offset, 0)
            test.not_nil(shown.scroll, "the test viewport must require scrolling")
            -- The lower row of the taller address field is clickable too.
            local address = shown.hits.address.field
            test.is_true(address.bottom_row > address.row)
            click(desk, address.from + shown.x, address.bottom_row + shown.y)
            shown = receive(frames, function(value) return value.clients == 6 end)
            test.is_true(shown.hits.dropdown[1].row > address.bottom_row)
            local root = shown.hits.dropdown[1]
            click(desk, root.from + shown.x, root.row + shown.y)
            shown = receive(frames, function(value) return value.clients == 5 end)
            desk.view:send({type = "mouse", action = "wheel", button = "wheel_down", x = shown.hits.cells[1].from + shown.x, y = shown.hits.cells[1].top + shown.y})
            shown = receive(frames, function(value) return value.offset == 1 end)
            -- Стрелка вверх — нижняя правая ячейка её строк у верха полосы.
            local bar = shown.scroll
            click(desk, bar.x + (bar.w or 1) - 1 + shown.x, bar.y + (bar.arrow_rows or 1) - 1 + shown.y)
            shown = receive(frames, function(value) return value.offset == 0 end)
            local first = shown.hits.cells[1]
            click(desk, first.from + shown.x, first.top + shown.y)
            click(desk, first.from + shown.x, first.top + shown.y)
            shown = receive(frames, function(value) return value.path:sub(1, 6) == "drive/" end)
            for _, button in ipairs(shown.hits.tools) do
                if button.id == "up" then click(desk, button.from + shown.x, button.bottom_row + shown.y) end
            end
            shown = receive(frames, function(value) return value.path == "" end)
            send(desk, "desktop.resize", {id = shown.id, w = 34, h = 18})
            shown = receive(frames, function(value) return value.width == 32 and value.height == 16 end)
            desk.view:send({type = "key", action = "press", key_type = "down", key = "down"})
            shown = receive(frames, function(value) return value.selected > 0 end)
            test.is_true(shown.revision > 4)
            send(desk, "desktop.close", {id = shown.id})
            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(desk.service) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(desk.service))
            process.unlisten(frames)
            desk.view:close()
        end)

        -- Каждый пункт строки меню что-то делает: строки меню без попаданий
        -- (было до 2026-09-11) — это слова, по которым щёлкают впустую.
        test.it("runs every item of the menu bar it draws", function()
            local frames = process.listen("explorer.painted", {message = true})
            local replies = process.listen("desktop.reply", {message = true})
            local desk = boot("pixels")
            send(desk, "desktop.open", {entry = "butschster.windows.explorer:window", x = 3, y = 2, w = 62, h = 22})
            local shown = receive(frames, function(value) return value.clients == 5 end)
            local titles = {}
            for _, hit in ipairs(shown.hits.menu) do titles[#titles + 1] = hit.menu end
            test.eq(table.concat(titles, " "), "File View Go Help", "only menus whose items work")

            local function pick(title, id, predicate)
                local head: any = nil
                for _, hit in ipairs(shown.hits.menu) do if hit.menu == title then head = hit end end
                test.not_nil(head, title)
                click(desk, head.from + shown.x, head.row + shown.y)
                shown = receive(frames, function(value) return #value.hits.menu_popup > 0 end)
                test.eq(shown.clients, 6, "the open menu is its own placement")
                local line: any = nil
                for _, hit in ipairs(shown.hits.menu_popup) do if hit.id == id then line = hit end end
                test.not_nil(line, title .. " → " .. id)
                click(desk, line.from + shown.x, line.row + shown.y)
                if predicate then
                    shown = receive(frames, function(value)
                        return #value.hits.menu_popup == 0 and predicate(value)
                    end)
                end
            end

            local first = shown.hits.cells[1]
            click(desk, first.from + shown.x, first.top + shown.y)
            click(desk, first.from + shown.x, first.top + shown.y)
            shown = receive(frames, function(value) return value.path:sub(1, 6) == "drive/" end)
            local drive = shown.path
            pick("Go", "back", function(value) return value.path == "" end)
            pick("Go", "forward", function(value) return value.path == drive end)
            pick("Go", "up", function(value) return value.path == "" end)

            -- Refresh перечитывает папку, и выбор снимается: так его видно.
            test.is_true(#shown.hits.cells >= 2, "the root shows at least two objects")
            local other = shown.hits.cells[#shown.hits.cells]
            click(desk, other.from + shown.x, other.top + shown.y)
            shown = receive(frames, function(value) return value.selected > 0 end)
            pick("View", "refresh", function(value) return value.selected == 0 and value.path == "" end)
            pick("Help", "about", function(value)
                return type(value.notice) == "string" and value.notice:find("My Computer", 1, true) ~= nil
            end)

            pick("File", "close", nil)
            local open = -1
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline do
                send(desk, "desktop.list", {reply_to = tostring(process.pid())})
                local answer = receive(replies, function(value) return value.command == "desktop.list" end)
                open = #(answer.windows or {})
                if open == 0 then break end
                channel.select({time.after("50ms"):case_receive()})
            end
            test.eq(open, 0, "File → Close closes the window")

            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(desk.service) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(desk.service))
            process.unlisten(frames)
            process.unlisten(replies)
            desk.view:close()
        end)

        test.it("uses its original TTY window when the shell draws in cells", function()
            local replies = process.listen("desktop.reply", {message = true})
            local desk = boot("cells")
            send(desk, "desktop.open", {entry = "butschster.windows.explorer:window", reply_to = tostring(process.pid())})
            local opened = receive(replies, function(value) return value.command == "desktop.open" end)
            test.is_true(opened.ok)
            test.eq(opened.window.content, "cells")
            send(desk, "desktop.close", {id = opened.window.id})
            desk.view:send({type = "key", action = "press", key_type = "runes", key = "q", ctrl = true})
            local deadline = time.now():unix_nano() + 5000000000
            while time.now():unix_nano() < deadline and process.registry.lookup(desk.service) do
                channel.select({time.after("20ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(desk.service))
            process.unlisten(replies)
            desk.view:close()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
