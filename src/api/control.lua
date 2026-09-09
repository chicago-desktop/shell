-- Командный канал к оболочке.
--
-- Оболочка — обычный процесс, зарегистрированный под именем. Ручка находит
-- его по имени, шлёт сообщение и ждёт ответа на собственный inbox.
--
-- Зачем это ручкам раскладки: композитор читает раскладку не каждый кадр, а
-- по команде. Ручка, изменившая строку и не сказавшая об этом, выглядит не
-- сработавшей — значок появился бы только после перезапуска.
--
-- Отсюда важное следствие для читателя ответа: «оболочка не отвечает» и
-- «оболочка не запущена» — разные вещи. Вторая нормальна: раскладку можно
-- править и при погашенной оболочке, и называть это отказом нельзя.

local channel = require("channel")
local process = require("process")
local time = require("time")

local control = {}

control.SERVICE_NAME = "butschster.windows.shell"

local REPLY_TOPIC = "desktop.reply"
-- Короче, чем у основы: оболочка на той же машине, а ручка, которая двигает
-- значок, не должна висеть пять секунд из-за занятого композитора.
local BUDGET = "2s"

-- Сообщение приезжает обёрнутым: payload — userdata, внутри бывает ещё и
-- массив из одного элемента. Поле, прочитанное напрямую, окажется nil без
-- всякой ошибки.
local function unwrap(value)
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        if ok and type(decoded) == "table" then return decoded end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return unwrap(value[1]) end
    return value
end

control.unwrap = unwrap

local function await(budget)
    local inbox = process.inbox()
    local expiry = time.after(budget)

    while true do
        local result = channel.select({inbox:case_receive(), expiry:case_receive()})
        if result.channel == expiry then
            return nil, "the shell did not answer within " .. budget
        end
        if not result.ok then
            return nil, "the call inbox closed while waiting for the shell"
        end
        local message = result.value
        if message:topic() == REPLY_TOPIC then
            return unwrap(message:payload()), nil
        end
        -- Чужое сообщение не съедаем: оно адресовано не нам.
    end
end

-- running() -> pid | nil
function control.running()
    local pid = process.registry.lookup(control.SERVICE_NAME)
    return pid
end

-- call(topic, body) -> (ответ, nil, запущена) | (nil, причина, запущена)
--
-- Третьим значением — была ли оболочка запущена вообще. Ручке раскладки это
-- нужно, чтобы не выдавать погашенную оболочку за отказ.
function control.call(topic, body)
    local pid, lerr = process.registry.lookup(control.SERVICE_NAME)
    if not pid then
        return nil, "the shell is not running (" .. tostring(lerr)
            .. "): run `wippy run --host butschster.windows:terminal windows`", false
    end

    body = type(body) == "table" and body or {}
    body.reply_to = process.pid()

    local sent, serr = process.send(pid, topic, body)
    if not sent then
        return nil, "could not deliver the command to the shell: " .. tostring(serr), true
    end

    local answer, aerr = await(BUDGET)
    if not answer then return nil, aerr, true end
    if answer.ok == false then
        return nil, tostring(answer.error or "the shell refused without a reason"), true
    end
    return answer, nil, true
end

-- refresh() -> {refreshed, error}
--
-- Не отказ и не исключение: раскладка уже записана, и провал перечитывания —
-- отдельный факт, который ручка обязана назвать, не выдавая запись за
-- неудавшуюся. Погашенная оболочка — не ошибка вовсе.
function control.refresh()
    local answer, err, running = control.call("desktop.refresh", {})
    if answer then return {refreshed = true} end
    if not running then return {refreshed = false, reason = "the shell is not running"} end
    return {refreshed = false, reason = tostring(err)}
end

return control
