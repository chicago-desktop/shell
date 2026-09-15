-- The startup process: spawned by the logon wrapper (`startup.begin`) with
-- the compositor's pid and the logged-on user's id; it opens that person's
-- startup windows through the compositor and ends. programs/startup.lua says
-- why it is a process of its own.
local startup = require("startup")

local function main(desktop: any, user_id: any)
    -- Bound first, returned after: a tail call of a yielding function from a
    -- coroutine's base frame is silently not executed in go-lua.
    local report = startup.run(desktop, user_id)
    return report ~= nil
end

return {main = main}
