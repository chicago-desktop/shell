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

local function lives(entry: string): string
    local lifecycle = assert(process.events())
    local view = assert(tty.viewport({width = 50, height = 16}))
    local grant = assert(view:grant())
    local pid, err = process.with_options({terminal = grant})
        :with_context({["tui_desktop.service"] = "butschster.windows.shell"})
        :spawn_monitored(entry, "app:processes", "hello")
    if not pid then return "spawn: " .. tostring(err) end
    local deadline = time.after("3s")
    while true do
        local picked = channel.select({lifecycle:case_receive(), deadline:case_receive()})
        if picked.channel == deadline then
            process.terminate(tostring(pid))
            return "alive"
        end
        if not picked.ok then return "event channel closed" end
        local event: any = picked.value
        if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
            return "EXIT: " .. tostring(event.result or event.error or "?")
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
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
