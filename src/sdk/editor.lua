local text = require("text")
local geometry = require("geometry")
local editor = {}
-- One UTF-8 parse for the whole window, taken from the base; the name is kept for callers.
editor.runes = text.runes
local whole = geometry.whole
function editor.event(text: any, state: any, event: any): (any, any)
    local chars: {string} = editor.runes(text)
    state.cursor = whole(math.max(0, math.min(#chars, whole(state.cursor))))
    local key = event.action ~= "release" and (event.key_type or event.key) or nil
    local inserted: any = nil
    if event.type == "paste" then inserted = tostring(event.text or ""):gsub("[\r\n]", " ")
    elseif key == "runes" and event.ctrl and event.key == "a" then state.selected = true
    elseif key == "runes" and not event.ctrl and not event.alt then inserted = tostring(event.key or "")
    elseif key == "left" then state.cursor = math.max(0, state.cursor - 1); state.selected = false
    elseif key == "right" then state.cursor = math.min(#chars, state.cursor + 1); state.selected = false
    elseif key == "home" then state.cursor = 0; state.selected = false
    elseif key == "end" then state.cursor = #chars; state.selected = false
    elseif key == "backspace" or key == "delete" then
        if state.selected then chars, state.cursor, state.selected = {}, 0, false
        elseif key == "backspace" and state.cursor > 0 then table.remove(chars, whole(state.cursor)); state.cursor = state.cursor - 1
        elseif key == "delete" and state.cursor < #chars then table.remove(chars, whole(state.cursor + 1)) end
        return table.concat(chars), "change"
    elseif key == "enter" then return text, "activate" end
    if inserted then
        if state.selected then chars, state.cursor, state.selected = {}, 0, false end
        for _, char in ipairs(editor.runes(inserted)) do
            state.cursor = state.cursor + 1
            table.insert(chars, whole(state.cursor), char)
        end
        return table.concat(chars), "change"
    end
    return text, nil
end
-- The field's text as it is shown: a password shows asterisks, one per
-- rune, so that the caret and the selection are counted over the same
-- positions. The value itself stays in `node.text`, and editing works on it.
function editor.shown(node: any): string
    local value = tostring(node.text or "")
    if node.password then return string.rep("*", #editor.runes(value)) end
    return value
end
-- Cell-width conservative visible suffix around the caret. Renderers share it.
function editor.visible(text: any, editing: any, columns: any): (any, any)
    local chars: {string} = editor.runes(text)
    local cursor = whole(math.max(0, math.min(#chars, editing and editing.cursor or #chars)))
    local room = whole(math.max(1, columns - 2))
    local first = whole(math.max(1, cursor - room + 2))
    return table.concat(chars, "", first, whole(math.min(#chars, first + room - 1))), cursor - first + 1
end
return editor
