-- Диспетчер задач: чистая модель.
--
-- Всё, что можно посчитать без рантайма, считается здесь и проверяется
-- прямо: история измерений, график блочными символами, форматы чисел,
-- раскладка вкладок. Окно только снимает цифры и рисует то, что отсюда
-- вернулось. Разойдись раскладка с рисованием — щелчок по вкладке попадал бы
-- на соседнюю; поэтому прямоугольники считает одна функция, а рисует и
-- проверяет попадания её результат.

local model = {}

-- Вкладки. Порядок — как на кадре диспетчера: приложения, процессы,
-- быстродействие; четвёртая вместо «Сети» — узел, потому что сеть у нас
-- это кластер рантайма, а не сетевые адаптеры.
model.TABS = {
    {id = "apps", text = "Приложения"},
    {id = "procs", text = "Процессы"},
    {id = "perf", text = "Быстродействие"},
    {id = "node", text = "Узел"},
}

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

model.whole = whole

-- ─── История ─────────────────────────────────────────────────────────────

-- push(history, value, cap) — добавить измерение, держать не больше cap.
--
-- История живёт от старого к новому; график читает её справа налево, чтобы
-- последнее измерение стояло у правого края, как на кадре.
function model.push(history: any, value: any, cap: any)
    local list: any = type(history) == "table" and history or {}
    list[#list + 1] = tonumber(value) or 0
    local limit = math.max(1, whole(cap))
    while #list > limit do table.remove(list :: {any}, 1) end
    return list
end

-- ─── График ──────────────────────────────────────────────────────────────

-- Восемь уровней заполнения ячейки снизу вверх. Строка целиком заполненная —
-- восьмой; пустая — пробел. Это единственный набор символов графика, и он
-- однобайтовый по ширине: все восемь — одна ячейка.
model.LEVELS = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}

