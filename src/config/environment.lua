-- Чтение окружения — одно на модуль.
--
-- Три разные вещи, и все выглядят как «переменной нет».
--
-- ПЕРВАЯ. `env.get` видит ТОЛЬКО файловое хранилище. На переменную из
-- окружения процесса он отвечает «environment variable not found» — то есть
-- `BUTSCHSTER_WINDOWS_PIXELS=1 wippy run …` без `get_all` не работает.
-- Окружение процесса отдаёт `env.get_all`.
--
-- ВТОРАЯ, и она тише. Объявленный модуль без выданного права выглядит как
-- модуль, которому нечего сказать: `get_all` кладёт в таблицу только
-- разрешённые ключи и на отказ не жалуется вовсе. Пустой ответ здесь
-- неотличим от «переменных нет». Различает их только `env.get`: на отказ по
-- правам он отвечает ошибкой вида `PermissionDenied`.
--
-- ТРЕТЬЯ, найдена при сведении четырёх копий в одну (2026-09-11). Ошибка
-- рантайма — не таблица, а userdata с методами: вид читается `err:kind()`.
-- Все копии, различавшие отказ, проверяли `type(err) == "table" and
-- err.kind == …` — условие, которого настоящая ошибка не выполняет никогда,
-- так что отказ по правам везде назывался «not set». Поэтому тест строит
-- ошибку тем же `errors.new`, что и рантайм, а не таблицей с полем.
--
-- Отказ по правам обязан называться отказом по правам: это единственная
-- причина, которую человек НЕ может исправить, задав переменную.

local env = require("env")
local logger = require("logger")

local environment = {}

environment.DENIED = "NO env.get PERMISSION — a policy denial, not a missing variable"
environment.NOT_SET = "not set"

-- Вид ошибки, а не текст: текст меняется, вид объявлен константой. Строка
-- или таблица вместо ошибки рантайма вида не имеет и до `pcall` не доходит:
-- ошибка, пойманная `pcall`, в go-lua рвёт upvalue у всего стека под ним
-- (sdk_test, «go-lua: ошибка под pcall…»), а зовут это из `main` оболочки.
local function kind_of(err: any): any
    if type(err) ~= "userdata" then return nil end
    local ok, kind = pcall(function() return err:kind() end)
    if ok then return kind end
    return nil
end

-- read(name, from?) -> значение | nil, откуда или почему нет, отказ по правам
--
-- Второе значение — "process environment" или "file store", когда значение
-- есть, и NOT_SET или DENIED, когда нет. Третье — true ровно при отказе по
-- правам: вызывающему не нужно сравнивать строки. `from` — подставной env с
-- теми же `get_all` и `get`, для тестов.
function environment.read(name: string, from: any?): (any, string, boolean)
    local store: any = from or env
    -- Пустота `get_all` ничего не доказывает, но его непустота доказывает.
    local all = store.get_all()
    if type(all) == "table" then
        local value: any = all[name]
        if type(value) == "string" and value ~= "" then return value, "process environment", false end
    end
    local stored, err = store.get(name)
    if type(stored) == "string" and stored ~= "" then return stored, "file store", false end
    if kind_of(err) == "PermissionDenied" then return nil, environment.DENIED, true end
    return nil, environment.NOT_SET, false
end

-- read_or(name, default, from?) -> значение или умолчание, откуда или почему нет, отказ по правам
--
-- Умолчание подставляется, но отказ по правам не проглатывается: он
-- называется в логе. `read(...) or "app:db"` превращал отказ в «человек
-- ничего не переназначал», и приложение, велевшее хранить раскладку в другой
-- базе, молча хранило её в умолчании.
function environment.read_or(name: string, default: string, from: any?): (string, string, boolean)
    local value, source, denied = environment.read(name, from)
    if value ~= nil then return tostring(value), source, false end
    if denied then
        logger:named("windows.environment"):warn("policy denies env.get for " .. name .. ", using default",
            {name = name, default = tostring(default)})
    end
    return default, source, denied
end

return environment
