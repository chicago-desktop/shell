-- Раскладка рабочего стола: ярлыки и папки стола.
--
-- Ярлык хранит ССЫЛКУ на запись реестра, а не код программы: программа
-- обновилась — ярлык ведёт на новую версию. Ссылка на исчезнувшую запись
-- остаётся строкой в таблице и помечается битой при чтении; убирать её молча
-- нельзя — пропавший значок читается как «я его случайно удалил», а битый
-- как «программы больше нет».

local sql = require("sql")
local env = require("env")
local time = require("time")
local uuid = require("uuid")

-- Значение по умолчанию в коде, переопределяемое окружением: ресурс базы
-- принадлежит приложению, а не модулю.
local DB_ID = env.get("BUTSCHSTER_WINDOWS_DB_ID") or "app:db"
local ITEMS = "butschster_windows_desktop_items"
local SEEDED = "butschster_windows_desktop_seeded"

local repo = {}

repo.KIND_SHORTCUT = "shortcut"
repo.KIND_FOLDER = "folder"

-- Соединение возвращается на КАЖДОМ пути, включая ошибку внутри работы:
-- потерянное соединение не даёт о себе знать, пока не кончится пул.
local function with_db(work)
    local db, err = sql.get(DB_ID)
    if err or not db then return nil, err or ("база недоступна: " .. DB_ID) end
    local ok, result, work_err = pcall(work, db)
    db:release()
    if not ok then return nil, tostring(result) end
    return result, work_err
end

local function now_stamp()
    return time.now():utc():format(time.RFC3339)
end

-- Координаты — целые: ячейка сетки, а не доля экрана. tonumber даёт number,
-- а колонка INTEGER, и дробное значение доехало бы до базы молча.
--
-- Пусто здесь — это ЗНАЧЕНИЕ, а не отсутствие данных: «место никто не
-- называл». Поэтому нуля вместо nil тут быть не может ни на одном пути: ноль —
-- это место, и он приклеил бы значок к левому верхнему углу вместо того, чтобы
-- отдать его композитору на раскладку.
local function cell(value: any)
    if value == nil then return nil end
    local number = tonumber(value)
    if number == nil then return nil end
    return math.tointeger(number) or math.tointeger(math.floor(number)) or 0
end

local function to_item(row: any)
    local record = row :: any
    return {
        id = record.id,
        kind = record.kind,
        -- Пустая строка и NULL приезжают из разных диалектов одинаково по
        -- смыслу — «записи нет», — поэтому нормализуются в nil здесь, а не
        -- в каждом читателе.
        entry = (type(record.entry) == "string" and record.entry ~= "") and record.entry or nil,
        parent_id = (type(record.parent_id) == "string" and record.parent_id ~= "") and record.parent_id or nil,
        title = record.title,
        x = cell(record.x),
        y = cell(record.y),
        created_at = record.created_at,
        updated_at = record.updated_at,
    }
end

