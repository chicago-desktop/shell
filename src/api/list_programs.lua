-- GET /windows/programs — каталог программ из реестра.
--
-- Ручки на СОЗДАНИЕ программы рядом нет и не будет: программы появляются
-- установкой модуля или сборкой окна через мастерскую основы. Ручка создания
-- означала бы второй источник истины рядом с реестром, и они разошлись бы на
-- первом же удалении модуля.
--
-- Отказ реестра отдаётся как отказ, а не как пустой список. Пустой список на
-- нечитаемый реестр отправляет человека искать ошибку в своём приложении,
-- где её нет.

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
