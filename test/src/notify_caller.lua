-- A caller of the notify library that is not a window: notify_test spawns it
-- under a scope of its choosing and reads what the call answered. The answer
-- is the process's result, read from its EXIT event: a caller whose scope may
-- not send could report it no other way. The args are JSON (a pid has a "|"
-- in it).
local json = require("json")
local notify = require("notify")

local function main(args: any): any
    local spec: any = json.decode(tostring(args)) or {}
    -- The suite's own desktop family, not the shell's (notify_test says why).
    if type(spec.family) == "string" and spec.family ~= "" then notify.FAMILY = spec.family end
    local reached, why = notify.balloon({user = spec.user, title = "Rights", text = "Only the notify policy."})
    return {reached = reached, why = why ~= nil and tostring(why) or nil}
end

return {main = main}
