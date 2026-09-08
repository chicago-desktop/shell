-- Диспетчер задач — окно, показывающее сам рантайм.
--
-- Четыре вкладки: открытые окна (их знает композитор), процессы рантайма
-- (`system.hosts.processes`), быстродействие (память и горутины во времени)
-- и узел (кластер, лидер, хосты). Цифры снимаются раз в секунду; история
-- держится на ширину графика.
--
-- Загрузки процессора в процентах здесь нет и не будет нарочно: рантайм её
-- не считает, а читать `/proc` окну нельзя — ему не выдаётся ни `exec`, ни
-- файловая система машины. Честная «нагрузка» рантайма — горутины и куча,
-- и она меняется на глазах, когда работает контент-машина или прогон.
--
-- Окно рисует только своё содержимое; рамку и заголовок рисует тема.

local channel = require("channel")
local os_clock = require("os")
local system = require("system")
local time = require("time")
local tty = require("tty")

local desktop = require("desktop")
local model = require("model")
local widgets = require("widgets")

local styles = widgets.styles

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local TICK = "1s"
local HISTORY_CAP = 240

-- Графики: зелёное по чёрному, как на кадре. Сетка — тёмно-зелёные точки.
local graph_styles = {
    line = tty.style():foreground("#00ff00"):background("#000000"),
    grid = tty.style():foreground("#004400"):background("#000000"),
    label = tty.style():foreground("#00ff00"):background("#000000"),
}

-- ─── Снятие цифр ─────────────────────────────────────────────────────────

local function snapshot(): any
    local out: any = {taken = tonumber(os_clock.time()) or 0}

    local mem: any = system.memory.stats()
    if type(mem) == "table" then out.memory = mem else out.memory = {} end
    out.goroutines = whole(system.runtime.goroutines())
    out.cpu_count = whole(system.runtime.cpu_count())
    out.max_procs = whole(system.runtime.max_procs())
    out.pid = tostring(system.process.pid())
    out.hostname = tostring(system.process.hostname())

    local procs, perr = system.hosts.processes("")
    if type(procs) == "table" then
        out.processes = model.processes(procs)
    else
        out.processes, out.processes_error = {}, tostring(perr or "список процессов не прочитан")
    end
    local hosts, herr = system.hosts.list()
    if type(hosts) == "table" then out.hosts = hosts else out.hosts, out.hosts_error = {}, tostring(herr) end

    -- Узел и кластер могут быть закрыты правами или не подняты вовсе — тогда
    -- вкладка говорит об этом, а не рисует пустоту.
    local ok_node, node_id = pcall(function() return system.node.id() end)
    out.node_id = ok_node and tostring(node_id) or nil
    local ok_role, role = pcall(function() return system.node.role() end)
    out.node_role = ok_role and tostring(role) or nil
    local ok_members, members = pcall(function() return system.cluster.members() end)
    out.members = ok_members and type(members) == "table" and members or nil
    local ok_leader, leader = pcall(function() return system.cluster.leader() end)
    out.leader = ok_leader and tostring(leader) or nil
    local ok_raft, raft_role = pcall(function() return system.raft.role() end)
    out.raft_role = ok_raft and tostring(raft_role) or nil

    return out
end

-- ─── Рисование ───────────────────────────────────────────────────────────

local function put_text(canvas, x: any, y: any, style: any, text: any, room: any)
    local span = whole(room)
    if span < 1 then return end
    canvas:put(whole(x), whole(y), widgets.fit(style, tostring(text), span), span)
end

-- Ящик с подписью сверху и чёрным полем графика внутри.
local function box(canvas, rect: any, title)
    if rect.w < 4 or rect.h < 3 then return nil end
    put_text(canvas, rect.x, rect.y, styles.face, title, rect.w)
    widgets.field(canvas, rect.x, rect.y + 1, rect.w, rect.h - 1)
    return {x = rect.x + 1, y = rect.y + 2, w = rect.w - 2, h = rect.h - 3}
end

