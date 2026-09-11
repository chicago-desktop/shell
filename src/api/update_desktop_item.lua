-- PATCH /windows/desktop/{id} — переместить или переименовать.
--
-- Меняются только раскладочные поля: место, имя, папка. `entry` и `kind`
-- неизменны намеренно — сменить запись у ярлыка значит подменить программу
-- под тем же значком, и человек запустил бы не то, что видит.
--
-- `parent_id: null` в теле — просьба вынести значок из папки на стол.
-- Отсутствие поля означает «не трогать»; без этого различия вынести значок
-- было бы нечем. Что в теле допустимо, решает `desktop_body`.

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

    local id = req:param("id")
    if type(id) ~= "string" or id == "" then
        return bad(res, "id: shortcut not named")
    end

    local patch, why = desktop_body.update(req:body())
    if not patch then return bad(res, tostring(why)) end

    -- Перенос в папку: что кладут, решает вид самого значка, поэтому он
    -- читается здесь, до записи.
    if type(patch.parent_id) == "string" then
        local item, ierr = repo.get(id)
        if ierr then return failed(res, "reading the shortcut: " .. tostring(ierr)) end
        if not item then
            res:set_status(http.STATUS.NOT_FOUND)
            res:write_json({success = false, error = "no such shortcut: " .. id})
            return
        end
        local parent, perr = repo.get(patch.parent_id)
        if perr then return failed(res, "reading the folder: " .. tostring(perr)) end
        local refused = desktop_body.nest(item.kind, parent)
        if refused then return bad(res, tostring(refused)) end
    end

    local item, err = repo.update(id, patch)
    if err then return failed(res, "moving: " .. tostring(err)) end
    if item == false then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({success = false, error = "no such shortcut: " .. id})
        return
    end

    -- Композитор перечитывает раскладку по команде: без неё значок остался
    -- бы на прежнем месте до перезапуска.
    res:set_status(http.STATUS.OK)
    res:write_json({success = true, item = item, shell = control.refresh()})
end

return {handler = handler}
