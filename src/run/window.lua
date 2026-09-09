-- «Выполнить» — диалог на SDK оболочки.
--
-- Интерфейс: значок, подсказка, поле «Открыть:», «ОК» и «Отмена». Запуск —
-- только просьбой к композитору (`desktop.open` через `request`): у окна нет
-- прав порождать процессы, и Bash под PTY поднимает композитор. Ответ на
-- просьбу приходит своим каналом — `context.watch(desktop.replies())`, —
-- поэтому окно не замирает, пока композитор открывает окно.
local desktop = require("desktop")
local app = require("app")
local model = require("model")

local definition: any = {}

function definition.init(args: any, context: any): any
    local state: any = {text = "", pending = false, failure = nil, answers = nil}
    local answers, err = desktop.replies()
    if answers then
        state.answers = answers
        if context.watch then context.watch(answers) end
    else
        state.failure = "the compositor reply channel did not open: " .. tostring(err)
    end
    return state
end

function definition.view(state: any, context: any): any
    return {kind = "column", padding = 1, gap = 0, children = {
        {kind = "row", size = 3, gap = 1, children = {
            {kind = "image", size = 5, image = "run", icon = "▸"},
            {kind = "label", text = "Type the name of a program or command to run in Bash."},
        }},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = 9, text = "Open:"},
            {kind = "input", id = "command", text = state.text},
        }},
        {kind = "label", text = state.failure or "", alert = state.failure ~= nil},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "ok", size = 12, text = "OK", default = true, disabled = state.pending},
            {kind = "button", id = "cancel", size = 12, text = "Cancel", disabled = state.pending},
        }},
    }}
end

local function launch(state: any, context: any)
    if state.pending then return end
    local spec, why = model.spec(state.text)
    if not spec then state.failure = why; return end
    local sent, err = desktop.request("desktop.open", spec)
    if not sent then state.failure = tostring(err); return end
    state.pending, state.failure = true, nil
end

function definition.update(state: any, action: any, context: any)
    if action.type == "channel" then
        if action.channel ~= state.answers or not action.ok then return false end
        local reply: any = action.value
        if type(reply) == "userdata" then reply = reply:payload() end
        if type(reply) == "userdata" then reply = reply:data() end
        if type(reply) == "table" and reply[1] ~= nil then reply = reply[1] end
        if type(reply) ~= "table" or reply.command ~= "desktop.open" or not state.pending then return false end
        state.pending = false
        if reply.ok then context.close() else state.failure = tostring(reply.error or "Could not open the window.") end
        return true
    end
    if action.id == "command" and action.type == "change" then
        state.text = tostring(action.value or "")
        state.failure = nil
    elseif (action.id == "command" and action.type == "activate") or action.id == "ok" then
        if action.id == "command" then state.text = tostring(action.value or state.text) end
        launch(state, context)
    elseif action.id == "cancel" or (action.type == "key" and action.key_type == "esc") then
        context.close()
    elseif action.type == "key" and action.ctrl and action.key == "u" then
        state.text = ""
    else return false end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
