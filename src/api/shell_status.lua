-- GET /windows/status — жива ли оболочка и что у неё с окнами мастерской.
--
-- Единственное место, где человек может увидеть restore_report. Лог
-- терминального хоста заглушён намеренно (иначе строка лога разъезжает кадр
-- насовсем), поэтому отказ восстановления, рассказанный только в лог, не
-- рассказан никому: окна, собранные мастерской, просто не появились бы в
-- меню, и объяснить это было бы нечем.
--
-- Погашенная оболочка — не отказ ручки: ответ 200 с `running = false`.
-- Пятисотка здесь означала бы, что стенд сломан, тогда как он просто не
-- запущен.

local http = require("http")
local security = require("security")
local control = require("control")

local function handler()
    local res = http.response()
    local req = http.request()
    if not res or not req then return nil, "no http context" end
    res:set_content_type(http.CONTENT.JSON)

    if not security.actor() then
        res:set_status(http.STATUS.UNAUTHORIZED)
        res:write_json({success = false, error = "authentication required"})
        return
    end

    local answer, err, running = control.call("desktop.list", {})
    if not answer then
        res:set_status(http.STATUS.OK)
        res:write_json({success = true, running = running == true, error = err})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        running = true,
        windows = answer.windows,
        focused = answer.focused,
        screen = answer.screen,
        -- Отчёт восстановления окон мастерской: skipped / restored / failed /
        -- names / error.
        restore = answer.restore,
    })
end

return {handler = handler}
