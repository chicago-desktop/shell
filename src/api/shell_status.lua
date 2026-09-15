-- GET /chicago/status — whether the shell is alive and how its workshop
-- windows are doing.
--
-- The only place where a person can see restore_report. The terminal host
-- log is muted on purpose (otherwise a log line scrambles the frame for
-- good), so a restore failure told only to the log is told to no one:
-- windows built by the workshop would simply not appear in the menu, and
-- there would be nothing to explain it with.
--
-- A shut-down shell is not an endpoint failure: the answer is 200 with
-- `running = false`. A 500 here would mean the stand is broken, whereas it
-- is simply not running.

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

    -- Raw frames of the frame measurement — only on request
    -- (`?frame_samples=1`): the summary over the last two hundred frames is
    -- always sent, it is small.
    local answer, err, running = control.call("desktop.list", {
        frame_samples = req:query("frame_samples") == "1",
    })
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
        -- Restore report for workshop windows: skipped / restored / failed /
        -- names / error.
        restore = answer.restore,
        -- Compositor frame instruments: paint_ms/present_ms/trigger of the
        -- last frame and the `window` summary over the last frames. Without
        -- them the answer to "why is it slow" can only be had by eye.
        frame = answer.frame,
    })
end

return {handler = handler}
