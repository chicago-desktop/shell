-- Task Manager: the pure model.
--
-- Everything that can be computed without the runtime is computed here and
-- checked directly: measurement history, the graph in block characters,
-- number formats, the tab layout. The window only takes the numbers and
-- draws what came back from here. If the layout diverged from the drawing, a
-- click on a tab would land on the neighbouring one; that is why one
-- function computes the rectangles, and both drawing and hit checks use its
-- result.

local charts = require("charts")

local model = {}

-- Tabs. The order is as in the Task Manager screenshot: applications,
-- processes, performance; the fourth, instead of "Networking", is the node,
-- because for us the network is the runtime cluster, not network adapters.
model.TABS = {
    {id = "apps", text = "Applications"},
    {id = "procs", text = "Processes"},
    {id = "perf", text = "Performance"},
    {id = "node", text = "Node"},
}

local geometry = require("geometry")
local whole = geometry.whole

model.whole = whole

-- ─── History ─────────────────────────────────────────────────────────────

-- push(history, value, cap): add a measurement, keep no more than cap.
--
-- The history runs from old to new; the graph reads it right to left, so
-- that the latest measurement stands at the right edge, as in the
-- screenshot.
function model.push(history: any, value: any, cap: any)
    local list: any = type(history) == "table" and history or {}
    list[#list + 1] = tonumber(value) or 0
    local limit = math.max(1, whole(cap))
    while #list > limit do table.remove(list :: {any}, 1) end
    return list
end

-- ─── Graph ───────────────────────────────────────────────────────────────
--
-- Columns in block characters and the round ceiling moved to the SDK
-- (`butschster.windows.sdk:charts`): any window with a history of a number
-- needs a graph. What stayed here are the names by which the tests and the
-- window call them.
model.LEVELS = {"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
model.graph = charts.graph
model.round_ceiling = charts.round_ceiling

-- ─── Formats ─────────────────────────────────────────────────────────────

function model.megabytes(bytes: any): string
    local n = tonumber(bytes) or 0
    if n < 1024 * 1024 then return string.format("%.1f MB", n / (1024 * 1024)) end
    return string.format("%d MB", whole(n / (1024 * 1024)))
end

function model.bytes(value: any): string
    local n = tonumber(value) or 0
    if n < 1024 then return string.format("%d B", whole(n)) end
    if n < 1024 * 1024 then return string.format("%d KB", whole(n / 1024)) end
    return model.megabytes(n)
end

-- uptime(seconds) -> "0:08:21" or "3d 04:15:02"
function model.uptime(seconds: any): string
    local total = math.max(0, whole(seconds))
    local days = total // 86400
    local hours = (total % 86400) // 3600
    local minutes = (total % 3600) // 60
    local secs = total % 60
    if days > 0 then
        return string.format("%dd %02d:%02d:%02d", days, hours, minutes, secs)
    end
    return string.format("%d:%02d:%02d", hours, minutes, secs)
end

-- epoch_seconds(stamp) -> Unix seconds from a number of unknown unit.
--
-- The runtime returns started_at as a number, and what it is in (seconds,
-- milliseconds or nanoseconds) depends on who filled it in. The order of
-- magnitude tells them apart reliably: there are fewer than 10¹¹ seconds
-- since 1970, fewer than 10¹⁴ milliseconds.
function model.epoch_seconds(stamp: any): number
    local n = tonumber(stamp) or 0
    if n > 1e17 then return n / 1e9 end
    if n > 1e14 then return n / 1e6 end
    if n > 1e11 then return n / 1e3 end
    return n
end

-- short_pid(pid) -> the tail of the identifier, so that it fits the column
function model.short_pid(pid: any): string
    local text = tostring(pid or "")
    if #text <= 12 then return text end
    return "…" .. text:sub(-11)
end

-- ─── Processes ───────────────────────────────────────────────────────────

-- processes(list) -> sorted rows {pid, source, state, steps, host, started}
--
-- Sorting by source, then by pid: a list that jumps on every refresh cannot
-- be read. Sorting by steps would sort by "who is more active", but activity
-- changes every second, and a row would slide out from under your eyes.
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

-- oldest_start(rows) -> the earliest started, or nil
function model.oldest_start(rows: any): any
    local oldest: any = nil
    for _, row in ipairs(type(rows) == "table" and rows or {}) do
        local at = tonumber(row.started) or 0
        if at > 0 and (oldest == nil or at < oldest) then oldest = at end
    end
    return oldest
end

return model
