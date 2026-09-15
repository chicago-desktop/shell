-- POST /chicago/desktop — create a desktop shortcut or folder.
--
-- A shortcut to an entry that is not in the registry is NOT rejected here: a
-- broken shortcut is a legitimate state (the program was removed, the icon
-- stayed), and forbidding it at creation would mean forbidding restoring the
-- icon of a program that is about to be installed back. But the answer says
-- `broken = true` right away: otherwise a typo in the identifier looks like a
-- successful creation and is discovered on the desktop a day later.
--
-- What is allowed in the body is decided by `desktop_body` — one place for
-- POST and PATCH.

local http = require("http")
local security = require("security")
local repo = require("repo")
local catalog = require("catalog")
local control = require("control")
local desktop_body = require("desktop_body")

local function bad(res, message)
    res:set_status(http.STATUS.BAD_REQUEST)
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

    -- The layout of the person asking: each person has their own desktop.
    local store: any = repo.of(tostring(security.actor():id()))

    local spec, why = desktop_body.create(req:body())
    if not spec then return bad(res, why) end

    if spec.parent_id then
        local parent, perr = store.get(spec.parent_id)
        if perr then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({success = false, error = "reading the folder: " .. tostring(perr)})
            return
        end
        local refused = desktop_body.nest(spec.kind, parent)
        if refused then return bad(res, refused) end
    end

    local title = spec.title
    local broken = nil
    local found, cerr = catalog.list()
    if spec.kind == repo.KIND_SHORTCUT and not cerr and found then
        local program = catalog.find(found.programs, spec.entry)
        broken = program == nil
        -- The default shortcut name is the program name; the user sets a name
        -- of their own explicitly, and it survives a program update.
        if title == "" and program then title = program.title end
    end
    if title == "" then title = spec.entry or "New Folder" end

    local item, err = store.create({
        kind = spec.kind,
        entry = spec.entry,
        parent_id = spec.parent_id,
        title = title,
        x = spec.x,
        y = spec.y,
    })
    if err or not item then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "creating: " .. tostring(err or "row not written")})
        return
    end

    item.broken = broken
    item.catalog_error = cerr
    -- The compositor reads the layout on command, not every frame. Without
    -- this the icon would appear only after a restart, and the endpoint would
    -- look like it did not work. A failed reread does not cancel the written
    -- row and is therefore named as a separate field, not as a refusal.
    res:set_status(http.STATUS.OK)
    res:write_json({success = true, item = item, shell = control.refresh()})
end

return {handler = handler}
