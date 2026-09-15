-- Notifications from modules (docs/sdk.md, "Notifications"): a balloon tip
-- by the notification area, a flashing taskbar button, a message window and
-- the taskbar notice line — on the desktops a person has open now.
--
-- There is no offline delivery, and that is the owner's rule: a person with
-- no open desktop gets nothing, and the caller hears "nobody to show it to"
-- and decides what to do — keep it, mail it, drop it. A queue here would
-- show yesterday's news at the next logon as if it were today's.
--
-- Every call answers the number of desktops it reached, or nil and the
-- reason: `notify.NOBODY`, or a desktop's refusal (a bad field, a full
-- queue). A call that reached one desktop of two answers 1.
--
-- Targeting, the same for every kind:
--   user    — every desktop of the shell's family (`notify.FAMILY`, `.2` …
--             `.16`) whose logged-on user has that id, as `desktop.list`
--             reports it (`user = {id, name}`);
--   desktop — one desktop service by its name;
--   neither — the calling window's own desktop (from its process context).
local process = require("process")
local json = require("json")
local desktop = require("desktop")

local notify = {}

-- The shell's desktops: one per connection under the terminal.ssh host,
-- found by the base's one naming rule (`window_api.desktops`).
notify.FAMILY = "chicago.shell.desktop"
-- The message window and its size — its entry's width and height (the window
-- is fixed-size), so a message is centred without reading the registry.
notify.MESSAGE = "chicago.shell.notify:message"
notify.MESSAGE_W = 56
notify.MESSAGE_H = 18
notify.NOBODY = "nobody to show it to"
-- How long one desktop has to answer. One that does not answer in time is
-- not counted: the caller is a service and must not hang on one desktop.
notify.BUDGET = "2s"

local function ask(name: string, topic: string, body: any): (any, any)
    local answer, err = desktop.ask(topic, body, {service = name, timeout = notify.BUDGET})
    return answer, err
end

