-- "Run" is a dialog on the shell SDK.
--
-- Interface: an icon, a hint, the "Open:" field, "OK" and "Cancel". Launching
-- is only by a request to the compositor (`desktop.open` via `request`): the
-- window has no permission to spawn processes, and the compositor brings up
-- Bash under a PTY. The reply to the request arrives on its own channel,
-- `context.watch(desktop.replies())`, so the window does not freeze while the
-- compositor opens the window.
local desktop = require("desktop")
local app = require("app")
local model = require("model")

local definition: any = {}

-- The request to the compositor goes through a field, not directly: the test
-- substitutes it and checks the request's shape and the parsing of the reply
-- without a live compositor.
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

-- The "My Computer" window is what "Browse…" opens: a program or a document
-- is looked for here in the shell's explorer. It does not put a path back
-- into the field (the explorer has no "pick a file" mode), so "Browse…" is a
-- road to the explorer, not a picker dialog.
local EXPLORER = "butschster.windows.explorer:window"

-- The window title is "Run", without an ellipsis: the ellipsis belongs to the
-- menu item, it promises a dialog, and the dialog itself is named without
-- it, as in Windows.
definition.title = "Run"

function definition.view(state: any, context: any): any
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "image", size = 4, image = "run", icon = "▸", size_px = 32},
            -- A failure takes the place of the hint: a separate line under the
            -- buttons pushed them away from the frame, and the hint is not
            -- needed at the moment of a failure.
            {kind = "label", text = state.failure or "Type the name of a program, folder, or document, and\nWindows will open it for you.",
                alert = state.failure ~= nil},
        }},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", size = 5, text = "Open:"},
            {kind = "input", id = "command", text = state.text},
        }},
        -- Buttons in a row always go to the right edge (a shell rule): an
        -- empty label without a size takes the remainder on the left. Right
        -- under the field, with no line between them, as in Windows 95.
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

-- "Browse…" asks the compositor to open the explorer and waits for the reply
-- on THE SAME channel as the launch. `state.browsing` tells them apart: the
-- reply for the explorer must not close the dialog, and the reply for the
-- launch must not silently vanish.
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
