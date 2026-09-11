-- Executable scaffold: the registry entry is its only connection to the shell.
local app = require("app")
local time = require("time")
local definition = {}
function definition.init(args: any, context: any): any
    local items = {}
    for index = 1, 80 do items[index] = {text = string.format("Document %02d", index), id = index} end
    -- The application's own channel: here it is a timer, in real life the compositor's answer or
    -- a subscription. It fires once and becomes a message. Every context has
    -- `watch` — the loop's and a test's (`app.context`) alike.
    context.watch(time.after("150ms"))
    return {items = items, selected = 1, text = args or "Example", message = "Select a document", checked = true}
end
function definition.view(model: any, context: any): any
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Application from the registry · " .. context.width .. " × " .. context.height},
        {kind = "split", gap = 1, children = {
            {kind = "list", id = "documents", weight = 2, items = model.items, selected = model.selected},
            {kind = "column", weight = 3, gap = 1, children = {
                {kind = "label", size = 2, text = model.message},
                {kind = "input", id = "name", size = 2, text = model.text},
                {kind = "checkbox", id = "subfolders", size = 1, checked = model.checked, text = "Include subfolders"},
                {kind = "label", text = "Wheel · Page Down · Home / End"},
            }},
        }},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "show", size = 12, text = "Show", default = true},
            {kind = "button", id = "stop", size = 12, text = "Stop", disabled = true},
            {kind = "button", id = "crash", size = 11, text = "Crash"},
            {kind = "button", id = "close", size = 12, text = "Close"},
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
    elseif action.id == "crash" then error("on purpose: the \"Crash\" button")
    elseif action.type == "channel" then model.message = "channel fired"
    elseif action.id == "close" then context.close()
    else return false end
end
-- Esc closes the window: the loop does it for an Esc `update` did not take.
definition.close_on_escape = true
return {main = app.main(definition), definition = definition}
