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
-- строкой `- ` с тем отступом, какой у пунктов в этом файле (`item_indent`).

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

local function is_toplevel(line: any): boolean
    local text = tostring(line)
    return text:match("^%S") ~= nil and text:match("^#") == nil
end

-- Отступ пунктов под `entries:` — тот, что в файле. Два пробела — только
-- если пунктов ещё нет: пункт с чужим отступом YAML прочтёт вложенным в
-- предыдущий или не прочтёт вовсе, и скажет об этом `wippy update`, а не окно.
local function item_indent(lines: any): string
    local inside = false
    for _, line in ipairs(lines) do
        local text = tostring(line)
        if text:match("^entries:%s*$") then
            inside = true
        elseif inside then
            local indent = text:match("^( *)%- ")
            if indent then return indent end
            if is_toplevel(text) then break end
        end
    end
    return "  "
end

local function is_item_start(line: any, indent: string): boolean
    return tostring(line):sub(1, #indent + 2) == indent .. "- "
end

-- Пункты списка — диапазоны строк от строки с «- » до следующего пункта или
-- ключа верхнего уровня. Разбор один: поиск, подсчёт и проверка правки видят
-- один и тот же список.
local function items_of(lines: any): any
    local indent = item_indent(lines)
    local out = {}
    local start: any = nil
    for index, line in ipairs(lines) do
        local opens = is_item_start(line, indent)
        if opens or is_toplevel(line) then
            if start ~= nil then out[#out + 1] = {from = start, to = index - 1} end
            start = opens and index or nil
        end
    end
    if start ~= nil then out[#out + 1] = {from = start, to = #lines} end
    return out
end

-- Перевод строки с обеих сторон: `name:` бывает первой строкой пункта.
local function body_of(lines: any, item: any): string
    return "\n" .. table.concat(lines, "\n", item.from, item.to) .. "\n"
end

local function is_dependency(body: string): boolean
    return body:match("kind:%s*ns%.dependency") ~= nil
end

-- Найти пункт с `name: <name>` и `kind: ns.dependency`.
-- Возвращает первую и последнюю строку пункта (без комментариев над ним).
local function find_item(lines: any, name: any): (any, any)
    local escaped = (tostring(name):gsub("%p", "%%%0"))
    for _, item in ipairs(items_of(lines)) do
        local body = body_of(lines, item)
        -- `name:` может стоять первой строкой пункта — тогда перед ним «- ».
        if body:match("\n%s*%-?%s*name:%s*" .. escaped .. "%s*\n") ~= nil and is_dependency(body) then
            return item.from, item.to
        end
    end
    return nil, nil
end

-- Сколько в файле объявлений — ПУНКТОВ, а не строк `- name:`: у пункта с
-- параметрами строк `- name:` несколько, и снятие одного такого пункта по
-- счёту строк выглядело бы как снятие трёх.
local function count_dependencies(lines: any): integer
    local count = 0
    for _, item in ipairs(items_of(lines)) do
        if is_dependency(body_of(lines, item)) then count = count + 1 end
    end
    return count
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

-- Отказ без пространства имён. Одна формулировка на два места — дописывание
-- и проверку правки: две разные читались бы как два разных отказа.
function model.no_namespace(file: any): string
    return "namespace not declared in " .. tostring(file or "the declarations file")
end

-- append_declaration(text, component, name, namespace, stamp, file) -> новый текст | nil, причина
--
-- Запись — как её написал бы человек: комментарий с идентификатором, откуда
-- и когда, версия «любая». Параметры не пишутся: чего требует модуль, окно
-- не знает, а `wippy update` и боот скажут об этом сами и по имени.
--
-- Пространства имён по умолчанию нет НАРОЧНО. Было `app.deps`, и файл без
-- строки `namespace:` получал запись, про которую статус говорил
-- «declaration nil:npc written».
function model.append_declaration(text: any, component: any, name: any, namespace: any, stamp: any, file: any): (any, any)
    if type(namespace) ~= "string" or namespace == "" then return nil, model.no_namespace(file) end
    local body = tostring(text or "")
    if body ~= "" and body:sub(-1) ~= "\n" then body = body .. "\n" end
    local indent = item_indent(lines_of(body))
    local field = indent .. "  "
    return body .. table.concat({
        "",
        indent .. "# " .. namespace .. ":" .. tostring(name),
        indent .. "# Installed from Add/Remove Programs " .. tostring(stamp or "") .. ".",
        indent .. "- version: '>=v0.0.0'",
        field .. "name: " .. tostring(name),
        field .. "kind: ns.dependency",
        field .. "meta: {}",
        field .. "component: " .. tostring(component),
        "",
    }, "\n"), nil
end

-- check_edit(before, after, name, delta, file) -> true | nil, причина
--
-- Правка проверяется ДО записи, тем же разбором, которым файл читается:
-- пространство имён на месте и не сменилось, объявлений стало ровно на
-- `delta` больше (+1 — дописали, -1 — сняли), а названный пункт находится
-- или не находится так, как обещано. Без этого файл, без которого стенд не
-- поднимается, узнал бы о кривой правке только на следующем бооте.
function model.check_edit(before: any, after: any, name: any, delta: integer, file: any): (any, any)
    local where = tostring(file or "the declarations file")
    local ns = model.namespace_of(after)
    if not ns then return nil, model.no_namespace(file) end
    if ns ~= model.namespace_of(before) then
        return nil, "the edit would change the namespace of " .. where .. "; nothing written"
    end
    local now = lines_of(after)
    local grown = count_dependencies(now) - count_dependencies(lines_of(before))
    if grown ~= delta then
        return nil, string.format("the edit would change %d declarations in %s instead of %d; nothing written",
            grown, where, delta)
    end
    local present = find_item(now, name) ~= nil
    if present ~= (delta > 0) then
        return nil, "declaration " .. tostring(name) .. (present and " is still" or " is not")
            .. " found in the edited " .. where .. "; nothing written"
    end
    return true, nil
end

-- write_file(handle, file, before, after) -> true | false, причина
--
-- Переименования у `fs` рантайма нет (у хэндла readfile, writefile, remove,
-- stat, exists…), поэтому подменить файл готовым временным одним шагом
-- нельзя. Взамен — три шага, и каждый отказ называет, где прежний текст:
--   1. файл на диске сверяется с тем, из которого сделана правка — иначе
--      правка затёрла бы чужую, сделанную рукой, пока окно было открыто;
--   2. прежний текст ложится в `<file>.bak` рядом (загрузчик рантайма читает
--      `_index.yaml` по имени, копия ему не видна);
--   3. запись и чтение обратно: не совпало — так и сказано.
function model.write_file(handle: any, file: string, before: string, after: string): (boolean, any)
    local backup = file .. ".bak"
    local current, rerr = handle:readfile(file)
    if type(current) ~= "string" then
        return false, file .. " not re-read before writing: " .. tostring(rerr)
    end
    if current ~= before then
        return false, file .. " changed on disk since it was read; nothing written, refresh and try again"
    end
    local _, berr = handle:writefile(backup, before)
    if berr then
        return false, "backup " .. backup .. " not written, " .. file .. " left as is: " .. tostring(berr)
    end
    local _, werr = handle:writefile(file, after)
    if werr then
        return false, file .. " not written: " .. tostring(werr) .. "; the previous text is in " .. backup
    end
    local back, verr = handle:readfile(file)
    if back ~= after then
        return false, file .. " reads back different from what was written ("
            .. tostring(verr or "content differs") .. "); the previous text is in " .. backup
    end
    return true, nil
end

return model