local function draw_graph(canvas, inner: any, history: any, unit: any)
    if not inner or inner.w < 2 or inner.h < 1 then return end
    local rows, top = model.graph(history, inner.w, inner.h, 0)
    for index, row in ipairs(rows) do
        -- Сетка — точки там, где график пуст; график перекрывает сетку.
        local parts = {}
        local column = 0
        for _, code in utf8.codes(row) do
            column = column + 1
            local char = utf8.char(code)
            if char == " " then
                parts[#parts + 1] = graph_styles.grid:render(column % 4 == 0 and "·" or " ")
            else
                parts[#parts + 1] = graph_styles.line:render(char)
            end
        end
        canvas:put(whole(inner.x), whole(inner.y) + index - 1, table.concat(parts), whole(inner.w))
    end
    local label = string.format("%s %s", tostring(top), unit)
    canvas:put(whole(inner.x), whole(inner.y), graph_styles.label:render(label), whole(math.min(inner.w, widgets.cells(label))))
end

-- Датчик: число крупно и полоска заполнения от нуля до потолка истории.
local function draw_gauge(canvas, inner: any, value: any, ceiling: any, caption: any)
    if not inner or inner.w < 3 or inner.h < 2 then return end
    local blank = graph_styles.grid:render(string.rep(" ", inner.w))
    local ix, iy, iw = whole(inner.x), whole(inner.y), whole(inner.w)
    for row = 0, whole(inner.h) - 1 do canvas:put(ix, iy + row, blank, iw) end
    local top = tonumber(ceiling) or 0
    if top <= 0 then top = 1 end
    local filled = whole(math.floor(math.min(1, (tonumber(value) or 0) / top) * inner.w + 0.5))
    local bar = graph_styles.line:render(string.rep("█", filled)) .. graph_styles.grid:render(string.rep("░", inner.w - filled))
    canvas:put(ix, iy + whole(inner.h) - 1, bar, iw)
    put_text(canvas, ix, iy, graph_styles.label, caption, iw)
end

local function draw_numbers(canvas, rect: any, title: any, lines: any)
    if rect.w < 10 or rect.h < 2 then return end
    put_text(canvas, rect.x, rect.y, styles.face_bold, title, rect.w)
    for index, pair in ipairs(lines) do
        local row = rect.y + index
        if row >= rect.y + rect.h then break end
        local label, value = tostring(pair[1]), tostring(pair[2])
        local value_w = widgets.cells(value)
        put_text(canvas, rect.x + 1, row, styles.face, label, rect.w - value_w - 2)
        canvas:put(whole(rect.x + rect.w - value_w), whole(row), styles.face:render(value), value_w)
    end
end

local function draw_list(canvas, page: any, header: any, rows: any, offset: any, failure: any)
    if page.w < 4 or page.h < 2 then return end
    put_text(canvas, page.x, page.y, styles.face_bold, header, page.w)
    widgets.field(canvas, page.x, page.y + 1, page.w, page.h - 1)
    local inner = {x = page.x + 1, y = page.y + 2, w = page.w - 2, h = page.h - 3}
    if inner.w < 1 or inner.h < 1 then return end
    local blank = styles.field:render(string.rep(" ", inner.w))
    for row = 0, whole(inner.h) - 1 do canvas:put(whole(inner.x), whole(inner.y) + row, blank, whole(inner.w)) end
    if failure then
        put_text(canvas, inner.x + 1, inner.y, styles.field, failure, inner.w - 2)
        return
    end
    for index = 1, inner.h do
        local line = rows[whole(offset) + index]
        if not line then break end
        put_text(canvas, inner.x, inner.y + index - 1, styles.field, line, inner.w)
    end
end

local function draw(out, canvas, width: any, height: any, view: any)
    local w, h = whole(width), whole(height)
    canvas:clear(styles.face:render(" "))
    local blank = styles.face:render(string.rep(" ", w))
    for row = 1, h do canvas:put(1, row, blank, w) end

    local plan: any = model.layout(w, h)
    view.tab_hits = widgets.tabs(canvas, plan.tabs.x, plan.tabs.y, plan.tabs.w, plan.tabs.h, model.TABS, view.tab)
    local page = plan.page
    local snap: any = view.snapshot or {}
    local tab = (model.TABS[whole(view.tab)] :: any).id

    if tab == "apps" then
        local rows = {}
        for _, window in ipairs(view.windows or {}) do
            local record: any = window
            rows[#rows + 1] = string.format("%-6s %-38s %s", tostring(record.id or ""),
                widgets.clip(tostring(record.title or ""), 38),
                record.minimized and "свёрнуто" or (record.ready and "работает" or "запускается"))
        end
        draw_list(canvas, page, "Задача                                        Состояние", rows, view.offset, view.windows_error)
    elseif tab == "procs" then
        local rows = {}
        for _, proc in ipairs(snap.processes or {}) do
            rows[#rows + 1] = string.format("%-13s %-36s %-9s %7d", model.short_pid(proc.pid),
                widgets.clip(proc.source, 36), widgets.clip(proc.state, 9), proc.steps)
        end
        draw_list(canvas, page, "PID           Запись                               Состояние   Шагов", rows, view.offset, snap.processes_error)
    elseif tab == "perf" then
        local perf = plan.perf
        if not perf then
            put_text(canvas, page.x, page.y, styles.face, "Окно слишком мало для графиков", page.w)
        else
            local mem: any = snap.memory or {}
            local heap = tonumber(mem.heap_in_use) or 0
            local _, heap_top = model.graph(view.heap_history, 1, 1, 0)
            local _, go_top = model.graph(view.goroutine_history, 1, 1, 0)

            draw_gauge(canvas, box(canvas, perf.gauge_a, "Горутины"), snap.goroutines, go_top, tostring(snap.goroutines or 0))
            draw_graph(canvas, box(canvas, perf.graph_a, "Горутины во времени"), view.goroutine_history, "")
            draw_gauge(canvas, box(canvas, perf.gauge_b, "Куча"), heap, heap_top, model.megabytes(heap))
            local heap_mb = {}
            for _, value in ipairs(view.heap_history) do heap_mb[#heap_mb + 1] = value / (1024 * 1024) end
            draw_graph(canvas, box(canvas, perf.graph_b, "Память во времени"), heap_mb, "МБ")

            if perf.numbers_h >= 2 then
                draw_numbers(canvas, perf.left, "Память", {
                    {"Занято", model.megabytes(mem.alloc)},
                    {"Куча в работе", model.megabytes(mem.heap_in_use)},
                    {"Куча у системы", model.megabytes(mem.heap_sys)},
                    {"Отдано системе", model.megabytes(mem.heap_released)},
                    {"Сборок мусора", tostring(whole(mem.num_gc))},
                })
                local started = model.oldest_start(snap.processes)
                local uptime = started and model.uptime((tonumber(snap.taken) or 0) - started) or "—"
                draw_numbers(canvas, perf.right, "Система", {
                    {"Процессов", tostring(#(snap.processes or {}))},
                    {"Хостов", tostring(#(snap.hosts or {}))},
                    {"Горутин", tostring(snap.goroutines or 0)},
                    {"Ядер / потоков", string.format("%d / %d", snap.cpu_count or 0, snap.max_procs or 0)},
                    {"Работает", uptime},
                })
            end
        end
    elseif tab == "node" then
        local lines = {
            {"Узел", snap.node_id or "недоступно"},
            {"Роль", snap.node_role or "недоступно"},
            {"Лидер", snap.leader or "—"},
            {"Raft", snap.raft_role or "—"},
            {"Участников", snap.members and tostring(#snap.members) or "—"},
            {"Хост", tostring(snap.hostname or "")},
            {"PID рантайма", tostring(snap.pid or "")},
        }
        draw_numbers(canvas, {x = page.x, y = page.y, w = math.min(page.w, 60), h = page.h}, "Узел рантайма", lines)
        local hosts_y = whole(page.y) + #lines + 2
        if hosts_y < whole(page.y) + whole(page.h) then
            local rows = {}
            for _, host in ipairs(snap.hosts or {}) do
                local record: any = host
                rows[#rows + 1] = string.format("%-40s %4d раб. %5d проц. %8d вып.",
                    widgets.clip(tostring(record.id or ""), 40), whole(record.workers),
                    whole(record.processes), whole(record.executed))
            end
            draw_list(canvas, {x = page.x, y = hosts_y, w = page.w, h = whole(page.y) + whole(page.h) - hosts_y},
                "Хосты процессов", rows, 0, snap.hosts_error)
        end
    end

    local mem: any = snap.memory or {}
    widgets.statusbar(canvas, 1, plan.status_row, w, {
        {text = string.format("Процессов: %d", #(snap.processes or {})), width = 16},
        {text = string.format("Горутин: %d", snap.goroutines or 0), width = 14},
        {text = "Память: " .. model.megabytes(mem.alloc)},
    })

    assert(out:present(canvas:rows(), {cursor = {x = 1, y = 1, visible = false}}))
end

-- ─── Окно ────────────────────────────────────────────────────────────────

local function main()
    local events = assert(tty.events())
    assert(tty.start())
    local out = assert(tty.surface({hide_cursor = true, synchronized_output = true}))

    local width, height = tty.screen_size()
    width, height = whole(width), whole(height)
    if width < 20 then width = 66 end
    if height < 8 then height = 22 end

    local view: any = {
        tab = 3,
        offset = 0,
        snapshot = nil,
        heap_history = {},
        goroutine_history = {},
        windows = nil,
        windows_error = nil,
        tab_hits = {},
    }

    local function sample()
        local snap = snapshot()
        view.snapshot = snap
        local mem: any = snap.memory or {}
        view.heap_history = model.push(view.heap_history, tonumber(mem.heap_in_use) or 0, HISTORY_CAP)
        view.goroutine_history = model.push(view.goroutine_history, snap.goroutines, HISTORY_CAP)
        -- Список окон — у композитора, и спрашивается только когда вкладка
        -- открыта: ждать ответа раз в секунду ради вкладки, которую не
        -- смотрят, незачем.
        if (model.TABS[whole(view.tab)] :: any).id == "apps" then
            local answer, err = desktop.list({timeout = "300ms"})
            if answer then
                view.windows, view.windows_error = answer.windows or {}, nil
            else
                view.windows, view.windows_error = {}, tostring(err)
            end
        end
    end

    local canvas = tty.canvas(width, height)
    sample()
    draw(out, canvas, width, height, view)

    local function switch(tab: any)
        view.tab = math.max(1, math.min(#model.TABS, whole(tab)))
        view.offset = 0
        sample()
    end

    local ticker = time.after(TICK)
    while true do
        local selected = channel.select({events:case_receive(), ticker:case_receive()})
        if not selected.ok then break end

        if selected.channel == ticker then
            sample()
            draw(out, canvas, width, height, view)
            ticker = time.after(TICK)
        else
            local event = selected.value
            if event.type == "close" then
                break
            elseif event.type == "resize" then
                local w, h = whole(event.width), whole(event.height)
                if w >= 20 then width = w end
                if h >= 8 then height = h end
                canvas = tty.canvas(width, height)
                draw(out, canvas, width, height, view)
            elseif event.type == "key" and event.action ~= "release" then
                local key = tostring(event.key or "")
                if key == "right" or key == "tab" then switch(view.tab + 1)
                elseif key == "left" then switch(view.tab - 1)
                elseif key:match("^[1-4]$") then switch(whole(key))
                elseif key == "down" then view.offset = view.offset + 1
                elseif key == "up" then view.offset = math.max(0, view.offset - 1)
                elseif key == "pgdown" then view.offset = view.offset + math.max(1, height - 6)
                elseif key == "pgup" then view.offset = math.max(0, view.offset - math.max(1, height - 6))
                elseif key == "home" then view.offset = 0
                elseif key == "r" then sample()
                end
                draw(out, canvas, width, height, view)
            elseif event.type == "mouse" and event.action == "press" then
                local tab = model.tab_at(view.tab_hits, event.x, event.y)
                if tab then
                    switch(tab)
                    draw(out, canvas, width, height, view)
                end
            elseif event.type == "mouse" and event.action == "wheel" then
                if event.button == "wheel_down" then view.offset = view.offset + 3
                elseif event.button == "wheel_up" then view.offset = math.max(0, view.offset - 3) end
                draw(out, canvas, width, height, view)
            end
        end
    end

    assert(out:close())
    assert(tty.stop())
end

return {main = main}
