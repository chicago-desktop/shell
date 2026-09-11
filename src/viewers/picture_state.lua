-- Image viewer: state provider.
--
-- The live half of a view window (FR-005 §4b). The compositor starts it with
-- three arguments — its own name, the window number and the open argument —
-- and from then on the provider is on its own: it reads the file under its
-- own permissions, pushes the state, and answers input, which the compositor
-- forwards to it as a `window.input` message, with a new state. It does not
-- draw.
--
-- The picture travels in the state whole, as base64. This is the price for
-- the compositor having no permission on drives: it receives the bytes from
-- whoever has the permission, and does not receive the permission. A file
-- larger than `files.MAX_IMAGE` is not opened — with a reason, not with an
-- empty window.

local base64 = require("base64")
local channel = require("channel")
local desktop_api = require("desktop")
local gfx = require("gfx")
local scroll = require("scroll")

local files = require("files")

local ZOOMS = {0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4}
local PAN_STEP = 48



local geometry = require("geometry")
local whole = geometry.whole

-- The caption is what is visible in any mode, including cells, where there
-- is no way to show the picture. That is why it is assembled here and not in
-- the drawing.
local function caption(state: any): string
    if state.failure then return tostring(state.failure) end
    local how = state.mode == "zoom" and string.format("%d%%", whole((tonumber(state.zoom) or 1) * 100))
        or "fit to window"
    return string.format("%s · %s · %s · +/- zoom, 1 — 100%%, 0 — fit, arrows — pan",
        tostring(state.name), files.human_size(state.size), how)
end

local function zoom_index(zoom: any): integer
    local best, best_at = 4, math.huge
    for index, value in ipairs(ZOOMS) do
        local gap = math.abs(value - (tonumber(zoom) or 1))
        if gap < best_at then best, best_at = index, gap end
    end
    return best
end

local function main(desktop, window_id, args, viewport: any)
    local inbox = assert(desktop_api.inputs())
    viewport = viewport or {width = 1, height = 1, cell_w = 8, cell_h = 18}
    local source_w, source_h = 0, 0

    local state: any = {
        mode = "fit", zoom = 1, x = 0, y = 0,
        name = "", size = 0, drive = "", path = "",
        data = nil, failure = nil, caption = "",
    }

    local file, why = files.parse(args)
    if not file then
        state.failure = why
    else
        state.name, state.drive, state.path = file.name, file.drive, file.path
        local bytes, read_err = files.read(file.drive, file.path, files.MAX_IMAGE)
        if not bytes then
            state.failure = read_err
        else
            state.size = #bytes
            local raster, decode_error = gfx.image(bytes :: string)
            if raster then
                source_w, source_h = raster:size()
                state.data = base64.encode(bytes :: string)
            else state.failure = "picture not opened: " .. tostring(decode_error) end
        end
    end

    local function push()
        state.caption = caption(state)
        local scale = state.mode == "zoom" and state.zoom or 0
        state.x = scroll.clamp(state.x, math.floor(source_w * scale + 0.5), viewport.width * viewport.cell_w)
        state.y = scroll.clamp(state.y, math.floor(source_h * scale + 0.5), viewport.height * viewport.cell_h)
        assert(desktop_api.publish_state(window_id, state))
    end

    push()

    -- Input changes only the display mode. The file is read once: the picture
    -- does not change from a key press, and rereading it on each one means
    -- keeping the drive busy for the sake of scrolling.
    local function handle(event: any): boolean
        if type(event) ~= "table" or state.failure then return false end
        if event.type == "key" and event.action ~= "release" then
            local key = tostring(event.key or "")
            if key == "+" or key == "=" then
                state.mode = "zoom"
                state.zoom = ZOOMS[math.min(#ZOOMS, zoom_index(state.zoom) + 1)]
                return true
            elseif key == "-" then
                state.mode = "zoom"
                state.zoom = ZOOMS[math.max(1, zoom_index(state.zoom) - 1)]
                return true
            elseif key == "1" then
                state.mode, state.zoom = "zoom", 1
                return true
            elseif key == "0" or key == "f" then
                state.mode, state.x, state.y = "fit", 0, 0
                return true
            elseif key == "left" then
                state.x = math.max(0, whole(state.x) - PAN_STEP); return true
            elseif key == "right" then
                state.x = whole(state.x) + PAN_STEP; return true
            elseif key == "up" then
                state.y = math.max(0, whole(state.y) - PAN_STEP); return true
            elseif key == "down" then
                state.y = whole(state.y) + PAN_STEP; return true
            elseif key == "home" then
                state.x, state.y = 0, 0; return true
            end
        elseif event.type == "mouse" and event.action == "wheel" then
            if event.button == "wheel_up" then
                state.y = math.max(0, whole(state.y) - PAN_STEP); return true
            elseif event.button == "wheel_down" then
                state.y = whole(state.y) + PAN_STEP; return true
            end
        end
        return false
    end

    while true do
        local picked = channel.select({inbox:case_receive()})
        if not picked.ok then break end
        local message = picked.value
        if message:topic() == "window.input" then
            local event = desktop_api.input_event(message)
            if event.type == "close" then break end
            if event.type == "resize" then viewport = {width = event.width, height = event.height, cell_w = event.cell_w, cell_h = event.cell_h}; push()
            elseif handle(event) then push() end
        end
    end
end

return {main = main}
