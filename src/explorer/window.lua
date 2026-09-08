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
local time = require("time")
local tty = require("tty")

local desktop = require("desktop")
local model = require("model")
local render = require("render")
local scrolling = require("scrolling")
local geometry = require("geometry")
local sources = require("sources")

-- Имени композитора здесь нет и быть не должно. Оно приезжает окну в
-- контексте процесса, и читает его `window_api` основы; своя константа
-- работала бы только под нашей оболочкой и молча промахивалась бы под любой
-- другой — а `open` ответа не ждёт, так что промах выглядел бы как успех.

-- Тот же порог, что у композитора на столе: одинаковый двойной щелчок в двух
-- местах одной оболочки — это не совпадение чисел, а одно поведение.
local DOUBLE_CLICK_NS = 500000000

local whole = geometry.whole

local function main(service, window_id, args, viewport: any)
    local pixel_view = type(viewport) == "table"
    local events: any
    local out: any
    local metrics: any = nil
    if pixel_view then
        events = assert(desktop.inputs())
        metrics = render.pixel_metrics(viewport.cell_w, viewport.cell_h)
    else
        -- Subscribe before start, which emits the first event.
        events = assert(tty.events())
        assert(tty.start())
        out = assert(tty.surface({hide_cursor = true, synchronized_output = true}))
    end

    -- Канал ответов композитора. Отдельная подписка на топик, а НЕ чтение
    -- общего inbox, и это не вкусовщина: цикл, читающий inbox ради ответа,
    -- забирает оттуда и чужое, а выброшенная команда композитора неотличима
    -- от неполученной. Смешивать два способа нельзя — подписка забирает
    -- `desktop.reply` себе, и в inbox его больше не будет.
    --
    -- Подписка открывается ДО первого вопроса: открытая после, она пропустила
    -- бы быстрый ответ. Отказ подписаться не мешает окну рисоваться — без
    -- ответов не работает только папка «Открытые окна», и она скажет почему.
    local answers, answers_error = desktop.replies()

    -- В режиме ячеек события приходят от viewport, в пиксельном — через
    -- window_api.inputs. Оба транспорта приводятся к одному виду события.

    local width, height
    if pixel_view then width, height = viewport.width, viewport.height
    else width, height = tty.screen_size() end
    width, height = whole(width), whole(height)
    -- Нулевой размер — не редкость: окно может подняться раньше, чем
    -- композитор сообщил геометрию. Нулевой холст роняет отрисовку на первой
    -- строке, поэтому размеры по умолчанию не «на всякий случай», а
    -- обязательны.
    if width < (pixel_view and 1 or 20) then width = 60 end
    if height < (pixel_view and 1 or 8) then height = 18 end

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
        -- Список открытых окон приносит ответ композитора и приносит его
        -- ПОЗЖЕ вопроса: окно спрашивает и продолжает рисоваться, а ответ
        -- приходит своим каналом в тот же цикл. Ждущий вызов заморозил бы
        -- кадр на всё время ожидания.
        windows = nil,
        windows_error = nil,
        -- Замечание — третье состояние между «показано всё» и «не прочитано»:
        -- срезанный список, непрочитанные диски, отказ на двойной щелчок.
        -- Оно не прячет объектов и не выдаёт себя за отказ.
        notice = nil,
        -- Адресная строка: текст и список предков считаются моделью при
        -- каждом переходе, а не в отрисовке, — кадр собирается на каждое
        -- событие, а путь меняется только при переходе.
        address = model.address(model.ROOT),
        address_items = model.ancestors(model.ROOT),
        address_open = false,
    }
    -- История для «Назад» и «Вперёд». Переход из списка адреса, по папке и
    -- по «Вверх» — всё это шаги вперёд; «Назад» снимает верх стопки.
    local history: any = {back = {}, forward = {}}
    local cells: any = {}
    local address_hits: any = {}
    local dropdown_hits: any = {}
    -- Попадания панели инструментов возвращает та же функция, что её рисует.
    -- Своя формула здесь дала бы кнопку, которая на ячейку левее, чем
    -- выглядит, — и разъехались бы они молча.
    local tools: any = {}
    local bar: any = {}
    local last_click: any = {x = 0, y = 0, at = 0}

    -- Спросить композитор и НЕ ждать: ответ приедет в `desktop.replies()`,
    -- который лежит в том же `select`, что и события. Ждущий вызов (`ask`)
    -- удобнее, но на время ожидания окно не рисуется, а рисовать себя — это
    -- всё, чем оно занято.
    local function request(topic, body: any)
        local ok, err = desktop.request(topic, body)
        return ok, err
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

    local function go(path: any, how: any?)
        if how ~= "back" and how ~= "forward" and state.path ~= path then
            history.back[#history.back + 1] = state.path
            history.forward = {}
        end
        state.path = path
        state.address = model.address(path)
        state.address_items = model.ancestors(path)
        state.address_open = false
        if path == "windows" then
            state.windows, state.windows_error = nil, nil
            -- `reply_to` подставляет библиотека: адрес ответа — это адрес
            -- процесса, и повторять его здесь значит завести второе место,
            -- где он может разойтись с подпиской.
            if not answers then
                state.windows_error = tostring(answers_error
                    or "подписка на ответы композитора не открылась")
            else
                local ok, err = request("desktop.list", {})
                if not ok then state.windows_error = tostring(err) end
            end
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
            local ok, err = desktop.open({
                entry = open.entry, title = open.title,
                w = open.w, h = open.h, args = open.args,
            })
            if not ok then state.notice = "не открылось: " .. tostring(err) end
        elseif open.action == "raise" then
            -- «raise» — намерение модели, а не имя топика: у композитора это
            -- `desktop.focus`, и зовётся оно по имени из библиотеки, а не
            -- строкой. Послать топик, которого у композитора нет, значит не
            -- получить ни окна, ни отказа.
            local ok, err = desktop.focus(open.id)
            if not ok then state.notice = "не поднялось: " .. tostring(err) end
        end
    end

    -- ─── отрисовка ───────────────────────────────────────────────────────

    -- Рисует не окно, а `render`: там только строки и арифметика, и поэтому
    -- кадр можно посмотреть пробником, не поднимая ни окна, ни стенда.
    -- Попадания приезжают оттуда же, где нарисованы, — посчитанные здесь
    -- своей формулой, они разъехались бы с рисунком молча.
    local function draw()
        local plan = render.layout(state, width, height, metrics)
        local hits = render.hits(plan)
        if pixel_view then
            state.width, state.height = width, height
            assert(desktop.publish_state(window_id, state))
        else
            local canvas = tty.canvas(width, height)
            hits = render.cells(canvas, plan)
            assert(out:present(canvas:rows()))
        end
        cells, tools, bar = hits.cells, hits.tools, hits.scroll or {}
        address_hits, dropdown_hits = hits.address or {}, hits.dropdown or {}
    end

    -- ─── ввод ────────────────────────────────────────────────────────────

    local function shape()
        return render.shape(width, height, #state.objects, state.offset, metrics)
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
        elseif key == "esc" or key == "escape" then
            state.address_open = false
        elseif event.key == "left" and event.alt then
            local previous = table.remove(history.back :: {any})
            if previous then history.forward[#history.forward + 1] = state.path; go(previous, "back") end
        elseif event.key == "right" and event.alt then
            local next_path = table.remove(history.forward :: {any})
            if next_path then history.back[#history.back + 1] = state.path; go(next_path, "forward") end
        elseif key == "right" then
            move(1)
        elseif key == "left" then
            move(-1)
        elseif key == "down" then
            move(shape().columns)
        elseif key == "up" then
            move(-shape().columns)
        elseif key == "pgdown" then
            scroll(shape().rows)
        elseif key == "pgup" then
            scroll(-shape().rows)
        elseif key == "home" then
            state.selected, state.offset = 1, 0
        elseif key == "end" then
            state.selected = #state.objects
            scroll(#state.objects)
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

    -- Кнопка панели срабатывает по ОТПУСКАНИЮ внутри себя, как в Windows и
    -- как в SDK: нажатие взводит, увод мыши снимает, отпускание снаружи —
    -- отмена. Взведённая кнопка нарисована вдавленной.
    local armed: any = nil
    local function tool_at(x: any, y: any): any
        for _, hit in ipairs(tools) do
            local button: any = hit
            if y >= button.row and y <= (button.bottom_row or button.row)
                and x >= button.from and x <= button.to then return button end
        end
        return nil
    end
    local function activate_tool(button: any)
        if button.id == "back" then
            local previous = table.remove(history.back :: {any})
            if previous then
                history.forward[#history.forward + 1] = state.path
                go(previous, "back")
            else
                state.notice = "Назад: истории нет"
            end
        elseif button.id == "forward" then
            local next_path = table.remove(history.forward :: {any})
            if next_path then
                history.back[#history.back + 1] = state.path
                go(next_path, "forward")
            else
                state.notice = "Вперёд: истории нет"
            end
        elseif button.id == "up" then
            local up = model.parent(state.path)
            if up then go(up) else state.notice = "Вверх: это корень" end
        elseif button.id == "refresh" then
            load()
        elseif button.id == "view_large" then
            state.notice = "Крупные значки — единственный вид пока"
        end
    end

    local scroll_capture: any = nil
    local function handle_mouse(event: any)
        local plan = render.layout(state, width, height, metrics)
        if armed and (event.action == "motion" or event.action == "release") then
            local over = tool_at(event.x, event.y)
            local inside = over ~= nil and over.id == armed.id
            if event.action == "motion" then
                if inside ~= (state.armed_tool == armed.id) then
                    state.armed_tool = inside and armed.id or nil
                    draw()
                end
                return
            end
            state.armed_tool = nil
            local chosen = armed
            armed = nil
            if inside and event.button == "left" then activate_tool(chosen) end
            draw()
            return
        end
        if not state.address_open and plan.scroll then
            local offset, capture, handled = scrolling.pointer(state.offset, plan.scroll.total, plan.scroll.visible,
                plan.scroll, scroll_capture, event)
            if handled then state.offset, scroll_capture = offset, capture; draw(); return end
        elseif scroll_capture then scroll_capture = nil end
        if event.action == "wheel" then
            if not geometry.contains(plan.inner, event.x, event.y) or state.address_open then return end
            if event.button == "wheel_up" then scroll(-1)
            elseif event.button == "wheel_down" then scroll(1)
            else return end
            draw()
            return
        end
        if event.action ~= "press" or event.button ~= "left" then return end

        -- Панель инструментов: «Вверх» — единственная кнопка, у которой есть
        -- что делать в первой версии. Кнопка, которая ничего не делает, —
        -- бутафория, и первое, что о ней спросят, почему она не работает;
        -- поэтому их всего две.
        -- Полоса прокрутки проверяется раньше значков: она лежит на том же
        -- поле, и щелчок по стрелке иначе достался бы значку под ней.

        -- Выпадающий список адреса — поверх всего, поэтому первым.
        for _, hit in ipairs(dropdown_hits) do
            local line: any = hit
            if event.y == line.row and event.x >= line.from and event.x <= line.to then
                local item: any = state.address_items[line.index]
                state.address_open = false
                if item and item.path ~= state.path then go(item.path) end
                draw()
                return
            end
        end
        if state.address_open then
            -- Щелчок мимо списка закрывает его и больше ничего не делает.
            state.address_open = false
            draw()
            return
        end
        for _, name in ipairs({"field", "drop"}) do
            local spot: any = address_hits[name]
            if spot and event.y >= spot.row and event.y <= (spot.bottom_row or spot.row)
                and event.x >= spot.from and event.x <= spot.to then
                state.address_open = true
                draw()
                return
            end
        end

        local tool = tool_at(event.x, event.y)
        if tool then
            -- Недоступная кнопка молчит, как в Windows: сообщение на каждый
            -- щелчок читалось бы как «что-то сломалось».
            if tool.disabled then return end
            armed = tool
            state.armed_tool = tool.id
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
        local cases = {events:case_receive()}
        if answers then cases[#cases + 1] = answers:case_receive() end

        local selected = channel.select(cases)
        if not selected.ok then break end

        if answers and selected.channel == answers then
            -- Ответ приезжает обёрнутым: payload — userdata, внутри бывает
            -- ещё и массив из одного элемента. Поле, прочитанное напрямую,
            -- окажется nil без ошибки — то есть «композитор ответил пустотой».
            local payload: any = selected.value:payload()
            if type(payload) == "userdata" then
                local ok, decoded = pcall(function() return payload:data() end)
                payload = ok and decoded or {}
            end
            if type(payload) == "table" and payload[1] ~= nil and #payload > 0 then
                payload = payload[1]
            end
            local body: any = type(payload) == "table" and payload or {}

            if body.ok == false then
                state.windows_error = tostring(body.error or "композитор отказал без причины")
                state.windows = nil
            else
                state.windows = type(body.windows) == "table" and body.windows or {}
                state.windows_error = nil
            end
            if state.path == "windows" or state.path == model.ROOT then load() end
            draw()
        else
            local event: any = selected.value
            if pixel_view then event = desktop.input_event(selected.value) end
            event = desktop.normalize_event(event)
            if event.type == "close" then
                break
            elseif event.type == "resize" then
                local w, h
                if pixel_view then
                    w, h = event.width, event.height
                    metrics = render.pixel_metrics(event.cell_w, event.cell_h)
                else w, h = tty.screen_size() end
                w, h = whole(w), whole(h)
                if w > 0 then width = w end
                if h > 0 then height = h end
                state.offset = shape().first
                draw()
            elseif event.type == "key" and event.action ~= "release" then
                handle_key(event)
            elseif event.type == "mouse" then
                handle_mouse(event)
            end
        end
    end

    if not pixel_view then tty.stop() end
end

return {main = main}
