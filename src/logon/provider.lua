-- Личность пользователя из логина и пароля.
--
-- Оболочка не умеет проверять пароли и не должна: таблица пользователей и
-- хеш принадлежат приложению. Поэтому здесь два имени из окружения — функция
-- входа приложения и хранилище токенов — и три шага между ними:
--
--   1. funcs.call(функция входа, {login, password}) → {success, token, …}.
--      Функция работает под СВОИМ актором с правами на базу пользователей;
--      оболочке эти права не выдаются, и код, приехавший в окно по HTTP, до
--      таблицы паролей не дотянется.
--   2. token_store:validate(token) → actor, scope. Токен — обычная сессия
--      приложения, та же, что у веб-входа: её видят `/user/me` и шаринг.
--   3. Актор и скоуп уезжают композитору, тот порождает под ними окна.
--
-- Объекты актора и скоупа через границу `funcs` не проезжают — только
-- таблицы. Отсюда токен как переносимая форма личности, а не «функция
-- вернёт актора».

local environment = require("environment")
local funcs = require("funcs")
local security = require("security")

local provider = {}

provider.FUNC_ENV = "BUTSCHSTER_WINDOWS_LOGON_FUNC"
provider.STORE_ENV = "BUTSCHSTER_WINDOWS_TOKEN_STORE"

-- Чтение окружения общее (`butschster.windows.config:environment`); здесь
-- только слова отказа для экрана входа.
local function read(name): (any, any)
    local value, _, denied = environment.read(name)
    if value ~= nil then return value, nil end
    if denied then return nil, "no permission to read " .. name .. " (env.get)" end
    return nil, nil
end

-- configured() -> {func, store} | nil, причина
--
-- «Не настроено» и «не разрешено» — разные ответы: первое означает оболочку
-- без входа, второе — стенд, где вход задуман, но не выдано право.
function provider.configured(): (any, any)
    local func, ferr = read(provider.FUNC_ENV)
    if ferr then return nil, ferr end
    local store, serr = read(provider.STORE_ENV)
    if serr then return nil, serr end
    if not func or not store then return nil, nil end
    return {func = func, store = store}, nil
end

-- authenticate(config, login, password) -> identity | nil, причина
--
-- identity = {actor, scope, context = {user_id, user_name}} — форма, которую
-- ждёт `library.run` в `options.logon`.
function provider.authenticate(config: any, login: any, password: any): (any, any)
    local answer, err = funcs.new():call(tostring(config.func), {
        login = tostring(login or ""),
        password = tostring(password or ""),
    })
    if type(answer) ~= "table" then
        return nil, "the logon function did not answer: " .. tostring(err)
    end
    if answer.success ~= true then
        return nil, tostring(answer.error or "logon rejected")
    end
    if type(answer.token) ~= "string" or answer.token == "" then
        return nil, "the logon function returned no token"
    end

    local store, serr = security.token_store(tostring(config.store))
    if not store then return nil, "token store: " .. tostring(serr) end
    local actor, scope, verr = store:validate(answer.token)
    store:close()
    if not actor or not scope then
        return nil, "token not accepted by the store: " .. tostring(verr)
    end

    return {
        actor = actor,
        scope = scope,
        context = {
            user_id = tostring(answer.user_id or actor:id()),
            user_name = tostring(answer.display_name or answer.user_id or actor:id()),
        },
    }, nil
end

return provider
