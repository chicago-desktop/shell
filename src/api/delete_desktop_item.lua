-- DELETE /windows/desktop/{id} — remove a desktop shortcut or folder.
--
-- The answer says whether the row EXISTED: "deleted something nonexistent"
-- and "deleted" are different answers, otherwise a typo in the identifier
-- looks like a successful deletion.
--
-- A deleted shortcut of a program with `desktop: true` does NOT come back on
-- the next start: the mark that the program has already been offered is kept
-- separately and is not touched when the icon is deleted. Without this,
-- deleting the icon would not work at all.
--
-- The contents of a deleted folder return to the desktop instead of being
-- deleted along with it: a cascade would carry off icons the user had put
-- into it, and there would be nothing to restore them with. The answer names
-- the number moved out.

local http = require("http")
local security = require("security")
local repo = require("repo")
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

    local id = req:param("id")
    if type(id) ~= "string" or id == "" then
        res:set_status(http.STATUS.BAD_REQUEST)
        res:write_json({success = false, error = "id: shortcut not named"})
        return
    end

    -- The layout of the person asking: another person's icon is not theirs to delete.
    local result, err = repo.of(tostring(security.actor():id())).delete(id)
    if err or not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "deleting: " .. tostring(err or "row untouched")})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        id = id,
        existed = result.existed == true,
        promoted = result.promoted,
        shell = control.refresh(),
        note = "a program with desktop true is no longer offered: the offered mark is not cleared",
    })
end

return {handler = handler}
