local text = require("text")
local geometry = require("geometry")
local editor = {}
-- Один разбор UTF-8 на всё окно — из основы; имя оставлено вызывающим.
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
-- Текст поля так, как его показывают: у пароля — звёздочки, по одной на
-- руну, чтобы каретка и выделение считались по тем же позициям. Само
-- значение остаётся в `node.text`, редактирование идёт по нему.
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
