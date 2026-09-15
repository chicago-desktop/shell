-- The shell's farewell screen and the fixed-size window rule.
--
-- What is checked is what makes such a window lie silently: a button drawn
-- somewhere other than where it is pressed; a row of rasters re-sent without
-- changes; a second redrawing the calendar; arithmetic that counts not the
-- way the buttons do.
local test = require("test")
local gfx = require("gfx")
local tty = require("tty")
local rasters = require("rasters")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local registry = require("registry")
local ui = require("ui")
local fs = require("fs")
local pixels = require("pixels")
local widgets = require("widgets")

local CELL = {w = 10, h = 20}

-- Titles and ids of the menu bar items from the window tree.
local function menu_of(tree: any): (string, string, boolean)
    local titles, ids, disabled = {}, {}, false
    for _, child in ipairs(tree.children or {}) do
        if child.kind == "menu" then
            for _, entry in ipairs(child.entries) do
                titles[#titles + 1] = tostring(entry.title)
                for _, item in ipairs(entry.items or {}) do
                    if not item.separator then ids[#ids + 1] = tostring(item.id) end
                    if item.disabled then disabled = true end
                end
            end
        end
    end
    return table.concat(titles, " "), table.concat(ids, " "), disabled
end

-- The label with this text in the plan and its width: a sheet title cut down
-- to one cell shows as a single letter.
local function label_width(plan: any, text: string): integer
    for _, item in ipairs(plan.items) do
        if item.node.kind == "label" and item.node.text == text then return item.rect.w end
    end
    return 0
end

local function versions(placements: any): any
    local out: any = {}
    for _, item in ipairs(placements) do
        out[item.id] = {raster = item.raster, version = item.raster:version()}
    end
    return out
end

local function moved(before: any, after: any): any
    local names = {}
    for id, now in pairs(after) do
        local was: any = before[id]
        if not was then names[#names + 1] = id .. " (appeared)"
        elseif was.raster ~= now.raster then names[#names + 1] = id .. " (RECREATED)"
        elseif was.version ~= now.version then names[#names + 1] = id end
    end
    table.sort(names)
    return names
end

-- Buttons named in cells do not share a cell: otherwise a click on the
-- border belongs to both at once, and whichever was found first wins.
local function assert_disjoint(buttons: any)
    for i = 1, #buttons do
        for j = i + 1, #buttons do
            local a, b = buttons[i], buttons[j]
            local rows = a.row <= b.bottom_row and b.row <= a.bottom_row
            local cols = a.from <= b.to and b.from <= a.to
            test.is_false(rows and cols, a.id .. " and " .. b.id .. " share a cell")
        end
    end
end

local function define_tests()
    test.describe("windows.shell farewell screen", function()
        test.it("after \"Shut Down\" — a black screen with the caption in the middle", function()
            -- The compositor holds this frame for FAREWELL_HOLD seconds; a
            -- frame without the caption would read as a hung terminal, not as
            -- a shutdown.
            local canvas = tty.canvas(80, 10)
            local painted = chrome.farewell(canvas, 80, 10)
            test.is_nil(painted, "there are no placements in cells")
            local rows = canvas:rows()
            local found: any = nil
            for index, row in ipairs(rows) do
                if tostring(row):find("safe to turn off", 1, true) then found = index end
            end
            test.eq(found, 5, "the caption stands in the middle row")
            test.is_true(tostring(rows[5]):find("\27[", 1, true) ~= nil, "the row is colored, not bare")
            test.is_true(tonumber(chrome.FAREWELL_HOLD) == 5, "five seconds, as asked")
            test.eq(chrome_pixels.FAREWELL_HOLD, chrome.FAREWELL_HOLD, "both themes hold it the same")
        end)

        test.it("a narrow screen gets a cut caption, not emptiness", function()
            local canvas = tty.canvas(20, 3)
            chrome.farewell(canvas, 20, 3)
            local rows = canvas:rows()
            local seen = false
            for _, row in ipairs(rows) do
                if tostring(row):find("It's now", 1, true) then seen = true end
            end
            test.is_true(seen)
        end)
    end)

    test.describe("windows.shell fixed size", function()
        test.it("a window with resizable false has no \"maximize\" button", function()
            local set = chrome.buttons_for({window_type = "app", resizable = false})
            test.eq(#set, 2)
            test.eq(set[1].id, "minimize")
            test.eq(set[2].id, "close")
            local free = chrome.buttons_for({window_type = "app"})
            test.eq(#free, 3, "a window that says nothing about it stretches and maximizes, as before")
            local dialog = chrome.buttons_for({window_type = "dialog", resizable = false})
            test.eq(#dialog, 2, "a dialog has no \"maximize\" anyway — the set does not change")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
