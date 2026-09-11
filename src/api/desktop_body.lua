-- Тело запросов стола — разбор и проверка ОДНИМ местом для POST и PATCH.
--
-- Ручки принимали то, что потом не рисуется: координату `"1e999"` (tonumber
-- даёт inf, а `repo.cell` превращал её в 0 — значок в углу, и пиксельная тема
-- его пропускала), папку в папке (вложенная папка нигде не рисуется, а два
-- PATCH давали цикл A→B→A), битый JSON как пустой успешный PATCH, имя без
-- потолка. Здесь нет ни HTTP, ни базы — только то, что в теле, поэтому каждый
-- отказ проверяется тестом без сервера.

local json = require("json")
local repo = require("repo")

local body = {}

body.COORD_MIN = 1
body.COORD_MAX = 10000
body.ENTRY_MAX = 256
body.TITLE_MAX = 512

body.FOLDER_IN_FOLDER = "parent_id: a desktop folder cannot go into a folder — nested folders are not drawn"

-- Длина в СИМВОЛАХ, а не в байтах: потолок, который кириллица выбирает вдвое
-- быстрее латиницы, — это два разных потолка под одним числом.
local function chars(value: string): integer
    local count = 0
    for _ in value:gmatch("[^\128-\191]") do count = count + 1 end
    return count
end

-- decode(raw) -> таблица | nil, причина
--
-- Битое тело — отказ, а не пустой объект: `json.decode(...) or {}` превращал
-- опечатку в успешный PATCH, который ничего не сделал.
function body.decode(raw: any): (any, any)
    local value, err = json.decode(tostring(raw or ""))
    if err ~= nil then return nil, "body is not JSON: " .. tostring(err) end
    -- Массив тоже приезжает таблицей; у объекта нет первого элемента.
    if type(value) ~= "table" or value[1] ~= nil then return nil, "body: a JSON object" end
    return value, nil
end

-- Координата — ячейка сетки: целое от 1 до 10000. Строка с числом
-- принимается, как и раньше, но только если число конечное и целое.
-- Бесконечность приходит числом — JSON `1e999`, вызов из Lua, — а не строкой:
-- `tonumber("1e999")` в go-lua даёт nil, а не inf.
local function coordinate(value: any): (any, any)
    local number: any = type(value) == "number" and value or (type(value) == "string" and tonumber(value) or nil)
    if number == nil then return nil, "a number" end
    -- До `math.tointeger`: в go-lua он отдаёт бесконечности целое вне
    -- диапазона, а не nil (замечено мутацией), так что без этой строки inf
    -- проходил бы как «целое».
    if number ~= number or number == math.huge or number == -math.huge then return nil, "a finite number" end
    local cell = math.tointeger(number)
    if cell == nil then return nil, "a whole number" end
    if cell < body.COORD_MIN or cell > body.COORD_MAX then
        return nil, string.format("between %d and %d", body.COORD_MIN, body.COORD_MAX)
    end
    return cell, nil
end
body.coordinate = coordinate

local function text(name: string, value: any, limit: integer): (any, any)
    if value == nil then return nil, nil end
    if type(value) ~= "string" then return nil, name .. ": a string" end
    if chars(value) > limit then return nil, string.format("%s: at most %d characters", name, limit) end
    return value, nil
end

-- names_null(raw, key) -> истина, если у объекта ВЕРХНЕГО уровня ключ `key` равен null
--
-- Разобранная таблица не отличает присланный null от отсутствующего поля —
-- оба nil, — а метки для null у json рантайма нет (`"null"` → nil). Различие
-- здесь смысловое: `parent_id: null` — «вынести на стол», отсутствие — «не
-- трогать». Раньше null искался подстрокой по всему телу и срабатывал на
-- вложенном объекте. Здесь — только ключ верхнего уровня: строки
-- пропускаются целиком, с экранированием, вложенность считается. Зовётся для
-- тела, которое json уже разобрал, — это поиск в правильном JSON, а не разбор.
function body.names_null(raw: any, key: string): boolean
    local source = tostring(raw or "")
    local depth, at, size = 0, 1, #source
    while at <= size do
        local char = source:sub(at, at)
        if char == '"' then
            local close = at + 1
            while close <= size do
                local inner = source:sub(close, close)
                if inner == "\\" then close = close + 2
                elseif inner == '"' then break
                else close = close + 1 end
            end
            local token = source:sub(at + 1, close - 1)
            at = close + 1
            if depth == 1 and token == key and source:match("^%s*:%s*null", at) then return true end
        elseif char == "{" or char == "[" then
            depth = depth + 1
            at = at + 1
        elseif char == "}" or char == "]" then
            depth = depth - 1
            at = at + 1
        else
            at = at + 1
        end
    end
    return false
