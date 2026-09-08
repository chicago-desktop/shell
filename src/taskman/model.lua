-- Диспетчер задач: чистая модель.
--
-- Всё, что можно посчитать без рантайма, считается здесь и проверяется
-- прямо: история измерений, график блочными символами, форматы чисел,
-- раскладка вкладок. Окно только снимает цифры и рисует то, что отсюда
-- вернулось. Разойдись раскладка с рисованием — щелчок по вкладке попадал бы
-- на соседнюю; поэтому прямоугольники считает одна функция, а рисует и
-- проверяет попадания её результат.

local charts = require("charts")

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

local geometry = require("geometry")
local whole = geometry.whole

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
--
-- Столбцы блочными символами и круглый потолок переехали в SDK
-- (`butschster.windows.sdk:charts`): график нужен любому окну с историей
-- числа. Здесь остались имена, по которым их зовут тесты и окно.
model.LEVELS = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
model.graph = charts.graph
model.round_ceiling = charts.round_ceiling

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

return model
