-- Logon dialog: "Welcome to Windows" before the first desktop frame.
--
-- This is not a compositor window — it has neither a process nor a viewport:
-- the desktop is not up yet, and the first thing a person sees is this dialog
-- over the teal. But it is drawn by THE SAME means as real windows: the frame
-- and title are laid down by the theme (`chrome.window` in cells,
-- `chrome_pixels.paint` in pixels), the fields and buttons by the shared SDK
-- renderer through a view window. There is no layout and no editor of its
-- own here: a dialog drawn separately would diverge from "Run…" on the first
-- theme edit.
--
-- Input mechanics are the SDK's `ui.event`, as in any window: Tab between
-- fields, Enter in the name moves to the password, Enter in the password and
-- "OK" — log on, Esc and "Cancel" — refusal. The mouse arrives in screen
-- coordinates and is translated into client coordinates by the same theme
-- insets the window was drawn with.

local channel = require("channel")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local ui = require("ui")
local cells = require("cells")
local input = require("input")

local screen_lib = {}

local function num(value: any): number
    return tonumber(value) or 0
end

screen_lib.TITLE = "Welcome to Windows"
screen_lib.PROMPT = "Type a user name and password to log on to Windows."
screen_lib.ENTRY = "butschster.windows.logon:screen"
screen_lib.RENDER = "butschster.windows.sdk:render"

-- Client size, in cells — after the Windows 95 reference: a 32 px icon on
-- the left, the prompt and two fields in the middle, "OK" and "Cancel" in a
-- column on the right, with no blank row between them. The width is the sum
-- of the columns: padding, icon (4), gap, middle (label 11 + gap + field 22),
-- gap, buttons (10), padding. Height: padding, prompt, two fields of two rows
-- each, the refusal row; there is no padding at the bottom — there is a row
-- under the theme's frame anyway.
-- The frame at the top and bottom goes by the theme insets, so the window
-- height is computed, not hard-coded.
local CLIENT_W, CLIENT_H = 52, 7

-- Component tree. Pure data: no functions and no rasters, as the SDK requires.
function screen_lib.tree(model: any): any
    return {kind = "row", padding = 1, padding_bottom = 0, gap = 1, children = {
        {kind = "column", size = 4, children = {
            -- 32 px, like the key with the flag in the original; 16 px got lost in the column.
            {kind = "image", size = 2, image = "key", icon = "⚿", size_px = 32},
        }},
        {kind = "column", children = {
            {kind = "label", size = 1, text = screen_lib.PROMPT},
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = 11, text = "User name:"},
                {kind = "input", id = "user", text = model.user, disabled = model.busy},
            }},
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = 11, text = "Password:"},
                {kind = "input", id = "password", text = model.password, password = true, disabled = model.busy},
            }},
            {kind = "label", size = 1, text = model.busy and "Checking…" or (model.error or ""), alert = model.error ~= nil},
        }},
        {kind = "column", size = 10, gap = 0, children = {
            {kind = "button", id = "ok", size = 2, text = "OK", default = true, disabled = model.busy},
            {kind = "button", id = "cancel", size = 2, text = "Cancel", disabled = model.busy},
        }},
    }}
end

