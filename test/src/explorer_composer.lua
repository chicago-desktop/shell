local library = require("library")
local chrome = require("chrome")
local cell_chrome = require("cell_chrome")
local render = require("render")
local fs = require("fs")
local gfx = require("gfx")
local process = require("process")

local function main(service, observer, mode)
    local font_store = assert(fs.get("app:system_fonts"))
    chrome.use_fonts(gfx.font(assert(font_store:readfile("LiberationSans-Regular.ttf")), {size = 13}),
        gfx.font(assert(font_store:readfile("LiberationSans-Bold.ttf")), {size = 13}))
    chrome.use_cell_size(8, 18)
    local paint = chrome.paint
    chrome.paint = function(state, cw, ch)
        local result = paint(state, cw, ch)
        for _, window in ipairs(state.windows) do
            if window.content_state and not window.waiting then
                local inset = chrome.window_insets(window)
                local width, height = window.w - inset.left - inset.right, window.h - inset.top - inset.bottom
                local plan = render.layout(window.content_state, width, height, render.pixel_metrics(cw, ch))
                local count = 0
                for _, placement in ipairs(result.placements) do
                    if placement.id:sub(1, #("client:" .. window.id)) == "client:" .. window.id then count = count + 1 end
                end
                process.send(observer, "explorer.painted", {id = window.id, image = window.image,
                    content = window.content, offset = window.content_state.offset, path = window.content_state.path,
                    selected = window.content_state.selected, width = width, height = height,
                    x = window.x + inset.left - 1, y = window.y + inset.top - 1,
                    revision = window.state_revision, hits = render.hits(plan), clients = count})
            end
        end
        return result
    end
    local theme = mode == "cells" and cell_chrome or chrome
    local ok, err = library.run({chrome = theme, service_name = service, restore = false,
        pixels = mode ~= "cells", cell_size = function() return 8, 18 end})
    return ok, err
end

return {main = main}
