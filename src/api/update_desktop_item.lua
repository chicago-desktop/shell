-- PATCH /windows/desktop/{id} — переместить или переименовать.
--
-- Меняются только раскладочные поля: место, имя, папка. `entry` и `kind`
-- неизменны намеренно — сменить запись у ярлыка значит подменить программу
-- под тем же значком, и человек запустил бы не то, что видит.
--
-- `parent_id: null` в теле — просьба вынести значок из папки на стол.
-- Отсутствие поля означает «не трогать»; без этого различия вынести значок
-- было бы нечем.

local http = require("http")
local json = require("json")
local security = require("security")
local repo = require("repo")
local control = require("control")

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

    local id = req:param("id")
    if type(id) ~= "string" or id == "" then
        return bad(res, "id: ярлык не назван")
    end

    local raw = req:body() or ""
    local body = json.decode(raw) or {}
    if type(body) ~= "table" then body = {} end

    if body.entry ~= nil or body.kind ~= nil then
        return bad(res, "entry и kind не меняются: подмена записи под тем же значком запускает не то, что видно")
    end

    local patch: any = {}
    if body.title ~= nil then
        if type(body.title) ~= "string" or body.title == "" then
            return bad(res, "title: непустая строка")
        end
        patch.title = body.title
    end
    if body.x ~= nil then
        if tonumber(body.x) == nil then return bad(res, "x: число") end
        patch.x = body.x
    end
    if body.y ~= nil then
        if tonumber(body.y) == nil then return bad(res, "y: число") end
        patch.y = body.y
    end

    -- Разобранная таблица не отличает присланный null от отсутствующего
    -- поля — оба приезжают как nil. Различие здесь смысловое («вынести на
    -- стол» против «не трогать»), поэтому null ищется в сыром теле.
    --
    -- ЭТО РАЗБОР ЧУЖОГО JSON РУКАМИ, и он временный. Условие снятия: как
    -- только у json появится значение-метка для null (json.null или подобное),
    -- заменить эту ветку на сравнение с ней — место в коде одно, вот оно.
    -- Долг записан осознанно: пока метки нет, единственная альтернатива —
    -- отдельная ручка «вынести на стол», то есть второй способ сделать то же
    -- самое, который разойдётся с первым.
    if body.parent_id ~= nil then
        if type(body.parent_id) ~= "string" or body.parent_id == "" then
            return bad(res, "parent_id: идентификатор папки или null")
        end
        local parent, perr = repo.get(body.parent_id)
        if perr then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({success = false, error = "чтение папки: " .. tostring(perr)})
            return
        end
        if not parent then return bad(res, "parent_id: такой папки нет") end
        if parent.kind ~= repo.KIND_FOLDER then
            return bad(res, "parent_id: вложить можно только в папку стола")
        end
        if body.parent_id == id then
            return bad(res, "parent_id: папка не может лежать в себе")
        end
        patch.parent_id = body.parent_id
    elseif string.find(raw, '"parent_id"%s*:%s*null') then
        patch.parent_id = false
    end

    local item, err = repo.update(id, patch)
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "перемещение: " .. tostring(err)})
        return
    end
    if item == false then
        res:set_status(http.STATUS.NOT_FOUND)
        res:write_json({success = false, error = "ярлыка нет: " .. id})
        return
    end

    -- Композитор перечитывает раскладку по команде: без неё значок остался
    -- бы на прежнем месте до перезапуска.
    res:set_status(http.STATUS.OK)
    res:write_json({success = true, item = item, shell = control.refresh()})
end

return {handler = handler}
