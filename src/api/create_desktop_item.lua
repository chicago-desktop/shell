-- POST /windows/desktop — завести ярлык или папку стола.
--
-- Ярлык на запись, которой в реестре нет, здесь НЕ отвергается: битый ярлык —
-- законное состояние (программу удалили, значок остался), и запрещать его при
-- создании значило бы запрещать восстановить значок программы, которую вот-вот
-- поставят обратно. Но ответ говорит `broken = true` сразу: опечатка в
-- идентификаторе иначе выглядит успешным созданием и обнаруживается на столе
-- через день.

local http = require("http")
local json = require("json")
local security = require("security")
local repo = require("repo")
local catalog = require("catalog")
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

    local body = json.decode(req:body() or "") or {}
    if type(body) ~= "table" then body = {} end

    local kind = type(body.kind) == "string" and body.kind or ""
    if kind ~= repo.KIND_SHORTCUT and kind ~= repo.KIND_FOLDER then
        return bad(res, "kind: only " .. repo.KIND_SHORTCUT .. " or " .. repo.KIND_FOLDER)
    end

    local entry = type(body.entry) == "string" and body.entry or ""
    if kind == repo.KIND_SHORTCUT and entry == "" then
        return bad(res, "entry: a shortcut must reference a registry entry")
    end
    -- Папка с записью — это ярлык, который назвали папкой. Промолчать здесь
    -- значит завести объект, который ведёт себя не как то, чем назван.
    if kind == repo.KIND_FOLDER and entry ~= "" then
        return bad(res, "entry: a desktop folder has no registry entry")
    end

    local title = type(body.title) == "string" and body.title or ""

    -- Координаты необязательны: без них значок кладёт композитор, когда узнает
    -- ширину экрана. Но названные обязаны быть числами и обязаны быть ОБЕ —
    -- одна координата не задаёт места, а нечисловая тихо превратилась бы в
    -- «места не назвали», и значок уехал бы не туда, куда просили.
    local has_x, has_y = body.x ~= nil, body.y ~= nil
    if has_x ~= has_y then
        return bad(res, "x and y: given together or not at all")
    end
    if has_x and (tonumber(body.x) == nil or tonumber(body.y) == nil) then
        return bad(res, "x and y: numbers")
    end

    local parent_id = type(body.parent_id) == "string" and body.parent_id ~= "" and body.parent_id or nil
    if parent_id then
        local parent, perr = repo.get(parent_id)
        if perr then
            res:set_status(http.STATUS.INTERNAL_ERROR)
            res:write_json({success = false, error = "reading the folder: " .. tostring(perr)})
            return
        end
        if not parent then
            return bad(res, "parent_id: no such folder")
        end
        -- Ярлык внутри ярлыка открыть нечем: у стола есть окно папки, а
        -- окна ярлыка не существует. Вложенная строка просто пропала бы с
        -- экрана, оставшись в таблице.
        if parent.kind ~= repo.KIND_FOLDER then
            return bad(res, "parent_id: only a desktop folder can hold items")
        end
    end

    local broken = nil
    local found, cerr = catalog.list()
    if kind == repo.KIND_SHORTCUT and not cerr and found then
        local program = catalog.find(found.programs, entry)
        broken = program == nil
        -- Имя ярлыка по умолчанию — имя программы; своё имя пользователь
        -- задаёт явно и оно переживает обновление программы.
        if title == "" and program then title = program.title end
    end
    if title == "" then title = entry ~= "" and entry or "New Folder" end

    local item, err = repo.create({
        kind = kind,
        entry = kind == repo.KIND_SHORTCUT and entry or nil,
        parent_id = parent_id,
        title = title,
        x = body.x,
        y = body.y,
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
