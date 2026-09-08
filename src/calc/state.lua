-- Поставщик состояния калькулятора: принимает ввод, считает, толкает табло.
--
-- Вторая половина окна-вида (FR-005 §4б): арифметика живёт здесь, под своим
-- узким актором, а рисует её чистая библиотека в композиторе. Ввод приезжает
-- сюда как `window.input`: щелчок — в ячейках содержимого, по раскладке
-- считается кнопка; клавиша — через таблицу движка, одну на оба способа.
--
-- Подсветка нажатой кнопки гасится по таймеру: мышь присылает только
-- нажатие, отпускания у содержимого окна нет, и без таймера кнопка
-- оставалась бы вдавленной до следующего щелчка.

local channel = require("channel")
local process = require("process")
local time = require("time")

local engine = require("engine")
local layout = require("layout")

local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- Наружу уходит не движок, а табло: краскам нужна строка и два признака.
local function view_of(state: any): any
    return {
        display = engine.display(state),
        memory = state.memory ~= nil,
        pressed = state.pressed,
        caption = engine.display(state),
    }
end

local function main(desktop, window_id)
    local inbox = process.inbox()
    local target = tostring(desktop)
    local id = tostring(window_id)
    local state = engine.new()

    local function push()
        process.send(target, "desktop.state", {id = id, state = view_of(state)})
    end

    push()

    local release: any = nil
    while true do
        local cases = {inbox:case_receive()}
        if release then cases[#cases + 1] = release:case_receive() end
        local picked = channel.select(cases)
        if not picked.ok then break end

        if picked.channel == inbox then
            local message = picked.value
            if message:topic() == "window.input" then
                local event: any = body_of(message).event or {}
                local pressed: any = nil
                if event.type == "mouse" and event.action == "press"
                    and event.button ~= "wheel_up" and event.button ~= "wheel_down" then
                    pressed = layout.button_at(event.x, event.y)
                elseif event.type == "key" then
                    pressed = engine.key(event)
                end
                if pressed then
                    state = engine.press(state, pressed)
                    push()
                    release = time.after("150ms")
                end
            end
        else
            release = nil
            if state.pressed then
                state.pressed = nil
                push()
            end
        end
    end
end

return {main = main}
