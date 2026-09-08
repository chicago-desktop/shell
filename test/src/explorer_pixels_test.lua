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
            test.eq(shown.height, 11)
            test.eq(shown.offset, 0)
            test.is_true(#shown.hits.scroll == 2, "the test viewport must require scrolling")
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
            for _, arrow in ipairs(shown.hits.scroll) do
                if arrow.id == "scroll_up" then click(desk, arrow.to + shown.x, arrow.bottom_row + shown.y) end
            end
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
            shown = receive(frames, function(value) return value.width == 32 and value.height == 15 end)
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
