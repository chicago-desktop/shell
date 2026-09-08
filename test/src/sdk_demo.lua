-- Executable scaffold: the registry entry is its only connection to the shell.
local app = require("app")
local time = require("time")
local definition = {}
function definition.init(args: any, context: any): any
    local items = {}
    for index = 1, 80 do items[index] = {text = string.format("Документ %02d", index), id = index} end
    -- Свой канал приложения: здесь — таймер, в жизни — ответ композитора или
    -- подписка. Сработает один раз и станет сообщением. В харнессе раскладки
    -- контекст голый, там канала нет.
    if context.watch then context.watch(time.after("150ms")) end
    return {items = items, selected = 1, text = args or "Пример", message = "Выберите документ", checked = true}
end
function definition.view(model: any, context: any): any
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Приложение из реестра · " .. context.width .. " × " .. context.height},
        {kind = "split", gap = 1, children = {
            {kind = "list", id = "documents", weight = 2, items = model.items, selected = model.selected},
            {kind = "column", weight = 3, gap = 1, children = {
                {kind = "label", size = 2, text = model.message},
                {kind = "input", id = "name", size = 2, text = model.text},
                {kind = "checkbox", id = "subfolders", size = 1, checked = model.checked, text = "Включая вложенные папки"},
                {kind = "label", text = "Колесо · Page Down · Home / End"},
            }},
        }},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "show", size = 12, text = "Показать", default = true},
            {kind = "button", id = "stop", size = 12, text = "Остановить", disabled = true},
            {kind = "button", id = "crash", size = 11, text = "Уронить"},
            {kind = "button", id = "close", size = 12, text = "Закрыть"},
        }},
    }}
end
function definition.update(model: any, action: any, context: any)
    if action.id == "documents" and action.type == "select" then
        model.selected = action.index
        model.message = action.value.text
    elseif action.id == "name" and action.type == "change" then model.text = action.value
    elseif action.id == "subfolders" and action.type == "change" then model.checked = action.value
    elseif action.id == "show" then model.message = model.text
    elseif action.id == "crash" then error("нарочно: кнопка «Уронить»")
    elseif action.type == "channel" then model.message = "канал сработал"
    elseif action.type == "key" and action.key_type == "esc" then context.close()
    elseif action.id == "close" then context.close() end
end
local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end
return {main = main, definition = definition}
