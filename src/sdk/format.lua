-- Time, names and refusal text for windows on the SDK (chicago.shell.sdk:format).
--
-- One parse of the timestamps the platform stores (RFC3339 UTC from
-- kickside/cron, SQLite's UTC datetime from kickside/core), one local
-- rendering of them, one rule for the name a person is shown by, and one rule
-- for a refusal's wording by its kind. A window or function that shows a time,
-- a user's name or a refusal takes it from here rather than writing its own —
-- the application's windows once had the same rule written twice and the
-- halves drifted. Pure: no IO, the window passes the clock's offset in
-- (`time.now():format("-07:00")` read through parse_offset).
local errors = require("errors")

local format = {}

-- Declared here, above every use: without it `text` would be the global
-- `text` module, a table, and calling it fails.
local function text(value: any): string
    if value == nil then return "" end
    return tostring(value)
end

-- A whole number as text. tostring prints a whole float without ".0" in
-- this go-lua (measured: the tests stay green with every value here made a
-- float), so no conversion to an integer is needed.
local function digits(value: number): string
    return tostring(math.floor(value))
end

local function two(value: number): string
    local s = digits(value)
    return #s < 2 and ("0" .. s) or s
end

-- ─── time ───────────────────────────────────────────────────────────────

-- Days since 1970-01-01 of a civil date (Howard Hinnant's algorithm).
local function days_from_civil(y: number, m: number, d: number): number
    if m <= 2 then y = y - 1 end
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end

local function civil_from_days(z: number): (number, number, number)
    z = z + 719468
    local era = (z >= 0 and z or z - 146096) // 146097
    local doe = z - era * 146097
    local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    local mp = (5 * doy + 2) // 153
    local d = doy - (153 * mp + 2) // 5 + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

-- parse_offset("+04:00") -> seconds east of UTC. What `time.now():format("-07:00")`
-- gives the window; anything else is UTC.
function format.parse_offset(value: any): number
    local sign, hh, mm = text(value):match("^([+-])(%d%d):?(%d%d)$")
    if not sign then return 0 end
    local seconds = (tonumber(hh) :: number) * 3600 + (tonumber(mm) :: number) * 60
    return sign == "-" and -seconds or seconds
end

-- parse_time(rfc3339) -> unix seconds, or nil for anything that is not a
-- timestamp. Fractions are dropped; a zone offset is honoured.
function format.parse_time(value: any): number?
    local y, mo, d, h, mi, s, rest = text(value):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    local zone = (rest :: string):gsub("^%.%d+", "")
    local offset = 0
    if zone ~= "Z" and zone ~= "z" and zone ~= "" then
        if not zone:match("^[+-]%d%d:?%d%d$") then return nil end
        offset = format.parse_offset(zone)
    end
    local days = days_from_civil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
    return days * 86400 + (tonumber(h) :: number) * 3600 + (tonumber(mi) :: number) * 60 + (tonumber(s) :: number) - offset
end

-- format_time(unix, offset) -> "2026-09-14 11:00" in local time.
function format.format_time(unix: number, offset: number): string
    local local_seconds = math.floor(unix + (offset or 0))
    local days = local_seconds // 86400
    local rest = local_seconds - days * 86400
    local y, m, d = civil_from_days(days)
    return digits(y) .. "-" .. two(m) .. "-" .. two(d) .. " " .. two(rest // 3600) .. ":" .. two((rest % 3600) // 60)
end

-- when(rfc3339, offset, missing) — a stored timestamp for a cell: local time,
-- `missing` when there is none, the raw text when it does not parse (a value
-- the window cannot read is shown, not hidden).
function format.when(value: any, offset: number, missing: string): string
    if value == nil or value == "" then return missing end
    local unix = format.parse_time(value)
    if not unix then return text(value) end
    return format.format_time(unix, offset)
end

format.digits = digits
format.two = two

-- ─── names ──────────────────────────────────────────────────────────────

-- display_name(user) — the name a user row of the users module is shown by:
-- the full name when there is one, else the e-mail, else the id. One rule for
-- the application's logon (the name the Start menu starts with), for the
-- refresh after a rename (CHICAGO_USER_FUNC) and for the windows that list
-- people: two copies of it would make the Start menu change a name that
-- nobody changed.
function format.display_name(user: any): string
    local display = type(user.full_name) == "string" and user.full_name ~= "" and user.full_name or user.email
    return tostring(display or user.user_id)
end

-- ─── refusals ───────────────────────────────────────────────────────────

-- explain(what, err) — a refusal as text for the status bar. The kind decides
-- the wording, the same rule as the shell's config libraries: a permission
-- refusal must not read as "not found" or as a generic failure, because the
-- fix is different (a policy, not the data).
function format.explain(what: string, err: any): string
    if err == nil then return what .. " failed" end
    local message = tostring(err)
    if errors.is(err, errors.PERMISSION_DENIED) then return what .. ": permission denied — " .. message end
    if errors.is(err, errors.NOT_FOUND) then return what .. ": not found — " .. message end
    return what .. ": " .. message
end

return format
