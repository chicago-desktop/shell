-- Цифры рантайма для трёх окон — «Диспетчер задач», «Свойства: Система»,
-- «Сетевое окружение» — одним чтением: на каждое поле значение ИЛИ причина.
--
-- Было три копии `snapshot()`, и все три теряли второе значение `system.*`:
-- отказ по правам становился нулём, «unnamed», «unavailable» или «(none)» —
-- то есть утверждением о рантайме, которое неправда. Здесь ошибка ложится в
-- `snap.problems[поле]` словами для человека, и отказ по правам называется
-- отказом по правам.
--
-- `system.*` не бросает, а возвращает nil и ошибку, поэтому `pcall` вокруг
-- вызовов здесь нет и не нужен. Он был бы и опасен: пойманная ошибка в go-lua
-- рвёт upvalue у всего стека под ней (sdk_test, «go-lua: ошибка под pcall…»).

local system = require("system")

local facts = {}

-- Имя поля → {раздел `system`, функция, как назвать человеку}. Пустой раздел
-- — функция в корне модуля.
local FIELDS: any = {
    memory = {"memory", "stats", "memory"},
    goroutines = {"runtime", "goroutines", "goroutines"},
    cpu_count = {"runtime", "cpu_count", "processors"},
    max_procs = {"runtime", "max_procs", "threads"},
    pid = {"process", "pid", "process id"},
    hostname = {"process", "hostname", "host name"},
    cwd = {"process", "cwd", "working directory"},
    node_id = {"node", "id", "node name"},
    node_addr = {"node", "addr", "node address"},
    node_role = {"node", "role", "node role"},
    members = {"cluster", "members", "cluster members"},
    leader = {"cluster", "leader", "leader"},
    raft_role = {"raft", "role", "Raft role"},
    hosts = {"hosts", "list", "process hosts"},
    modules = {"", "modules", "Lua modules"},
}

-- Вид и текст ошибки рантайма. Ошибка — userdata с методами; всё прочее
-- (строка, таблица) вида не имеет и до `pcall` не доходит.
local function kind_and_text(err: any): (any, string)
    if type(err) ~= "userdata" then return nil, tostring(err) end
    local ok_kind, kind = pcall(function() return err:kind() end)
    local ok_text, message = pcall(function() return err:message() end)
    return ok_kind and kind or nil, ok_text and tostring(message) or tostring(err)
end

-- denied(err) -> отказ ли это по правам
--
-- Модуль `system` рантайма помечает отказ по правам НЕ видом PermissionDenied,
-- а Invalid с текстом «permission denied: system.read on …»
-- (runtime/lua/modules/system: module.go, cluster.go, hosts.go, raft.go);
-- PermissionDenied там ставит только lock.go. Поэтому читаются и вид, и
-- начало текста — пока рантайм не поправлен. Одного вида мало: Invalid
-- значит и «пустой идентификатор хоста».
function facts.denied(err: any): boolean
    local kind, message = kind_and_text(err)
    if kind == "PermissionDenied" then return true end
    return kind == "Invalid" and message:sub(1, 17) == "permission denied"
end

-- reason(what, err) -> причина словами
function facts.reason(what: string, err: any): string
    local _, message = kind_and_text(err)
    if facts.denied(err) then
        if message:sub(1, 17) == "permission denied" then return what .. ": " .. message end
        return what .. ": permission denied (" .. message .. ")"
    end
    return what .. ": unavailable (" .. message .. ")"
end

-- read(names, from?) -> снимок: snap[поле] = значение, snap.problems[поле] = причина
--
-- `from` — подставной `system` с теми же разделами, для тестов. nil без
-- ошибки — значение, а не отказ: «лидера ещё не выбрали» — законное
-- состояние.
function facts.read(names: any, from: any?): any
    local source: any = from or system
    local snap: any = {problems = {}}
    for _, name in ipairs(type(names) == "table" and names or {}) do
        local spec: any = FIELDS[name]
        if not spec then
            snap.problems[name] = tostring(name) .. ": unknown fact"
        else
            local section: any = spec[1] == "" and source or (type(source) == "table" and source[spec[1]] or nil)
            local call: any = type(section) == "table" and section[spec[2]] or nil
            if type(call) ~= "function" then
                snap.problems[name] = spec[3] .. ": not in this runtime"
            else
                local value, err = call()
                if err ~= nil then snap.problems[name] = facts.reason(tostring(spec[3]), err)
                else snap[name] = value end
            end
        end
    end
    return snap
end

-- processes(hosts, from?) -> все процессы, причина | nil
--
-- По каждому хосту отдельно: пустой идентификатор хоста отвечает пустым
-- списком, а не «всеми». Хост, чьи процессы не прочитались, назван в причине.
function facts.processes(hosts: any, from: any?): (any, any)
    local source: any = from or system
    local all: any = {}
    local failures = {}
    local section: any = type(source) == "table" and source.hosts or nil
    local call: any = type(section) == "table" and section.processes or nil
    for _, host in ipairs(type(hosts) == "table" and hosts or {}) do
        local record: any = host
        local what = "processes of " .. tostring(record.id)
        if type(call) ~= "function" then
            failures[#failures + 1] = what .. ": not in this runtime"
        else
            local list, err = call(tostring(record.id or ""))
            if err ~= nil then failures[#failures + 1] = facts.reason(what, err)
            elseif type(list) == "table" then
                for _, proc in ipairs(list) do all[#all + 1] = proc end
            end
        end
    end
    return all, #failures > 0 and table.concat(failures, "; ") or nil
end

return facts