end

-- nest(kind, parent) -> причина | nil
--
-- Что можно положить в папку. Папку — нельзя: вложенная папка нигде не
-- рисуется, а разрешённая вложенность давала цикл двумя PATCH. Проверяется
-- первым, до поиска папки: ответ не зависит от того, какую назвали.
function body.nest(kind: any, parent: any): any
    if kind == repo.KIND_FOLDER then return body.FOLDER_IN_FOLDER end
    if parent == nil then return "parent_id: no such folder" end
    -- Ярлык внутри ярлыка открыть нечем: у стола есть окно папки, а окна
    -- ярлыка не существует.
    if parent.kind ~= repo.KIND_FOLDER then return "parent_id: only a desktop folder can hold items" end
    return nil
end

-- create(raw) -> {kind, entry, title, x, y, parent_id} | nil, причина
function body.create(raw: any): (any, any)
    local value, err = body.decode(raw)
    if not value then return nil, err end

    local kind = type(value.kind) == "string" and value.kind or ""
    if kind ~= repo.KIND_SHORTCUT and kind ~= repo.KIND_FOLDER then
        return nil, "kind: only " .. repo.KIND_SHORTCUT .. " or " .. repo.KIND_FOLDER
    end

    local entry, eerr = text("entry", value.entry, body.ENTRY_MAX)
    if eerr then return nil, eerr end
    entry = entry or ""
    if kind == repo.KIND_SHORTCUT and entry == "" then
        return nil, "entry: a shortcut must reference a registry entry"
    end
    -- Папка с записью — это ярлык, который назвали папкой.
    if kind == repo.KIND_FOLDER and entry ~= "" then
        return nil, "entry: a desktop folder has no registry entry"
    end

    local title, terr = text("title", value.title, body.TITLE_MAX)
    if terr then return nil, terr end

    -- Координаты необязательны: без них значок кладёт композитор, когда
    -- узнает ширину экрана. Но названные обязаны быть ОБЕ — одна координата
    -- не задаёт места.
    local has_x, has_y = value.x ~= nil, value.y ~= nil
    if has_x ~= has_y then return nil, "x and y: given together or not at all" end
    local x: any, y: any = nil, nil
    if has_x then
        local xerr: any, yerr: any
        x, xerr = coordinate(value.x)
        if xerr then return nil, "x: " .. tostring(xerr) end
        y, yerr = coordinate(value.y)
        if yerr then return nil, "y: " .. tostring(yerr) end
    end

    local parent_id: any = type(value.parent_id) == "string" and value.parent_id ~= "" and value.parent_id or nil
    if value.parent_id ~= nil and parent_id == nil then return nil, "parent_id: a folder id" end
    if parent_id and kind == repo.KIND_FOLDER then return nil, body.FOLDER_IN_FOLDER end

    return {kind = kind, entry = entry ~= "" and entry or nil, title = title or "",
        x = x, y = y, parent_id = parent_id}, nil
end

-- update(raw) -> patch | nil, причина
--
-- В patch — только названные поля; `parent_id = false` — «вынести на стол».
function body.update(raw: any): (any, any)
    local value, err = body.decode(raw)
    if not value then return nil, err end

    if value.entry ~= nil or value.kind ~= nil then
        return nil, "entry and kind do not change: swapping the entry under the same icon launches something other than what is shown"
    end

    local patch: any = {}
    if value.title ~= nil then
        if type(value.title) ~= "string" or value.title == "" then return nil, "title: a non-empty string" end
        local title, terr = text("title", value.title, body.TITLE_MAX)
        if terr then return nil, terr end
        patch.title = title
    end
    for _, axis in ipairs({"x", "y"}) do
        if value[axis] ~= nil then
            local cell, why = coordinate(value[axis])
            if why then return nil, axis .. ": " .. tostring(why) end
            patch[axis] = cell
        end
    end
    if value.parent_id ~= nil then
        if type(value.parent_id) ~= "string" or value.parent_id == "" then
            return nil, "parent_id: a folder id or null"
        end
        patch.parent_id = value.parent_id
    elseif body.names_null(raw, "parent_id") then
        patch.parent_id = false
    end
    return patch, nil
end

return body
