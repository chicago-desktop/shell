-- Owns the event loop and transport; applications own only data and actions.
--
-- Что цикл гарантирует приложению:
--   * ошибка во `view` или `update` не рвёт окно: она становится видимым
--     состоянием (текст ошибки и кнопка «Закрыть»), `dispose` и закрытие
--     транспорта выполняются всё равно;
--   * отказ композитора на публикацию кадра или закрытие — не смерть окна;
--   * кроме событий ввода и таймера приложение может слушать свои каналы
--     (`context.watch(ch)`), и ответ приходит действием `{type = "channel"}`;
--   * клавиша, которую не взял ни один компонент, доходит действием
--     `{type = "key"}` — так закрываются по Esc и обновляются по F5;
--   * `close` доставляется действием до выхода из цикла.
--
-- Изменяемое состояние цикла живёт в ТАБЛИЦЕ `loop`, а не в локальных
-- переменных, и это не стиль. В go-lua (wippy 0.3.35a) после первой ошибки,
-- пойманной pcall, присваивание внешней переменной из замыкания перестаёт
-- быть видно владельцу: `draw` клал новый план, а цикл читал старый, и
-- нажатие по запасному дереву искало кнопку в дереве приложения.
-- Проверено тестом: `local v = 1; local function bump() v = v + 1 end;
-- pcall(error); bump()` — снаружи v == 1. Поле таблицы такого не знает.
local channel = require("channel")
local tty = require("tty")
local time = require("time")
local desktop = require("desktop")
local ui = require("ui")
local cells = require("cells")
local app = {}

-- Дерево, которое показывается вместо упавшего приложения. Окно без него
-- либо исчезало (и человек не узнавал почему), либо застывало на последнем
-- кадре и выглядело живым.
local function failure_tree(reason: any): any
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Окно остановлено: ошибка в приложении"},
        {kind = "label", text = tostring(reason)},
        {kind = "button", id = "sdk_close", size = 2, text = "Закрыть", default = true},
    }}
end

function app.run(definition: any, first: any, window_id: any, args: any, viewport: any)
    local native = type(viewport) == "table"
    local events: any, surface: any
    if native then events = assert(desktop.inputs())
    else
        args = first
        assert(tty.start())
        events = assert(tty.events())
        surface = assert(tty.surface({hide_cursor = true, synchronized_output = true}))
    end
    local width: any, height: any = 1, 1
    if native then width, height = viewport.width, viewport.height else width, height = tty.screen_size() end

    local loop: any = {plan = nil, revision = 0, watched = {}}
    local context: any = {args = args, width = width, height = height, native = native, closing = false,
        failure = nil, window_id = window_id}
    function context.close() context.closing = true end
    -- Свой канал приложения: ответ композитора на `desktop.replies()`,
    -- подписка, таймер запроса. Сработавший канал приходит действием
    -- `{type = "channel", channel = ch, value = ..., ok = ...}`.
    function context.watch(ch: any)
        for _, known in ipairs(loop.watched) do if known == ch then return end end
        loop.watched[#loop.watched + 1] = ch
    end
    function context.unwatch(ch: any)
        local kept: any = {}
        for _, known in ipairs(loop.watched) do
            if known ~= ch then kept[#kept + 1] = known end
        end
        loop.watched = kept
    end

    local function guarded(what: string, fn: any, ...): any
        local ok, result = pcall(fn, ...)
        if ok then return result end
        context.failure = what .. ": " .. tostring(result)
        return nil
    end

    local model: any = definition.init and guarded("init", definition.init, args, context) or {}
    local interaction = ui.interaction()

    local function draw()
        local tree: any = nil
        if not context.failure then tree = guarded("view", definition.view, model, context) end
        if context.failure then tree = failure_tree(context.failure) end
        local ok, built = pcall(ui.plan, tree, context.width, context.height, interaction)
        if ok then loop.plan = built
        else
            -- Дерево не раскладывается (дубль id, неизвестный kind) — это тоже
            -- ошибка приложения, и она обязана быть видна.
            context.failure = "plan: " .. tostring(built)
            loop.plan = ui.plan(failure_tree(context.failure), context.width, context.height, interaction)
        end
        loop.revision = loop.revision + 1
        if native then
            desktop.publish_state(window_id, {sdk = 1, revision = loop.revision, ui = tree, interaction = interaction})
        else
            surface:present(cells.rows(loop.plan, interaction, context.width, context.height),
                {cursor = {x = 1, y = 1, visible = false}})
        end
    end

    local function dispatch(action: any)
        if action == nil then return true end
        if context.failure then
            if action.type == "activate" and action.id == "sdk_close" then context.closing = true end
            return true
        end
        if not definition.update then return true end
        local verdict = guarded("update", definition.update, model, action, context)
        -- `update` может вернуть false: «ничего не изменилось, не рисуй».
        return verdict ~= false
    end

    local timer: any = definition.interval and time.after(definition.interval) or nil
    draw()
    while not context.closing do
        local cases = {events:case_receive()}
        if timer then cases[#cases + 1] = timer:case_receive() end
        for _, ch in ipairs(loop.watched) do cases[#cases + 1] = ch:case_receive() end
        local picked = channel.select(cases)
        if not picked.ok and picked.channel == events then break end
        local action: any
        local redraw = true
        if timer and picked.channel == timer then
            action = {type = "tick"}
            timer = time.after(definition.interval)
            redraw = dispatch(action)
        elseif picked.channel == events then
            local event = native and desktop.input_event(picked.value) or desktop.normalize_event(picked.value)
            if event.type == "close" then
                dispatch({type = "close"})
                break
            end
            if event.type == "resize" then
                if native then context.width, context.height = event.width, event.height
                else context.width, context.height = tty.screen_size() end
                action = {type = "resize", width = context.width, height = context.height}
            else
                action = ui.event(loop.plan, interaction, event)
                -- Клавиша, не взятая компонентом, — приложению: Esc, F5, Ctrl+S.
                if action == nil and event.type == "key" and event.action ~= "release" then
                    action = {type = "key", key = event.key, key_type = event.key_type,
                        alt = event.alt, ctrl = event.ctrl, shift = event.shift}
                end
            end
            redraw = dispatch(action)
        else
            -- Свой канал приложения. Закрытый канал отписывается сам: иначе
            -- `select` возвращался бы на нём без конца.
            if not picked.ok then context.unwatch(picked.channel) end
            redraw = dispatch({type = "channel", channel = picked.channel, value = picked.value, ok = picked.ok})
        end
        if not context.closing and redraw then draw() end
    end
    if definition.dispose then pcall(definition.dispose, model, context) end
    -- Закрытие — просьба, а не утверждение: композитор мог закрыть окно сам,
    -- и второй запрос ему отвечать не о чем.
    if native then desktop.close(window_id) else pcall(tty.stop) end
end
return app
