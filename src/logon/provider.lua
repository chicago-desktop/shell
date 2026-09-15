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
local errors = require("errors")

local provider = {}

provider.FUNC_ENV = "BUTSCHSTER_WINDOWS_LOGON_FUNC"
provider.STORE_ENV = "BUTSCHSTER_WINDOWS_TOKEN_STORE"
-- The application's function that answers the logged-on user's current
-- display name, {user_id} → {name}. Read without a default: unset keeps the
-- name as it was at logon.
provider.USER_FUNC_ENV = "BUTSCHSTER_WINDOWS_USER_FUNC"

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

-- unvouched_refusal(auth, config, config_error) -> reason | nil
--
-- A terminal host can let a person in without asking who they are
-- (`terminal.ssh` with `auth: logon`), and says so in the session's context:
-- `terminal.auth` is "none". Then the logon is the only door. A shell that
-- would come up without one — logon not configured, or not permitted — must
-- not open a desktop under its own account to whoever connected; on the
-- machine's own terminal (no `terminal.auth`) and behind a key it still may.
function provider.unvouched_refusal(auth: any, config: any, config_error: any): any
    if auth ~= "none" or config ~= nil then return nil end
    local why = config_error ~= nil and tostring(config_error)
        or ("the logon is not configured (" .. provider.FUNC_ENV .. ", " .. provider.STORE_ENV .. ")")
    return "this desktop was reached without a key and cannot ask who you are: " .. why
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
    local identity, why = provider.redeem(config, answer, err)
    return identity, why
end

-- authenticate_key(config, key, call?) -> identity | nil, reason
--
-- The terminal host saw the client prove it holds this account key and put it
-- in the session's context (`terminal.key`); the application's logon function
-- turns it into the owner's session, or says why not — and then the logon
-- screen asks as usual. `call` stands in for `funcs.new():call` in tests.
function provider.authenticate_key(config: any, key: any, call: any?): (any, any)
    if type(key) ~= "string" or key == "" then return nil, "no SSH key" end
    local invoke: any = call or function(name: any, args: any): (any, any)
        local answer, err = funcs.new():call(tostring(name), args)
        return answer, err
    end
    local answer, err = invoke(tostring(config.func), {ssh_key = key})
    local identity, why = provider.redeem(config, answer, err)
    return identity, why
end

-- redeem(config, answer, err) -> identity | nil, reason: the logon function's
-- answer turned into an actor and a scope by the token store.
function provider.redeem(config: any, answer: any, err: any): (any, any)
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

-- display_name(func, user_id, call?) -> name | nil, reason, permission denial
--
-- The name the application gives the logged-on user NOW: the profile window
-- can rename the account while the shell runs, and Start must not keep the
-- name from logon. `call` stands in for `funcs.new():call` in tests. The kind
-- of the error is read with `errors.is`, not under `pcall`: this runs in the
-- compositor's frame, and an error caught under pcall in go-lua tears the
-- upvalues of the frames below it.
function provider.display_name(func: any, user_id: any, call: any?): (string?, string?, boolean)
    if type(user_id) ~= "string" or user_id == "" then return nil, "no user id", false end
    local invoke: any = call or function(name: any, args: any): (any, any)
        local answer, err = funcs.new():call(tostring(name), args)
        return answer, err
    end
    local answer, err = invoke(tostring(func), {user_id = user_id})
    if err ~= nil and errors.is(err, errors.PERMISSION_DENIED) then
        return nil, "no permission to call " .. tostring(func) .. ": " .. tostring(err), true
    end
    if type(answer) ~= "table" then
        return nil, "the user name function did not answer: " .. tostring(err), false
    end
    -- {success = true, user_id, name} or {success = false, error}: the name
    -- is read only from a success.
    if answer.success ~= true then
        return nil, "the user name function refused: " .. tostring(answer.error or "no reason given"), false
    end
    if type(answer.name) ~= "string" or answer.name == "" then
        return nil, "the user name function returned no name", false
    end
    return answer.name, nil, false
end

return provider
