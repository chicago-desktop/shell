-- A stand-in for a desktop of the shell's family, for notify_test. It takes
-- the name it is given, answers `desktop.list` with its person logged on, a
-- screen and two windows, answers every notification command (or refuses
-- it, in the "refuse" mode), and tells the watcher each command it got with
-- its body. The args are JSON: a pid has a "|" in it, so a joined string
-- would split in the wrong place.
local process = require("process")
local channel = require("channel")
local json = require("json")

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then body = body:data() end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function main(args: any)
    local spec: any = json.decode(tostring(args)) or {}
    local name = tostring(spec.name)
    local watcher = tostring(spec.watcher)
    local registered, err = process.registry.register(name)
    if not registered then
        process.send(watcher, "standin.ready", {name = name, error = tostring(err)})
        return
    end
    process.send(watcher, "standin.ready", {name = name})

    local inbox = process.inbox()
    while true do
        local picked = channel.select({inbox:case_receive()})
        if not picked.ok then break end
        local message: any = picked.value
        local topic = tostring(message:topic())
        local body = body_of(message)
        if topic == "standin.stop" then break end
        local answer: any = {ok = true}
        if topic == "desktop.list" then
            answer.service = name
            if spec.user ~= nil then answer.user = {id = spec.user, name = "Person " .. tostring(spec.user)} end
            answer.screen = {width = 100, height = 30}
            answer.windows = {{id = "w1", entry = "app:flash_target"}, {id = "w2", entry = "app:elsewhere"}}
        elseif spec.mode == "refuse" then
            answer = {ok = false, error = "the desktop already holds 8 balloons"}
        elseif topic == "desktop.open" then
            answer.window = {id = "w9", entry = body.entry}
        end
        if type(body.reply_to) == "string" and body.reply_to ~= "" then
            answer.command = topic
            process.send(body.reply_to, "desktop.reply", answer)
        end
        if topic ~= "desktop.list" then
            process.send(watcher, "standin.got", {desktop = name, topic = topic, body = body})
        end
    end
    process.registry.unregister(name)
end

return {main = main}
