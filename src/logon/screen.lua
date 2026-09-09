-- Диалог входа: «Вход в Windows» до первого кадра стола.
--
-- Это не окно композитора — ни процесса, ни viewport у него нет: стол ещё не
-- поднят, и первое, что видит человек, — этот диалог поверх бирюзового.
-- Но рисуется он ТЕМ ЖЕ, чем настоящие окна: рамку и заголовок кладёт тема
-- (`chrome.window` в ячейках, `chrome_pixels.paint` в пикселях), поля и
-- кнопки — общий отрисовщик SDK через окно-вид. Своей раскладки и своего
-- редактора здесь нет: диалог, нарисованный отдельно, разошёлся бы с
-- «Выполнить…» на первой правке темы.
--
-- Механика ввода — `ui.event` SDK, как в любом окне: Tab между полями, Enter
-- в имени переводит в пароль, Enter в пароле и «OK» — вход, Esc и «Отмена» —
-- отказ. Мышь приходит в координатах экрана и переводится в клиентские по
-- тем же инсетам темы, по которым окно и нарисовано.

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

-- Размер клиента, в ячейках: отступ, подсказка, два поля по две строки,
-- строка отказа, отступ — восемь строк. Рамка сверху и снизу — по инсетам
-- темы, поэтому высота окна считается, а не приколочена.
local CLIENT_W, CLIENT_H = 66, 8

-- Дерево компонентов. Чистые данные: без функций и растров, как требует SDK.
function screen_lib.tree(model: any): any
    return {kind = "row", padding = 1, gap = 1, children = {
        {kind = "column", size = 7, children = {
            {kind = "image", size = 3, image = "key", icon = "⚿"},
        }},
        {kind = "column", children = {
            {kind = "label", size = 1, text = screen_lib.PROMPT},
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = 18, text = "User name:"},
                {kind = "input", id = "user", text = model.user, disabled = model.busy},
            }},
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = 18, text = "Password:"},
                {kind = "input", id = "password", text = model.password, password = true, disabled = model.busy},
            }},
            {kind = "label", size = 1, text = model.busy and "Checking…" or (model.error or ""), alert = model.error ~= nil},
        }},
        {kind = "column", size = 12, gap = 1, children = {
            {kind = "button", id = "ok", size = 2, text = "OK", default = true, disabled = model.busy},
            {kind = "button", id = "cancel", size = 2, text = "Cancel", disabled = model.busy},
        }},
    }}
end

-- Окно-диалог по центру экрана в форме, которую понимают обе темы: те же
-- поля, что композитор даёт окну-виду. Содержимое — состояние SDK версии 1.
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

-- run(screen, authenticate) -> identity | nil, причина
--
-- `screen` — то, что даёт `library.run` в `options.logon`; `authenticate` —
-- (login, password) -> identity | nil, причина.
function screen_lib.run(screen: any, authenticate: any): (any, any)
    local theme: any = screen.pixels and chrome_pixels or chrome
    local interaction = ui.interaction()
    local model: any = {user = "", password = "", error = nil, busy = false}
    -- Изменяемое состояние цикла — в таблице, а не в локальных: после
    -- ошибки под pcall замыкание и владелец видят разные значения.
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

    -- Мышь — в клиентские координаты окна. Отрицательные и заоконные
    -- значения не отбрасываются: отпускание кнопки за её пределами обязано
    -- дойти до SDK, иначе взведённая кнопка останется нажатой.
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
        -- Пароль не переживает отказ: ещё одна попытка начинается с пустого
        -- поля, как в оригинале.
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
            -- Крестик в заголовке — та же «Отмена»: рамку рисует тема, и
            -- попадание в её кнопку считает тоже она.
            return nil, "logon cancelled"
        else
            local action = ui.event(loop.plan, interaction, to_client(event))
            if action == nil then
                if event.type == "key" and event.action ~= "release" and event.key_type == "esc" then
                    return nil, "logon cancelled"
                end
                -- Взвод и отпускание кнопки меняют её вид без действия.
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
                -- Enter в имени ведёт в пароль; пустое имя — подсказка на месте,
                -- а не переход в поле, которое без имени бессмысленно.
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
