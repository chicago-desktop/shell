-- GET /windows/desktop — ярлыки и папки рабочего стола.
--
-- Ярлык хранит ссылку на запись реестра, поэтому имя и значок здесь берутся
-- из каталога, а не из строки: программа обновилась — ярлык ведёт на новую
-- версию.
--
-- Ярлык на исчезнувшую запись отдаётся с `broken = true`, а не пропадает.
-- Пропавший значок читается как «я его случайно удалил», битый — как
-- «программы больше нет»; это разные утверждения, и подменять одно другим
-- нельзя.
--
-- Нечитаемый каталог не делает раскладку недоступной: ярлыки отдаются, а
-- `catalog_error` говорит, почему у них нет признака битости. Отказ целиком
-- означал бы пустой стол при исправном хранилище.

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

    local items, err = repo.list()
    if err then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "чтение раскладки: " .. tostring(err)})
        return
    end

    -- Нечитаемый каталог не отменяет стола: ярлыки отдаются как есть, без
    -- признака битости, а причина названа в catalog_error.
    local found, cerr = catalog.list()

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        items = view.join(items, cerr and nil or found),
        catalog_error = cerr,
    })
end

return {handler = handler}
