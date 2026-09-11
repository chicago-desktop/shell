-- "Display Properties", like Display Properties in Windows 95, two tabs.
--
-- "Background" is the desktop color: a list of colors and a preview
-- monitor; "Apply" and "OK" write the choice into the shell settings and ask
-- the compositor to reread the desktop (`desktop.refresh`), which repaints
-- the desktop and icons in both modes. There is no pattern and no wallpaper
-- on purpose: the desktop in pixel mode is cells, and a full-screen raster
-- would be resent on every change of a window on top of it.
--
-- "Settings" is resolution and palette, read-only: the compositor knows the
-- screen and cell size (`desktop.list`), the runtime forces the palette.
local app = require("app")
local desktop = require("desktop")
local repo = require("repo")
local model = require("model")
local geometry = require("geometry")
local whole = geometry.whole

local definition: any = {}

local function screen_info(): any
    local answer, err = desktop.list({timeout = "300ms"})
    if type(answer) ~= "table" then return {failure = err and tostring(err) or nil} end
    return {screen = answer.screen, cell = answer.cell, pixels = answer.pixels == true}
end

function definition.init(args: any, context: any): any
    local stored, err = repo.setting("desktop_color")
    local chosen = model.valid(stored) and stored or model.DEFAULT
    return {tab = 1, chosen = chosen, saved = chosen, info = screen_info(),
        failure = err and ("settings not read: " .. tostring(err)) or nil,
        -- The write and the request to the compositor are moved into a
        -- field: the test substitutes its own and checks that "Apply" calls
        -- them, without a database.
        persist = function(hex: any)
            local _, werr = repo.set_setting("desktop_color", hex)
            if werr then return nil, tostring(werr) end
            local _, rerr = desktop.request("desktop.refresh", {})
            if rerr then return nil, "desktop not refreshed: " .. tostring(rerr) end
            return true, nil
        end}
end

local function background(state: any): any
    return {kind = "column", gap = 0, children = {
        {kind = "monitor", size = 8, color = state.chosen},
        {kind = "row", gap = 1, children = {
            {kind = "group", title = "Desktop color", children = {
                {kind = "list", id = "colors", items = model.color_items(state.chosen), selected = state.chosen},
            }},
            {kind = "column", size = 22, children = {
                {kind = "label", size = 1, text = ""},
                {kind = "label", size = 1, text = "Selected: " .. tostring(state.chosen)},
                {kind = "label", size = 1, text = state.chosen ~= state.saved and "Not applied" or "Applied"},
                {kind = "label", text = state.failure or "", alert = state.failure ~= nil},
            }},
        }},
    }}
end

local function settings(state: any): any
    local info: any = state.info or {}
    return {kind = "column", gap = 0, children = {
        {kind = "monitor", size = 8, color = state.saved},
        {kind = "row", gap = 1, children = {
            {kind = "group", title = "Color palette", children = {
                {kind = "field", size = 2, text = model.palette()},
                {kind = "label", size = 1, text = model.graphics(info.pixels)},
                {kind = "label", text = "Set by the runtime."},
            }},
            {kind = "group", title = "Screen resolution", children = {
                {kind = "field", size = 2, text = model.resolution(info.screen, info.cell)},
                {kind = "label", size = 1, text = info.failure and ("the compositor did not answer: " .. tostring(info.failure)) or model.cell_text(info.cell), alert = info.failure ~= nil},
                {kind = "label", text = "Set by the terminal."},
            }},
        }},
    }}
end

function definition.view(state: any, context: any): any
    local labels = {}
    for index, tab in ipairs(model.TABS) do labels[index] = tab.text end
    local page: any = state.tab == 2 and settings(state) or background(state)
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "tabs", id = "pages", labels = labels, active = state.tab, padding = 1, children = {page}},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "ok", size = 10, text = "OK", default = true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
            {kind = "button", id = "apply", size = 12, text = "Apply", disabled = state.chosen == state.saved},
        }},
    }}
end

local function apply(state: any): boolean
    if state.chosen == state.saved then return true end
    local ok, err = state.persist(state.chosen)
    if not ok then
        state.failure = tostring(err)
        return false
    end
    state.saved = state.chosen
    state.failure = nil
    return true
end

function definition.update(state: any, action: any, context: any)
    if action.id == "pages" and action.type == "select" then state.tab = whole(action.index)
    elseif action.id == "colors" and (action.type == "select" or action.type == "activate") then
        local item: any = action.value
        if type(item) == "table" and model.valid(item.id) then state.chosen = item.id end
    elseif action.id == "apply" then apply(state)
    elseif action.id == "ok" then
        if apply(state) then context.close() end
    elseif action.id == "cancel" then context.close()
    else return false end
end

-- Esc closes the window: the loop does it for an Esc `update` did not take.
definition.close_on_escape = true

return {main = app.main(definition), definition = definition}
