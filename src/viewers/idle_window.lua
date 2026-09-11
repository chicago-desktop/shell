-- Body of a view window's entry.
--
-- A window with `window_content: pixels` is not started by the compositor:
-- the theme draws it, the state provider brings the data. The entry must
-- still be a process — that is how the catalog finds it — and this file
-- exists for the sake of that form. If it is started after all, the entry
-- was opened not as a view; then it simply waits to be shut down and draws
-- nothing.
local channel = require("channel")
local time = require("time")

local function main()
    while true do
        local picked = channel.select({time.after("30s"):case_receive()})
        if not picked.ok then break end
    end
end

return {main = main}
