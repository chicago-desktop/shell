-- The balloon tip and the flash in both themes.
--
-- The balloon stands above the taskbar with its tail on the row between,
-- pointing at the clock or at the tray item it names; its text wraps and is
-- ellipsized; its × and its body are hits from the same rectangle the theme
-- draws; in pixels it is two `top` placements, so the windows under it are
-- cut away. A flashing window's lit phase lights its taskbar button and its
-- title, and a swap repaints only those. The PNG shots in test/shots are for
-- the eye: balloon-clock.png, balloon-tray.png, flash-plain.png, flash-lit.png.
local test = require("test")
local tty = require("tty")
local fs = require("fs")
local gfx = require("gfx")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")

-- What a row shows, one cell per entry, the styles cut out.
local function visible(row: any): any
    local out, i = {}, 1
    while i <= #row do
        local ch = row:sub(i, i)
        if ch == "\27" then
            while i <= #row and row:sub(i, i) ~= "m" do i = i + 1 end
        else
            local size = 1
            local byte = ch:byte()
            if byte >= 240 then size = 4
            elseif byte >= 224 then size = 3
            elseif byte >= 192 then size = 2 end
            out[#out + 1] = row:sub(i, i + size - 1)
            i = i + size - 1
        end
        i = i + 1
    end
    return out
end

-- The first column where `text` starts in a row of cells, or nil.
local function column_of(cells: any, text: string): any
    local line = table.concat(cells)
    local at = line:find(text, 1, true)
    if not at then return nil end
    -- Byte offset to cells: count the cells before it.
    local before = line:sub(1, at - 1)
    local count = 0
    for _ in before:gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
    return count + 1
end

local function balloon_hits(hits: any): any
    local out = {}
    for _, hit in ipairs(hits) do
        if hit.balloon ~= nil then out[#out + 1] = hit end
    end
    return out
end

local function use_fonts()
    chrome.use_pattern(nil)
    chrome.use_wallpaper(nil, nil)
    local files = assert(fs.get("chicago.shell.theme:fonts"))
    chrome_pixels.use_fonts(
        assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
        assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true})))
    chrome_pixels.use_cell_size(10, 20)
end

local function find(painted: any, id: string): any
    for _, item in ipairs(painted.placements) do
        if item.id == id then return item end
    end
    return nil
end

local function whole_w(state: any): integer return math.tointeger(state.width) or 80 end
local function whole_h(state: any): integer return math.tointeger(state.height) or 24 end

-- The whole screen as the eye would see it: the desktop, the windows' faces
-- (their content is cells, not pictures), then every placement in order.
-- Taken right after the frame: the store paints the next one into the same
-- buffers.
local function shot(painted: any, state: any, name: string)
    local screen = gfx.raster(whole_w(state) * 10, whole_h(state) * 20)
    screen:fill("#008080")
    for _, window in ipairs(state.windows or {}) do
        screen:rect((window.x - 1) * 10 + 1, (window.y - 1) * 20 + 1, window.w * 10, window.h * 20, "#ffffff")
    end
    for _, item in ipairs(painted.placements) do
        screen:blit(item.raster, (item.x - 1) * 10 + 1, (item.y - 1) * 20 + 1)
    end
    assert(assert(fs.get("app:shots")):writefile(name, assert(screen:encode("png"))))
end

