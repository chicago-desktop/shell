-- Просмотр картинок: поставщик состояния.
--
-- Живая половина окна-вида (FR-005 §4б). Композитор запускает его с тремя
-- аргументами — своим именем, номером окна и аргументом открытия — и дальше
-- поставщик сам: читает файл под своими правами, толкает состояние, а на
-- ввод, который композитор пересылает ему сообщением `window.input`,
-- отвечает новым состоянием. Рисует не он.
--
-- Картинка едет в состоянии целиком, base64. Это плата за то, что у
-- композитора нет права на диски: он получает байты от того, у кого право
-- есть, и не получает права. Файл больше `files.MAX_IMAGE` не открывается —
-- с причиной, а не пустым окном.

local base64 = require("base64")
local channel = require("channel")
local process = require("process")

local files = require("files")

local ZOOMS = {0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4}
local PAN_STEP = 48

local function body_of(message: any): any
    local body: any = message:payload()
    if type(body) == "userdata" then
        local ok, decoded = pcall(function() return body:data() end)
        body = ok and decoded or {}
    end
    if type(body) == "table" and body[1] ~= nil and #body > 0 then body = body[1] end
    return type(body) == "table" and body or {}
end

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Подпись — то, что видно в любом режиме, включая ячейки, где картинку
-- показать нечем. Поэтому она собирается здесь, а не в отрисовке.
local function caption(state: any): string
    if state.failure then return tostring(state.failure) end
    local how = state.mode == "zoom" and string.format("%d%%", whole((tonumber(state.zoom) or 1) * 100))
        or "по размеру окна"
    return string.format("%s · %s · %s · +/- масштаб, 1 — 100%%, 0 — по окну, стрелки — сдвиг",
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

local function main(desktop, window_id, args)
    local inbox = process.inbox()

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
            state.data = base64.encode(bytes :: string)
        end
    end

    local function push()
        state.caption = caption(state)
        process.send(tostring(desktop), "desktop.state", {
            id = tostring(window_id),
            state = state,
        })
    end

    push()

    -- Ввод меняет только способ показа. Файл прочитан один раз: картинка не
    -- меняется от нажатия клавиши, а перечитывать её на каждое — значит
    -- держать диск занятым ради прокрутки.
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
            local body = body_of(message)
            if handle(body.event) then push() end
        end
    end
end

return {main = main}