-- graph(history, width, height, ceiling) -> строки сверху вниз, потолок
--
-- Столбец на измерение, последнее — справа. Потолок — максимум истории,
-- округлённый вверх до «круглого», чтобы график не дёргался на каждом
-- измерении; ноль-потолок читается как единица, иначе деление на ноль
-- нарисовало бы пустоту при нулевой нагрузке и не отличалось бы от отказа.
function model.graph(history: any, width: any, height: any, ceiling: any): (any, any)
    local w, h = whole(width), whole(height)
    local rows: {string} = {}
    if w < 1 or h < 1 then return rows, 1 end

    local list: any = type(history) == "table" and history or {}
    local count = whole(#list)
    local top = tonumber(ceiling) or 0
    if top <= 0 then
        local peak = 0
        for _, value in ipairs(list) do
            local number = tonumber(value) or 0
            if number > peak then peak = number end
        end
        top = model.round_ceiling(peak)
    end
    if top <= 0 then top = 1 end

    local units = h * 8
    -- Столбцы: сколько восьмушек заполнено у каждого; -1 — измерения нет.
    -- Явный if вместо `a and b or nil`: на этой конструкции падал сам
    -- тайп-чекер линтера, и падение не называло места.
    local columns: {integer} = {}
    for column = 1, w do
        local index = count - w + column
        local filled = -1
        if index >= 1 then
            local value = tonumber(list[index]) or 0
            if value > top then value = top end
            filled = whole(math.floor(value / top * units + 0.5))
            if filled < 0 then filled = 0 end
            if filled > units then filled = units end
        end
        columns[column] = filled
    end

    for row = 1, h do
        local parts: {string} = {}
        -- Строка row считается сверху; снизу это уровень h - row.
        local floor = (h - row) * 8
        for column = 1, w do
            local filled = columns[column]
            local char = " "
            if filled >= floor + 8 then
                char = model.LEVELS[8]
            elseif filled > floor then
                char = model.LEVELS[filled - floor]
            end
            parts[column] = char
        end
        rows[row] = table.concat(parts)
    end
    return rows, top
end

-- round_ceiling(value) -> «круглый» потолок не меньше value
function model.round_ceiling(value: any): number
    local v = tonumber(value) or 0
    if v <= 0 then return 0 end
    local magnitude = 10.0 ^ math.floor(math.log(v, 10))
    local steps = {1.0, 2.0, 2.5, 5.0, 10.0}
    for _, step in ipairs(steps) do
        if magnitude * step >= v then return magnitude * step end
    end
    return magnitude * 10
end

-- ─── Форматы ─────────────────────────────────────────────────────────────

function model.megabytes(bytes: any): string
    local n = tonumber(bytes) or 0
    if n < 1024 * 1024 then return string.format("%.1f МБ", n / (1024 * 1024)) end
    return string.format("%d МБ", whole(n / (1024 * 1024)))
end

function model.bytes(value: any): string
    local n = tonumber(value) or 0
    if n < 1024 then return string.format("%d Б", whole(n)) end
    if n < 1024 * 1024 then return string.format("%d КБ", whole(n / 1024)) end
    return model.megabytes(n)
end

-- uptime(seconds) -> "0:08:21" или "3 д 04:15:02"
function model.uptime(seconds: any): string
    local total = math.max(0, whole(seconds))
    local days = total // 86400
    local hours = (total % 86400) // 3600
    local minutes = (total % 3600) // 60
    local secs = total % 60
    if days > 0 then
        return string.format("%d д %02d:%02d:%02d", days, hours, minutes, secs)
    end
    return string.format("%d:%02d:%02d", hours, minutes, secs)
end

-- epoch_seconds(stamp) -> секунды Unix из числа неизвестной размерности.
--
-- Рантайм отдаёт started_at числом, а в чём — секунды, миллисекунды или
-- наносекунды — зависит от того, кто заполнял. Порядок величины различает их
-- надёжно: секунд с 1970 года меньше 10¹¹, миллисекунд меньше 10¹⁴.
function model.epoch_seconds(stamp: any): number
    local n = tonumber(stamp) or 0
    if n > 1e17 then return n / 1e9 end
    if n > 1e14 then return n / 1e6 end
    if n > 1e11 then return n / 1e3 end
    return n
end

-- short_pid(pid) -> хвост идентификатора, чтобы влезал в колонку
function model.short_pid(pid: any): string
    local text = tostring(pid or "")
    if #text <= 12 then return text end
    return "…" .. text:sub(-11)
end

-- ─── Процессы ────────────────────────────────────────────────────────────

-- processes(list) -> отсортированные строки {pid, source, state, steps, host, started}
--
-- Сортировка по источнику, потом по pid: список, который прыгает при каждом
-- обновлении, нельзя читать. По шагам сортировал бы «кто активнее», но
-- активность меняется каждую секунду, и строка уезжала бы из-под глаз.
function model.processes(list: any): any
    local out = {}
    for _, item in ipairs(type(list) == "table" and list or {}) do
        local record: any = item
        out[#out + 1] = {
            pid = tostring(record.pid or ""),
            source = tostring(record.source or "?"),
            state = tostring(record.state or ""),
            steps = whole(record.steps),
            host = tostring(record.host or ""),
            started = model.epoch_seconds(record.started_at),
        }
    end
    table.sort(out, function(left, right)
        if left.source ~= right.source then return left.source < right.source end
        return left.pid < right.pid
    end)
    return out
end

-- oldest_start(rows) -> самое раннее started, или nil
function model.oldest_start(rows: any): any
    local oldest: any = nil
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local at = tonumber(row.started) or 0
        if at > 0 and (oldest == nil or at < oldest) then oldest = at end
    end
    return oldest
end

-- ─── Раскладка ───────────────────────────────────────────────────────────

-- layout(width, height) -> прямоугольники
--
-- Вкладки занимают всё окно кроме статусной строки; внутри вкладки —
-- «страница»: прямоугольник внутри рамки вкладок с полем в одну ячейку.
-- На странице «Быстродействие» — четыре ящика, как на кадре: два графика
-- справа, два датчика слева, два блока цифр внизу.
function model.layout(width: any, height: any): any
    local w, h = whole(width), whole(height)
    local tabs = {x = 1, y = 1, w = w, h = math.max(4, h - 1)}
    local page = {x = tabs.x + 2, y = tabs.y + 2, w = math.max(0, tabs.w - 4), h = math.max(0, tabs.h - 3)}
    local status_row = h

    local perf: any = nil
    if page.w >= 30 and page.h >= 10 then
        local gauge_w = math.min(14, page.w // 4)
        local graph_w = page.w - gauge_w - 1
        local numbers_h = math.min(6, math.max(0, page.h - 8))
        local graphs_h = page.h - numbers_h
        local each = graphs_h // 2
        perf = {
            gauge_a = {x = page.x, y = page.y, w = gauge_w, h = each},
            graph_a = {x = page.x + gauge_w + 1, y = page.y, w = graph_w, h = each},
            gauge_b = {x = page.x, y = page.y + each, w = gauge_w, h = graphs_h - each},
            graph_b = {x = page.x + gauge_w + 1, y = page.y + each, w = graph_w, h = graphs_h - each},
            numbers_h = numbers_h,
            left = {x = page.x, y = page.y + graphs_h, w = page.w // 2, h = numbers_h},
            right = {x = page.x + page.w // 2 + 1, y = page.y + graphs_h, w = page.w - page.w // 2 - 1, h = numbers_h},
        }
    end
    return {tabs = tabs, page = page, status_row = status_row, perf = perf}
end

-- tab_at(hits, x, y) -> номер вкладки или nil
function model.tab_at(hits: any, x: any, y: any): any
    return nil
end

return model
