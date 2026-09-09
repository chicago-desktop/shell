-- «Дата и время» — диалог на SDK оболочки, вид «Свойства: Дата и время»
-- Windows 95. Только для чтения: крутить нечего, «ОК» и «Отмена»
-- закрывают, «Применить» выключена навсегда.
--
-- Календарь и стрелочные часы — компоненты SDK (`calendar`, `clock`);
-- месяц, год и цифровое время — поля только для чтения. Секунда приходит
-- тиком раз в секунду; если она не сменилась, кадр не перерисовывается.
local time = require("time")
local geometry = require("geometry")
local app = require("app")

local whole = geometry.whole

local MONTHS = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

-- Снимок часов. Календарную арифметику считает модуль time: день 0
-- следующего месяца — это последний день текущего, и високосность с ним.
local function snapshot(): any
    local now = time.now():in_local()
    local year, month, day = now:date()
    local hour, minute, second = now:clock()
    local first = time.date(whole(year), whole(month), 1, 0, 0, 0, 0, now:location())
    local last = time.date(whole(year), whole(month) + 1, 0, 0, 0, 0, 0, now:location())
    return {
        year = whole(year), month = whole(month), day = whole(day),
        hour = whole(hour), minute = whole(minute), second = whole(second),
        first_weekday = (whole(first:weekday()) + 6) % 7,
        days = whole(last:day()),
        zone = "UTC" .. now:format("-07:00"),
    }
end

local function zone_caption(zone: any): string
    local given = type(zone) == "string" and zone or ""
    if given == "" then return "Current time zone: unknown" end
    return "Current time zone: " .. given
end

local definition: any = {}
definition.interval = "1s"

function definition.init(args: any, context: any): any
    return {clock = snapshot(), tab = 1}
end

function definition.view(state: any, context: any): any
    local c: any = state.clock
    local digital = string.format("%02d:%02d:%02d", whole(c.hour), whole(c.minute), whole(c.second))
    local page: any
    if state.tab == 1 then
        page = {kind = "column", gap = 0, children = {
            {kind = "row", gap = 1, children = {
                {kind = "group", title = "Date", children = {
                    {kind = "row", size = 1, gap = 1, children = {
                        {kind = "field", text = tostring(MONTHS[whole(c.month)] or "—")},
                        {kind = "field", size = 7, text = tostring(c.year)},
                    }},
                    {kind = "calendar", year = c.year, month = c.month, day = c.day,
                        first_weekday = c.first_weekday, days = c.days},
                }},
                {kind = "group", size = 16, title = "Time", children = {
                    {kind = "clock", hour = c.hour, minute = c.minute, second = c.second},
                    {kind = "field", size = 1, text = digital, align = "left"},
                }},
            }},
            {kind = "label", size = 1, text = zone_caption(c.zone)},
        }}
    else
        page = {kind = "column", padding = 1, children = {
            {kind = "label", size = 1, text = zone_caption(c.zone)},
            {kind = "label", text = "The time zone is set by the system; it is only shown here."},
        }}
    end
    return {kind = "column", padding = 1, gap = 0, children = {
        {kind = "tabs", id = "pages", labels = {"Date & Time", "Time Zone"}, active = state.tab, children = {page}},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = ""},
            {kind = "button", id = "ok", size = 10, text = "OK", default = true},
            {kind = "button", id = "cancel", size = 10, text = "Cancel"},
            {kind = "button", id = "apply", size = 12, text = "Apply", disabled = true},
        }},
    }}
end

function definition.update(state: any, action: any, context: any)
    if action.type == "tick" then
        local fresh = snapshot()
        local same = fresh.second == state.clock.second and fresh.minute == state.clock.minute
            and fresh.day == state.clock.day
        state.clock = fresh
        return not same
    elseif action.id == "pages" and action.type == "select" then state.tab = whole(action.index)
    elseif action.id == "ok" or action.id == "cancel" then context.close()
    elseif action.type == "key" and (action.key_type == "esc" or action.key_type == "enter") then context.close()
    else return false end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition, snapshot = snapshot}
