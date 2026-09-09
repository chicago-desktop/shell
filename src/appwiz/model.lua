-- «Установка и удаление программ» — чистая модель.
--
-- Программа здесь — модуль wippy. Установлен он тем, что объявлен записью
-- `ns.dependency` в исходниках приложения и лежит в кэше вендора; снять и
-- поставить его в работающем рантайме нельзя — это делает `wippy update`
-- по объявлениям, и вступает в силу после перезапуска. Поэтому окно правит
-- ОБЪЯВЛЕНИЕ, а не реестр: то, что оно записало, `wippy update` прочитает
-- ровно так же, как написанное рукой.
--
-- Всё, что можно проверить без рантайма, лежит здесь: слияние объявлений с
-- кэшем, правка текста `_index.yaml`, имя для новой записи. Окно только
-- читает, рисует и пишет.

local model = {}

local geometry = require("geometry")
local whole = geometry.whole

-- Size, the way Windows writes it: "3.19 MB", "412 KB".
function model.human_size(bytes: any): string
    local n = tonumber(bytes) or 0
    if n <= 0 then return "—" end
    if n < 1024 then return string.format("%d bytes", n) end
    if n < 1024 * 1024 then return string.format("%d KB", n // 1024) end
    return string.format("%.2f MB", n / (1024 * 1024))
end

-- Модуль называется `org/name`, строчными; ничего другого `wippy update`
-- не разрешит, а разрешит он позже и молча про причину.
function model.valid_component(text: any): boolean
    if type(text) ~= "string" then return false end
    return text:match("^[a-z0-9][a-z0-9_%-%.]*/[a-z0-9][a-z0-9_%-%.]*$") ~= nil
end

-- Имя записи `ns.dependency` для модуля `org/name` — `name`. Занятое имя
-- ЗАМЕЩАЕТ прежнюю запись без настоящего предупреждения (рантайм пишет
-- `will use last definition` и берёт последнюю), и ломаются чужие
-- `ns.requirement`; поэтому занятое имя уступает форме `org-name`.
function model.dep_name(component: any, taken: any): string
    local text = tostring(component or "")
    local org, name = text:match("^([^/]+)/(.+)$")
    if not name then name, org = text, "" end
    local used: any = type(taken) == "table" and taken or {}
    if used[name] then return org .. "-" .. name end
    return name
end

-- Слияние объявлений реестра с кэшем вендора в строки окна.
--
--   declared  {{id = "app.deps:bridge", component = "org/m", version = ">=…"}, …}
--   cached    {{module = "org/m", version = "1.2.3", size = N, pinned = bool}, …}
--   app_ns    пространство имён объявлений приложения ("app.deps")
--
-- Строка: component, name (имя записи, если объявил приложение), owner —
-- "app" (объявлено приложением), "module" (объявлено чужим модулем — его
-- зависимость), "cache" (только в кэше), declared_by (пространство имён),
-- constraint, version, size, pinned. Версия — закреплённая локом; у
-- рабочей копии (замена в .wippy.yaml) кэша нет, version = nil.
function model.merge(declared: any, cached: any, app_ns: any): any
    local by_component: any = {}
    local order = {}
    local function row(component: any)
        local key = tostring(component)
        if not by_component[key] then
            by_component[key] = {component = key, size = 0}
            order[#order + 1] = key
        end
        return by_component[key]
    end
    local prefix = tostring(app_ns or "") .. ":"
    for _, entry in ipairs(type(declared) == "table" and declared or {}) do
        local record: any = entry
        if type(record.component) == "string" and record.component ~= "" then
            local line: any = row(record.component)
            local id = tostring(record.id or "")
            local ns = id:match("^(.-):") or ""
            local mine = prefix ~= ":" and id:sub(1, #prefix) == prefix
            -- Объявление приложения главнее чужого: именно его правит окно.
            if mine or line.owner == nil or line.owner == "cache" then
                line.owner = mine and "app" or "module"
                line.declared_by = ns
                line.name = mine and id:sub(#prefix + 1) or line.name
                line.constraint = tostring(record.version or "")
                line.entry = id
            end
        end
    end
    for _, item in ipairs(type(cached) == "table" and cached or {}) do
        local record: any = item
        if type(record.module) == "string" and record.module ~= "" then
            local line: any = row(record.module)
            line.owner = line.owner or "cache"
            -- Закреплённая локом версия — та, что работает; остальные в кэше
            -- лишь лежат. Без закреплённой берётся последняя названная.
            if record.pinned or line.version == nil or not line.pinned then
                line.version = tostring(record.version or "")
                line.size = tonumber(record.size) or 0
                line.pinned = record.pinned and true or false
            end
        end
    end
    table.sort(order)
    local out = {}
    for _, key in ipairs(order) do out[#out + 1] = by_component[key] end
    return out
end

-- Кто установил — одной строкой для человека.
function model.owner_text(line: any): string
    if line.owner == "app" then return "declared by the application (" .. tostring(line.entry) .. ")" end
    if line.owner == "module" then return "required by module " .. tostring(line.declared_by) end
    return "cache only — declared by no one"
end

-- ─── Правка `_index.yaml` объявлений ─────────────────────────────────────
--
-- Файл правится ТЕКСТОМ, а не через разбор и сборку YAML: у человека там
-- комментарии, и пересобранный файл их потерял бы. Пункт списка начинается
-- строкой `  - ` в два пробела — так его пишет и `wippy`, и рука.

local function lines_of(text: any): any
    local out = {}
    local source = tostring(text or "") .. "\n"
    for line in source:gmatch("(.-)\n") do out[#out + 1] = line end
    -- gmatch с добавленным переводом строки даёт лишнюю пустую строку в
    -- конце ровно тогда, когда текст уже кончался переводом строки.
    if #out > 0 and out[#out] == "" and tostring(text or ""):sub(-1) == "\n" then out[#out] = nil end
    return out
end

function model.namespace_of(text: any): any
    return tostring(text or ""):match("\n%s*namespace:%s*([%w_%.%-]+)")
        or tostring(text or ""):match("^%s*namespace:%s*([%w_%.%-]+)")
end

local function is_item_start(line: any): boolean
    return tostring(line):match("^  %- ") ~= nil
end

local function is_toplevel(line: any): boolean
    local text = tostring(line)
    return text:match("^%S") ~= nil and text:match("^#") == nil
end

-- Найти пункт с `name: <name>` и `kind: ns.dependency`.
-- Возвращает первую и последнюю строку пункта (без комментариев над ним).
local function find_item(lines: any, name: any): (any, any)
    local escaped = (tostring(name):gsub("%p", "%%%0"))
    local function matches(from: integer, to: integer): boolean
        -- Перевод строки с обеих сторон: `name:` бывает первой строкой пункта.
        local body = "\n" .. table.concat(lines, "\n", from, to) .. "\n"
        -- `name:` может стоять первой строкой пункта — тогда перед ним «- ».
        return body:match("\n%s*%-?%s*name:%s*" .. escaped .. "%s*\n") ~= nil
            and body:match("kind:%s*ns%.dependency") ~= nil
    end
    local start: any = nil
    for index, line in ipairs(lines) do
        if is_item_start(line) or is_toplevel(line) then
            if start ~= nil then
                if matches(start, index - 1) then return start, index - 1 end
                start = nil
            end
            if is_item_start(line) then start = index end
        end
    end
    if start ~= nil and matches(start, #lines) then return start, #lines end
    return nil, nil
end

-- remove_declaration(text, name) -> новый текст | nil, причина
--
-- Снимается сам пункт, комментарии вплотную над ним и одна пустая строка
-- над ними — то, что человек написал про эту запись. Пустые строки в конце
-- пункта остаются: они принадлежат следующему.
function model.remove_declaration(text: any, name: any): (any, any)
    local lines = lines_of(text)
    local first, last = find_item(lines, name)
    if not first then
        return nil, "declaration " .. tostring(name) .. " not found in the file"
    end
    local from: integer = math.tointeger(first) or 1
    while from > 1 and tostring(lines[from - 1]):match("^%s*#") do from = from - 1 end
    if from > 1 and tostring(lines[from - 1]):match("^%s*$") then from = from - 1 end
    -- Хвост пункта до следующего — пустые строки и комментарии — не его:
    -- комментарий над следующим пунктом принадлежит следующему.
    local to: integer = math.tointeger(last) or from
    while to > first and (tostring(lines[to]):match("^%s*$") or tostring(lines[to]):match("^%s*#")) do
        to = to - 1
    end
    local out = {}
    for index = 1, from - 1 do out[#out + 1] = lines[index] end
    for index = to + 1, #lines do out[#out + 1] = lines[index] end
    return table.concat(out, "\n") .. "\n", nil
end

-- append_declaration(text, component, name, namespace, stamp) -> новый текст
--
-- Запись — как её написал бы человек: комментарий с идентификатором, откуда
-- и когда, версия «любая». Параметры не пишутся: чего требует модуль, окно
-- не знает, а `wippy update` и боот скажут об этом сами и по имени.
function model.append_declaration(text: any, component: any, name: any, namespace: any, stamp: any): string
    local body = tostring(text or "")
    if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
    local ns = tostring(namespace or "app.deps")
    return body .. table.concat({
        "",
        "  # " .. ns .. ":" .. tostring(name),
        "  # Installed from Add/Remove Programs " .. tostring(stamp or "") .. ".",
        "  - version: '>=v0.0.0'",
        "    name: " .. tostring(name),
        "    kind: ns.dependency",
        "    meta: {}",
        "    component: " .. tostring(component),
        "",
    }, "\n")
end

return model
