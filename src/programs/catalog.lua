-- Каталог программ: что можно запустить.
--
-- Источник один — реестр: записи с `meta.type: tui_desktop.window`, тот же
-- тип, что читает основа, чтобы одна запись работала в обеих оболочках.
-- Своей копии списка оболочка не держит намеренно — копия означала бы, что
-- установленный модуль не появится в меню, пока кто-то не нажмёт «обновить».
--
-- Главное здесь — форма отказа. `list` возвращает РАЗНЫЕ значения на «реестр
-- не прочитан» (nil, причина) и на «программ нет» (пустой каталог, nil).
-- Слитые в одно, они отправляют человека искать ошибку в своём приложении,
-- где её нет.

local registry = require("registry")

local catalog = {}

catalog.WINDOW_TYPE = "tui_desktop.window"
catalog.DEFAULT_ICON = "▢"

-- Глубже трёх уровней меню в терминале не читается: на четвёртом подменю
-- уходит за правый край экрана. Лишние сегменты не отбрасывают программу, а
-- сводят её к третьему уровню — потерять программу хуже, чем потерять папку.
catalog.MAX_DEPTH = 3

-- Программа без `order` идёт после программ с ним, а между собой они
-- сортируются по алфавиту. Число выбрано заведомо большим любого разумного
-- порядка, но не бесконечностью: с ней сравнение двух безпорядковых программ
-- давало бы inf < inf = false в обе стороны, и порядок зависел бы от того,
-- в каком виде реестр вернул список.
local NO_ORDER = 1e9

-- "Служебные/Сеть" -> {"Служебные", "Сеть"}. Пустые сегменты выбрасываются:
-- "Служебные//Сеть" — это опечатка, а не безымянная папка посередине.
local function parse_group(value: any)
    local out = {}
    if type(value) ~= "string" then return out end
    for segment in string.gmatch(value, "[^/]+") do
        local trimmed = string.match(segment, "^%s*(.-)%s*$")
        if trimmed ~= "" and #out < catalog.MAX_DEPTH then out[#out + 1] = trimmed end
    end
    return out
end

local function compare(left: any, right: any)
    if left.order ~= right.order then return left.order < right.order end
    return left.title < right.title
end

local function new_node(title: any, path: any)
    return { title = title, path = path, folders = {}, programs = {} }
end

-- Папка заводится тем, что в неё что-то положили. Отдельной записи для папки
-- меню нет: папка без программ бессмысленна, а объявленная отдельно —
-- разъезжается со своим содержимым при удалении модуля.
local function ensure_folder(node: any, name: any)
    for _, folder in ipairs(node.folders) do
        if folder.title == name then return folder end
    end
    local path = node.path == "" and name or (node.path .. "/" .. name)
    local folder = new_node(name, path)
    -- Папке нужен свой порядок для сортировки рядом с программами; она
    -- получает порядок самой ранней программы внутри — иначе группа
    -- «Служебные» уезжала бы в конец только потому, что у неё нет order.
    folder.order = NO_ORDER
    node.folders[#node.folders + 1] = folder
    return folder
end

local function sort_node(node: any)
    table.sort(node.programs, compare)
    for _, folder in ipairs(node.folders) do sort_node(folder) end
    table.sort(node.folders, compare)
end

local function to_program(record: any)
    local meta = type(record.meta) == "table" and record.meta or {}
    local order = tonumber(meta.order)
    return {
        entry = record.id,
        title = type(meta.title) == "string" and meta.title ~= "" and meta.title or record.id,
        group = parse_group(meta.group),
        order = order or NO_ORDER,
        icon = type(meta.icon) == "string" and meta.icon ~= "" and meta.icon or catalog.DEFAULT_ICON,
        width = tonumber(meta.width),
        height = tonumber(meta.height),
        args = type(meta.args) == "string" and meta.args or nil,
        -- `desktop` в реестре — просьба ВЫНЕСТИ ярлык на стол при первом
        -- появлении, а не утверждение, что ярлык там есть. Есть он или нет,
        -- знает только раскладка.
        desktop = meta.desktop == true or meta.desktop == "true",
    }
end

-- build(records) -> каталог
--
-- Отделено от чтения реестра нарочно: раскладка меню — чистое правило
-- («папки из meta.group, порядок из meta.order»), и проверять его надо без
-- живого реестра. Правило, проверяемое только через реестр, проверяется
-- один раз, а потом никогда.
--
-- Каталог: { programs = плоский список, tree = корень меню }.
function catalog.build(records: any)
    local programs = {}
    for _, entry in ipairs(type(records) == "table" and records or {}) do
        local record = entry :: any
        if type(record.id) == "string" then programs[#programs + 1] = to_program(record) end
    end
    table.sort(programs, compare)

    local root = new_node(nil, "")
    root.order = NO_ORDER
    for _, program in ipairs(programs) do
        local node = root
        for _, name in ipairs(program.group) do
            local folder = ensure_folder(node, name)
            if program.order < folder.order then folder.order = program.order end
            node = folder
        end
        node.programs[#node.programs + 1] = program
    end
    sort_node(root)

    return { programs = programs, tree = root }
end

-- list() -> (каталог, nil) | (nil, причина)
--
-- Два исхода различимы по ПЕРВОМУ значению: пустой каталог — это таблица,
-- нечитаемый реестр — nil. Вернуть на отказ пустой список значило бы сказать
-- «программ нет» там, где верно «не смогли посмотреть».
function catalog.list()
    local found, err = registry.find({ ["meta.type"] = catalog.WINDOW_TYPE })
    if err then return nil, "каталог не прочитан: " .. tostring(err) end
    if type(found) ~= "table" then return nil, "каталог не прочитан: реестр ответил не списком" end
    return catalog.build(found), nil
end

-- Программа по идентификатору записи. Нужна ярлыку: он хранит ссылку, а имя,
-- значок и размер окна берёт из реестра — программа обновилась, ярлык ведёт
-- на новую версию.
function catalog.find(programs: any, entry)
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        if program.entry == entry then return program end
    end
    return nil
end

return catalog
