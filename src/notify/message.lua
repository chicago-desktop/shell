-- A message from a service that has no window of its own — "net send", a
-- message box: the title on the caption and beside the picture, the text
-- under it, one OK button (or the caller's caption). OK or Esc closes it.
--
-- `chicago.shell.sdk:notify` opens it (`notify.message`), one window per
-- call, with JSON args `{title, text, icon?, button?, bell?}`: the compositor
-- carries a window's args only as a string. Args that do not read as that
-- are not a crash and not an empty window: the window says what was wrong.
-- `bell` is kept and not rung — the runtime's surface has no bell to ring
-- (the base's README, `desktop.balloon`).
local json = require("json")
local app = require("app")
local ui = require("ui")
local text = require("text")
local geometry = require("geometry")

local whole = geometry.whole

local definition: any = {close_on_escape = true}

-- The pictures: the shell's pack in pixels, a letter in cells.
local IMAGES: any = {info = "info", warning = "warning", error = "error"}
local GLYPHS: any = {info = "i", warning = "!", error = "×"}
-- A button's caption at most, in characters: the button is sized by it.
local BUTTON_TEXT = 24
-- The rows around the text: the padding above and below, the picture row,
-- the button row and one blank row before it (`ui.message`'s layout).
local AROUND = 2 + 4 + 2 + 1

-- read(args) -> the message, or the message saying why it could not be read.
local function read(args: any): any
    local failed = {title = "Message", icon = "error", button = "OK", bell = false}
    if type(args) ~= "string" or args == "" then
        failed.text = "The message came without its text."
        return failed
    end
    local decoded, err = json.decode(args)
    if type(decoded) ~= "table" then
        failed.text = "The message could not be read: " .. tostring(err or "not a JSON object")
        return failed
    end
    local given: any = decoded
    return {
        title = type(given.title) == "string" and given.title ~= "" and given.title or "Message",
        text = type(given.text) == "string" and given.text or "",
        icon = type(given.icon) == "string" and IMAGES[given.icon] ~= nil and given.icon or nil,
        button = type(given.button) == "string" and given.button ~= "" and text.clip(given.button, BUTTON_TEXT) or "OK",
        bell = given.bell == true,
    }
end

-- lines(value, width, limit) -> the text in lines of at most `width` cells,
-- `limit` lines at most, the last one ending in "…" when the text was cut. A
-- line break in the text starts a new line; a word wider than a line is cut.
local function lines(value: any, width: integer, limit: integer): any
    local out: any = {}
    local state: any = {cut = false}
    local function push(line: string): boolean
        if #out >= limit then
            state.cut = true
            return false
        end
        out[#out + 1] = line
        return true
    end
    -- Built before the loop, not in its header: an `or` in a generic for's
    -- expression list reached the concat as nil here (go-lua).
    local source = tostring(value or "") .. "\n"
    for paragraph in source:gmatch("([^\n]*)\n") do
        local line = ""
        local any_word = false
        for word in paragraph:gmatch("%S+") do
            any_word = true
            local candidate = line == "" and word or (line .. " " .. word)
            if text.cells(candidate) <= width then
                line = candidate
            else
                if line ~= "" and not push(line) then break end
                line = text.clip(word, width)
            end
        end
        if state.cut then break end
        if (line ~= "" or not any_word) and not push(line) then break end
    end
    -- The text's own last line break leaves an empty paragraph behind: not a line.
    if #out > 1 and out[#out] == "" then out[#out] = nil end
    if state.cut and #out > 0 then
        local last = tostring(out[#out])
        if text.cells(last) >= width then last = text.clip(last, width - 1) end
        out[#out] = last .. "…"
    end
    return out
end

definition.lines = lines

function definition.init(args: any, context: any): any
    return read(args)
end

-- The caption is the message's title: the entry's "Message" says nothing.
function definition.title(model: any): any
    return model.title
end

function definition.view(model: any, context: any): any
    local width = math.max(8, whole(context.width) - 2)
    local room = math.max(1, whole(context.height) - AROUND)
    return ui.message({
        title = model.title,
        lines = lines(model.text, width, room),
        image = model.icon and IMAGES[model.icon] or nil,
        icon = model.icon and GLYPHS[model.icon] or nil,
        buttons = {{id = "message_ok", text = model.button, default = true}},
    })
end

function definition.update(model: any, action: any, context: any): any
    if action.type == "activate" and action.id == "message_ok" then
        context.close()
        return true
    end
    -- Anything else changes nothing; Esc falls through to close_on_escape.
    return false
end

return {main = app.main(definition), definition = definition}
