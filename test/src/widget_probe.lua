-- A desktop widget on the SDK (FR-006): the entry the harness declares with
-- `meta.type: windows.widget`, so the catalog reads a real registry record,
-- and the definition the runner test drives. A widget is an SDK application
-- with an `interval` and no input: `init`, `view`, and `update` for the tick.
local app = require("app")
local gadget = require("gadget")

local definition = {interval = "2s"}

function definition.init(): any
    return {ticks = 0, history = {}}
end

function definition.view(model: any): any
    return gadget.stack{
        gadget.stat{caption = "Ticks", value = model.ticks},
        gadget.history{caption = "History", values = model.history},
    }
end

function definition.update(model: any, action: any): any
    if action.type ~= "tick" then return false end
    model.ticks = model.ticks + 1
    model.history[#model.history + 1] = model.ticks
    if #model.history > 60 then table.remove(model.history, 1) end
    return true
end

return {main = app.main(definition), definition = definition}
