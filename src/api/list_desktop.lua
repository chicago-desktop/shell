-- GET /chicago/desktop — desktop shortcuts and folders.
--
-- A shortcut stores a reference to a registry entry, so the name and icon
-- here are taken from the catalog, not from the row: the program was
-- updated — the shortcut leads to the new version.
--
-- A shortcut to a vanished entry is returned with `broken = true`, not
-- dropped. A missing icon reads as "I deleted it by accident", a broken one
-- as "the program is gone"; these are different statements, and one must not
-- be substituted for the other.
--
-- An unreadable catalog does not make the layout unavailable: the shortcuts
-- are returned, and `catalog_error` says why they have no broken flag. A
-- refusal as a whole would mean an empty desktop with working storage.

local http = require("http")
local security = require("security")
local repo = require("repo")
local catalog = require("catalog")
local view = require("view")

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

    -- The layout of the person asking: each person has their own desktop.
    local items, err = repo.of(tostring(security.actor():id())).list()
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "reading the layout: " .. tostring(err)})
        return
    end

    -- An unreadable catalog does not cancel the desktop: the shortcuts are
    -- returned as they are, without the broken flag, and the reason is named
    -- in catalog_error.
    local found, cerr = catalog.list()

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        items = view.join(items, cerr and nil or found),
        catalog_error = cerr,
    })
end

return {handler = handler}
