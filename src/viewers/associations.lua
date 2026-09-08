-- Реестр типов файлов: какое расширение какая программа открывает.
--
-- В Windows это HKEY_CLASSES_ROOT — отдельная ветка, которую программы
-- заполняют при установке. Здесь отдельной ветки нет и не нужно: **программа
-- сама объявляет, что открывает**, полем `meta.opens` в своей записи реестра,
-- и таблица собирается из каталога в момент, когда она понадобилась.
-- Установленный модуль приносит свои типы сам; удалённый уносит их с собой;
-- второй копии, которую надо было бы синхронизировать, не существует.
--
-- Чистые таблицы, ни одного вызова в рантайм — проверяется прямо.

local files = require("files")

local associations = {}

-- opens_of(item) -> список расширений строчными без точек
--
-- Принимает обе формы, в которых программа приезжает: сырую запись реестра
-- (`meta.opens`) и пункт каталога (`opens`). Форма одна и та же на выходе,
-- и снимается здесь, а не у каждого читателя.
local function opens_of(item: any): {string}
    local list: any = nil
    if type(item) == "table" then
        if type(item.opens) == "table" then
            list = item.opens
        elseif type(item.meta) == "table" and type(item.meta.opens) == "table" then
            list = item.meta.opens
        elseif type(item.data) == "table" and type(item.data.meta) == "table"
            and type(item.data.meta.opens) == "table" then
            list = item.data.meta.opens
        end
    end
    local out: {string} = {}
    for _, ext in ipairs(type(list) == "table" and list or {}) do
        local text = tostring(ext):lower():gsub("^%.", "")
        if text ~= "" then out[#out + 1] = text end
    end
    return out
end

local function id_of(item: any): any
    if type(item) ~= "table" then return nil end
    local id = item.entry or item.id
    if type(id) ~= "string" or id == "" then return nil end
    return id
end

local function meta_of(item: any): any
    if type(item) ~= "table" then return {} end
    if type(item.meta) == "table" then return item.meta end
    if type(item.data) == "table" and type(item.data.meta) == "table" then return item.data.meta end
    return {}
end

local function field(item: any, name: string): any
    if type(item) ~= "table" then return nil end
    if item[name] ~= nil then return item[name] end
    return meta_of(item)[name]
end

-- table(programs) -> {ext -> программа}, предупреждения
--
-- Два претендента на одно расширение — это не выбор, а спор, и спор
-- называется: побеждает первый по идентификатору записи (устойчиво между
-- запусками, в отличие от порядка реестра), а проигравший попадает в
-- предупреждения. Молчаливый выбор здесь однажды открыл бы фотографию
-- блокнотом и никто бы не понял почему.
function associations.table(programs: any): (any, any)
    local claims: any = {}
    for _, item in ipairs(type(programs) == "table" and programs or {}) do
        local id = id_of(item)
        if id then
            for _, ext in ipairs(opens_of(item)) do
                local list: any = claims[ext] or {}
                local image = field(item, "image")
                list[#list + 1] = {
                    entry = id,
                    title = tostring(field(item, "title") or id),
                    width = tonumber(field(item, "width")),
                    height = tonumber(field(item, "height")),
                    -- Значок программы становится значком её файлов: в
                    -- Windows тип файла несёт и программу, и картинку, и
                    -- это одна запись, а не две.
                    image = type(image) == "string" and image ~= "" and image or nil,
                }
                claims[ext] = list
            end
        end
    end

    local out, warnings = {}, {}
    for ext, list in pairs(claims) do
        table.sort(list, function(left, right) return left.entry < right.entry end)
        out[ext] = list[1]
        if #list > 1 then
            local names = {}
            for _, claim in ipairs(list) do names[#names + 1] = claim.entry end
            warnings[#warnings + 1] = {ext = ext, entries = names, chosen = list[1].entry}
        end
    end
    return out, warnings
end

-- find(programs, name) -> программа | nil, причина
function associations.find(programs: any, name: any): (any, any)
    local ext = files.ext(name)
    if ext == "" then
        return nil, "у файла " .. tostring(files.name_of(name)) .. " нет расширения"
    end
    local by_ext = associations.table(programs)
    local program = by_ext[ext]
    if not program then
        return nil, "файлы ." .. ext .. " нечем открыть: ни одна программа их не объявила"
    end
    return program, nil
end

-- image_for(programs, name) -> имя значка программы или nil
--
-- nil означает «файл нечем открыть» — и рисовать его надо значком
-- неизвестного документа, а не пустотой и не значком соседа. Кто рисует,
-- решает сам, какой значок у неизвестного; здесь только факт.
function associations.image_for(programs: any, name: any): any
    local program = associations.find(programs, name)
    if not program then return nil end
    return program.image
end

-- open(programs, drive, path) -> заявка на окно | nil, причина
--
-- Заявка — та же форма, что у ярлыка стола и пункта меню: `open_window` с
-- записью, заголовком, размером и аргументом. Заголовок — имя файла, как в
-- Windows: окно называется тем, что в нём открыто.
function associations.open(programs: any, drive: any, path: any): (any, any)
    local program, why = associations.find(programs, path)
    if not program then return nil, why end
    return {
        action = "open_window",
        entry = program.entry,
        title = files.name_of(path) .. " — " .. program.title,
        w = program.width,
        h = program.height,
        args = files.encode(drive, path),
    }, nil
end

return associations
