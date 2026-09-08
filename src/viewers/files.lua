-- Файл на диске реестра: как его назвать одной строкой и как прочитать.
--
-- Просмотрщик открывается композитором с одним строковым аргументом — тем
-- же `args`, что получает любое окно-приложение. Здесь тот аргумент
-- собирается и разбирается, и это ЕДИНСТВЕННОЕ место, где известна его форма:
-- проводник зовёт `encode`, окно зовёт `parse`, и ни один из них не знает,
-- что внутри JSON. Разбери его проводник по-своему — и первый же файл с
-- пробелом в имени открылся бы не тем.
--
-- Диск — это запись реестра (`fs.directory`, `fs.embed`), а не путь на
-- машине: файл читается модулем `fs` под правами самого окна, и окно с
-- правом на запись диска не получает права на каталог мимо неё.

local fs = require("fs")
local json = require("json")

local files = {}

-- Потолки. Блокнот на мегабайте текста в терминале уже бесполезен, а
-- картинка больше восьми мегабайт едет между процессами в base64 на каждое
-- нажатие клавиши — это не размер для просмотрщика, а размер для отказа с
-- причиной.
files.MAX_TEXT = 1 << 20
files.MAX_IMAGE = 8 << 20

-- encode(drive, path) -> строка аргумента
function files.encode(drive: any, path: any): string
    return json.encode({drive = tostring(drive), path = tostring(path)})
end

-- name_of(path) -> имя файла без каталога
function files.name_of(path: any): string
    local text = tostring(path or "")
    return text:match("([^/]+)/*$") or text
end

-- ext(name) -> расширение строчными без точки, или ""
--
-- Расширение — это то, по чему проводник выбирает программу, поэтому регистр
-- снимается здесь, один раз: `Photo.PNG` и `photo.png` — один и тот же вид.
function files.ext(name: any): string
    local text = files.name_of(name)
    -- Точка в начале — скрытый файл, а не расширение: у `.bashrc` его нет.
    if text:sub(1, 1) == "." and not text:sub(2):find(".", 1, true) then return "" end
    local ext = text:match("%.([^%.]+)$")
    if not ext or ext == text then return "" end
    return ext:lower()
end

-- parse(args) -> {drive, path, name, ext} | nil, причина
function files.parse(args: any): (any, any)
    if type(args) ~= "string" or args == "" then
        return nil, "окну не сказали, какой файл открыть"
    end
    local decoded: any = json.decode(args)
    if type(decoded) ~= "table" then
        return nil, "аргумент окна не разобран: " .. args
    end
    local drive, path = decoded.drive, decoded.path
    if type(drive) ~= "string" or drive == "" or type(path) ~= "string" or path == "" then
        return nil, "в аргументе окна нет диска или пути"
    end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    return {drive = drive, path = path, name = files.name_of(path), ext = files.ext(path)}, nil
end

-- read(drive, path, limit) -> байты | nil, причина
--
-- Отказ называет, ЧТО не открылось: диск или файл. «Не прочитан» без адреса
-- отправляет человека проверять права там, где их не трогали.
function files.read(drive: any, path: any, limit: any): (any, any)
    local handle, err = fs.get(tostring(drive))
    if err or not handle then
        return nil, "диск " .. tostring(drive) .. " не открылся: " .. tostring(err or "нет такой записи")
    end
    local data, read_err = handle:readfile(tostring(path))
    if read_err or type(data) ~= "string" then
        return nil, "файл " .. tostring(path) .. " не прочитан: " .. tostring(read_err)
    end
    local cap = math.tointeger(tonumber(limit) or 0) or 0
    if cap > 0 and #data > cap then
        return nil, string.format("файл %s слишком велик: %d байт при потолке %d",
            tostring(path), #data, cap)
    end
    return data, nil
end

-- human_size(bytes) -> "12 КБ"
function files.human_size(bytes: any): string
    local n = tonumber(bytes) or 0
    if n < 1024 then return string.format("%d байт", n) end
    if n < 1024 * 1024 then return string.format("%d КБ", n // 1024) end
    return string.format("%.1f МБ", n / (1024 * 1024))
end

return files
