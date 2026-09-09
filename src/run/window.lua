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

-- Просьба композитору — через поле, а не напрямую: тест подменяет её и
-- проверяет форму просьбы и разбор ответа без живого композитора.
definition.request = function(command: any, body: any): (any, any)
    local sent, err = desktop.request(command, body)
    return sent, err
end

function definition.init(args: any, context: any): any
    local state: any = {text = "", pending = false, browsing = false, failure = nil, answers = nil}
    local answers, err = desktop.replies()
    if answers then
        state.answers = answers
        if context.watch then context.watch(answers) end
    else
        state.failure = "the compositor reply channel did not open: " .. tostring(err)
    end
    return state
end

-- Окно «Мой компьютер» — то, что открывает «Обзор…»: программу или документ
-- здесь ищут в проводнике оболочки. Путь обратно в поле он не кладёт —
-- у проводника нет режима «выбрать файл», — так что «Обзор…» это дорога в
-- проводник, а не диалог выбора.
local EXPLORER = "butschster.windows.explorer:window"

-- Заголовок окна — «Run», без многоточия: многоточие — у пункта меню, оно
-- обещает диалог, а сам диалог называется без него, как в Windows.
definition.title = "Run"

function definition.view(state: any, context: any): any
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "image", size = 4, image = "run", icon = "▸", size_px = 32},
            -- Отказ занимает место подсказки: отдельная строка под кнопками
            -- отодвигала их от рамки, а подсказка в момент отказа не нужна.
            {kind = "label", text = state.failure or "Type the name of a program, folder, or document, and\nWindows will open it for you.",
                alert = state.failure ~= nil},
        }},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = 5, text = "Open:"},
            {kind = "input", id = "command", text = state.text},
        }},
        -- Кнопки в ряд — всегда к правому краю (правило оболочки): пустая
        -- метка без размера забирает остаток слева. Сразу под полем, без
        -- строки между ними, как в Windows 95.
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "ok", size = 10, text = "OK", default = true, disabled = state.pending},
            {kind = "button", id = "cancel", size = 10, text = "Cancel", disabled = state.pending},
            {kind = "button", id = "browse", size = 10, text = "Browse…", disabled = state.pending},
        }},
    }}
end

local function launch(state: any, context: any)
    if state.pending then return end
    local spec, why = model.spec(state.text)
    if not spec then state.failure = why; return end
    local sent, err = definition.request("desktop.open", spec)
    if not sent then state.failure = tostring(err); return end
    state.pending, state.failure = true, nil
end

-- «Обзор…» просит композитор открыть проводник и ждёт ответ ТЕМ ЖЕ каналом,
-- что и запуск. Различает их `state.browsing`: ответ на проводник не должен
-- закрывать диалог, а ответ на запуск — не должен молча пропасть.
local function browse(state: any)
    if state.pending or state.browsing then return end
    local sent, err = definition.request("desktop.open", {entry = EXPLORER})
    if not sent then state.failure = tostring(err); return end
    state.browsing, state.failure = true, nil
end

function definition.update(state: any, action: any, context: any)
    if action.type == "channel" then
        if action.channel ~= state.answers or not action.ok then return false end
        local reply: any = action.value
        if type(reply) == "userdata" then reply = reply:payload() end
        if type(reply) == "userdata" then reply = reply:data() end
        if type(reply) == "table" and reply[1] ~= nil then reply = reply[1] end
        if type(reply) ~= "table" or reply.command ~= "desktop.open" then return false end
        if state.browsing then
            state.browsing = false
            if not reply.ok then state.failure = tostring(reply.error or "Could not open My Computer.") end
            return true
        end
        if not state.pending then return false end
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
    elseif action.id == "browse" and action.type == "activate" then
        browse(state)
    elseif action.type == "key" and action.ctrl and action.key == "u" then
        state.text = ""
    else return false end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
