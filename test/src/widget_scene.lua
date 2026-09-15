-- The desktop widgets scene (FR-006 §10): three widgets in the right column —
-- the weather, the heap and the goroutines, built with the kit — and a window
-- over part of the last one's history, so the heap's progress bar shows whole. One scene for the test that checks it and for
-- `paint-png`, which refreshes test/shots/widgets.png: two copies would show
-- two different things.
local gfx = require("gfx")
local gadget = require("gadget")

local scene = {}

scene.WIDTH = 110
scene.HEIGHT = 34
-- The desktop's last row above the pixel taskbar, two rows at a 14–27 px cell.
scene.BOTTOM = 32
scene.DESKTOP = "#008080"

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- series(base, spread) — sixty samples for a graph, the same every time.
local function series(base: integer, spread: integer): any
    local out: any = {}
    for index = 1, 60 do out[index] = base + (index * 7) % spread + index % 5 end
    return out
end

-- A widget as the base hands it to the theme (FR-006 §4).
local function widget(id: string, spec: any, tree: any, revision: any): any
    return {id = id, entry = spec.entry, title = spec.title, opens = spec.opens, w = spec.w, h = spec.h,
        waiting = false, stopped = false, state_revision = revision,
        content_state = {sdk = 1, revision = revision, ui = tree, interaction = {}}}
end

-- state(options?) -> the chrome state. `goroutines` is the number on the
-- third widget (428), `revision` every widget's (1); `unrevised = true`
-- leaves the revision out.
function scene.state(options: any?): any
    local given: any = type(options) == "table" and options or {}
    local revision: any = given.revision or 1
    if given.unrevised == true then revision = nil end
    return {
        width = scene.WIDTH, height = scene.HEIGHT, top = 1, bottom = scene.BOTTOM, clock = "12:00",
        items = {{id = "computer", kind = "shortcut", entry = "windows.shell.explorer:window",
            title = "My Computer", x = 2, y = 1}},
        windows = {{id = "w1", title = "Notepad", x = 62, y = 22, w = 36, h = 8, window_type = "app"}},
        focused_id = "w1",
        widgets = {
            widget("g1", {entry = "app.weather:widget", title = "Weather", opens = "app.weather:window", w = 20, h = 7},
                gadget.stack{
                    gadget.stat{caption = "Feels like +19", value = "+21", unit = " °C", image = "clock", icon = "☼"},
                    gadget.lines{lines = {"Samara", "Partly cloudy"}},
                }, revision),
            widget("g2", {entry = "app.monitor:memory", title = "Memory", opens = "windows.shell.taskman:window",
                w = 20, h = 8},
                gadget.stack{
                    gadget.meter{caption = "Heap", value = 312, ceiling = 500, unit = " MB"},
                    gadget.history{caption = "Heap in use", values = series(250, 70), ceiling = 500, unit = " MB"},
                }, revision),
            widget("g3", {entry = "app.monitor:goroutines", title = "Goroutines", w = 20, h = 9},
                gadget.stack{
                    gadget.stat{caption = "Running now", value = given.goroutines or 428},
                    gadget.history{caption = "Last two minutes", values = series(380, 60)},
                }, revision),
        },
    }
end

-- compose(painted, state, cell) -> the screen as one raster: the desktop
-- colour, the windows' client white where cells would be, and every
-- placement at the place the surface puts it.
function scene.compose(painted: any, state: any, cell: any): any
    local cw, ch = whole(cell.w), whole(cell.h)
    local screen = gfx.raster(whole(state.width) * cw, whole(state.height) * ch)
    screen:fill(scene.DESKTOP)
    for _, entry in ipairs(state.windows) do
        local window: any = entry
        screen:rect((whole(window.x) - 1) * cw + 1, (whole(window.y) - 1) * ch + 1,
            whole(window.w) * cw, whole(window.h) * ch, "#ffffff")
    end
    for _, entry in ipairs(painted.placements) do
        local item: any = entry
        screen:blit(item.raster, (whole(item.x) - 1) * cw + 1, (whole(item.y) - 1) * ch + 1)
    end
    return screen
end

return scene