-- Весь стол разом, включая содержимое папок: оболочка рисует и стол, и окна
-- папок из одного чтения, а отдельные запросы на каждую папку означали бы
-- кадр, собранный из разных моментов времени.
--
-- Порядок задан явно и до последнего поля. `(x IS NULL)` первым — потому что
-- пустые координаты диалекты сортируют по-разному (SQLite кладёт NULL в
-- начало, PostgreSQL по возрастанию — в конец), и раскладка значков зависела
-- бы от того, на какой базе стоит стенд. `created_at, id` в хвосте — потому
-- что порядок значков БЕЗ координат решает, в какие ячейки их положит
-- композитор: сортировка по имени переставляла бы их при переименовании
-- программы.
function repo.list()
    return with_db(function(db)
        local rows, err = db:query(
            "SELECT * FROM " .. ITEMS ..
            " ORDER BY (x IS NULL), y, x, created_at, id", {})
        if err then return nil, err end
        local out = {}
        for _, row in ipairs(rows or {}) do out[#out + 1] = to_item(row) end
        return out
    end)
end

function repo.get(id)
    return with_db(function(db)
        local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1", { id })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return nil, nil end
        return to_item(row)
    end)
end

-- create(item) -> (item, nil) | (nil, причина)
--
-- Идентификатор чеканится здесь, а не приходит снаружи: ярлык — объект
-- состояния, и позволить вызывающему назвать его id значит позволить ему
-- переписать чужой ярлык, промахнувшись именем.
--
-- Без `x`/`y` строка пишется БЕЗ координат, и это не пропуск, а утверждение:
-- место выберет композитор, когда узнает ширину экрана. Подставь мы здесь
-- ноль — значок стал бы «поставленным в левый верхний угол», и переложить его
-- было бы уже нельзя.
function repo.create(item)
    return with_db(function(db)
        local id, uerr = uuid.v7()
        if not id then return nil, "идентификатор: " .. tostring(uerr) end
        local stamp = now_stamp()
        local _, err = db:execute(
            "INSERT INTO " .. ITEMS ..
            " (id, kind, entry, parent_id, title, x, y, created_at, updated_at)" ..
            " VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
            {
                id, item.kind, item.entry, item.parent_id, item.title,
                cell(item.x), cell(item.y), stamp, stamp,
            })
        if err then return nil, err end
        return {
            id = id,
            kind = item.kind,
            entry = item.entry,
            parent_id = item.parent_id,
            title = item.title,
            x = cell(item.x),
            y = cell(item.y),
            created_at = stamp,
            updated_at = stamp,
        }
    end)
end

-- update(id, patch) -> (item, nil) | (false, nil) | (nil, причина)
--
-- `false` означает «такой строки нет» и отличается от отказа базы: иначе
-- опечатка в идентификаторе выглядит успешным перемещением.
--
-- В patch трактуются только названные поля. `parent_id = false` — просьба
-- вынести из папки на стол: nil здесь означал бы «не трогать», и вынести
-- значок было бы нечем.
--
-- Названное место делает значок ПОСТАВЛЕННЫМ: с этого момента композитор его
-- не перекладывает, даже если экран сузился и значок ушёл за край. Так и
-- задумано — место, названное человеком, неприкосновенно.
function repo.update(id, patch: any)
    return with_db(function(db)
        local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1", { id })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return false, nil end

        local current = to_item(row)
        local title = patch.title ~= nil and patch.title or current.title
        local x = patch.x ~= nil and cell(patch.x) or current.x
        local y = patch.y ~= nil and cell(patch.y) or current.y
        local parent_id = current.parent_id
        if patch.parent_id == false then
            parent_id = nil
        elseif patch.parent_id ~= nil then
            parent_id = patch.parent_id
        end

        local stamp = now_stamp()
        local _, uerr = db:execute(
            "UPDATE " .. ITEMS ..
            " SET title = $1, x = $2, y = $3, parent_id = $4, updated_at = $5 WHERE id = $6",
            { title, x, y, parent_id, stamp, id })
        if uerr then return nil, uerr end

        current.title = title
        current.x = x
        current.y = y
        current.parent_id = parent_id
        current.updated_at = stamp
        return current
    end)
end

-- delete(id) -> (результат, nil) | (nil, причина)
--
-- Результат говорит, БЫЛА ли строка: `existed = false` — это не отказ, но и
-- не успех удаления, иначе опечатка в идентификаторе выглядит успехом.
--
-- Содержимое удалённой папки не удаляется вместе с ней, а возвращается на
-- стол. Каскад здесь означал бы, что снятая папка уносит с собой значки,
-- которые пользователь в неё складывал, — и восстановить их нечем.
function repo.delete(id)
    return with_db(function(db)
        local rows, err = db:query("SELECT * FROM " .. ITEMS .. " WHERE id = $1", { id })
        if err then return nil, err end
        local row = rows and rows[1]
        if not row then return { existed = false, promoted = 0 } end

        local item = to_item(row)
        local promoted = 0
        if item.kind == repo.KIND_FOLDER then
            local children, cerr = db:query(
                "SELECT id FROM " .. ITEMS .. " WHERE parent_id = $1", { id })
            if cerr then return nil, cerr end
            promoted = #(children or {})
            if promoted > 0 then
                local _, perr = db:execute(
                    "UPDATE " .. ITEMS .. " SET parent_id = NULL, updated_at = $1 WHERE parent_id = $2",
                    { now_stamp(), id })
                if perr then return nil, perr end
            end
        end

        local _, derr = db:execute("DELETE FROM " .. ITEMS .. " WHERE id = $1", { id })
        if derr then return nil, derr end
        return { existed = true, promoted = promoted, item = item }
    end)
end

-- ─── Отметка «эту программу мы уже предлагали» ───────────────────────────
--
-- Живёт отдельно от раскладки и не удаляется никогда. Только благодаря
-- этому удаление значка работает: ярлык ушёл, отметка осталась, и программа
-- с `desktop: true` не выносится на стол вновь на следующем старте.

function repo.seeded()
    return with_db(function(db)
        local rows, err = db:query("SELECT entry FROM " .. SEEDED, {})
        if err then return nil, err end
        local out = {}
        for _, row in ipairs(rows or {}) do
            local record = row :: any
            if type(record.entry) == "string" then out[record.entry] = true end
        end
        return out
    end)
end

-- Отметить программу предложенной. Повторный вызов не отказ: отметка — это
-- утверждение о прошлом, и второй раз оно всё так же верно.
function repo.mark_seeded(entry)
    return with_db(function(db)
        local rows, err = db:query("SELECT entry FROM " .. SEEDED .. " WHERE entry = $1", { entry })
        if err then return nil, err end
        if rows and rows[1] then return false end
        local _, ierr = db:execute(
            "INSERT INTO " .. SEEDED .. " (entry, seeded_at) VALUES ($1, $2)",
            { entry, now_stamp() })
        if ierr then return nil, ierr end
        return true
    end)
end

return repo
