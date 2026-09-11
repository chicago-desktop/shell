-- User identity from login and password.
--
-- The shell cannot check passwords and must not: the users table and the
-- hash belong to the application. So there are two names from the
-- environment here — the application's logon function and the token store —
-- and three steps between them:
--
--   1. funcs.call(logon function, {login, password}) → {success, token, …}.
--      The function runs under ITS OWN actor with permissions on the users
--      database; those permissions are not given to the shell, and code that
--      arrived into a window over HTTP will not reach the password table.
--   2. token_store:validate(token) → actor, scope. The token is an ordinary
--      application session, the same as a web logon: `/user/me` and sharing
--      see it.
--   3. The actor and scope go to the compositor, which spawns windows under
--      them.
--
-- Actor and scope objects do not travel across the `funcs` boundary — only
-- tables do. Hence the token as the portable form of identity, rather than
-- "the function will return an actor".

local environment = require("environment")
local funcs = require("funcs")
local security = require("security")

local provider = {}

provider.FUNC_ENV = "BUTSCHSTER_WINDOWS_LOGON_FUNC"
provider.STORE_ENV = "BUTSCHSTER_WINDOWS_TOKEN_STORE"

-- Reading the environment is shared (`butschster.windows.config:environment`);
-- here there are only the words of refusal for the logon screen.
local function read(name): (any, any)
    local value, _, denied = environment.read(name)
    if value ~= nil then return value, nil end
    if denied then return nil, "no permission to read " .. name .. " (env.get)" end
    return nil, nil
end

-- configured() -> {func, store} | nil, reason
--
-- "Not configured" and "not permitted" are different answers: the first
-- means a shell without logon, the second a stand where logon is intended but
-- the permission was not granted.
function provider.configured(): (any, any)
    local func, ferr = read(provider.FUNC_ENV)
    if ferr then return nil, ferr end
    local store, serr = read(provider.STORE_ENV)
    if serr then return nil, serr end
    if not func or not store then return nil, nil end
    return {func = func, store = store}, nil
end

-- authenticate(config, login, password) -> identity | nil, reason
--
-- identity = {actor, scope, context = {user_id, user_name}} — the form that
-- `library.run` expects in `options.logon`.
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
