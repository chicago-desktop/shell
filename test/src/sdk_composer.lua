local process = require("process")
local fs = require("fs")
local gfx = require("gfx")
local library = require("library")
local chrome = require("chrome")
local cell_chrome = require("cell_chrome")
local catalog = require("catalog")
local function main(service, observer, mode)
    local files = assert(fs.get("chicago.shell.theme:fonts"))
    chrome.use_fonts(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}),
        gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
    chrome.use_cell_size(8, 18)
    local paint = chrome.paint
    chrome.paint = function(state, cw, ch)
        local result = paint(state, cw, ch)
        if state.menu then
            local spots = {}
            for _, spot in ipairs(result.hits.menu) do
                local item: any = spot.index and state.menu.items[spot.index] or nil
                if item then spots[item.entry or item.action] = spot
                elseif spot.open then spots[table.concat(spot.open, "/")] = spot end
            end
            process.send(observer, "run.menu", {spots = spots})
        end
        for _, window in ipairs(state.windows) do
            if window.entry == "app:sdk_demo" and window.content_state and not window.waiting then
                local inset = chrome.window_insets(window)
                process.send(observer, "sdk.frame", {id = window.id, state = window.content_state,
                    x = window.x + inset.left - 1, y = window.y + inset.top - 1,
                    width = window.w - inset.left - inset.right,
                    height = window.h - inset.top - inset.bottom})
            end
        end
        return result
    end
    local ok, err = library.run({chrome = mode == "cells" and cell_chrome or chrome,
        service_name = service, restore = false, pixels = mode ~= "cells",
        cell_size = function() return 8, 18 end,
        catalog = function()
            local found, why = catalog.list()
            if not found then return {}, why end
            return catalog.menu_items(found.programs), nil
        end})
    return ok, err
end
return {main = main}
