-- «Мой компьютер» — окно, показывающее сам стенд.
--
-- НЕЗАКОНЧЕНО И НАМЕРЕННО НЕ ОБЪЯВЛЕНО В РЕЕСТРЕ. Работа остановлена по
-- просьбе человека; файл оставлен целым, но записи процесса для него нет ни в
-- одном `_index.yaml`, поэтому на боот и на `wippy lint` он не влияет никак.
--
-- Чтобы продолжить, нужны четыре вещи, и все они названы в отчёте координатору:
--   1) запись процесса `butschster.windows.explorer:window` с
--      `meta.type: tui_desktop.window`, своей политикой и модулями
--      [channel, process, time, tty, sql, env, uuid, registry];
--   2) своя политика окна: process.context, process.send, process.registry,
--      db.get, registry.get, registry.find — без spawn и exec;
--   3) `sources.list` для пути `desktop/<id>` — содержимое папки стола;
--   4) `defaults.lua`: «Мой компьютер» должен вести сюда, а не на обозреватель
--      стенда `butschster.tui_desktop.apps:commander`.
--
-- Проверено глазами, но НЕ запуском: окно ни разу не поднималось.
--
-- Рисует ТОЛЬКО своё содержимое: строку меню, панель инструментов, поле со
-- значками и статусную строку. Рамка, заголовок и кнопки заголовка — хром, он
-- за темой; композитор отдаёт окну весь прямоугольник внутри рамки, и что там
-- нарисовано — дело окна.
--
-- Примитивы общие с темой (`widgets`, `icons`): свои значило бы завести
-- вторую, чуть другую кнопку, и внутри окна Windows 95 оказалась бы другая
-- Windows. Разошлись бы они видом, а не отказом, — то есть заметили бы через
-- неделю.

local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local icons = require("icons")
local model = require("model")
local sources = require("sources")
local widgets = require("widgets")

-- Композитор, которому окно шлёт просьбы. Это НЕ имя основы: под второй
-- оболочкой композитор зарегистрирован своим именем, и библиотека основы
-- `window_api` с зашитым `butschster.tui_desktop.desktop` сюда не годится —
-- она искала бы чужой процесс и молча ничего не делала.
local SHELL_SERVICE = "butschster.windows.shell"
local REPLY_TOPIC = "desktop.reply"

-- Тот же порог, что у композитора на столе: одинаковый двойной щелчок в двух
-- местах одной оболочки — это не совпадение чисел, а одно поведение.
local DOUBLE_CLICK_NS = 500000000

