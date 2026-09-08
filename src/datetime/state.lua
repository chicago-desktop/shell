-- Поставщик состояния окна «Дата и время».
--
-- Ровно та половина, ради которой запись окна называет два имени (FR-005
-- §4б): данные добывает этот процесс под своим узким актором, а рисует их
-- чистая библиотека в композиторе. Здесь добыча одна — часы машины.
--
-- Состояние толкается САМИМ поставщиком, раз в секунду, когда сменилась
-- секунда: композитор не спрашивает, он несёт. Ввод приезжает сюда же —
-- окно только для чтения, поэтому из всего ввода читаются лишь щелчки по
-- «ОК» и «Отмена», и оба закрывают окно просьбой к композитору.

local channel = require("channel")
local process = require("process")
local time = require("time")

local layout = require("layout")

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Полезная нагрузка сообщения. Копия того, как читает её поставщик в
-- харнессе основы: `payload()` может отдать обёртку, а не таблицу, и поле,
-- прочитанное с обёртки, — это nil без ошибки.
local function body_of(message: any)
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

-- Снимок часов в том виде, в каком его рисует раскладка. Календарную
-- арифметику считает модуль time: день 0 следующего месяца — это последний
-- день текущего, и високосность вместе с ним.
local function snapshot(): any
    local now = time.now():in_local()
    local year, month, day = now:date()
    local hour, minute, second = now:clock()
    local first = time.date(whole(year), whole(month), 1, 0, 0, 0, 0, now:location())
    local last = time.date(whole(year), whole(month) + 1, 0, 0, 0, 0, 0, now:location())
    return {
        year = whole(year), month = whole(month), day = whole(day),
        hour = whole(hour), minute = whole(minute), second = whole(second),
        -- 0 = понедельник: у time воскресенье нулевое, у раскладки — седьмое.
        first_weekday = (whole(first:weekday()) + 6) % 7,
        days = whole(last:day()),
        zone = "UTC" .. now:format("-07:00"),
        caption = "часы " .. now:format("15:04:05"),
    }
end

local function main(desktop, window_id)
    local inbox = process.inbox()
    local target = tostring(desktop)
    local id = tostring(window_id)

    local function push(state: any)
        process.send(target, "desktop.state", {id = id, state = state})
    end

    local shown = snapshot()
    push(shown)

    while true do
        local picked = channel.select({inbox:case_receive(), time.after("250ms"):case_receive()})
        if not picked.ok then break end

        if picked.channel == inbox then
            local message = picked.value
            if message:topic() == "window.input" then
                local event: any = body_of(message).event or {}
                local pressed: any = nil
                if event.type == "mouse" and event.action == "press" and event.button ~= "wheel_up"
                    and event.button ~= "wheel_down" then
                    pressed = layout.button_at(event.x, event.y)
                elseif event.type == "key" and (event.key_type == "esc" or event.key_type == "enter") then
                    pressed = event.key_type == "esc" and "cancel" or "ok"
                end
                if pressed == "ok" or pressed == "cancel" then
                    -- Закрывает композитор, а не поставщик: у поставщика нет
                    -- окна, только его номер. Ответа не ждём — закрытое окно
                    -- гасит и этот процесс.
                    process.send(target, "desktop.close", {id = id})
                end
            end
        else
            local fresh = snapshot()
            if fresh.second ~= shown.second or fresh.minute ~= shown.minute
                or fresh.day ~= shown.day then
                shown = fresh
                push(shown)
            end
        end
    end
end

return {main = main}
