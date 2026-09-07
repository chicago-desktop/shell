-- «Мой компьютер» — окно, показывающее сам стенд.
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
--
-- Окно не читает ни базы, ни реестра само: и то, и другое — через `sources`,
-- под правами своей политики. Своих процессов оно не порождает: `spawn` и
-- `exec` ему не выданы, и открыть соседнее окно оно может только просьбой к
-- композитору.

local channel = require("channel")
local process = require("process")
local time = require("time")
local tty = require("tty")

local model = require("model")
local render = require("render")
local sources = require("sources")

-- Композитор, которому окно шлёт просьбы. Это НЕ имя основы: под второй
-- оболочкой композитор зарегистрирован своим именем, и библиотека основы
-- `window_api` с зашитым `butschster.tui_desktop.desktop` сюда не годится —
-- она искала бы чужой процесс и молча ничего не делала.
local SHELL_SERVICE = "butschster.windows.shell"
local REPLY_TOPIC = "desktop.reply"

-- Тот же порог, что у композитора на столе: одинаковый двойной щелчок в двух
-- местах одной оболочки — это не совпадение чисел, а одно поведение.
local DOUBLE_CLICK_NS = 500000000

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

    local state: any = {
        path = model.ROOT,
        title = "Мой компьютер",
        objects = {},
        failure = nil,
        selected = 0,
        -- Первый видимый ряд сетки. Живёт здесь, а не в отрисовке: кадр
        -- собирается заново на каждое событие, и прокрутка, забытая между
        -- кадрами, отскакивала бы к началу на каждое нажатие.
        offset = 0,
        -- Список открытых окон приносит ответ композитора, а не библиотека:
        -- цикл ожидания ответа забрал бы из inbox и чужие сообщения тоже, а
        -- съеденная команда композитора неотличима от неполученной.
        windows = nil,
        windows_error = nil,
        -- Замечание — третье состояние между «показано всё» и «не прочитано»:
        -- срезанный список, непрочитанные диски, отказ на двойной щелчок.
        -- Оно не прячет объектов и не выдаёт себя за отказ.
        notice = nil,
    }
    local cells: any = {}
    -- Попадания панели инструментов возвращает та же функция, что её рисует.
    -- Своя формула здесь дала бы кнопку, которая на ячейку левее, чем
    -- выглядит, — и разъехались бы они молча.
    local tools: any = {}
    local bar: any = {}
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
        state.offset = 0
        state.notice = nil

        -- Открытые окна — единственный источник, который не читается: его
        -- приносит ответ композитора, и до ответа сказать про него нечего.
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

        local shown, err = sources.list(state.path, {
            windows = state.windows and #state.windows or nil,
        })
        if err or not shown then
            -- Заголовок при отказе НЕ меняется на имя папки, которую не
            -- открыли: подпись «Программы» над причиной читалась бы как
            -- «программы кончились».
            state.objects, state.failure = {}, err or "не прочитано"
            state.title = "Мой компьютер"
            return
        end

        state.objects, state.failure = shown.objects, nil
        state.title = tostring(shown.title or "Мой компьютер")
        state.notice = shown.notice
    end

    local function go(path: any)
        state.path = path
        if path == "windows" then
            state.windows, state.windows_error = nil, nil
            local ok, err = ask("desktop.list", {reply_to = process.pid()})
            if not ok then state.windows_error = tostring(err) end
        end
        load()
    end

    local function activate(object: any)
        if type(object) ~= "table" then return end

        -- Двойной щелчок, после которого не произошло ничего, неотличим от
        -- незамеченного, и второе, что попробует человек, — щёлкнуть сильнее.
        -- Причина уже собрана моделью в `detail`.
        if type(object.open) ~= "table" then
            state.notice = "открыть нечем: " .. tostring(object.detail or object.title)
            return
        end

        local open = object.open
        if open.action == "folder" then
            go(open.path)
        elseif open.action == "open_window" then
            local ok, err = ask("desktop.open", {
                entry = open.entry, title = open.title,
                w = open.w, h = open.h, args = open.args,
            })
            if not ok then state.notice = "не открылось: " .. tostring(err) end
        elseif open.action == "raise" then
            -- Команда композитора называется `desktop.focus`; «raise» — это
            -- намерение модели, а не имя топика. Послать топик, которого у
            -- композитора нет, значит не получить ни окна, ни отказа.
            local ok, err = ask("desktop.focus", {id = open.id})
            if not ok then state.notice = "не поднялось: " .. tostring(err) end
        end
    end

    -- ─── отрисовка ───────────────────────────────────────────────────────

    -- Рисует не окно, а `render`: там только строки и арифметика, и поэтому
    -- кадр можно посмотреть пробником, не поднимая ни окна, ни стенда.
    -- Попадания приезжают оттуда же, где нарисованы, — посчитанные здесь
    -- своей формулой, они разъехались бы с рисунком молча.
    local function draw()
        local canvas = tty.canvas(width, height)
        local hits = render.window(canvas, state, width, height)
        cells = hits.cells
        tools = hits.tools
        bar = hits.scroll
        assert(out:present(canvas:rows()))
    end

    -- ─── ввод ────────────────────────────────────────────────────────────

    local function shape()
        return render.shape(width, height, #state.objects, state.offset)
    end

    -- Прокрутка на `delta` рядов. Зажимает её `render.shape`, и намеренно:
    -- одно место, где решается, что дальше показывать нечего. Отсюда и два
    -- присваивания — первое двигает от того ряда, на котором прокрутка стоит
    -- на самом деле, второе спрашивает, куда она встала.
    local function scroll(delta: any)
        state.offset = shape().first + whole(delta)
        state.offset = shape().first
    end

    -- Выделение ходит по сетке, а не по списку, и тянет за собой прокрутку:
    -- выделенный объект, уехавший за край видимого, — это выделение, которого
    -- не видно, и следующая клавиша уводит его дальше вслепую.
    local function move(delta: any)
        if #state.objects == 0 then return end
        local next_index = state.selected + whole(delta)
        if next_index < 1 then next_index = 1 end
        if next_index > #state.objects then next_index = #state.objects end
        state.selected = next_index

        local grid = shape()
        local row = (next_index - 1) // grid.columns
        if row < grid.first then
            state.offset = row
        elseif row >= grid.first + grid.rows then
            state.offset = row - grid.rows + 1
        end
    end

    local function handle_key(event: any)
        local key = event.key_type or event.key
        if key == "enter" then
            activate(state.objects[state.selected])
        elseif key == "backspace" then
            local up = model.parent(state.path)
            if up then go(up) end
        elseif key == "right" then
            move(1)
        elseif key == "left" then
            move(-1)
        elseif key == "down" then
            move(shape().columns)
        elseif key == "up" then
            move(-shape().columns)
        elseif key == "pgdn" or key == "page_down" then
            scroll(shape().rows)
        elseif key == "pgup" or key == "page_up" then
            scroll(-shape().rows)
        elseif key == "home" then
            state.selected, state.offset = 1, 0
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
        -- Полоса прокрутки проверяется раньше значков: она лежит на том же
        -- поле, и щелчок по стрелке иначе достался бы значку под ней.
        for _, hit in ipairs(bar) do
            local arrow: any = hit
            if event.y == arrow.row and event.x >= arrow.from and event.x <= arrow.to then
                scroll(arrow.id == "scroll_down" and 1 or -1)
                draw()
                return
            end
        end

        for _, hit in ipairs(tools) do
            local button: any = hit
            if event.y == button.row and event.x >= button.from and event.x <= button.to then
                if button.id == "up" then
                    local up = model.parent(state.path)
                    if up then go(up) end
                elseif button.id == "refresh" then
                    load()
                end
                draw()
                return
            end
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
