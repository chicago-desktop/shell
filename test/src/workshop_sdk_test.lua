-- A window on the shell SDK assembled by the WORKSHOP: the code and the description arrive
-- as a table, the entry is applied to the live registry, the window's process starts with
-- a viewport grant and does not die on the first frame. Exactly the path by which
-- an agent assembles a window over MCP with no files and no restart.
local test = require("test")
local channel = require("channel")
local process = require("process")
local registry = require("registry")
local time = require("time")
local tty = require("tty")
local apps = require("apps")

local NAME = "workshop_sdk_probe"

local SOURCE = [[
local app = require("app")
local definition = {}
function definition.init(args, context)
    return {items = {"First", "Second", "Third"}, selected = 1, text = args or ""}
end
function definition.view(model, context)
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Workshop window on the SDK"},
        {kind = "list", id = "items", items = model.items, selected = model.selected},
        {kind = "input", id = "text", size = 2, text = model.text},
        {kind = "button", id = "close", size = 2, text = "Close"},
    }}
end
function definition.update(model, action, context)
    if action.id == "items" and action.type == "select" then model.selected = action.index
    elseif action.id == "text" and action.type == "change" then model.text = action.value
    elseif action.id == "close" then context.close() end
end
local function main(first, id, args, viewport)
    app.run(definition, first, id, args, viewport)
end
return {main = main}
]]

-- A window that draws its first frame and dies right after it: the case the
-- liveness check below must catch within its deadline.
local DYING_NAME = "workshop_dying_probe"
local DYING = [[
local tty = require("tty")
local function main(first, id, args, viewport)
    assert(tty.start())
    local surface = assert(tty.surface({hide_cursor = true}))
    local canvas = tty.canvas(20, 2)
    canvas:put(1, 1, "first frame", 20)
    assert(surface:present(canvas:rows()))
    error("dies right after its first frame")
end
return {main = main}
]]

-- Alive means: the first frame is on the viewport and the process has not
-- exited within GRACE after it. The earlier form waited three seconds and
-- took silence for life; a window that never drew passed as alive.
local FIRST_FRAME_NS = 3000000000
local GRACE = "300ms"

-- The exit event as text: its result is a table, and `tostring` of it names
-- nothing.
local function dump(value: any, depth: integer): string
    if type(value) ~= "table" then return tostring(value) end
    if depth > 3 then return "{…}" end
    local parts = {}
    for key, item in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. dump(item, depth + 1) end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

local function drawn(view: any): boolean
    local snap: any = view:snapshot(-1)
    for _, row in ipairs(snap and snap.rows or {}) do
        if tostring(row):find("[^ ]") then return true end
    end
    return false
end

local function lives(entry: string): string
    local lifecycle = assert(process.events())
    local view = assert(tty.viewport({width = 50, height = 16}))
    local grant = assert(view:grant())
    local pid, err = process.with_options({terminal = grant})
        :with_context({["tui_desktop.service"] = "butschster.windows.shell"})
        :spawn_monitored(entry, "app:processes", "hello")
    if not pid then return "spawn: " .. tostring(err) end
    local deadline = time.now():unix_nano() + FIRST_FRAME_NS
    local grace: any = nil
    while true do
        local cases = {lifecycle:case_receive(), time.after("20ms"):case_receive()}
        if grace then cases[#cases + 1] = grace:case_receive() end
        local picked = channel.select(cases)
        if picked.channel == lifecycle then
            if not picked.ok then return "event channel closed" end
            local event: any = picked.value
            if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
                view:close()
                return "EXIT: " .. dump(event, 0)
            end
        elseif grace and picked.channel == grace then
            process.terminate(tostring(pid))
            view:close()
            return "alive"
        elseif not grace then
            if drawn(view) then
                grace = time.after(GRACE)
            elseif time.now():unix_nano() > deadline then
                process.terminate(tostring(pid))
                view:close()
                return "no first frame within 3 s"
            end
        end
    end
end

local function define_tests()
    test.describe("the workshop assembles a window on the SDK", function()
        test.it("the description passes validation and ends up in an entry with the SDK import and the pixel view", function()
            local window, err = apps.prepare({
                name = NAME, title = "SDK probe", width = 50, height = 16, source = SOURCE,
                modules = {"json"}, group = "Programs",
                imports = {app = "butschster.windows.sdk:app"},
                pixel_render = "butschster.windows.sdk:render",
                image = "program", window_type = "app",
            })
            test.is_nil(err)
            local entry = apps.build_entry(window)
            test.eq(entry.data.imports.app, "butschster.windows.sdk:app")
            test.eq(entry.meta.pixel_render, "butschster.windows.sdk:render")
            test.eq(entry.meta.pixel_state, entry.id)
            test.eq(entry.meta.image, "program")
        end)

        test.it("a window applied to the registry starts and stays alive", function()
            local window = assert(apps.prepare({
                name = NAME, title = "SDK probe", width = 50, height = 16, source = SOURCE,
                imports = {app = "butschster.windows.sdk:app"},
                pixel_render = "butschster.windows.sdk:render",
            }))
            local ok, aerr = apps.apply(window)
            test.is_true(ok == true, "the registry did not accept the window: " .. tostring(aerr))
            local id = apps.entry_id(NAME)
            test.not_nil(registry.get(id))
            local outcome = lives(id)
            test.eq(outcome, "alive")
            assert(apps.remove(NAME))
            test.is_nil(registry.get(id))
        end)

        test.it("a window that dies right after its first frame is caught, not taken for alive", function()
            local window = assert(apps.prepare({name = DYING_NAME, title = "Dying probe", width = 30, height = 6,
                source = DYING}))
            local ok, aerr = apps.apply(window)
            test.is_true(ok == true, "the registry did not accept the window: " .. tostring(aerr))
            local outcome = lives(apps.entry_id(DYING_NAME))
            assert(apps.remove(DYING_NAME))
            test.is_true(outcome:find("EXIT", 1, true) == 1, "the death is reported: " .. outcome)
            test.is_true(outcome:find("dies right after its first frame", 1, true) ~= nil,
                "with the window's own reason: " .. outcome)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
