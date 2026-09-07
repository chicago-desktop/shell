-- Что появляется на столе само и почему оно не появляется дважды.
--
-- Два повода завести значок, и они разные по тому, КТО просит:
--   `ensure`  — программа объявила `desktop: true` в своей записи реестра;
--   `furnish` — оболочка ставит мебель первого запуска (см. `defaults`).
--
-- Общее у них одно и главное: отметка о том, что значок уже предлагали, живёт
-- в отдельной таблице и не удаляется НИКОГДА. Пользователь убрал значок —
-- ярлык ушёл из раскладки, отметка осталась, и на следующем старте значок не
-- возвращается. Без отметки удаление значка не работало бы вовсе: он приходил
-- бы обратно каждый старт, и человек решил бы, что удаление сломано.
--
-- МЕСТА ЗДЕСЬ НЕ ВЫБИРАЮТ. Строка пишется без координат, и это утверждение, а
-- не пропуск: оболочка раскладывает значки раньше, чем терминал сообщил свой
-- размер, поэтому выбранное ею место может оказаться за краем экрана — а
-- значок за краем не обрезается, он исчезает целиком и молча. Место выбирает
-- композитор в момент кадра, когда ширина известна.
--
-- Ошибка отметки после успешного создания ярлыка не откатывает ярлык: цена
-- второго значка на следующем старте меньше, чем цена значка, помеченного
-- предложенным, но не предложённого, — такой уже никогда не вынесут.

local repo = require("repo")

local seed = {}

-- place(wanted) -> (созданные, nil) | (nil, причина)
--
-- `wanted` — список {key, kind, entry, title}. `key` — то, по чему считается
-- «уже предлагали»: для программы это её запись, для мебели — собственный
-- ключ оболочки.
local function place(wanted: any)
    local seeded, serr = repo.seeded()
    if serr then return nil, "отметки предложенных: " .. tostring(serr) end

    -- Порядок обхода — тот, в котором пришёл список, поэтому два старта подряд
    -- заводят значки одинаково, а композитор кладёт их в одни и те же ячейки.
    local created = {}
    for _, want in ipairs(type(wanted) == "table" and wanted or {}) do
        if not (seeded :: any)[want.key] then
            local item, cerr = repo.create({
                kind = want.kind,
                entry = want.entry,
                title = want.title,
            })
            if cerr then return nil, tostring(want.key) .. ": " .. tostring(cerr) end
            created[#created + 1] = item

            local _, merr = repo.mark_seeded(want.key)
            if merr then return nil, "отметка " .. tostring(want.key) .. ": " .. tostring(merr) end
        end
    end

    return created, nil
end

-- furnish(objects) -> (созданные, nil) | (nil, причина)
--
-- Мебель первого запуска. Заводится ПЕРВОЙ, до программ: композитор кладёт
-- значки в том порядке, в каком их отдаёт раскладка, и мебель должна занять
-- начало колонки, как на настоящем столе.
function seed.furnish(objects: any)
    local wanted = {}
    for _, object in ipairs(type(objects) == "table" and objects or {}) do
        wanted[#wanted + 1] = {
            key = object.key,
            kind = object.kind,
            entry = object.entry,
            title = object.title,
        }
    end
    local created, err = place(wanted)
    return created, err
end

-- ensure(programs) -> (созданные, nil) | (nil, причина)
--
-- Идемпотентна: повторный вызов при неизменном каталоге ничего не пишет.
-- Поэтому её можно звать не только на старте — окно, собранное мастерской при
-- запущенной оболочке, получит свой значок, не дожидаясь перезапуска.
function seed.ensure(programs: any)
    local wanted = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        if program.desktop then
            wanted[#wanted + 1] = {
                key = program.entry,
                kind = repo.KIND_SHORTCUT,
                entry = program.entry,
                title = program.title,
            }
        end
    end
    local created, err = place(wanted)
    return created, err
end

return seed