-- targets(spec) -> {{name, listing?}, …} | nil, reason
--
-- The desktops the spec names. `listing` is the `desktop.list` answer when
-- the person's desktops were looked for: the caller needs no second question.
local function targets(spec: any): (any, any)
    if spec.desktop ~= nil then
        if type(spec.desktop) ~= "string" or spec.desktop == "" then
            return nil, "desktop names a desktop service by its name, a string"
        end
        if not process.registry.lookup(spec.desktop) then return {}, nil end
        return {{name = spec.desktop}}, nil
    end
    if spec.user ~= nil then
        local wanted = tostring(spec.user)
        local found: any = {}
        local answered = false
        local failure: any = nil
        for _, running in ipairs(desktop.desktops(notify.FAMILY)) do
            local name = tostring(running.name)
            local listing, err = ask(name, "desktop.list", {})
            if type(listing) == "table" then
                answered = true
                local user: any = listing.user
                if type(user) == "table" and user.id ~= nil and tostring(user.id) == wanted then
                    found[#found + 1] = {name = name, listing = listing}
                end
            else
                failure = failure or err
            end
        end
        -- Desktops are running and not one could be asked: that is not
        -- "nobody". A caller without the right to send would otherwise take a
        -- refusal for an empty desktop list — the silence this module must
        -- not hand out.
        if not answered and failure ~= nil then return nil, "no desktop could be asked: " .. tostring(failure) end
        return found, nil
    end
    local name, source = desktop.service()
    if source ~= "context" then
        return nil, "name the user or the desktop: the caller is not a window on a desktop"
    end
    return {{name = name}}, nil
end

-- deliver(found, topic, build) -> reached | nil, reason
--
-- `build(target)` gives the body for that desktop (a fresh table: the ask
-- writes its return address into it).
local function deliver(found: any, topic: string, build: any): (any, any)
    if #found == 0 then return nil, notify.NOBODY end
    local reached = 0
    local first: any = nil
    for _, target in ipairs(found) do
        local answer, err = ask(tostring(target.name), topic, build(target))
        if answer then reached = reached + 1 else first = first or err end
    end
    if reached > 0 then return reached, nil end
    return nil, first or notify.NOBODY
end

local function pick(spec: any, fields: any): any
    local out: any = {}
    for _, name in ipairs(fields) do out[name] = spec[name] end
    return out
end

local BALLOON_FIELDS = {"key", "title", "text", "icon", "image", "anchor", "entry", "args", "timeout", "bell", "remove"}

-- balloon{title, text, icon?, image?, anchor?, entry?, args?, timeout?, bell?, key?, user?|desktop?}
-- balloon{key, remove = true, user?|desktop?}
--
-- The fields are the base's `desktop.balloon`: `icon` info, warning or
-- error; `image` a pack picture instead; `anchor` the tray item the tail
-- points at; `entry`/`args` what a click on the body opens; `timeout` seconds
-- (10, clamped to 2..60); the same `key` replaces.
function notify.balloon(spec: any): (any, any)
    if type(spec) ~= "table" then return nil, "a balloon is a table with title and text" end
    local found, why = targets(spec)
    if not found then return nil, why end
    return deliver(found, "desktop.balloon", function() return pick(spec, BALLOON_FIELDS) end)
end

-- notice{text, ttl?, user?|desktop?} — the taskbar notice line for ttl
-- seconds (5, clamped to 1..60); an empty text clears it.
function notify.notice(spec: any): (any, any)
    if type(spec) ~= "table" then return nil, "a notice is a table with text" end
    local found, why = targets(spec)
    if not found then return nil, why end
    return deliver(found, "desktop.notice", function() return pick(spec, {"text", "ttl"}) end)
end

-- message{title, text, icon?, button?, bell?, user?|desktop?}
--
-- A window of its own on each desktop reached (`notify.MESSAGE`), centred on
-- the screen, one per call: the args travel as JSON, the compositor carries
-- a window's args only as a string.
function notify.message(spec: any): (any, any)
    if type(spec) ~= "table" then return nil, "a message is a table with title and text" end
    local args, encode_error = json.encode({title = spec.title, text = spec.text, icon = spec.icon,
        button = spec.button, bell = spec.bell})
    if type(args) ~= "string" then return nil, "the message could not be encoded: " .. tostring(encode_error) end
    local found, why = targets(spec)
    if not found then return nil, why end
    return deliver(found, "desktop.open", function(target: any)
        local body: any = {entry = notify.MESSAGE, args = args}
        local listing: any = target.listing or ask(tostring(target.name), "desktop.list", {})
        local screen: any = type(listing) == "table" and listing.screen or nil
        if type(screen) == "table" then
            local width = math.tointeger(tonumber(screen.width)) or 0
            local height = math.tointeger(tonumber(screen.height)) or 0
            if width > 0 and height > 0 then
                body.x = math.max(1, (width - notify.MESSAGE_W) // 2 + 1)
                body.y = math.max(1, (height - notify.MESSAGE_H) // 2 + 1)
            end
        end
        return body
    end)
end

-- flash(id) — a window of the caller's own desktop (nil: the calling window);
-- flash{id?, count?, stop?, desktop?} — the same with a count, a stop, or on
-- a named desktop; flash{entry, count?, stop?, user?|desktop?} — every open
-- window of that entry on the person's desktops. A window id belongs to one
-- desktop, so `user` goes only with `entry`. The answer counts the desktops
-- where a window flashed.
function notify.flash(spec: any): (any, any)
    local given: any = type(spec) == "table" and spec or {id = spec}
    if given.entry == nil then
        if given.user ~= nil then
            return nil, "a window id belongs to one desktop: flash an entry for a user, or name the desktop"
        end
        local found, why = targets({desktop = given.desktop})
        if not found then return nil, why end
        return deliver(found, "desktop.flash", function()
            return {id = given.id, count = given.count, stop = given.stop}
        end)
    end

    if type(given.entry) ~= "string" or given.entry == "" then return nil, "entry names a window entry, a string" end
    local found, why = targets(given)
    if not found then return nil, why end
    if #found == 0 then return nil, notify.NOBODY end
    local reached = 0
    local first: any = nil
    for _, target in ipairs(found) do
        local listing: any = target.listing or ask(tostring(target.name), "desktop.list", {})
        local flashed = false
        for _, window in ipairs(type(listing) == "table" and type(listing.windows) == "table" and listing.windows or {}) do
            if window.entry == given.entry then
                local answer, err = ask(tostring(target.name), "desktop.flash",
                    {id = window.id, count = given.count, stop = given.stop})
                if answer then flashed = true else first = first or err end
            end
        end
        if flashed then reached = reached + 1 end
    end
    if reached > 0 then return reached, nil end
    return nil, first or ("no window of " .. given.entry .. " is open on those desktops")
end

return notify
