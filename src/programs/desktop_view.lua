-- Раскладка, дополненная каталогом: то, что видно на столе.
--
-- Одно место, где строка раскладки встречается с записью реестра. Им
-- пользуются и оболочка (чтобы нарисовать значок и знать, что открывать), и
-- ручка `GET /windows/desktop`. Разойдись эти два соединения — на экране и в
-- ответе ручки был бы разный стол, и объяснить расхождение было бы нечем.
--
-- Ярлык хранит только ссылку, поэтому имя, значок и размер окна берутся из
-- реестра: программа обновилась — ярлык ведёт на новую версию. Собственное
-- имя, если пользователь его задал, переживает обновление: оно в строке.

local catalog = require("catalog")

local view = {}

-- join(items, found) -> список
--
-- `found` — результат catalog.list() или nil, если каталог не прочитан. Во
-- втором случае признак битости НЕ выставляется вовсе: сказать «ярлык битый»
-- на основании непрочитанного каталога значит обвинить исправную программу.
function view.join(items: any, found: any)
    local programs = type(found) == "table" and found.programs or nil
    local out = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        local row: any = {
            id = item.id,
            kind = item.kind,
            entry = item.entry,
            parent_id = item.parent_id,
            title = item.title,
            x = item.x,
            y = item.y,
            created_at = item.created_at,
            updated_at = item.updated_at,
        }
        if item.kind == "shortcut" and programs then
            local program = catalog.find(programs, item.entry)
            row.broken = program == nil
            if program then
                row.icon = program.icon
                row.program_title = program.title
                row.w = program.width
                row.h = program.height
                row.width = program.width
                row.height = program.height
                row.args = program.args
            end
            -- Как выглядит битый значок, решает тема: она рисует, она и знает,
            -- чем отличить. Раскладка утверждает только факт — записи нет.
            -- Значок, выбранный здесь, отнял бы у темы это решение молча.
        end
        out[#out + 1] = row
    end
    return out
end

return view
