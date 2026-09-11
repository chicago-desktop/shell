-- "My Computer" — a window that shows the running system itself.
--
-- It draws ONLY its own contents: the menu bar, the toolbar, the icon field
-- and the status bar. The frame, the title and the title buttons are chrome,
-- they belong to the theme; the compositor gives the window the whole
-- rectangle inside the frame, and what is drawn there is the window's
-- business.
--
-- The primitives are shared with the theme (`widgets`, `icons`): our own
-- would mean creating a second, slightly different button, and inside the
-- Windows 95 window there would be a different Windows. They would diverge
-- in looks, not in a failure — that is, it would be noticed a week later.
--
-- The window reads neither the database nor the registry by itself: both go
-- through `sources`, under the permissions of its policy. It does not spawn
-- processes of its own: it is not granted `spawn` and `exec`, and it can open
-- a neighbouring window only by a request to the compositor.

local channel = require("channel")
local time = require("time")
local tty = require("tty")

local desktop = require("desktop")
local model = require("model")
local render = require("render")
local scrolling = require("scrolling")
local geometry = require("geometry")
local sources = require("sources")

-- The compositor's name is not here and must not be. It arrives to the
-- window in the process context, and the base's `window_api` reads it; a
-- constant of our own would work only under our shell and would silently
-- miss under any other — and `open` does not wait for a reply, so a miss
-- would look like success.

-- The same threshold as the compositor has on the desktop: an identical
-- double click in two places of one shell is not a coincidence of numbers
-- but one behaviour.
local DOUBLE_CLICK_NS = 500000000

local whole = geometry.whole

-- The compositor's reply arrives wrapped: the payload is userdata, and inside
-- there is sometimes also an array of one element. A field read directly
-- will turn out nil without an error — that is, "the compositor replied with
-- emptiness". There is one unwrapping per window: the base has the same one
-- living as a `local` in `window_api` and not exported.
local function unwrap(message: any): any
    local value: any = message:payload()
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        value = ok and decoded or {}
    end
    if type(value) == "table" and value[1] ~= nil and #value > 0 then value = value[1] end
    return type(value) == "table" and value or {}
