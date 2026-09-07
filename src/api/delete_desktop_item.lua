-- DELETE /windows/desktop/{id} — убрать ярлык или папку стола.
--
-- Ответ говорит, БЫЛА ли строка: «удалил несуществующее» и «удалил» — разные
-- ответы, иначе опечатка в идентификаторе выглядит успешным удалением.
--
-- Удалённый ярлык программы с `desktop: true` НЕ возвращается на следующем
-- старте: отметка о том, что программу уже предлагали, лежит отдельно и при
-- удалении значка не трогается. Без этого удаление значка не работало бы
-- вовсе.
--
-- Содержимое удалённой папки возвращается на стол, а не удаляется следом:
-- каскад унёс бы значки, которые пользователь в неё складывал, и восстановить
-- их было бы нечем. Ответ называет число вынесенных.

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
        res:write_json({success = false, error = "id: ярлык не назван"})
        return
    end

    local result, err = repo.delete(id)
    if err or not result then
        res:set_status(http.STATUS.INTERNAL_ERROR)
        res:write_json({success = false, error = "удаление: " .. tostring(err or "строка не тронута")})
        return
    end

    res:set_status(http.STATUS.OK)
    res:write_json({
        success = true,
        id = id,
        existed = result.existed == true,
        promoted = result.promoted,
        shell = control.refresh(),
        note = "программа с desktop true больше не предлагается: отметка о предложении не снимается",
    })
end

return {handler = handler}
