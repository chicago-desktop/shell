-- GET /windows/programs — the program catalog from the registry.
--
-- There is no endpoint to CREATE a program next to it, and there will not be
-- one: programs appear by installing a module or by building a window
-- through the base workshop. A creation endpoint would mean a second source
-- of truth next to the registry, and they would diverge on the very first
-- module removal.
--
-- A registry failure is returned as a failure, not as an empty list. An
-- empty list for an unreadable registry sends a person to look for the
-- error in their own application, where there is none.

local http = require("http")
local security = require("security")
local catalog = require("catalog")

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

    local found, err = catalog.list()
    if err or not found then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = err or "catalog not read"})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        programs = found.programs,
        menu = found.tree,
    })
end

return {handler = handler}