end

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

    -- The compositor's reply channel. A separate subscription to a topic, and
    -- NOT reading the shared inbox, and this is not a matter of taste: a loop
    -- that reads the inbox for the sake of a reply takes other messages from
    -- it too, and a thrown-away compositor command is indistinguishable from
    -- one never received. The two ways must not be mixed — the subscription
    -- takes `desktop.reply` for itself, and it will no longer be in the inbox.
    --
    -- The subscription is opened BEFORE the first question: opened after, it
    -- would miss a fast reply. A failure to subscribe does not stop the window
    -- from drawing — without replies only the "Open Windows" folder does not
    -- work, and it will say why.
    local answers, answers_error = desktop.replies()

    -- In cell mode events come from the viewport, in pixel mode through
    -- window_api.inputs. Both transports are brought to one event shape.

    local width, height
    if pixel_view then width, height = viewport.width, viewport.height
    else width, height = tty.screen_size() end
    width, height = whole(width), whole(height)
    -- A zero size is not rare: the window may come up before the compositor
    -- has reported the geometry. A zero canvas crashes drawing on the first
    -- row, so the default sizes are not "just in case" but mandatory.
    if width < (pixel_view and 1 or 20) then width = 60 end
    if height < (pixel_view and 1 or 8) then height = 18 end

    local state: any = {
        path = model.ROOT,
        title = "My Computer",
        objects = {},
        failure = nil,
        selected = 0,
        -- The first visible row of the grid. Lives here, not in the drawing:
        -- the frame is assembled anew on every event, and a scroll forgotten
        -- between frames would jump back to the start on every key press.
        offset = 0,
        -- The list of open windows is brought by the compositor's reply, and
        -- it brings it LATER than the question: the window asks and keeps
        -- drawing, and the reply arrives over its own channel into the same
        -- loop. A waiting call would freeze the frame for the whole wait.
        windows = nil,
        windows_error = nil,
        -- A notice is a third state between "everything is shown" and "not
        -- read": a truncated list, unread drives, a refusal on a double
        -- click. It does not hide objects and does not pass itself off as a
        -- failure.
        notice = nil,
        -- The address bar: the text and the list of ancestors are computed
        -- by the model on every navigation, not in the drawing — the frame is
        -- assembled on every event, while the path changes only on
        -- navigation.
        address = model.address(model.ROOT),
        address_items = model.ancestors(model.ROOT),
        address_open = false,
    }
    -- History for "Back" and "Forward". Navigating from the address list, by
    -- a folder and by "Up" — all of these are steps forward; "Back" pops the
    -- top of the stack.
    local history: any = {back = {}, forward = {}}
    local cells: any = {}
    local address_hits: any = {}
    local dropdown_hits: any = {}
    -- The toolbar hits are returned by the same function that draws it. A
    -- formula of our own here would give a button one cell to the left of
    -- where it appears — and they would drift apart silently.
    local tools: any = {}
    -- The menu bar titles and the open list's rows — also from the plan.
    local menu_hits: any = {}
    local popup_hits: any = {}
    local last_click: any = {x = 0, y = 0, at = 0}

    -- Ask the compositor and do NOT wait: the reply will arrive in
    -- `desktop.replies()`, which sits in the same `select` as the events. A
    -- waiting call (`ask`) is more convenient, but while waiting the window
    -- does not draw, and drawing itself is all it is busy with.
    local function request(topic, body: any)
        local ok, err = desktop.request(topic, body)
        return ok, err
    end

    -- ─── contents ────────────────────────────────────────────────────────

    local function load()
        state.selected = 0
        state.offset = 0
        state.notice = nil

        -- Open windows are the only source that is not read: it is brought
        -- by the compositor's reply, and until the reply there is nothing to
        -- say about it.
        if state.path == "windows" then
            state.title = "Open Windows"
            if state.windows_error then
                state.objects, state.failure = {}, state.windows_error
            elseif state.windows then
                state.objects, state.failure = model.windows(state.windows), nil
            else
                -- Not answered yet — this is neither an empty folder nor a
                -- failure. Saying "no objects" here means lying for a quarter
                -- of a second, and a person will manage to read it.
                state.objects, state.failure = {}, "asking the shell…"
            end
            return
        end

        local shown, err = sources.list(state.path, {
            windows = state.windows and #state.windows or nil,
        })
        if err or not shown then
            -- On failure the title does NOT change to the name of the folder
            -- that was not opened: the caption "Programs" over the reason
            -- would read as "the programs ran out".
            state.objects, state.failure = {}, err or "not read"
            state.title = "My Computer"
            return
        end

        state.objects, state.failure = shown.objects, nil
        state.title = tostring(shown.title or "My Computer")
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
            -- `reply_to` is filled in by the library: the reply address is
            -- the process address, and repeating it here would mean creating
            -- a second place where it can diverge from the subscription.
            if not answers then
                state.windows_error = tostring(answers_error
                    or "subscription to compositor replies did not open")
            else
                local ok, err = request("desktop.list", {})
                if not ok then state.windows_error = tostring(err) end
            end
        end
        load()
    end

    local function activate(object: any)
        if type(object) ~= "table" then return end

        -- A double click after which nothing happened is indistinguishable
        -- from an unnoticed one, and the second thing a person will try is to
        -- click harder. The reason has already been gathered by the model in
        -- `detail`.
        if type(object.open) ~= "table" then
            state.notice = "nothing to open it with: " .. tostring(object.detail or object.title)
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
            if not ok then state.notice = model.refusal("desktop.open", err) end
        elseif open.action == "raise" then
            -- "raise" is the model's intent, not a topic name: at the
            -- compositor it is `desktop.focus`, and it is called by the name
            -- from the library, not by a string. Sending a topic the
            -- compositor does not have means getting neither a window nor a
            -- refusal.
            local ok, err = desktop.focus(open.id)
            if not ok then state.notice = model.refusal("desktop.focus", err) end
        end
    end

    -- ─── drawing ─────────────────────────────────────────────────────────

    -- It is not the window that draws but `render`: there is only strings and
    -- arithmetic there, and so a frame can be viewed with a probe without
    -- starting either the window or the runtime. The hits arrive from the
    -- same place where they are drawn — computed here by our own formula,
    -- they would drift apart from the picture silently.
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
        cells, tools = hits.cells, hits.tools
        menu_hits, popup_hits = hits.menu or {}, hits.menu_popup or {}
        address_hits, dropdown_hits = hits.address or {}, hits.dropdown or {}
    end

    -- ─── commands ────────────────────────────────────────────────────────

    -- One function for a toolbar button, a menu item and a key: "Up" on the
    -- toolbar and "Go → Up One Level" are one action, not two similar ones.
    local function command(id: any)
        if id == "back" then
            local previous = table.remove(history.back :: {any})
            if previous then
                history.forward[#history.forward + 1] = state.path
                go(previous, "back")
            else
                state.notice = "Back: no history"
            end
        elseif id == "forward" then
            local next_path = table.remove(history.forward :: {any})
            if next_path then
                history.back[#history.back + 1] = state.path
                go(next_path, "forward")
            else
                state.notice = "Forward: no history"
            end
        elseif id == "up" then
            local up = model.parent(state.path)
            if up then go(up) else state.notice = "Up: this is the root" end
        elseif id == "refresh" then
            -- Through `go`, not `load`: "Open Windows" must be asked of the
            -- compositor anew, not re-read from the previous reply.
            go(state.path)
        elseif id == "view_large" then
            state.notice = "Large Icons is the only view so far"
        elseif id == "about" then
            state.notice = "My Computer: the drives, folders and open windows of this runtime"
        elseif id == "close" then
            -- The window is closed by the compositor, which sends `close`; a
            -- refusal goes into the status bar, as with any other command.
            local ok, err = desktop.close(window_id)
            if not ok then state.notice = model.refusal("desktop.close", err) end
        end
    end

    -- ─── input ───────────────────────────────────────────────────────────

    local function shape()
        return render.shape(width, height, #state.objects, state.offset, metrics)
    end

    -- Scroll by `delta` rows. It is clamped by `render.shape`, and on
    -- purpose: one place where it is decided that there is nothing further to
    -- show. Hence the two assignments — the first moves from the row the
    -- scroll actually stands on, the second asks where it ended up.
    local function scroll(delta: any)
        state.offset = shape().first + whole(delta)
        state.offset = shape().first
    end

    -- The selection moves through the grid, not the list, and drags the
    -- scroll along: a selected object that went past the edge of what is
    -- visible is a selection that cannot be seen, and the next key takes it
    -- further blindly.
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
            state.menu_open = nil
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
        elseif (event.key == "r" and event.ctrl) or key == "f5" or event.key == "F5" then
            command("refresh")
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

    -- A toolbar button fires on RELEASE inside itself, as in Windows and as
    -- in the SDK: pressing arms it, moving the mouse away disarms it,
    -- releasing outside is a cancel. An armed button is drawn sunken.
    local armed: any = nil
    local function tool_at(x: any, y: any): any
        for _, hit in ipairs(tools) do
            local button: any = hit
            if y >= button.row and y <= (button.bottom_row or button.row)
                and x >= button.from and x <= button.to then return button end
        end
        return nil
    end
    local function menu_at(x: any, y: any): any
        for _, hit in ipairs(menu_hits) do
            local title: any = hit
            if y == title.row and x >= title.from and x <= title.to then return title end
        end
        return nil
    end

    local scroll_capture: any = nil
    local function handle_mouse(event: any)
        local plan = render.layout(state, width, height, metrics)
        local covered = state.address_open or state.menu_open ~= nil
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
            if inside and event.button == "left" then command(chosen.id) end
            draw()
            return
        end
        -- The scrollbar: a click on an arrow, the track and the thumb is
        -- resolved by `scroll.pointer` with the same geometry it is drawn
        -- with. Under an open list it does not respond — the click belongs to
        -- the list.
        if not covered and plan.scroll then
            local offset, capture, handled = scrolling.pointer(state.offset, plan.scroll.total, plan.scroll.visible,
                plan.scroll, scroll_capture, event)
            if handled then state.offset, scroll_capture = offset, capture; draw(); return end
        elseif scroll_capture then scroll_capture = nil end
        if event.action == "wheel" then
            if not geometry.contains(plan.inner, event.x, event.y) or covered then return end
            if event.button == "wheel_up" then scroll(-1)
            elseif event.button == "wheel_down" then scroll(1)
            else return end
            draw()
            return
        end
        if event.action ~= "press" or event.button ~= "left" then return end

        -- The order of checks is the order of layers from top to bottom: the
        -- open menu, the address list, the toolbar, the icons. The scrollbar
        -- has already been checked above: it lies on the same field, and a
        -- click on an arrow would otherwise go to the icon under it.

        -- An open menu: a list row executes the item, another title switches
        -- the list, a click elsewhere only collapses it.
        if state.menu_open then
            local picked: any = nil
            for _, hit in ipairs(popup_hits) do
                local line: any = hit
                if event.y == line.row and event.x >= line.from and event.x <= line.to then picked = line end
            end
            local title = menu_at(event.x, event.y)
            state.menu_open = (title and title.index ~= state.menu_open) and title.index or nil
            if picked then command(picked.id) end
            draw()
            return
        end
        local title = menu_at(event.x, event.y)
        if title then
            state.menu_open, state.address_open = title.index, false
            draw()
            return
        end

        -- The address dropdown list.
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
            -- A click outside the list closes it and does nothing else.
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
            -- A disabled button is silent, as in Windows: a message on every
            -- click would read as "something broke".
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
        -- A double click opens, a single one selects. A program that starts
        -- on one click is a trap: a person moves the mouse along the list and
        -- launches everything they touched.
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
            -- Whose reply this is, the model decides: the channel receives
            -- not only the window list but also an unsolicited refusal to
            -- open/focus/state. The refusal goes into the status bar, and
            -- `load` is not called after it — it would erase the notice before
            -- it is read.
            local taken = model.take_reply(state, unwrap(selected.value))
            if taken == "list" and (state.path == "windows" or state.path == model.ROOT) then load() end
            if taken then draw() end
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
