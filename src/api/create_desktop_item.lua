-- POST /windows/desktop — завести ярлык или папку стола.
--
-- Ярлык на запись, которой в реестре нет, здесь НЕ отвергается: битый ярлык —
-- законное состояние (программу удалили, значок остался), и запрещать его при
-- создании значило бы запрещать восстановить значок программы, которую вот-вот
-- поставят обратно. Но ответ говорит `broken = true` сразу: опечатка в
-- идентификаторе иначе выглядит успешным созданием и обнаруживается на столе
-- через день.
--
-- Что в теле допустимо, решает `desktop_body` — одно место для POST и PATCH.

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

    local spec, why = desktop_body.create(req:body())
    if not spec then return bad(res, why) end

    if spec.parent_id then
        local parent, perr = repo.get(spec.parent_id)
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
        -- Имя ярлыка по умолчанию — имя программы; своё имя пользователь
        -- задаёт явно и оно переживает обновление программы.
        if title == "" and program then title = program.title end
    end
    if title == "" then title = spec.entry or "New Folder" end

    local item, err = repo.create({
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
    -- Композитор читает раскладку по команде, а не каждый кадр. Без этого
    -- значок появился бы только после перезапуска, и ручка выглядела бы не
    -- сработавшей. Провал перечитывания не отменяет записанной строки и
    -- поэтому назван отдельным полем, а не отказом.
    res:set_status(http.STATUS.OK)
    res:write_json({success = true, item = item, shell = control.refresh()})
end

return {handler = handler}
