local process = require("process")
local fs = require("fs")
local gfx = require("gfx")
local library = require("library")
local chrome = require("chrome")
local function main(service, observer)
    local files = assert(fs.get("app:system_fonts"))
    chrome.use_fonts(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}),
        gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
    chrome.use_cell_size(8, 18)
    local paint = chrome.paint
    chrome.paint = function(state, cw, ch)
        local result = paint(state, cw, ch)
        for _, window in ipairs(state.windows) do
            if window.entry == "windows.shell.taskman:window" and window.content_state and not window.waiting then
                local inset = chrome.window_insets(window)
                process.send(observer, "taskman.frame", {id = window.id, state = window.content_state,
                    x = window.x + inset.left - 1, y = window.y + inset.top - 1,
                    width = window.w - inset.left - inset.right,
                    height = window.h - inset.top - inset.bottom})
            end
        end
        return result
    end
    local ok, err = library.run({chrome = chrome, service_name = service, restore = false, pixels = true,
        cell_size = function() return 8, 18 end, catalog = function() return {}, nil end})
    return ok, err
end
return {main = main}