-- A dialog window in the centre of the screen, in the form both themes
-- understand: the same fields the compositor gives a view window. The
-- content is SDK state version 1.
local function window_for(theme: any, width: any, height: any, revision: any, tree: any, interaction: any): any
    local probe: any = {window_type = "dialog"}
    local inset: any = theme.window_insets(probe)
    local w = CLIENT_W + inset.left + inset.right
    local h = CLIENT_H + inset.top + inset.bottom
    if w > width then w = width end
    if h > height then h = height end
    return {
        id = "logon", entry = screen_lib.ENTRY, title = screen_lib.TITLE,
        window_type = "dialog", resizable = false, image = nil,
        content = "pixels", render = screen_lib.RENDER,
        content_state = {sdk = 1, revision = revision, ui = tree, interaction = interaction},
        state_revision = revision, waiting = false,
        x = math.max(1, (width - w) // 2 + 1), y = math.max(1, (height - h) // 2 + 1),
        w = w, h = h, minimized = false, maximized = false, closing = false,
        rows = nil,
    }
end

-- run(screen, authenticate) -> identity | nil, reason
--
-- `screen` is what `library.run` gives in `options.logon`; `authenticate` is
-- (login, password) -> identity | nil, reason.
function screen_lib.run(screen: any, authenticate: any): (any, any)
    local theme: any = screen.pixels and chrome_pixels or chrome
    local interaction = ui.interaction()
    local model: any = {user = "", password = "", error = nil, busy = false}
    -- Mutable loop state lives in a table, not in locals: after an error
    -- under pcall the closure and the owner see different values.
    local loop: any = {plan = nil, window = nil, inset = nil, revision = 0}

    local function draw()
        local width, height = screen.width, screen.height
        local canvas = screen.canvas
        loop.revision = loop.revision + 1
        local tree = screen_lib.tree(model)
        local window = window_for(theme, width, height, loop.revision, tree, interaction)
        local inset: any = theme.window_insets(window)
        local cols = math.max(1, num(window.w) - num(inset.left) - num(inset.right))
        local rows = math.max(1, num(window.h) - num(inset.top) - num(inset.bottom))
        loop.plan = ui.plan(tree, cols, rows, interaction)
        loop.window, loop.inset = window, inset

        if screen.pixels then
            local cell_w, cell_h = screen.cell()
            chrome_pixels.fill(canvas, width, height, {top = 0, bottom = height, items = {}, bare = true})
            local painted = chrome_pixels.paint({
                width = width, height = height, top = 0, bottom = height,
                windows = {window}, focused_id = window.id,
                items = {}, failure = nil, selected = nil, menu = nil,
                status = "", clock = "", hint = "", bare = true,
            }, cell_w, cell_h)
            screen.present(painted)
        else
            chrome.fill(canvas, width, height, {top = 1, bottom = height, items = {}})
            window.rows = cells.rows(loop.plan, interaction, cols, rows)
            chrome.window(canvas, window, true)
            screen.present(nil)
        end
    end

    -- The mouse — into the window's client coordinates. Negative and
    -- outside-the-window values are not dropped: releasing a button outside
    -- its bounds must reach the SDK, otherwise an armed button stays pressed.
    local function to_client(event: any): any
        local window, inset = loop.window, loop.inset
        if event.type ~= "mouse" or not window then return event end
        local copy: any = {}
        for key, value in pairs(event) do copy[key] = value end
        copy.x = (tonumber(event.x) or 0) - (window.x + inset.left) + 1
        copy.y = (tonumber(event.y) or 0) - (window.y + inset.top) + 1
        return copy
    end

    local function submit(): (any, any)
        if model.busy then return nil, nil end
        if model.user == "" then
            model.error = "Type a user name."
            interaction.focus = "user"
            draw()
            return nil, nil
        end
        model.busy, model.error = true, nil
        draw()
        local identity, why = authenticate(model.user, model.password)
        model.busy = false
        if identity then return identity, nil end
        -- The password does not survive a refusal: another attempt starts
        -- with an empty field, as in the original.
        model.password = ""
        model.error = tostring(why or "Logon failed.")
        interaction.focus = "password"
        draw()
        return nil, nil
    end

    draw()
    while true do
        local picked = channel.select({screen.events:case_receive()})
        if not picked.ok then return nil, "the terminal closed before logon" end
        local event = input.normalize(picked.value)
        if event.type == "close" then return nil, "logon cancelled" end
        if event.type == "resize" then
            screen.resize()
            draw()
        elseif event.type == "mouse" and event.action == "press" and event.button == "left"
            and theme.title_button_at(loop.window, event.x, event.y) == "close" then
            -- The close box in the title is the same "Cancel": the frame is
            -- drawn by the theme, and the hit on its button is computed by
            -- the theme too.
            return nil, "logon cancelled"
        else
            local action = ui.event(loop.plan, interaction, to_client(event))
            if action == nil then
                if event.type == "key" and event.action ~= "release" and event.key_type == "esc" then
                    return nil, "logon cancelled"
                end
                -- Arming and releasing a button change its look without an action.
                if event.type == "mouse" then draw() end
            elseif action.type == "change" and action.id == "user" then
                model.user = tostring(action.value or "")
                model.error = nil
                draw()
            elseif action.type == "change" and action.id == "password" then
                model.password = tostring(action.value or "")
                model.error = nil
                draw()
            elseif action.type == "activate" and action.id == "user" then
                -- Enter in the name leads to the password; an empty name is a
                -- hint in place, not a move into a field that is meaningless
                -- without a name.
                if model.user == "" then model.error = "Type a user name."
                else interaction.focus = "password" end
                draw()
            elseif action.type == "activate" and (action.id == "password" or action.id == "ok") then
                local identity = submit()
                if identity then return identity, nil end
            elseif action.type == "activate" and action.id == "cancel" then
                return nil, "logon cancelled"
            else
                draw()
            end
        end
    end
end

return screen_lib
