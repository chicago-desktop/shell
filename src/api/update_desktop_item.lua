-- PATCH /chicago/desktop/{id} — move or rename.
--
-- Only layout fields change: place, name, folder. `entry` and `kind` are
-- immutable on purpose — changing a shortcut's entry means swapping the
-- program under the same icon, and a person would launch something other
-- than what they see.
--
-- `parent_id: null` in the body is a request to move the icon out of the
-- folder onto the desktop. An absent field means "leave alone"; without this
-- distinction there would be no way to move an icon out. What is allowed in
-- the body is decided by `desktop_body`.

local http = require("http")
local security = require("security")
local repo = require("repo")
local control = require("control")
local desktop_body = require("desktop_body")

local function bad(res, message)
    res:set_status(http.STATUS.BAD_REQUEST)
    res:write_json({success = false, error = message})
end

local function failed(res, message)
    res:set_status(http.STATUS.INTERNAL_ERROR)
    res:write_json({success = false, error = message})
end

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

    -- The layout of the person asking: another person's icon is "no such shortcut".
    local store: any = repo.of(tostring(security.actor():id()))

    local id = req:param("id")
    if type(id) ~= "string" or id == "" then
        return bad(res, "id: shortcut not named")
    end

    local patch, why = desktop_body.update(req:body())
    if not patch then return bad(res, tostring(why)) end

    -- Moving into a folder: what is being put in is decided by the kind of
    -- the icon itself, so it is read here, before the write.
    if type(patch.parent_id) == "string" then
        local item, ierr = store.get(id)
        if ierr then return failed(res, "reading the shortcut: " .. tostring(ierr)) end
        if not item then
            res:set_status(http.STATUS.NOT_FOUND)
            res:write_json({success = false, error = "no such shortcut: " .. id})
            return
        end
        local parent, perr = store.get(patch.parent_id)
        if perr then return failed(res, "reading the folder: " .. tostring(perr)) end
        local refused = desktop_body.nest(item.kind, parent)
        if refused then return bad(res, tostring(refused)) end
    end

    local item, err = store.update(id, patch)
    if err then return failed(res, "moving: " .. tostring(err)) end
    if item == false then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({success = false, error = "no such shortcut: " .. id})
        return
    end

    -- The compositor rereads the layout on command: without it the icon would
    -- stay in its old place until a restart.
    res:set_status(http.STATUS.OK)
    res:write_json({success = true, item = item, shell = control.refresh()})
end

return {handler = handler}