local function define_tests()
    test.describe("chicago.shell balloon in cells", function()
        test.it("stands over the clock, frames its picture, bold title and text, and gives its × and body as hits", function()
            local canvas = tty.canvas(80, 24)
            local hits = chrome.bars(canvas, 80, 24, {windows = {}, clock = "12:00", tray = {},
                balloon = {key = "a", title = "aICQ", text = "Anna: hi", icon = "info"}})
            local rows = canvas:rows()
            local clock_at = column_of(visible(rows[24]), "12:00")
            test.not_nil(clock_at, "the clock is on the taskbar")

            local tail_row = visible(rows[23])
            local tail_at = column_of(tail_row, "◥") or column_of(tail_row, "◤")
            test.not_nil(tail_at, "the tail is on the row above the taskbar")
            test.is_true(tail_at >= clock_at and tail_at <= clock_at + 4,
                "the tail points into the clock: tail " .. tostring(tail_at) .. ", clock " .. tostring(clock_at))

            -- One line of text: the frame's top on row 19, the title on 20, the
            -- text on 21, the frame's bottom on 22, right above the tail.
            local top, title, body, bottom = visible(rows[19]), visible(rows[20]), visible(rows[21]), visible(rows[22])
            local left = column_of(top, "┌")
            test.not_nil(left, "the frame's top")
            test.eq(column_of(bottom, "└"), left, "the frame's bottom under its top")
            test.not_nil(column_of(title, "aICQ"), "the title")
            test.not_nil(column_of(title, "i"), "the info letter")
            local close_at = column_of(title, "✕")
            test.not_nil(close_at, "the ×")
            test.not_nil(column_of(body, "Anna: hi"), "the text")

            local own = balloon_hits(hits)
            test.eq(#own, 3, "the ×, the body and the tail")
            test.eq(hits[1].balloon, "close", "the × comes first: the first hit under the pointer wins")
            test.eq(own[1].row, 20)
            test.is_true(close_at >= own[1].from and close_at <= own[1].to, "the × is where its hit is")
            test.eq(own[2].balloon, "open")
            test.eq(own[2].row, 19)
            test.eq(own[2].bottom_row, 22)
            test.eq(own[2].from, left)
            test.eq(own[3].row, 23, "the tail is a hit too")
            test.eq(own[3].from, tail_at)
        end)

        test.it("points at the tray item it names, and at the clock when that item is gone", function()
            local tray = {{key = "icq", text = "ICQ"}, {key = "mail", text = "Mail"}}
            local function tail_for(anchor: any): (any, any)
                local canvas = tty.canvas(80, 24)
                chrome.bars(canvas, 80, 24, {windows = {}, clock = "12:00", tray = tray,
                    balloon = {key = "a", title = "Mail", text = "One new", anchor = anchor}})
                local rows = canvas:rows()
                local tail_row = visible(rows[23])
                return column_of(tail_row, "◥") or column_of(tail_row, "◤"), visible(rows[24])
            end
            local tail_at, taskbar = tail_for("icq")
            local icq_at = column_of(taskbar, "ICQ")
            test.not_nil(icq_at)
            test.is_true(tail_at >= icq_at - 1 and tail_at <= icq_at + 3,
                "the tail points into the ICQ item: tail " .. tostring(tail_at) .. ", item " .. tostring(icq_at))
            local lost_at, lost_bar = tail_for("absent")
            local clock_at = column_of(lost_bar, "12:00")
            test.is_true(lost_at >= clock_at and lost_at <= clock_at + 4, "an unknown anchor points at the clock")
        end)

        test.it("wraps a long text to four lines ending in an ellipsis, and draws nothing without room", function()
            local canvas = tty.canvas(80, 24)
            local long = string.rep("the scan found nothing wrong ", 12)
            local hits = chrome.bars(canvas, 80, 24, {windows = {}, clock = "12:00", tray = {},
                balloon = {key = "a", title = "ScanDisk", text = long, icon = "warning"}})
            local rows = canvas:rows()
            -- Four lines: the frame from row 16 to row 22.
            local top = visible(rows[16])
            local left = column_of(top, "┌")
            test.not_nil(left, "four text lines put the frame's top on row 16")
            local right = column_of(top, "┐")
            test.is_true(right - left + 1 <= chrome.BALLOON_CELLS + 4, "no wider than the text's limit and the frame")
            local last = table.concat(visible(rows[21]))
            test.is_true(last:find("…", 1, true) ~= nil, "the fourth line ends in an ellipsis: " .. last)
            test.is_true(table.concat(visible(rows[18])):find("…", 1, true) == nil, "only the last line is cut")
            test.eq(#balloon_hits(hits), 3)

            local short = tty.canvas(80, 5)
            local tight = chrome.bars(short, 80, 5, {windows = {}, clock = "12:00", tray = {},
                balloon = {key = "a", title = "ScanDisk", text = long}})
            test.eq(#balloon_hits(tight), 0, "no room above the taskbar: no balloon and no hit")
            for row = 1, 4 do
                test.is_true(table.concat(visible(short:rows()[row])):find("┌", 1, true) == nil, "nothing drawn on row " .. row)
            end
        end)
    end)

    test.describe("chicago.shell balloon in pixels", function()
        local UNDER: any = {id = "w1", title = "Under", x = 36, y = 10, w = 45, h = 12}

        local function scene(balloon: any, tray: any): any
            return {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00", items = {},
                tray = tray or {}, windows = {UNDER}, focused_id = "w1", balloon = balloon}
        end

        test.it("is two top placements above the taskbar, its tail at the clock, the windows cut under it", function()
            use_fonts()
            local state = scene({key = "a", title = "aICQ", text = "Anna: hi", icon = "info"})
            local painted = chrome_pixels.paint(state, 10, 20)
            shot(painted, state, "balloon-clock.png")
            local body, tail = find(painted, "balloon"), find(painted, "balloon:tail")
            test.not_nil(body, "the balloon's body")
            test.not_nil(tail, "the balloon's tail")
            test.is_true(body.top == true, "the body lies over the windows like a menu panel")
            test.is_true(tail.top == true and tail.overlay == true, "the tail is transparent but for its triangle")
            -- The taskbar takes two rows at a 20-px cell (23 and 24).
            test.eq(tail.y, 22, "the tail on the row above the taskbar")
            test.eq(body.y + body.rows - 1, 21, "the box ends on the row above the tail")
            test.eq(tail.cols, 2)
            test.is_true(tail.x + 1 >= 72 and tail.x + 1 <= 80, "the tail's point is in the clock's cells: " .. tostring(tail.x))
            test.eq(body.rows, 3, "one line of text is three rows")
            test.is_true(body.cols <= 32, "no wider than 320 px")

            -- Nothing below the balloon shows through it: every other placement
            -- is cut away from its rectangle.
            for _, item in ipairs(painted.placements) do
                if item.top ~= true then
                    local apart = item.x + item.cols - 1 < body.x or item.x > body.x + body.cols - 1
                        or item.y + item.rows - 1 < body.y or item.y > body.y + body.rows - 1
                    test.is_true(apart, item.id .. " lies under the balloon")
                end
            end

            local own = balloon_hits(painted.hits.bars)
            test.eq(#own, 3)
            test.eq(own[1].balloon, "close")
            test.eq(own[1].row, body.y)
            test.eq(own[1].to, body.x + body.cols - 1, "the × reaches the box's right edge")
            test.is_true(own[1].from >= body.x + body.cols - 3, "the × is at the top right")
            test.eq(own[2].from, body.x)
            test.eq(own[2].bottom_row, body.y + body.rows - 1)
            test.eq(own[3].row, tail.y)
            test.eq(own[3].from, tail.x)

            local version, tail_version = body.raster:version(), tail.raster:version()
            local again = chrome_pixels.paint(state, 10, 20)
            test.eq(find(again, "balloon").raster:version(), version, "the same balloon is not repainted")
            test.eq(find(again, "balloon:tail").raster:version(), tail_version)
            chrome_pixels.fonts = nil
        end)

        test.it("points into the tray item it names, and a long text wraps to at most four lines", function()
            use_fonts()
            local tray = {{key = "icq", text = "ICQ", entry = "app:icq", image = "info"}}
            local long = string.rep("Errors were found on drive C and fixed. ", 10)
            local state = scene({key = "s", title = "ScanDisk", text = long, icon = "warning", anchor = "icq"}, tray)
            local painted = chrome_pixels.paint(state, 10, 20)
            shot(painted, state, "balloon-tray.png")
            local item_hit: any = nil
            for _, hit in ipairs(painted.hits.bars) do
                if hit.entry == "app:icq" then item_hit = hit end
            end
            test.not_nil(item_hit, "the tray item's hit")
            local tail = find(painted, "balloon:tail")
            local point = tail.x + 1
            test.is_true(point >= item_hit.from and point <= item_hit.to,
                "the tail's point is in the ICQ item's cells: " .. tostring(point) .. " in "
                .. tostring(item_hit.from) .. ".." .. tostring(item_hit.to))
            local body = find(painted, "balloon")
            -- 1 + 6 + 16 + 4 + 4 × 15 + 6 + 1 = 94 px: five rows of 20.
            test.eq(body.rows, 5, "four lines at most")
            test.is_true(body.cols <= 32, "no wider than 320 px")
            test.eq(body.y + body.rows - 1, 21)

            state.balloon.text = "Short."
            test.eq(find(chrome_pixels.paint(state, 10, 20), "balloon").rows, 3, "a short text is three rows")
            chrome_pixels.fonts = nil
        end)
    end)

    test.describe("chicago.shell flashing window", function()
        test.it("lights the taskbar button and the title in cells, and a swap changes only those two rows", function()
            local function frame(lit: boolean): any
                local canvas = tty.canvas(80, 24)
                local flashing = {id = "w1", title = "Mail", x = 5, y = 3, w = 30, h = 10, rows = {},
                    flashing = true, flash_lit = lit}
                local other = {id = "w2", title = "Editor", x = 40, y = 5, w = 30, h = 10, rows = {}}
                chrome.window(canvas, flashing, false)
                chrome.window(canvas, other, true)
                chrome.bars(canvas, 80, 24, {windows = {flashing, other}, focused_id = "w2", clock = "12:00", tray = {}})
                return canvas:rows()
            end
            local lit, plain = frame(true), frame(false)
            local differ = {}
            for row = 1, 24 do
                if lit[row] ~= plain[row] then differ[#differ + 1] = tostring(row) end
            end
            test.eq(table.concat(differ, ","), "4,24", "only the title row and the taskbar change")

            -- Lit is the active look: the same title a focused window has.
            local focused = tty.canvas(80, 24)
            chrome.window(focused, {id = "w1", title = "Mail", x = 5, y = 3, w = 30, h = 10, rows = {}}, true)
            test.eq(lit[4], focused:rows()[4], "the lit title is the focused title")
            test.is_true(lit[4] ~= plain[4], "the plain title is the idle one")
        end)

        test.it("lights them in pixels, and a swap repaints the taskbar and that title and nothing else", function()
            use_fonts()
            local function state(lit: boolean): any
                return {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00", tray = {}, items = {},
                    windows = {
                        {id = "w1", title = "Mail", x = 5, y = 3, w = 30, h = 10, flashing = true, flash_lit = lit},
                        {id = "w2", title = "Editor", x = 40, y = 5, w = 30, h = 10},
                    }, focused_id = "w2"}
            end
            local function versions(painted: any): any
                local out: any = {}
                for _, item in ipairs(painted.placements) do out[item.id] = item.raster:version() end
                return out
            end
            local plain_state = state(false)
            local plain = chrome_pixels.paint(plain_state, 10, 20)
            shot(plain, plain_state, "flash-plain.png")
            local before = versions(plain)
            local lit_state = state(true)
            local lit = chrome_pixels.paint(lit_state, 10, 20)
            shot(lit, lit_state, "flash-lit.png")
            local after = versions(lit)
            local changed = {}
            for id, version in pairs(after) do
                if before[id] ~= version then changed[#changed + 1] = id end
            end
            table.sort(changed)
            test.eq(table.concat(changed, ","), "bars,win:w1:head", "a swap repaints the taskbar and the lit title only")
            local steady = versions(chrome_pixels.paint(state(true), 10, 20))
            for id, version in pairs(after) do
                test.eq(steady[id], version, id .. " is repainted with nothing changed")
            end
            chrome_pixels.fonts = nil
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
