-- AntiBug (FR-009 §3) measurement: a function entry with its OWN declared
-- actor and policy. It reports who it runs as and what it may do, so the test
-- sees whether a `funcs` call honours the callee's `security` block.
local security = require("security")

local function run(): any
    local actor = security.actor()
    return {
        actor = actor and actor:id() or nil,
        probe = security.can("antibug.probe", "target") == true,
        other = security.can("antibug.other", "target") == true,
    }
end

return {run = run}