local MENU = {
    {text = "Файл", accel = 1},
    {text = "Правка", accel = 1},
    {text = "Вид", accel = 1},
    {text = "Справка", accel = 1},
}

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local function main()
    -- Подписка до старта: start() эмитит первое событие, и подписчик должен
    -- уже существовать.
    local events = assert(tty.events())
    assert(tty.start())

    local out = assert(tty.surface({hide_cursor = true, synchronized_output = true}))
    local inbox = process.inbox()

    local width, height = tty.screen_size()
    width, height = whole(width), whole(height)
    -- Нулевой размер — не редкость: окно может подняться раньше, чем
    -- композитор сообщил геометрию. Нулевой холст роняет отрисовку на первой
    -- строке, поэтому размеры по умолчанию не «на всякий случай», а
    -- обязательны.
    if width < 20 then width = 60 end
    if height < 8 then height = 18 end

    local grid = icons.grid()

    local state: any = {
        path = model.ROOT,
        title = "Мой компьютер",
        objects = {},
        failure = nil,
        selected = 0,
        -- Список открытых окон приносит ответ композитора, а не библиотека:
        -- цикл ожидания ответа забрал бы из inbox и чужие сообщения тоже, а
        -- съеденная команда композитора неотличима от неполученной.
        windows = nil,
        windows_error = nil,
    }
    local cells: any = {}
    local last_click: any = {x = 0, y = 0, at = 0}

    local function shell_pid()
        local pid = process.registry.lookup(SHELL_SERVICE)
        return pid
    end

    local function ask(topic, body: any)
        local pid = shell_pid()
        if not pid then return false, "оболочка не отвечает" end
        body = type(body) == "table" and body or {}
        local sent, serr = process.send(pid, topic, body)
        if not sent then return false, tostring(serr) end
        return true, nil
    end

    -- ─── содержимое ──────────────────────────────────────────────────────

    local function load()
        state.selected = 0
        if state.path == model.ROOT then
            local counts = sources.counts()
            -- Открытые окна считает не `sources`: их знает только композитор,
            -- и число приезжает вместе со списком.
            if state.windows then (counts :: any).windows = #state.windows end
            state.objects = model.root(counts)
            state.failure = nil
            state.title = "Мой компьютер"
            return
        end

        if state.path == "windows" then
            state.title = "Открытые окна"
            if state.windows_error then
                state.objects, state.failure = {}, state.windows_error
            elseif state.windows then
                state.objects, state.failure = model.windows(state.windows), nil
            else
                -- Ещё не ответили — это не пустая папка и не отказ. Сказать
                -- «объектов нет» здесь значит соврать на четверть секунды, и
                -- человек успеет это прочитать.
                state.objects, state.failure = {}, "спрашиваем оболочку…"
            end
            return
        end

        local objects, err = sources.list(state.path)
        state.title = state.path == "programs" and "Программы" or "Рабочий стол"
        if err or not objects then
            state.objects, state.failure = {}, err or "не прочитано"
        else
            state.objects, state.failure = objects, nil
        end
    end

    local function go(path)
        state.path = path
        if path == "windows" then
            state.windows, state.windows_error = nil, nil
            local ok, err = ask("desktop.list", {reply_to = process.pid()})
            if not ok then state.windows_error = tostring(err) end
        end
        load()
    end

    local function activate(object: any)
        if type(object) ~= "table" or type(object.open) ~= "table" then return end
        local open = object.open
        if open.action == "folder" then
            go(open.path)
        elseif open.action == "open_window" then
            ask("desktop.open", {
                entry = open.entry, title = open.title,
                w = open.w, h = open.h, args = open.args,
            })
        elseif open.action == "raise" then
            ask("desktop.raise", {id = open.id})
        end
    end

    -- ─── отрисовка ───────────────────────────────────────────────────────

    local function draw()
        local canvas = tty.canvas(width, height)
        canvas:clear(widgets.styles.face:render(" "))

        widgets.menu_bar(canvas, 1, 1, width, MENU)
        widgets.toolbar(canvas, 1, 2, width, {
            {icon = "↑", label = "Вверх"},
            {sep = true},
            {icon = "⟳", label = "Обновить"},
        })

        -- Поле списка: вдавленная рамка от темы, белая изнанка своя. Значки
        -- лежат на белом, как в проводнике, а не на сером лице панели.
        local field_top, field_bottom = 3, height - 1
        local field_h = field_bottom - field_top + 1
        widgets.field(canvas, 1, field_top, width, field_h)

        local inner_x, inner_y = 2, field_top + 1
        local inner_w, inner_h = width - 2, field_h - 2
        if inner_w > 0 and inner_h > 0 then
            local blank = widgets.styles.field:render(string.rep(" ", inner_w))
            for row = 0, inner_h - 1 do canvas:put(inner_x, inner_y + row, blank, inner_w) end
        end

        cells = {}
        if state.failure then
            canvas:put(inner_x + 1, inner_y,
                widgets.fit(widgets.styles.field, tostring(state.failure), inner_w - 2), inner_w - 2)
        else
            local columns = inner_w // grid.w
            if columns < 1 then columns = 1 end
            local rows = inner_h // grid.h
            if rows < 1 then rows = 1 end

            for index, object in ipairs(state.objects) do
                local slot = index - 1
                local column = slot % columns
                local row = slot // columns
                if row < rows then
                    -- Прямоугольник попадания берётся у `icons.cell`, а не
                    -- считается своей формулой: посчитанный отдельно, он
                    -- разъедется с рисунком, и щелчок попадёт на соседа.
                    local box = icons.cell(canvas,
                        inner_x + column * grid.w, inner_y + row * grid.h,
                        object,
                        {surface = "panel", room = grid.w, selected = index == state.selected})
                    if box then
                        cells[#cells + 1] = {
                            index = index, from = box.from, to = box.to,
                            top = box.top, bottom = box.bottom,
                        }
                    end
                end
            end
        end

        -- Счётчик — содержимое окна, а не хрома: он пересчитывается на каждое
        -- открытие папки, и канал «окно сообщает теме свою строку» означал бы,
        -- что композитор знает про устройство чужого окна.
        local count = state.failure and "—" or (tostring(#state.objects) .. " объектов")
        widgets.statusbar(canvas, 1, height, width, {
            {text = count, width = 16},
            {text = state.title},
        })

        assert(out:present(canvas:rows()))
    end

    -- ─── ввод ────────────────────────────────────────────────────────────

    local function move(delta)
        if #state.objects == 0 then return end
        local next_index = state.selected + delta
        if next_index < 1 then next_index = 1 end
        if next_index > #state.objects then next_index = #state.objects end
        state.selected = next_index
    end

    local function columns_now()
        local inner_w = width - 2
        local columns = inner_w // grid.w
        if columns < 1 then columns = 1 end
        return columns
    end

    local function handle_key(event: any)
        local key = event.key_type or event.key
        if key == "enter" then
            activate(state.objects[state.selected])
        elseif key == "backspace" then
            if state.path ~= model.ROOT then go(model.ROOT) end
        elseif key == "right" then
            move(1)
        elseif key == "left" then
            move(-1)
        elseif key == "down" then
            move(columns_now())
        elseif key == "up" then
            move(-columns_now())
        elseif event.key == "r" and event.ctrl then
            load()
        end
        draw()
    end

    local function spot(x: any, y: any)
        for _, cell in ipairs(cells) do
            if x >= cell.from and x <= cell.to and y >= cell.top and y <= cell.bottom then
                return cell.index
            end
        end
        return nil
    end

    local function handle_mouse(event: any)
        if event.action ~= "press" then return end

        -- Панель инструментов: «Вверх» — единственная кнопка, у которой есть
        -- что делать в первой версии. Кнопка, которая ничего не делает, —
        -- бутафория, и первое, что о ней спросят, почему она не работает;
        -- поэтому их всего две.
        if event.y == 2 then
            if event.x <= 10 then
                if state.path ~= model.ROOT then go(model.ROOT) end
            else
                load()
            end
            draw()
            return
        end

        local moment = time.now():unix_nano()
        local repeated = last_click.x == event.x and last_click.y == event.y
            and (moment - last_click.at) < DOUBLE_CLICK_NS
        last_click = {x = event.x, y = event.y, at = moment}

        local index = spot(event.x, event.y)
        if not index then
            state.selected = 0
            draw()
            return
        end

        state.selected = index
        -- Двойной щелчок открывает, одиночный выделяет. Программа, стартующая
        -- с одного клика, — ловушка: человек ведёт мышь по списку и запускает
        -- всё, чего коснулся.
        if repeated then activate(state.objects[index]) end
        draw()
    end

    load()
    draw()

    while true do
        local selected = channel.select({events:case_receive(), inbox:case_receive()})
        if not selected.ok then break end

        if selected.channel == inbox then
            local message = selected.value
            -- Ответ разбирает собственный цикл окна. Библиотека запрос-ответ
            -- забрала бы из inbox и команды композитора тоже, а съеденная
            -- команда неотличима от неполученной.
            if message:topic() == REPLY_TOPIC then
                local payload: any = message:payload()
                if type(payload) == "userdata" then
                    local ok, decoded = pcall(function() return payload:data() end)
                    payload = ok and decoded or {}
                end
                if type(payload) == "table" and payload[1] ~= nil and #payload > 0 then
                    payload = payload[1]
                end
                local body: any = type(payload) == "table" and payload or {}
                state.windows = type(body.windows) == "table" and body.windows or {}
                state.windows_error = nil
                if state.path == "windows" or state.path == model.ROOT then load() end
                draw()
            end
        else
            local event: any = selected.value
            if event.type == "close" then
                break
            elseif event.type == "resize" then
                local w, h = tty.screen_size()
                w, h = whole(w), whole(h)
                if w >= 20 then width = w end
                if h >= 8 then height = h end
                draw()
            elseif event.type == "key" then
                handle_key(event)
            elseif event.type == "mouse" then
                handle_mouse(event)
            end
        end
    end

    tty.stop()
end

return {main = main}
