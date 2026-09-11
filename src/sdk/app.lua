-- Owns the event loop and transport; applications own only data and actions.
--
-- What the loop guarantees to the application:
--   * an error in `view` or `update` does not tear the window down: it becomes
--     visible state (the error text and a "Close" button), and `dispose` and
--     closing the transport still run;
--   * the compositor refusing to publish a frame or to close is not the death of the window;
--   * besides input events and the timer, the application can listen to its own channels
--     (`context.watch(ch)`), and the answer arrives as the action `{type = "channel"}`;
--   * a key that no component took arrives as the action
--     `{type = "key"}` — that is how windows close on Esc and refresh on F5;
--   * `close` is delivered as an action before the loop exits.
--
-- The loop's mutable state lives in the TABLE `loop`, not in local
-- variables, and this is not a matter of style. In go-lua (wippy 0.3.35a), after the first error
-- caught by pcall, an assignment to an outer variable from a closure stops
-- being visible to the owner: `draw` stored a new plan, the loop read the old one, and
-- a press on the fallback tree looked for the button in the application's tree.
-- Verified by a test: `local v = 1; local function bump() v = v + 1 end;
-- pcall(error); bump()` — from outside v == 1. A table field does not have this problem.
local channel = require("channel")
local tty = require("tty")
local time = require("time")
local desktop = require("desktop")
local ui = require("ui")
local cells = require("cells")
local app = {}

-- The tree shown in place of a crashed application. Without it the window
-- either vanished (and the person never learned why) or froze on its last
-- frame and looked alive.
local function failure_tree(reason: any): any
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Window stopped: application error"},
        {kind = "label", text = tostring(reason)},
        {kind = "button", id = "sdk_close", size = 2, text = "Close", default = true},
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
    -- The application's own channel: the compositor's answer on `desktop.replies()`,
    -- a subscription, a request timer. A channel that fired arrives as the action
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
        -- The fallback tree was already on screen, so there is nothing to repeat.
        local failed_before = context.failure ~= nil
        local tree: any = nil
        if not context.failure then tree = guarded("view", definition.view, model, context) end
        if context.failure then tree = failure_tree(context.failure) end
        local ok, built = pcall(ui.plan, tree, context.width, context.height, interaction)
        if ok then loop.plan = built
        else
            -- The tree does not lay out (duplicate id, unknown kind) — this is also
            -- an application error, and it must be visible.
            context.failure = "plan: " .. tostring(built)
            loop.plan = ui.plan(failure_tree(context.failure), context.width, context.height, interaction)
        end
        loop.revision = loop.revision + 1
        if native then
            -- `definition.title` is the window title when it differs from the menu
            -- item's ("Run…" in "Start", "Run" on the window). A string or a function of the
            -- model; empty means the entry's title, as before.
            local title: any = definition.title
            if type(title) == "function" then title = guarded("title", title, model, context) end
            desktop.publish_state(window_id, {sdk = 1, revision = loop.revision, ui = tree, interaction = interaction,
                title = type(title) == "string" and title ~= "" and title or nil})
        else
            -- A frame in cells is also code that depends on the application's tree. A frame
            -- that failed to build sends the window to the fallback tree instead of carrying
            -- the error past `dispose` and `tty.stop` and leaving the terminal without a cursor.
            local shown = guarded("draw", function()
                surface:present(cells.rows(loop.plan, interaction, context.width, context.height),
                    {cursor = {x = 1, y = 1, visible = false}})
                return true
            end)
            if not shown and not failed_before then draw() end
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
        -- `update` may return false: "nothing changed, do not draw".
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
            -- Parsing the event and `ui.event` run under the same guard as `update`:
            -- otherwise a garbage event or an error while walking the tree tore the loop
            -- down past `dispose`, `desktop.close` and `tty.stop`. If it did not parse, it is
            -- an empty event, and the next frame is the fallback tree.
            local event: any = guarded("input", function()
                return native and desktop.input_event(picked.value) or desktop.normalize_event(picked.value)
            end) or {}
            if event.type == "close" then
                dispatch({type = "close"})
                break
            end
            if event.type == "resize" then
                if native then context.width, context.height = event.width, event.height
                else context.width, context.height = tty.screen_size() end
                action = {type = "resize", width = context.width, height = context.height}
            else
                action = guarded("event", ui.event, loop.plan, interaction, event)
                -- A key no component took goes to the application: Esc, F5, Ctrl+S.
                if action == nil and event.type == "key" and event.action ~= "release" then
                    action = {type = "key", key = event.key, key_type = event.key_type,
                        alt = event.alt, ctrl = event.ctrl, shift = event.shift}
                end
            end
            redraw = dispatch(action)
        else
            -- The application's own channel. A closed channel unsubscribes itself: otherwise
            -- `select` would keep returning on it forever.
            if not picked.ok then context.unwatch(picked.channel) end
            redraw = dispatch({type = "channel", channel = picked.channel, value = picked.value, ok = picked.ok})
        end
        if not context.closing and redraw then draw() end
    end
    if definition.dispose then pcall(definition.dispose, model, context) end
    -- Closing is a request, not an assertion: the compositor may have closed the window itself,
    -- and it has nothing to answer to a second request.
    if native then desktop.close(window_id) else pcall(tty.stop) end
end
return app
