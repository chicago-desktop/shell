-- Window title buttons.
--
-- One rule and its consequences are checked: what is DRAWN and what is
-- PRESSED must be one and the same. Drifted apart, they give a button one
-- cell to the left of where it looks — or, worse, a button that is drawn and
-- silently does not work. Neither looks like an error: it looks like "the
-- click did not work".
local test = require("test")
local menu_layout = require("menu_layout")
local placements = require("placements")
local catalog = require("catalog")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local tty = require("tty")
local pixels = require("pixels")
local fs = require("fs")
local gfx = require("gfx")
local desktop_pixels = require("desktop_pixels")

-- What is actually drawn in the title row. The style is cut out: we care
-- about the characters and their places, and the color is checked by the
-- probe.
local function visible(row)
    local out, i = {}, 1
    local stack = 0
    while i <= #row do
        local ch = row:sub(i, i)
        if ch == "\27" then
            while i <= #row and row:sub(i, i) ~= "m" do i = i + 1 end
        elseif ch:byte() and ch:byte() < 32 then
            stack = stack + 1
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

local function glyphs_of(set)
    local out = {}
    for _, button in ipairs(set) do out[#out + 1] = button.glyph end
    return out
end

-- Which buttons are DRAWN in the title of a window of this type.
local function drawn_buttons(window_type)
    local canvas = tty.canvas(40, 8)
    local window = {x = 1, y = 1, w = 40, h = 8, title = "Window",
                    window_type = window_type, rows = {}}
    chrome.window(canvas, window, true)

    local row = visible(canvas:rows()[2] or "")
    local set = chrome.buttons_for(window)
    local wanted = glyphs_of(set)

    local found = {}
    for _, glyph in ipairs(wanted) do
        for index, cell in ipairs(row) do
            if cell == glyph then found[glyph] = index end
        end
    end
    return found, set, window
end

local function define_tests()
    test.describe("pixel theme without a cell size", function()
        -- FIRST in this file on purpose: the module is fresh here and nothing
        -- has named the cell size yet — the state a guessed default hid.
        test.it("refuses to paint or fill until the cell size is named, and once it is forgotten", function()
            local canvas = tty.canvas(20, 10)
            local filled, why = chrome_pixels.fill(canvas, 20, 10, {})
            test.is_nil(filled, "fill drew on a guessed cell size")
            test.eq(why, "cell size not set")
            local painted, pwhy = chrome_pixels.paint({width = 20, height = 10})
            test.is_nil(painted, "paint drew on a guessed cell size")
            test.eq(pwhy, "cell size not set")

            chrome_pixels.use_cell_size(10, 20)
            test.not_nil(chrome_pixels.fill(canvas, 20, 10, {}), "fill refuses a named cell size")

            chrome_pixels.use_cell_size(nil, nil)
            local _, forgotten = chrome_pixels.fill(canvas, 20, 10, {})
            test.eq(forgotten, "cell size not set", "a forgotten size is kept")
        end)
    end)

    test.describe("Bash window colors", function()
        test.it("applies terminal defaults by entry identity in both themes", function()
            local bash = {entry = "butschster.tui_desktop.desktop:window_pty", title = "top"}
            local defaults = chrome.content_colors(bash)
            test.eq(defaults.background, "#000000")
            test.eq(defaults.foreground, "#c0c0c0")
            test.eq(chrome_pixels.content_colors(bash), defaults)
            test.is_nil(chrome.content_colors({entry = "butschster.windows.explorer:window", title = "Bash"}))
            test.is_nil(chrome.content_colors({entry = "butschster.windows.run:window"}))
        end)

        test.it("fills blank PTY rows and passes defaults through to ANSI parsing", function()
            local body, fills, received = {"prompt\27[0m>"}, {}, nil
            local canvas = {
                put = function(_, x, y, row) fills[y] = row end,
                put_rows = function(_, x, y, rows, width, defaults)
                    test.eq(rows, body)
                    received = defaults
                end,
            }
            local window = {entry = "butschster.tui_desktop.desktop:window_pty", title = "Bash",
                x = 1, y = 1, w = 40, h = 8, rows = body}
            chrome.window(canvas, window, true)
            test.eq(received.background, "#000000")
            local inset = chrome.window_insets(window)
            local blank = tty.style():foreground("#c0c0c0"):background("#000000")
                :render(string.rep(" ", 40 - inset.left - inset.right))
            test.eq(fills[8 - inset.bottom], blank)
            fills = {}
            chrome_pixels.window_background(canvas, window)
            test.eq(fills[8], tty.style():foreground("#c0c0c0"):background("#000000"):render(string.rep(" ", 40)))
        end)
    end)
    test.describe("native window proportions", function()
        test.it("keeps the caption in one row from 16px cells and maps every button pixel to its hit", function()
            for _, cw in ipairs({8, 10}) do
                for _, ch in ipairs({12, 16, 18, 20, 22, 24, 32}) do
                    chrome_pixels.use_cell_size(cw, ch)
                    local window = {x = 5, y = 4, w = 40, h = 20, window_type = "app"}
                    local top = chrome_pixels.window_insets(window).top
                    test.eq(top, ch >= 16 and 1 or 2, "one row from 16px, two below")
                    local caption = math.max(14, math.min(18, top * ch - 2))
                    local buttons = chrome_pixels.title_buttons(window)
                    test.eq(#buttons, 3)
                    for index, button in ipairs(buttons) do
                        test.eq(button.rect.h, caption - 4, "button four pixels shorter than the caption")
                        test.eq(button.rect.y, 3 + 2, "two pixels inside the caption")
                        for py = button.rect.y, button.rect.y + button.rect.h - 1 do
                            local row = window.y + (py - 1) // ch
                            test.is_true(row < window.y + top, "button must not enter client")
                            for px = button.rect.x, button.rect.x + button.rect.w - 1 do
                                local col = window.x + (px - 1) // cw
                                test.eq(chrome_pixels.title_button_at(window, col, row), button.id)
                            end
                        end
                        test.is_nil(chrome_pixels.title_button_at(window, button.from, window.y + top))
                    end
                    -- A joined pair, a separate "close" two blue pixels from the frame.
                    local bw = caption - 2
                    test.eq(buttons[1].rect.w, bw)
                    test.eq(buttons[2].rect.w, bw)
                    test.eq(buttons[2].rect.x, buttons[1].rect.x + bw, "minimize and maximize touch")
                    test.is_true(buttons[3].rect.w >= bw - 2 and buttons[3].rect.w <= bw)
                    -- The gap before "close" is two pixels plus what the pair
                    -- fell short of whole cells (12 px in two cells of 10 — eight).
                    local gap = buttons[3].rect.x - buttons[2].rect.x - bw
                    test.is_true(gap >= 2 and gap <= 2 + 2 * cw - bw + 2, "close stands apart by the cell slack")
                    local last = buttons[3].rect
                    test.eq(window.w * cw - (last.x + last.w - 1), 6, "frame plus caption padding")
                    if cw == 8 and ch >= 20 then
                        test.eq(gap, 2, "eight-pixel cells reproduce Windows 95 exactly")
                        test.eq(last.w, 16)
                    end
                end
            end
            chrome_pixels.use_cell_size(10, 20)
        end)

        test.it("wraps long names without silently dropping the remaining characters", function()
            local font = {measure = function(_, text)
                local count = 0
                for _ in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do count = count + 1 end
                return count * 7
            end}
            local lines = pixels.wrap(font, "Programs", 35, 2)
            test.eq(#lines, 2)
            test.eq(table.concat(lines), "Programs")
            local clipped = pixels.wrap(font, "оченьдлинноеимяфайловойсистемы", 49, 2)
            test.eq(#clipped, 2)
            test.eq(clipped[2]:sub(-3), "…")
        end)
    end)
    test.describe("Start footer and taskbar clock", function()
        test.it("keeps shutdown with its icon on a short screen", function()
            local programs = {}
            for index = 1, 30 do
                programs[index] = {entry = "app:p" .. index, title = "Program " .. index,
                    in_menu = true, order = index}
            end
            local items = catalog.menu_items(programs)
            test.eq(items[#items].action, "quit")
            test.eq(items[#items].image, "shutdown")
            local plan = chrome.menu_layout(80, 12, items, nil, {}, 1,
                {compact = true, root_rows = 2, bottom = 2})
            local footer = plan.panels[1].lines[#plan.panels[1].lines]
            test.eq(footer.image, "shutdown")
            test.is_true(footer.separator_before)
            test.eq(plan.hits[#plan.hits].index, #items)
        end)

        test.it("clock hits cover both rows and the right edge", function()
            chrome.clock_entry = "app:clock"
            chrome_pixels.clock_entry = "app:clock"
            for _, size in ipairs({{8, 18}, {10, 20}, {8, 16}}) do
                chrome_pixels.use_cell_size(size[1], size[2])
                local painted = chrome_pixels.paint({width = 80, height = 24, bottom = 22,
                    clock = "12:30", windows = {}, items = {}}, size[1], size[2])
                local last = painted.hits.bars[#painted.hits.bars]
                test.eq(last.entry, "app:clock")
                test.eq(last.from, 72)
                test.eq(last.to, 80)
                test.eq(last.row, 23)
                test.eq(last.bottom_row, 24)
            end
            local canvas = tty.canvas(80, 24)
            local hits = chrome.bars(canvas, 80, 24, {clock = "12:30", windows = {}})
            test.eq(hits[#hits].entry, "app:clock")
            test.eq(hits[#hits].to, 80)
            chrome.clock_entry, chrome_pixels.clock_entry = nil, nil
            chrome_pixels.use_cell_size(10, 20)
        end)
    end)

    test.describe("butschster.windows title buttons", function()
        test.it("pixel buttons have separate cells and perform the declared action", function()
            for _, size in ipairs({{10, 20}, {8, 16}}) do
                chrome_pixels.use_cell_size(size[1], size[2])
                for _, kind in ipairs({"app", "dialog", "tool"}) do
                    local window = {id = "buttons", x = 5, y = 3, w = 35, h = 12, window_type = kind}
                    local occupied = {}
                    local buttons = chrome_pixels.title_buttons(window)
                    test.eq(#buttons, #chrome.buttons_for(window))
                    for _, button in ipairs(buttons) do
                        test.is_true(button.to - button.from + 1 >= 2)
                        for x = button.from, button.to do
                            test.is_nil(occupied[x], "two buttons share one cell")
                            occupied[x] = true
                            test.eq(chrome_pixels.title_button_at(window, x, button.row), button.id)
                        end
                    end
                    test.is_nil(chrome_pixels.title_button_at(window, window.x + 2, window.y))
                end
            end
            chrome_pixels.use_cell_size(10, 20)
        end)

        test.it("the pixel frame and the icon behind the front window are cropped and not repainted without changes", function()
            local state = {width = 80, height = 24, bottom = 23, clock = "12:00", items = {
                {id = "icon", x = 2, y = 4, kind = "folder", title = "Folder"},
            }, windows = {
                {id = "back", x = 4, y = 3, w = 32, h = 14, title = "Back"},
                {id = "front", x = 20, y = 4, w = 25, h = 12, title = "Front"},
            }, focused_id = "front"}
            local first = chrome_pixels.paint(state, 10, 20)
            local stored = {}
            local cropped = false
            for _, item in ipairs(first.placements) do
                stored[item.id] = {raster = item.raster, version = item.raster:version()}
                if item.id:find(":crop:", 1, true) then cropped = true end
                if item.id:find("win:back", 1, true) == 1 or item.id:find("desk:", 1, true) == 1 then
                    test.is_true(item.x + item.cols <= 20 or item.x >= 45
                        or item.y + item.rows <= 4 or item.y >= 16,
                        "a lower placement covered the front window: " .. item.id)
                end
            end
            test.is_true(cropped, "the scene must check a partial overlap")
            local again = chrome_pixels.paint(state, 10, 20)
            test.eq(#again.placements, #first.placements)
            for _, item in ipairs(again.placements) do
                test.eq(item.raster, stored[item.id].raster)
                test.eq(item.raster:version(), stored[item.id].version)
            end
        end)

        test.it("the taskbar and tall menu items are pressable over their whole drawn height", function()
            for _, cell in ipairs({{10, 20}, {12, 23}, {8, 16}}) do
                chrome_pixels.use_cell_size(cell[1], cell[2])
                local layout = chrome_pixels.layout(100, 30)
                local state = {width = 100, height = 30, bottom = 30 - layout.bottom,
                    clock = "12:00", windows = {}, items = {},
                    menu = {items = {{entry = "app:test", title = "Program", group = {"Programs"}}}, cursor = 1}}
                local painted = chrome_pixels.paint(state, cell[1], cell[2])
                local bar, menu = nil, nil
                for _, image in ipairs(painted.placements) do
                    if image.id == "bars" then bar = image end
                    if image.id == "menu:1" then menu = image end
                end
                test.not_nil(bar)
                test.not_nil(menu)
                test.is_true(bar.rows * cell[2] >= 28, "the taskbar must not shrink into a thin strip")
                test.eq(bar.y, state.bottom + 1)
                test.eq(bar.y + bar.rows - 1, state.height)
                test.eq(menu.y + menu.rows, bar.y, "the menu stands directly above the taskbar")
                local start = painted.hits.bars[1]
                test.eq(start.row, bar.y)
                test.eq(start.bottom_row, state.height)
                test.eq(#painted.hits.menu, 1, "one item stays one keyboard step")
                local choice = painted.hits.menu[1]
                test.eq(choice.row, menu.y)
                test.eq(choice.bottom_row, menu.y + menu.rows - 1)
                state.menu.open = {"Programs"}
                local expanded = chrome_pixels.paint(state, cell[1], cell[2])
                test.eq(#expanded.hits.menu, 2, "a folder and a program are two logical hits")
                local child = expanded.hits.menu[2]
                test.is_true((child.bottom_row - child.row + 1) * cell[2] >= 24,
                    "the submenu keeps its padding and does not go back to a cramped row")

            end
        end)

        test.it("closed and open Start give different taskbar frames", function()
            local state = {width = 80, height = 24, bottom = 23, clock = "12:00", windows = {}, items = {}}
            local first = chrome_pixels.paint(state, 10, 20)
            local bar = first.placements[1].raster
            local before = bar:version()
            state.menu = {items = {{entry = "app:test", title = "Program"}}, cursor = 1}
            local after = chrome_pixels.paint(state, 10, 20)
            test.is_true(bar:version() > before, "Start must become pressed")
            test.eq(after.hits.bars[1].action, "menu")
        end)

        test.it("gives each window type its own set of buttons", function()
            -- The three types are declared by the base; the theme picks the
            -- set by them, and does not derive it from anything else.
            test.eq(#chrome.buttons_for({window_type = "app"}), 3)
            test.eq(#chrome.buttons_for({window_type = "dialog"}), 2,
                "a dialog is neither minimized nor maximized")
            test.eq(#chrome.buttons_for({window_type = "tool"}), 1,
                "a tool window is only closed")
        end)

        test.it("treats an unknown and an unnamed type as an ordinary window", function()
            -- A typo in the declaration is no reason not to draw the window,
            -- and what to do with an unknown type is decided by the base —
            -- the theme merely does not argue.
            test.eq(#chrome.buttons_for({}), 3)
            test.eq(#chrome.buttons_for({window_type = "popup"}), 3)
            test.eq(#chrome.buttons_for(nil), 3)
        end)

        test.it("exactly what is drawn is what gets pressed", function()
            -- The main thing here. A dialog had three buttons drawn and two
            -- pressable: the painting took its own set, the hit its own.
            for _, window_type in ipairs({"app", "dialog", "tool"}) do
                local found, set, window = drawn_buttons(window_type)

                test.eq(#found and true, true)
                for _, button in ipairs(set) do
                    local at = found[button.glyph]
                    test.not_nil(at, window_type .. ": button " .. button.id .. " is not drawn")
                    test.eq(chrome.title_button_at(window, at, window.y + 1), button.id,
                        window_type .. ": under button " .. button.id .. " the hit is a different one")
                end
            end
        end)

        test.it("does not draw buttons on a dialog that it does not have", function()
            -- A drawn button that silently does not work is worse than its
            -- absence: the first thing anyone will ask about it is why it
            -- does not work.
            local found = drawn_buttons("dialog")
            for _, button in ipairs(chrome.BUTTONS) do
                if button.id == "minimize" or button.id == "maximize" then
                    test.is_nil(found[button.glyph],
                        "a dialog has no button " .. button.id)
                end
            end
        end)

        test.it("draws no digit shortcuts in the menu", function()
            -- Windows 95 did not have them, and a person opening programs
            -- with the mouse reads a column of digits as the question "what
            -- are they for". They appeared not by design but because of a
            -- tool: the probe could not do the mouse.
            local canvas = tty.canvas(60, 20)
            chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Calculator", icon = "▣"},
                {entry = "app:notepad", title = "Notepad"},
                {entry = "app:paint", title = "Editor"},
            }, nil, {})

            local rows = canvas:rows()
            for index = 1, 20 do
                local line = table.concat(visible(rows[index] or ""))
                test.is_true(line:find("%d") == nil or line:find("21:") ~= nil,
                    "menu row " .. index .. " carries a digit: " .. line)
            end
        end)

        test.it("highlights the menu row that Enter will open", function()
            -- The compositor does not recompute what is selected now, but
            -- reads what is DRAWN: a second count would drift from the first,
            -- and Enter would open a row other than the highlighted one.
            local canvas = tty.canvas(60, 20)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Calculator", icon = "▣"},
                {entry = "app:notepad", title = "Notepad"},
                {entry = "app:ping", title = "Ping", group = "System Tools"},
            }, nil, {}, 2)

            local under = nil
            local marked = 0
            for _, hit in ipairs(hits) do
                if hit.cursor then marked = marked + 1; under = hit end
            end
            test.eq(marked, 1, "exactly one row is highlighted")
            test.eq(under.slot, 2, "the second selectable row of the panel")
            test.eq(under.level, 1)
        end)

        test.it("highlights nothing when there is no cursor", function()
            -- The mouse does not set up a cursor: a highlighted row while
            -- working with the mouse would promise that Enter opens
            -- something, and nobody pressed it.
            local canvas = tty.canvas(60, 20)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Calculator"},
            }, nil, {})
            for _, hit in ipairs(hits) do
                test.is_nil(hit.cursor)
            end
        end)

        test.it("counts selectable rows, not all of them", function()
            -- Hints and the "…N more" clipping also take up rows, and they
            -- cannot be selected: count them, and the cursor would land on a
            -- row with nothing to open.
            local many = {}
            for index = 1, 40 do
                many[index] = {entry = "app:p" .. index, title = "Program " .. index}
            end
            local canvas = tty.canvas(60, 12)
            local hits = chrome.menu(canvas, 60, 12, many, nil, {}, 1)

            local slots = {}
            for _, hit in ipairs(hits) do slots[#slots + 1] = hit.slot end
            for index, slot in ipairs(slots) do
                test.eq(slot, index, "the numbers of selectable rows run in a row from one")
            end
        end)

        test.it("gives way to the name when the buttons do not fit", function()
            -- A title without a name does not say which window this is, and
            -- it can also be closed from the taskbar.
            local narrow = {x = 1, y = 1, w = 10, h = 6, title = "Window",
                            window_type = "app", rows = {}}
            test.is_nil(chrome.title_button_at(narrow, 8, 2),
                "the buttons are not drawn — so there is no hit either")
        end)

        test.it("fills the desktop and the taskbar face in both modes", function()
            -- A FUNCTION THAT NOBODY CALLS IS GREEN IN ANY SUITE.
            --
            -- `chrome_pixels.fill` was written and called by nothing: the
            -- compositor skipped it in pixel mode. In the very first live run
            -- it crashed on `widgets.styles.desktop`, which did not exist —
            -- the desktop style lay in a second, almost identical table in
            -- the theme. Two tables of one and the same thing drift apart
            -- exactly on the keys both of them rarely need.
            --
            -- So BOTH fills are called here: it must not be possible to
            -- break them separately.
            for _, theme in ipairs({chrome, chrome_pixels}) do
                local canvas = tty.canvas(40, 10)
                local hits = (theme :: any).fill(canvas, 40, 10, {top = 1, bottom = 9, items = {}})
                test.not_nil(hits, "the fill must return a hit map, even an empty one")

                local rows = canvas:rows()
                test.eq(#rows, 10)
                test.is_true(#tostring(rows[1]) > 0, "the desktop must be painted")
                test.is_true(#tostring(rows[10]) > 0, "the taskbar face must be painted")
            end
        end)

        test.it("keeps the styles in one table, not in two similar ones", function()
            -- A key that lives in one theme and is missing from the other is
            -- a failure on the running system, not a difference in look. It
            -- is checked by the identity of the table: two copies will sooner
            -- or later drift apart, one cannot.
            local widgets_styles = require("widgets").styles
            for _, name in ipairs({"desktop", "desktop_text", "desktop_broken",
                                   "title", "title_idle", "banner", "face", "select"}) do
                test.not_nil(widgets_styles[name],
                    "style " .. name .. " must be in the shared table")
            end
        end)

        test.it("root rows go by order, a program can stand above a folder, separator_after separates the next one", function()
            -- As in Windows: "My Computer" on top, a line under it, then the
            -- folders. A folder stands where its earliest program is.
            local items = {
                {entry = "app:calc", title = "Calculator", group = {"Programs"}, order = 20},
                {entry = "app:reg", title = "Registry", group = {"Settings"}, order = 110},
                {entry = "app:mycomp", title = "My Computer", group = {}, order = 5, separator_after = true},
                {entry = "app:run", title = "Run…", group = {}, order = 900},
            }
            local shown = chrome.menu_layout(90, 24, items, nil, {})
            local lines = shown.panels[1].lines
            test.eq(lines[1].label, "My Computer")
            test.eq(lines[2].label, "Programs")
            test.eq(lines[3].label, "Settings")
            test.eq(lines[4].label, "Run…")
            test.is_true(lines[2].separator_before == true, "the line under 'My Computer' belongs to the next row")
            test.is_nil(lines[1].separator_before)
            test.is_nil(lines[3].separator_before)
        end)

        test.it("the logged-on user is the first root row, with an icon, without a hit and without a slot", function()
            local items = {
                {entry = "app:mycomp", title = "My Computer", group = {}, order = 5, separator_after = true},
                {entry = "app:calc", title = "Calculator", group = {"Programs"}, order = 20},
                {entry = "app:run", title = "Run…", group = {}, order = 900},
            }
            local shown = chrome.menu_layout(90, 24, items, nil, {}, 1, {user = {id = "u1", name = "butschster"}})
            local lines = shown.panels[1].lines
            test.eq(lines[1].kind, "user")
            test.eq(lines[1].label, "butschster")
            test.eq(lines[1].image, "user")
            test.is_true(lines[1].bold == true, "the name is set in bold, like a caption")
            test.is_true(not lines[1].dim, "the name is not dimmed")
            test.is_true(lines[2].separator_before == true, "the line under the name belongs to the next row")
            test.eq(lines[2].label, "My Computer")
            -- The row is not selectable: there are no hits on its row, and
            -- cursor 1 is still the first PROGRAM.
            for _, hit in ipairs(shown.hits) do
                test.is_true(hit.row ~= lines[1].row, "there must be no hit on the user row")
            end
            test.eq(shown.hits[1].row, lines[2].row)
            test.is_true(shown.hits[1].cursor == true)
            test.eq(shown.hits[1].slot, 1)
            -- There is no name in a submenu.
            local opened = chrome.menu_layout(90, 24, items, nil, {"Programs"}, 1, {user = {name = "butschster"}})
            test.eq(opened.panels[2].lines[1].kind, "item")
            -- Without a user there is no row at all; an empty name is the same.
            test.eq(chrome.menu_layout(90, 24, items, nil, {}).panels[1].lines[1].label, "My Computer")
            test.eq(chrome.menu_layout(90, 24, items, nil, {}, 1, {user = {name = ""}}).panels[1].lines[1].label, "My Computer")
            -- The context menu at the anchor does not show the name.
            local context = chrome.menu_layout(90, 24, {{entry = "app:x", label = "Open"}}, nil, {}, 1,
                {anchor = {x = 5, y = 5}, user = {name = "butschster"}})
            test.eq(context.panels[1].lines[1].label, "Open")
        end)

        test.it("chrome.use_user raises the name into the shared session and clears it", function()
            local items = {{entry = "app:run", title = "Run…", group = {}, order = 900}}
            chrome.use_user({id = "u1", name = "butschster"})
            test.eq(chrome.session.user.name, "butschster")
            test.eq(chrome.session.user.id, "u1")
            -- Both themes pass exactly this table into the layout.
            local shown = chrome.menu_layout(90, 24, items, nil, {}, 1, {user = chrome.session.user})
            test.eq(shown.panels[1].lines[1].kind, "user")
            chrome.use_user(nil)
            test.is_nil(chrome.session.user)
            chrome.use_user({name = 42})
            test.is_nil(chrome.session.user)
            chrome.use_user({name = ""})
            test.is_nil(chrome.session.user)
        end)

        test.it("in pixels the measure gets the level and the kind, and the hits cover the whole panel", function()
            local items = {
                {entry = "app:calc", title = "Calculator", group = {"Programs"}, order = 20},
                {entry = "app:run", title = "Run…", group = {}, order = 900},
            }
            local seen = {}
            local measure = function(label, level, kind)
                seen[#seen + 1] = {label = label, level = level, kind = kind}
                return 10
            end
            local shown = chrome.menu_layout(90, 24, items, nil, {"Programs"}, 1,
                {compact = true, bottom = 2, measure = measure})
            local levels, kinds = {}, {}
            for _, call in ipairs(seen) do levels[call.level] = true; kinds[call.kind] = true end
            test.is_true(levels[1] and levels[2], "the measure saw the root and the submenu")
            test.is_true(kinds.group and kinds.item, "the measure saw a folder and a program")
            for _, hit in ipairs(shown.hits) do
                local panel = shown.panels[hit.level]
                test.eq(hit.from, panel.x + panel.banner, "the hit starts at the first cell of the list")
                test.eq(hit.to, panel.x + panel.w - 1, "the hit ends at the last cell of the panel")
            end
            -- In cells the outermost cells are the frame, and they are not a hit.
            local cells_mode = chrome.menu_layout(90, 24, items, nil, {})
            local first = cells_mode.hits[1]
            test.eq(first.from, cells_mode.panels[1].x + 1 + cells_mode.panels[1].banner)
            test.eq(first.to, cells_mode.panels[1].x + cells_mode.panels[1].w - 2)
            -- The context menu is measured with level 0.
            seen = {}
            chrome.menu_layout(90, 24, {{entry = "app:x", label = "Open"}}, nil, {}, 1,
                {anchor = {x = 5, y = 5}, compact = true, measure = measure})
            test.eq(seen[1].level, 0)
            test.eq(seen[1].kind, "context")
        end)

        test.it("an icon's context menu is one panel at the anchor, without folders and banner, inside the screen", function()
            local items = {
                {label = "Open", bold = true, entry = "app:mycomp", title = "My Computer"},
                {label = "Properties", entry = "app:sysprops", separator_before = true},
            }
            local shown = chrome.menu_layout(90, 24, items, nil, {}, 2, {anchor = {x = 10, y = 5}})
            test.eq(#shown.panels, 1)
            local panel = shown.panels[1]
            test.eq(panel.x, 10)
            test.eq(panel.y, 5)
            test.eq(panel.banner, 0, "the context menu has no banner")
            test.is_true(panel.context == true)
            test.eq(#panel.lines, 2)
            test.eq(panel.lines[1].label, "Open", "the caption is label, not the window title")
            test.is_true(panel.lines[1].bold == true, "the default action is bold")
            test.is_true(panel.lines[2].separator_before == true)
            test.is_true(panel.lines[2].selected == true, "cursor 2 highlights the second row")
            test.eq(#shown.hits, 2)
            test.eq(shown.hits[2].index, 2)
            test.eq(shown.hits[2].slot, 2)
            test.eq(shown.hits[2].cursor, true)
            test.is_true(shown.hits[1].from > panel.x and shown.hits[1].to < panel.x + panel.w)

            -- At the screen edge the panel shifts inwards, it is not cut.
            local edge = chrome.menu_layout(90, 24, items, nil, {}, 1, {anchor = {x = 88, y = 23}})
            local box = edge.panels[1]
            test.is_true(box.x + box.w - 1 <= 90, "the panel does not go past the right edge")
            test.is_true(box.y + box.h - 1 <= 23, "the panel does not lie on the taskbar")

            -- The pixel theme: one row per item, and the anchor — from the same menu.
            local flat = chrome.menu_layout(90, 24, items, nil, {}, 1,
                {anchor = {x = 10, y = 5}, compact = true, context_rows = 1, bottom = 2})
            test.eq(flat.panels[1].h, 2, "in pixels one row per item and no frame")
            test.eq(chrome.menu_layout(90, 24, {}, nil, {}, 1, {anchor = {x = 1, y = 1}}).panels[1], nil,
                "an empty list — no panel")
        end)

        test.it("carries a group from the registry entry to a folder in the menu", function()
            -- THIS WHOLE PATH WAS GREEN AND NEVER ONCE TRAVERSED. The catalog
            -- parsed `meta.group` into a TABLE of segments, while the theme
            -- expected a STRING and parsed it a second time — that is, the
            -- path came out empty, the folder was not created, the program
            -- lay on the top level. No failure, no trace: the program is
            -- visible, just not where it was asked to be.
            --
            -- Checked end to end, through both pure functions: the registry
            -- is not needed for that, and separately each half was right.
            local built = catalog.build({
                {id = "app:calc", meta = {type = "tui_desktop.window",
                                          title = "Calculator", group = "Accessories"}},
                {id = "app:bash", meta = {type = "tui_desktop.window",
                                          title = "MS-DOS Prompt", group = ""}},
            })

            test.eq(#built.tree.folders, 1, "the folder must appear in the catalog tree")
            test.eq(built.tree.folders[1].title, "Accessories")
            test.eq(#built.tree.programs, 1, "only the one that asked for the root stays on the top level")

            -- And now the same through the theme's eyes: it gets the menu
            -- items in the form the shell puts them in.
            local items = {}
            for _, program in ipairs(catalog.listed(built.programs)) do
                items[#items + 1] = {
                    entry = program.entry, title = program.title,
                    group = program.group, order = program.order, icon = program.icon,
                }
            end

            local flat = chrome.menu_layout(90, 24, items, nil, {})
            test.eq(#flat.panels, 1, "without opening there is one panel")

            local folders, programs = 0, 0
            for _, line in ipairs(flat.panels[1].lines) do
                if line.kind == "group" then folders = folders + 1 end
                if line.kind == "item" then programs = programs + 1 end
            end
            test.eq(folders, 1, "the theme must show the folder, not lay everything out flat")
            test.eq(programs, 1)

            -- And the opening: only then does the arrow get something to work with.
            local opened = chrome.menu_layout(90, 24, items, nil, {"Accessories"})
            test.eq(#opened.panels, 2, "an open folder must give a second panel")

            local inside = 0
            for _, line in ipairs(opened.panels[2].lines) do
                if line.kind == "item" then inside = inside + 1 end
            end
            test.eq(inside, 1, "inside the folder lies what was put into it")
        end)

        test.it("keeps the menu depth as one number, not two", function()
            -- Depth clipping lived TWICE: `catalog.MAX_DEPTH` and a constant
            -- of its own in the theme. Two numbers with one meaning will one
            -- day be changed one at a time — the same trouble as the two
            -- style tables, only about a number.
            --
            -- Now depth is limited by whoever parses the path, and the
            -- cascade is stopped by the screen width. Checked by the theme
            -- showing EXACTLY as many levels as the catalog gave.
            local built = catalog.build({
                {id = "app:deep", meta = {type = "tui_desktop.window",
                                          title = "Deep", group = "A/B/C/D/E"}},
            })
            local program = catalog.find(built.programs, "app:deep")
            test.eq(#program.group, catalog.MAX_DEPTH,
                "the catalog must clip the path itself, and clip it to its own number")

            local items = {{entry = program.entry, title = program.title,
                            group = program.group, order = program.order}}
            local opened = chrome.menu_layout(200, 24, items, nil, program.group)
            test.eq(#opened.panels, catalog.MAX_DEPTH + 1,
                "the theme shows exactly as many levels as the catalog gave")
        end)
    end)

    -- The layout failure and the status line — in pixels.
    --
    -- The cell theme drew both things, the pixel one read neither: an
    -- unreadable layout looked like an empty desktop with no reason, and the
    -- compositor's messages — including its complaints about a bad frame from
    -- the theme itself — were seen by nobody.
    --
    -- There is nothing to read a pixel of a raster with, so the PNG bytes of
    -- frames differing in the LAST word are compared. One check catches both
    -- "the text is not drawn" and "the text is cut off, not wrapped": a cut
    -- would eat exactly the end, and both frames would match.
    -- One value in two places: the taskbar layout and the desktop icon hit were
    -- computed by each theme on its own. `chrome` computes them now, so a
    -- mutation of the shared rule turns both themes red.
    test.describe("one taskbar and desktop layout for both themes", function()
        local WINDOWS: any = {}
        for index = 1, 5 do WINDOWS[index] = {id = "w" .. index, title = "Window " .. index} end

        local function use_fonts()
            -- A pattern or wallpaper left by a test that failed mid-way must
            -- not paint under this one.
            chrome.use_pattern(nil)
            chrome.use_wallpaper(nil, nil)
            local files = assert(fs.get("app:system_fonts"))
            chrome_pixels.use_fonts(
                assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
                assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true})))
            chrome_pixels.use_cell_size(10, 20)
        end

        -- Start first, window buttons in order and sharing no cell, the clock at
        -- the right edge, and no button reaching into it.
        local function check_bar(hits: any, w: integer, name: string): any
            local start, clock = hits[1], hits[#hits]
            test.eq(start.action, "menu", name)
            test.eq(start.from, 1, name)
            test.eq(clock.entry, "app:clock", name)
            test.eq(clock.to, w, name .. ": the clock sits at the right edge")
            local previous, ids = start.to, {}
            for index = 2, #hits - 1 do
                local hit = hits[index]
                test.is_true(hit.from > previous, name .. ": " .. tostring(hit.id) .. " overlaps its neighbour")
                previous = hit.to
                ids[#ids + 1] = hit.id
            end
            test.is_true(previous < clock.from, name .. ": a window button reaches into the clock")
            test.is_true(#ids >= 3, name .. ": the scene must show several windows")
            return ids
        end

        local function same_as_plan(hits: any, plan: any, name: string)
            test.eq(hits[1].to, plan.start.to, name .. ": Start")
            test.eq(#hits - 2, #plan.tasks, name .. ": window buttons")
            for index, task in ipairs(plan.tasks) do
                test.eq(hits[index + 1].from, task.from, name .. ": start of " .. tostring(task.id))
                test.eq(hits[index + 1].to, task.to, name .. ": end of " .. tostring(task.id))
            end
            test.eq(hits[#hits].from, plan.clock.from, name .. ": clock")
        end

        test.it("the cell theme takes its taskbar bounds from chrome.taskbar_layout", function()
            chrome.clock_entry = "app:clock"
            local hits = chrome.bars(tty.canvas(80, 24), 80, 24, {clock = "12:30", windows = WINDOWS})
            chrome.clock_entry = nil
            check_bar(hits, 80, "cells")
            same_as_plan(hits, chrome.taskbar_layout(80, WINDOWS, {start = hits[1].to, gap = 1, clock = 9}), "cells")
        end)

        test.it("the pixel theme takes its taskbar bounds from the same layout", function()
            chrome_pixels.clock_entry = "app:clock"
            chrome_pixels.use_cell_size(10, 20)
            local hits = chrome_pixels.paint({width = 80, height = 24, bottom = 22, clock = "12:30",
                windows = WINDOWS, items = {}}, 10, 20).hits.bars
            chrome_pixels.clock_entry = nil
            check_bar(hits, 80, "pixels")
            same_as_plan(hits, chrome.taskbar_layout(80, WINDOWS,
                {start = hits[1].to, task_min = 16, task_max = 16, clock = 9, clock_gap = 1}), "pixels")
        end)

        -- The notification area is one more slot of the shared layout. Tray
        -- items sit between the window buttons and the clock, against the
        -- clock, and each theme hits exactly where the plan puts them.
        local TRAY: any = {
            {key = "weather", text = "+17°", entry = "app:weather", icon = "☼", image = "clock"},
            {key = "mail", text = "3 new", entry = "app:mail"},
        }
        -- A caption without `entry`: drawn in its slot, no hit.
        local NOTE: any = {key = "note", text = "idle"}

        local function split(hits: any): any
            local parts: any = {tasks = {}, tray = {}}
            for _, hit in ipairs(hits) do
                if hit.action == "menu" then parts.start = hit
                elseif hit.id ~= nil then parts.tasks[#parts.tasks + 1] = hit
                elseif hit.entry == "app:clock" then parts.clock = hit
                elseif hit.entry ~= nil then parts.tray[#parts.tray + 1] = hit end
            end
            return parts
        end

        -- The theme measures its captions itself; the plan is rebuilt from the
        -- widths it hit, and then every window button and tray item must land
        -- where that plan says. A theme placing the tray on its own drifts
        -- off the plan and turns this red.
        local function same_tray_plan(hits: any, metrics: any, name: string)
            local parts = split(hits)
            test.eq(#parts.tray, #TRAY, name .. ": one hit per tray item")
            test.not_nil(parts.clock, name .. ": the clock is still there")
            test.eq(parts.tray[#parts.tray].to + 1, parts.clock.from, name .. ": the tray sits against the clock")
            local widths = {}
            for index, hit in ipairs(parts.tray) do
                widths[index] = hit.to - hit.from + 1
                test.eq(hit.entry, TRAY[index].entry, name .. ": the hit opens its own item's window")
            end
            metrics.tray = widths
            metrics.start = parts.start.to
            local plan = chrome.taskbar_layout(80, WINDOWS, metrics)
            test.eq(#parts.tasks, #plan.tasks, name .. ": window buttons")
            for index, task in ipairs(plan.tasks) do
                test.eq(parts.tasks[index].to, task.to, name .. ": end of " .. tostring(task.id))
            end
            for index, slot in ipairs(plan.tray) do
                test.eq(parts.tray[index].from, slot.from, name .. ": start of tray item " .. index)
            end
            local last_task = parts.tasks[#parts.tasks]
            test.is_true(last_task == nil or last_task.to < parts.tray[1].from,
                name .. ": a window button reaches into the tray")
        end

        test.it("puts the tray between the window buttons and the clock in both themes", function()
            chrome.clock_entry = "app:clock"
            local cell_hits = chrome.bars(tty.canvas(80, 24), 80, 24, {clock = "12:30", windows = WINDOWS, tray = TRAY})
            same_tray_plan(cell_hits, {gap = 1, clock = 9}, "cells")
            -- The caption without an entry is drawn in order and gets no hit.
            local canvas = tty.canvas(80, 24)
            local noted = split(chrome.bars(canvas, 80, 24,
                {clock = "12:30", windows = WINDOWS, tray = {NOTE, TRAY[1], TRAY[2]}}))
            chrome.clock_entry = nil
            test.eq(#noted.tray, 2, "cells: a caption without an entry has no hit")
            local row = (tostring((canvas:rows() :: any)[24]):gsub("\27%[[%d;:]*m", ""))
            test.is_true(row:find(" idle  ☼ +17°  3 new ", 1, true) ~= nil,
                "cells: the captions in order, the glyph before its caption: " .. row)

            use_fonts()
            chrome_pixels.clock_entry = "app:clock"
            local function bar_png(items: any): any
                local painted = chrome_pixels.paint({width = 80, height = 24, bottom = 22, clock = "12:30",
                    windows = WINDOWS, items = {}, tray = items}, 10, 20)
                local bytes = nil
                for _, image in ipairs(painted.placements) do
                    if image.id == "bars" then bytes = assert(image.raster:encode("png")) end
                end
                return painted.hits.bars, bytes
            end
            local pixel_hits, with_tray = bar_png(TRAY)
            local _, without = bar_png({})
            local plain_hits, no_image = bar_png({{key = "weather", text = "+17°", entry = "app:weather"}, TRAY[2]})
            chrome_pixels.clock_entry = nil
            chrome_pixels.fonts = nil
            same_tray_plan(pixel_hits, {task_min = 16, task_max = 16, clock = 9, clock_gap = 1}, "pixels")
            test.is_true(with_tray ~= without, "pixels: the tray captions are drawn")
            -- The weather icon: a wider slot and a different picture.
            test.is_true(with_tray ~= no_image, "pixels: the tray icon is drawn beside the caption")
            local wide = split(pixel_hits).tray[1]
            local narrow = split(plain_hits).tray[1]
            test.is_true(wide.to - wide.from > narrow.to - narrow.from,
                "pixels: an item with an image gets room for the icon")
        end)

        test.it("reserves the tray before window buttons and drops only what does not fit", function()
            -- 40 cells: Start 8, gap 1, clock 7 with a gap of 1. The budget for
            -- the tray is 24: 5 fits, 30 does not, 4 still does.
            local plan = chrome.taskbar_layout(40, WINDOWS, {start = 8, gap = 1, clock = 7, clock_gap = 1,
                task_min = 7, task_max = 20, tray = {5, 30, 4}})
            test.eq(#plan.tray, 2)
            test.eq(plan.tray[1].index, 1)
            test.eq(plan.tray[2].index, 3)
            test.eq(plan.tray[1].from, 25)
            test.eq(plan.tray[2].to, 33, "against the clock")
            test.eq(plan.clock.from, 34)
            -- Window buttons gave way: two of five, and neither reaches the tray.
            test.eq(#plan.tasks, 2)
            test.is_true(plan.tasks[2].to < plan.tray[1].from)
            -- No tray: the same layout as before the slot existed, with a third
            -- button in the room the tray took.
            local bare = chrome.taskbar_layout(40, WINDOWS, {start = 8, gap = 1, clock = 7, clock_gap = 1,
                task_min = 7, task_max = 20})
            test.eq(#bare.tray, 0)
            test.eq(#bare.tasks, 3)
            test.eq(bare.tasks[3].to, 30)
        end)

        -- The owner's rule (2026-09-11): the taskbar carries notices only —
        -- "could not open: …" shows with and without windows, since it
        -- happens exactly when nothing is open yet. The compositor's key
        -- hint arrives as `status` and is never drawn by either theme.
        local NOTICE = "could not open: app:gone"
        local HINT = "alt+n bash · alt+o programs · ctrl+q quit"

        test.it("cells: the notice shows with and without windows, the status hint never", function()
            local function row(windows: any, state: any): string
                local canvas = tty.canvas(80, 24)
                state.clock, state.windows = "12:30", windows
                chrome.bars(canvas, 80, 24, state)
                local rows: any = canvas:rows()
                return (tostring(rows[24]):gsub("\27%[[%d;:]*m", ""))
            end
            test.is_true(row({WINDOWS[1]}, {notice = NOTICE}):find(NOTICE, 1, true) ~= nil,
                "the notice is shown beside a window")
            test.is_true(row({}, {notice = NOTICE}):find(NOTICE, 1, true) ~= nil,
                "the notice is shown on an empty taskbar too")
            test.is_nil(row({WINDOWS[1]}, {status = HINT}):find("alt+n", 1, true), "the status hint is not drawn")
            test.is_nil(row({}, {status = HINT}):find("alt+n", 1, true), "nor on an empty taskbar")
        end)

        test.it("pixels: the notice shows with and without windows, the status hint never", function()
            local one = {WINDOWS[1]}
            use_fonts()
            -- Bytes are taken right after each frame: the store paints the next
            -- frame into the same buffer.
            local function bar_png(windows: any, state: any): any
                state.width, state.height, state.bottom, state.clock = 80, 24, 22, "12:00"
                state.windows, state.items = windows, {}
                local painted = chrome_pixels.paint(state, 10, 20)
                for _, image in ipairs(painted.placements) do
                    if image.id == "bars" then return assert(image.raster:encode("png")) end
                end
                return nil
            end
            local shown, bare = bar_png(one, {notice = NOTICE}), bar_png(one, {})
            local empty_with, empty_without = bar_png({}, {notice = NOTICE}), bar_png({}, {})
            local hinted, empty_hinted = bar_png(one, {status = HINT}), bar_png({}, {status = HINT})
            chrome_pixels.fonts = nil
            test.is_true(shown ~= bare, "the notice is drawn beside a window")
            test.is_true(empty_with ~= empty_without, "the notice is drawn on an empty taskbar too")
            test.eq(hinted, bare, "the status hint is not drawn")
            test.eq(empty_hinted, empty_without, "nor on an empty taskbar")
            test.not_nil(chrome.taskbar_layout(80, {}, {start = 11, gap = 1, clock = 9}).status,
                "the layout keeps notice room on an empty taskbar")
        end)

        test.it("places a desktop icon by one clipping rule and gives one hit table", function()
            chrome_pixels.use_cell_size(10, 20)
            -- The layout was written on another screen: left of the edge, above the desk.
            local item = {id = "d1", x = 0, y = 0, kind = "program", entry = "app:x", title = "X",
                w = 40, h = 12, args = {a = 1}, properties = "app:props"}
            local cell_hits = chrome.fill(tty.canvas(80, 24), 80, 24, {top = 2, bottom = 22, items = {item}})
            local pixel_hits = chrome_pixels.paint({width = 80, height = 24, top = 2, bottom = 22,
                items = {item}, windows = {}}, 10, 20).hits.desktop
            test.is_true(#cell_hits > 0, "cells: the icon moves to the edge of the desk")
            test.is_true(#pixel_hits > 0, "pixels: the same, instead of vanishing")
            local function keys(hit: any): string
                local out = {}
                for key in pairs(hit) do out[#out + 1] = tostring(key) end
                table.sort(out)
                return table.concat(out, ",")
            end
            for name, hits in pairs({cells = cell_hits, pixels = pixel_hits}) do
                local hit = hits[1]
                test.eq(hit.from, 1, name .. ": the left edge")
                test.eq(hit.row, 2, name .. ": the top of the desk, not row zero")
                test.eq(hit.properties, "app:props", name)
                test.eq(hit.w, 40, name)
                test.eq(hit.args.a, 1, name)
            end
            test.eq(keys(cell_hits[1]), keys(pixel_hits[1]), "both hits carry the same fields")

            local far = {id = "d2", x = 81, y = 3, kind = "program"}
            test.eq(#chrome.fill(tty.canvas(80, 24), 80, 24, {top = 2, bottom = 22, items = {far}}), 0,
                "cells: right of the screen, not drawn")
            test.eq(#chrome_pixels.paint({width = 80, height = 24, top = 2, bottom = 22, items = {far},
                windows = {}}, 10, 20).hits.desktop, 0, "pixels: the same")
        end)

        test.it("draws the Start banner from the one string chrome.MENU_BANNER in both themes", function()
            -- Long captions: the banner only appears on a wide panel.
            local long: any, other: any = {}, {}
            for index = 1, 10 do
                long[index] = {entry = "app:p" .. index, title = "A program with a long name " .. index}
                other[index] = {entry = "app:q" .. index, title = "Another program with a name " .. index}
            end
            local saved = chrome.MENU_BANNER

            chrome.MENU_BANNER = "Abcdefghij"
            local plan = chrome.menu_layout(80, 24, long, nil, {}, 1, {})
            local lines: any = plan.panels[1].lines
            local letters = ""
            for index = #lines, 1, -1 do
                local letter = tostring(lines[index].banner_letter or " ")
                if letter ~= " " then letters = letters .. letter end
            end

            use_fonts()
            local layout = chrome_pixels.layout(100, 30)
            local function menu_png(items: any): any
                local painted = chrome_pixels.paint({width = 100, height = 30, bottom = 30 - layout.bottom,
                    clock = "12:00", windows = {}, items = {}, menu = {items = items, cursor = 1}}, 10, 20)
                for _, image in ipairs(painted.placements) do
                    if image.id == "menu:1" then return assert(image.raster:encode("png")) end
                end
                return nil
            end
            chrome.MENU_BANNER = saved
            local first = menu_png(long)
            -- Another state in between, so the menu raster is painted again: its
            -- key is built from the items, not from the banner.
            menu_png(other)
            chrome.MENU_BANNER = "Other 1999"
            local second = menu_png(long)
            chrome.MENU_BANNER = saved
            chrome_pixels.fonts = nil

            test.eq(letters, "ABCDEFGHIJ", "cells write chrome.MENU_BANNER in capitals, bottom to top")
            test.not_nil(first, "the menu is painted")
            test.is_true(first ~= second, "the pixel theme paints chrome.MENU_BANNER, not a copy of its own")
        end)
    end)

    test.describe("pixel desktop failure and taskbar status", function()
        local function use_fonts()
            -- A pattern or wallpaper left by a test that failed mid-way must
            -- not paint under this one.
            chrome.use_pattern(nil)
            chrome.use_wallpaper(nil, nil)
            local files = assert(fs.get("app:system_fonts"))
            local face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            chrome_pixels.use_fonts(face, bold)
            chrome_pixels.use_cell_size(10, 20)
            return face
        end
        local function find(painted: any, id): any
            for _, item in ipairs(painted.placements) do
                if item.id == id then return item end
            end
            return nil
        end
        -- The bytes are taken RIGHT AFTER the frame: the store paints the next
        -- frame into the same buffer, and a raster from the previous frame
        -- already shows the new one.
        local function png(painted: any, id)
            local item = find(painted, id)
            test.not_nil(item, "no placement " .. id)
            return assert(item.raster:encode("png"))
        end

        test.it("the desktop names the reason for an unreadable layout in full, wrapped, not cut off", function()
            local face = use_fonts()
            -- Two lines, not three: on the third, at the wrap limit, a
            -- different font would put an ellipsis instead of the last word,
            -- and the case would turn red for the wrong reason.
            local reason = "database is locked: SELECT id, x, y, image FROM butschster_windows_desktop"
                .. " ORDER BY position, table "
            test.is_true(face:measure(reason .. "alpha") > 48 * 10,
                "the scene must be wider than the plate, otherwise there is nothing to wrap")
            local state: any = {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00",
                items = {{id = "icon", x = 2, y = 4, kind = "folder", title = "Folder"}},
                windows = {{id = "w1", title = "Notepad", x = 30, y = 10, w = 40, h = 10}},
                focused_id = "w1", failure = reason .. "alpha",
                notice = "could not open: app:gone — entry not found"}
            local painted = chrome_pixels.paint(state, 10, 20)

            -- The screenshot is for the eyes, from the same frame that is checked below.
            local screen = gfx.raster(80 * 10, 24 * 20)
            screen:fill("#008080")
            for _, item in ipairs(painted.placements) do
                screen:blit(item.raster, (item.x - 1) * 10 + 1, (item.y - 1) * 20 + 1)
            end
            assert(assert(fs.get("app:shots")):writefile("layout-failure.png", assert(screen:encode("png"))))

            local plate = find(painted, "desk:failure")
            test.not_nil(plate, "the layout failure must be on the desktop")
            test.eq(plate.x, 3)
            test.eq(plate.y, 2, "the row under the top of the desktop, as in cells")
            test.eq(plate.cols, 48)
            test.is_true(plate.y + plate.rows - 1 <= 22, "the plate does not reach onto the taskbar")
            test.is_nil(find(painted, "desk:icon"), "the icons of an unread layout are not drawn")
            local first = assert(plate.raster:encode("png"))
            local version = plate.raster:version()

            local again = find(chrome_pixels.paint(state, 10, 20), "desk:failure")
            test.eq(again.raster, plate.raster, "the same failure — the same raster")
            test.eq(again.raster:version(), version, "the same failure is not repainted")

            state.failure = reason .. "omega"
            test.is_true(png(chrome_pixels.paint(state, 10, 20), "desk:failure") ~= first,
                "the end of the reason is not drawn: a cut instead of a wrap")

            state.failure = nil
            local cleared = chrome_pixels.paint(state, 10, 20)
            test.is_nil(find(cleared, "desk:failure"), "the layout was read — no plate")
            test.not_nil(find(cleared, "desk:icon"))
            chrome_pixels.fonts = nil
        end)

        test.it("the taskbar shows the notice between the windows and the clock", function()
            use_fonts()
            local state: any = {width = 80, height = 24, bottom = 22, clock = "12:00", items = {},
                windows = {{id = "w1", title = "Notepad", x = 5, y = 3, w = 30, h = 10}}, focused_id = "w1"}
            local bare = png(chrome_pixels.paint(state, 10, 20), "bars")

            state.notice = "could not open: app:gone — entry not found"
            local painted = chrome_pixels.paint(state, 10, 20)
            local shown = png(painted, "bars")
            test.is_true(shown ~= bare, "the notice is not drawn")
            local version = find(painted, "bars").raster:version()
            test.eq(find(chrome_pixels.paint(state, 10, 20), "bars").raster:version(), version,
                "the same notice — the taskbar is not repainted")

            state.notice = "could not open: app:gone — entry missing"
            test.is_true(png(chrome_pixels.paint(state, 10, 20), "bars") ~= shown,
                "a different end of the notice — a different frame")

            -- Tight: fewer than six cells between the window button and the clock.
            state.width, state.notice = 36, nil
            local narrow = chrome_pixels.paint(state, 10, 20)
            local task = narrow.hits.bars[#narrow.hits.bars]
            test.eq(task.id, "w1")
            test.is_true(36 - 8 - (task.to + 1) < 6, "the scene must leave fewer than six cells")
            local empty = png(narrow, "bars")
            state.notice = "could not open: app:gone"
            test.eq(png(chrome_pixels.paint(state, 10, 20), "bars"), empty, "when tight the notice is not drawn")
            chrome_pixels.fonts = nil
        end)

        -- The pattern costs pixels, so its shape is checked: one placement per
        -- desktop row under the icons, cropped by windows like an icon, and a
        -- window dragged over it re-sends only the strips of the rows it
        -- covers. The numbers go to shots/pattern-cost.txt for the report.
        test.it("a desktop pattern is a strip per row, and a dragged window re-sends only its own rows", function()
            use_fonts()
            test.is_true(chrome.use_pattern({136, 84, 34, 69, 136, 21, 34, 81}))
            local state: any = {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00",
                items = {{id = "icon", x = 2, y = 2, kind = "folder", title = "Folder"}},
                windows = {{id = "w1", title = "Notepad", x = 10, y = 5, w = 20, h = 8}}, focused_id = "w1"}
            local first = chrome_pixels.paint(state, 10, 20)
            local before: any = {}
            local placements_first, first_px = 0, 0
            for _, item in ipairs(first.placements) do
                before[item.id] = {raster = item.raster, version = item.raster:version()}
                if tostring(item.id):find("desk:pattern:", 1, true) == 1 then
                    placements_first = placements_first + 1
                    first_px = first_px + item.cols * item.rows * 200
                    test.eq(item.rows, 1, "a strip is one row: " .. item.id)
                end
            end
            test.is_true(placements_first >= 22, "every desktop row has its strip, the covered rows their crops")
            state.windows[1].x = 40
            local second = chrome_pixels.paint(state, 10, 20)
            local resent, resent_px = 0, 0
            for _, item in ipairs(second.placements) do
                local id = tostring(item.id)
                local was: any = before[id]
                if id:find("desk:pattern:", 1, true) == 1
                    and (was == nil or was.raster ~= item.raster or was.version ~= item.raster:version()) then
                    resent = resent + 1
                    resent_px = resent_px + item.cols * item.rows * 200
                    local line = math.tointeger(tonumber(id:match("^desk:pattern:(%d+)")))
                    test.is_true(line ~= nil and line >= 5 and line <= 12, "only the window's rows are re-sent: " .. id)
                end
            end
            test.is_true(resent > 0, "the rows under the window change")
            assert(assert(fs.get("app:shots")):writefile("pattern-cost.txt", string.format(
                "10x20 cells, 80x24 screen, Weave: first frame %d pattern placements, %d px; "
                .. "a 20x8 window dragged 30 columns: %d placements re-sent, %d px\n",
                placements_first, first_px, resent, resent_px)))
            test.is_true(chrome.use_pattern(nil))
            for _, item in ipairs(chrome_pixels.paint(state, 10, 20).placements) do
                test.is_nil(tostring(item.id):find("desk:pattern:", 1, true), "no pattern, no strips: " .. item.id)
            end
            chrome_pixels.fonts = nil
        end)

        -- The wallpaper is drawn into the same strips. A tile continues from the
        -- screen's corner across strips — rows 1 and 17 start 320 px apart,
        -- ten 32 px tiles, so they are the same picture; a centred picture
        -- leaves the top rows plain and fills the middle. A dragged window
        -- re-sends only its own rows, as with the pattern.
        test.it("a wallpaper is drawn into the row strips, tiled or centred, and a drag re-sends only its rows", function()
            use_fonts()
            local lines: any = {}
            for _, case in ipairs({{"wallpaper_rivets", "tile"}, {"wallpaper_sky", "center"}}) do
                local file, mode = case[1], case[2]
                test.is_true(chrome.use_wallpaper(file, mode), file .. " " .. mode)
                local state: any = {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00", items = {},
                    windows = {{id = "w1", title = "Notepad", x = 10, y = 5, w = 20, h = 8}}, focused_id = "w1"}
                local first = chrome_pixels.paint(state, 10, 20)
                local before: any, strip_png: any = {}, {}
                local strips, first_px = 0, 0
                for _, item in ipairs(first.placements) do
                    before[item.id] = {raster = item.raster, version = item.raster:version()}
                    local line = tostring(item.id):match("^desk:pattern:(%d+)$")
                    if line then strip_png[math.tointeger(tonumber(line))] = assert(item.raster:encode("png")) end
                    if tostring(item.id):find("desk:pattern:", 1, true) == 1 then
                        strips = strips + 1
                        first_px = first_px + item.cols * item.rows * 200
                    end
                end
                test.is_true(strips >= 22, mode .. ": every desktop row has its strip")
                if mode == "tile" then
                    test.eq(strip_png[1], strip_png[17], "tile: the tile continues across strips — rows 1 and 17 match")
                    test.is_true(strip_png[1] ~= strip_png[2], "tile: rows at another phase differ")
                else
                    test.eq(strip_png[1], strip_png[2], "center: the rows above the picture are plain desktop")
                    test.is_true(strip_png[1] ~= strip_png[13], "center: the picture fills the middle rows")
                end
                state.windows[1].x = 40
                local resent, resent_px = 0, 0
                for _, item in ipairs(chrome_pixels.paint(state, 10, 20).placements) do
                    local id = tostring(item.id)
                    local was: any = before[id]
                    if id:find("desk:pattern:", 1, true) == 1
                        and (was == nil or was.raster ~= item.raster or was.version ~= item.raster:version()) then
                        resent = resent + 1
                        resent_px = resent_px + item.cols * item.rows * 200
                        local line = math.tointeger(tonumber(id:match("^desk:pattern:(%d+)")))
                        test.is_true(line ~= nil and line >= 5 and line <= 12, mode .. ": only the window's rows are re-sent: " .. id)
                    end
                end
                test.is_true(resent > 0, mode .. ": the rows under the window change")
                lines[#lines + 1] = string.format("%s %s: first frame %d strip placements, %d px; "
                    .. "a 20x8 window dragged 30 columns: %d re-sent, %d px", file, mode, strips, first_px, resent, resent_px)
            end
            assert(assert(fs.get("app:shots")):writefile("wallpaper-cost.txt", "10x20 cells, 80x24 screen\n" .. table.concat(lines, "\n") .. "\n"))
            test.is_false(chrome.use_wallpaper("rivets", "tile"), "a name outside the wallpaper folder is not a wallpaper")
            test.is_false(chrome.use_wallpaper("wallpaper_rivets", "stretch"), "nor a mode Windows 95 did not have")
            test.is_true(chrome.use_wallpaper(nil))
            chrome_pixels.fonts = nil
        end)

        test.it("a view that threw an error is a failure text in the window, not a crashed shell frame", function()
            use_fonts()
            -- `children` not as a list: `ui.plan` throws inside the view library.
            local window = {id = "v", x = 5, y = 3, w = 30, h = 10, title = "View", content = "pixels",
                render = "butschster.windows.sdk:render",
                content_state = {sdk = 1, revision = 1, ui = {kind = "column", children = 42}}}
            local ok, painted = pcall(chrome_pixels.paint, {width = 80, height = 24, bottom = 22, clock = "12:00",
                items = {}, windows = {window}, focused_id = "v"}, 10, 20)
            chrome_pixels.fonts = nil
            test.is_true(ok, "the shell frame crashed: " .. tostring(painted))
            test.not_nil(find(painted, "win:v:notice"), "the view failure must be text on the window's face")
            test.not_nil(find(painted, "win:v:head"), "the window frame is in place")
        end)
    end)

    -- The Start menu and the context menu are over the windows ALWAYS.
    --
    -- The runtime surface resends only what is new, changed, or covers a
    -- repainted row (surface.go, appendPlacements), and sixel has no z order.
    -- An open menu does not change; the raster of a window under it is resent
    -- on each of its ticks and lies on top. So what is checked is not the list
    -- order, but that there is NOT A SINGLE piece of someone else's raster
    -- under the menu — neither in the first frame nor in the second, where the
    -- window changed and the menu did not.
    test.describe("menu above windows", function()
        local function load_fonts()
            -- A pattern or wallpaper left by a test that failed mid-way must
            -- not paint under this one.
            chrome.use_pattern(nil)
            chrome.use_wallpaper(nil, nil)
            local files = assert(fs.get("app:system_fonts"))
            local face = assert(gfx.font(assert(files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local bold = assert(gfx.font(assert(files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            chrome_pixels.use_fonts(face, bold)
            chrome_pixels.use_cell_size(10, 20)
        end
        local function overlaps(a: any, b: any): boolean
            return a.x < b.x + b.cols and b.x < a.x + a.cols and a.y < b.y + b.rows and b.y < a.y + a.rows
        end
        local function menus_of(painted: any): any
            local out = {}
            for _, item in ipairs(painted.placements) do
                if tostring(item.id):find("menu:", 1, true) == 1 then out[#out + 1] = item end
            end
            return out
        end
        local function below_menu(painted: any): any
            local hits = {}
            for _, item in ipairs(painted.placements) do
                if tostring(item.id):find("menu:", 1, true) ~= 1 then
                    for _, panel in ipairs(menus_of(painted)) do
                        if overlaps(item, panel) then hits[#hits + 1] = item.id .. " under " .. panel.id end
                    end
                end
            end
            return hits
        end
        local function by_id(painted: any, id: string): any
            for _, item in ipairs(painted.placements) do if item.id == id then return item end end
            return nil
        end
        -- A cell window under the menu and an SDK window with pixel content,
        -- the latter on top, so that its raster is cut only by the menu.
        local function scene(): any
            return {width = 80, height = 24, bottom = 22, clock = "12:00", items = {},
                windows = {
                    {id = "cells", x = 2, y = 3, w = 40, h = 16, title = "Bash", window_type = "app"},
                    {id = "sdk", x = 6, y = 8, w = 44, h = 12, title = "Task Manager", window_type = "app",
                        content = "pixels", render = "butschster.windows.sdk:render", state_revision = 1,
                        content_state = {sdk = 1, revision = 1, ui = {kind = "label", text = "tick 1"}}},
                },
                focused_id = "sdk",
                menu = {items = {
                    {entry = "app:calc", title = "Calculator", group = {"Programs"}},
                    {entry = "app:notepad", title = "Notepad", group = {"Programs"}},
                    {entry = "app:run", title = "Run…", group = {}},
                    {entry = "app:shutdown", title = "Shut Down…", group = {}},
                }, open = {"Programs"}, cursor = 1}}
        end

        -- An open menu and the taskbar's captions are measured once, not every
        -- frame: a frame with the same menu calls `font:measure` zero times.
        -- The fonts are instrumented IN PLACE, so the theme sees the same font
        -- set it measured with; nothing is repainted, so the counting stand-in
        -- never reaches `raster:text`, which wants a real font.
        test.it("a frame with the same menu measures no text; a changed menu is laid out anew", function()
            load_fonts()
            local state: any = scene()
            state.tray = {{key = "weather", text = "+21°", entry = "app:weather"}}
            chrome_pixels.paint(state, 10, 20)
            local fonts: any = chrome_pixels.fonts
            local counted: any = {n = 0}
            local function counting(font: any): any
                return setmetatable({}, {__index = function(_, name)
                    return function(_, ...)
                        if name == "measure" then counted.n = counted.n + 1 end
                        return font[name](font, ...)
                    end
                end})
            end
            local face, bold = fonts.face, fonts.bold
            fonts.face, fonts.bold = counting(face), counting(bold)
            local again = chrome_pixels.paint(state, 10, 20)
            fonts.face, fonts.bold = face, bold
            test.eq(counted.n, 0, "the second frame measured text " .. counted.n .. " times")
            test.is_true(#again.hits.menu > 0, "the menu is still there, from the kept layout")

            -- A moved cursor and a closed folder are different layouts.
            state.menu.cursor = 2
            local under: any = nil
            for _, hit in ipairs(chrome_pixels.paint(state, 10, 20).hits.menu) do
                if hit.cursor then under = hit end
            end
            test.eq(under and under.slot, 2, "a moved cursor lays the menu out anew")
            state.menu.open = {}
            local panels = 0
            for _, item in ipairs(chrome_pixels.paint(state, 10, 20).placements) do
                if tostring(item.id):find("menu:", 1, true) == 1 then panels = panels + 1 end
            end
            test.eq(panels, 1, "a closed folder is one panel: the kept layout is not reused")
            chrome_pixels.fonts = nil
        end)

        test.it("no piece of a window lies under the menu, and a change of the window does not touch the menu", function()
            load_fonts()
            local state: any = scene()
            local first = chrome_pixels.paint(state, 10, 20)
            local panels = menus_of(first)
            test.is_true(#panels >= 2, "the scene opens a cascade")
            test.eq(#below_menu(first), 0, table.concat(below_menu(first), "; "))
            local cropped = false
            for _, item in ipairs(first.placements) do
                if tostring(item.id):match("^win:sdk:sdk:row:%d+:crop:") then cropped = true end
            end
            test.is_true(cropped, "the scene must cover the window's pixel content with the menu")
            for _, panel in ipairs(panels) do
                test.is_nil(tostring(panel.id):find(":crop:", 1, true), "the menu panel is whole: " .. panel.id)
            end
            local kept: any = {}
            for _, panel in ipairs(panels) do kept[panel.id] = {raster = panel.raster, version = panel.raster:version()} end
            -- The client is a placement per row (`win:sdk:sdk:row:N`); the rows
            -- under the menu come as their crops.
            local rows_before: any = {}
            for _, item in ipairs(first.placements) do
                if tostring(item.id):find("win:sdk:sdk:row:", 1, true) == 1 then rows_before[item.id] = item.raster:version() end
            end

            -- The second frame: the window changed (a tick), the menu did not.
            state.windows[2].state_revision = 2
            state.windows[2].content_state = {sdk = 1, revision = 2, ui = {kind = "label", text = "tick 2"}}
            local second = chrome_pixels.paint(state, 10, 20)
            test.eq(#below_menu(second), 0, table.concat(below_menu(second), "; "))
            for _, panel in ipairs(menus_of(second)) do
                test.eq(panel.raster, kept[panel.id].raster, "the panel raster is the same: " .. panel.id)
                test.eq(panel.raster:version(), kept[panel.id].version, "the panel is not repainted: " .. panel.id)
            end
            local moved = false
            for _, item in ipairs(second.placements) do
                local was = rows_before[item.id]
                if was ~= nil and item.raster:version() ~= was then moved = true end
            end
            test.is_true(moved, "the window's changed rows are repainted, crops following their rows")

            -- The menu is closed: no crops, the window's rows came back whole.
            state.menu = nil
            local closed = chrome_pixels.paint(state, 10, 20)
            test.not_nil(by_id(closed, "win:sdk:sdk:row:1"), "the window content is whole rows again")
            for _, item in ipairs(closed.placements) do
                test.is_nil(tostring(item.id):match("^win:sdk:sdk:row:%d+:crop:"), "a crop outlived the menu: " .. item.id)
            end
            chrome_pixels.fonts = nil
        end)

        test.it("an icon's context menu is the top layer too", function()
            load_fonts()
            local state: any = scene()
            state.menu = {anchor = {x = 12, y = 10}, cursor = 1, open = {}, items = {
                {label = "Open", bold = true, entry = "app:x", title = "X"},
                {label = "Properties", entry = "app:p", separator_before = true},
            }}
            local painted = chrome_pixels.paint(state, 10, 20)
            test.eq(#menus_of(painted), 1)
            test.eq(#below_menu(painted), 0, table.concat(below_menu(painted), "; "))
            chrome_pixels.fonts = nil
        end)

        test.it("the base's pixels.frame: under an open menu the canvas is empty, after closing it is content again", function()
            load_fonts()
            local state: any = scene()
            state.windows = {}
            local function filled(): any
                local canvas = tty.canvas(80, 24)
                for row = 1, 24 do canvas:put(1, row, string.rep("X", 80), 80) end
                return canvas
            end
            local opened = chrome_pixels.paint(state, 10, 20)
            local panel = menus_of(opened)[1]
            local canvas = filled()
            desktop_pixels.frame(canvas, opened)
            test.eq(visible(canvas:rows()[panel.y])[panel.x], " ", "the cells under the menu are erased — nothing shows through")
            state.menu = nil
            local after = filled()
            desktop_pixels.frame(after, chrome_pixels.paint(state, 10, 20))
            test.eq(visible(after:rows()[panel.y])[panel.x], "X", "the menu is gone — the cells are given back to the content")
            chrome_pixels.fonts = nil
        end)

        test.it("in cells, under the menu is the menu, not the window", function()
            local canvas = tty.canvas(60, 20)
            local body = {}
            for index = 1, 17 do body[index] = string.rep("X", 58) end
            chrome.window(canvas, {x = 1, y = 1, w = 60, h = 19, title = "Under the menu", rows = body}, false)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Calculator"},
                {entry = "app:notepad", title = "Notepad"},
            }, nil, {})
            test.is_true(#hits > 0)
            local rows = canvas:rows()
            for _, hit in ipairs(hits) do
                local line = visible(rows[hit.row] or "")
                for col = hit.from, hit.to do
                    test.is_true(line[col] ~= "X", string.format("the window shows through at %d,%d", col, hit.row))
                end
            end
        end)
    end)

    -- ─── the extracted libraries, directly ─────────────────────────────────
    -- chrome.menu_layout and the pixel theme's cropping moved into their own
    -- libraries (review, 2026-09-11). The theme cases above are the contract
    -- that behaviour did not change; these pin the libraries themselves.
    test.describe("menu_layout library", function()
        test.it("lays a cascade out in compact metrics: panels side by side, a submenu level with its folder", function()
            local items = {
                {entry = "app:a", title = "Alpha", group = {"Programs"}, order = 10},
                {entry = "app:b", title = "Beta", group = {"Programs"}, order = 20},
                {entry = "app:c", title = "Control", group = {"Settings"}, order = 30},
                {entry = "app:q", title = "Shut Down", action = "quit", order = 90},
            }
            local shown = menu_layout.layout(90, 24, items, nil, {"Programs"}, 1,
                {compact = true, bottom = 2, root_rows = 2, item_rows = 1, banner = ""})
            test.eq(#shown.panels, 2, "the root and the open Programs folder")
            local root, sub = shown.panels[1], shown.panels[2]
            test.eq(root.x, 1)
            test.eq(root.y + root.h - 1, 22, "the root stands on the taskbar: 24 rows minus 2")
            test.eq(root.h, #root.lines * 2, "compact: no frame rows, and a root row is two cells tall")
            test.eq(sub.x, root.x + root.w, "the submenu stands right of the root")
            local folder_row = nil
            for _, line in ipairs(root.lines) do
                if line.kind == "group" and line.label == "Programs" then folder_row = line.row end
            end
            test.not_nil(folder_row)
            test.eq(sub.y, folder_row, "compact: the submenu's first row is level with its folder")
            test.eq(sub.h, #sub.lines)
            local hit = nil
            for _, spot in ipairs(shown.hits) do
                if spot.level == 2 and spot.slot == 1 then hit = spot end
            end
            test.not_nil(hit)
            test.eq(hit.from, sub.x, "compact: the hit spans the whole panel, the frame is pixels")
            test.eq(hit.to, sub.x + sub.w - 1)
            test.is_true(hit.cursor == true, "cursor 1 marks the first row of the deepest panel")
        end)

        test.it("takes the banner as a parameter and writes it bottom to top", function()
            local items = {
                {entry = "app:a", title = "A long program name", order = 1},
                {entry = "app:b", title = "Another long name", order = 2},
                {entry = "app:c", title = "The third long name", order = 3},
            }
            local shown = menu_layout.layout(90, 24, items, nil, {}, 1, {banner = "xyz"})
            local root = shown.panels[1]
            test.eq(root.banner, 2, "the panel is wide enough for the vertical caption")
            local last = #root.lines
            test.eq(root.lines[last].banner_letter, "X", "the caption reads bottom to top, in capitals")
            test.eq(root.lines[last - 1].banner_letter, "Y")
            test.eq(root.lines[last - 2].banner_letter, "Z")
            local plain = menu_layout.layout(90, 24, items, nil, {}, 1, {})
            test.eq(plain.panels[1].lines[last].banner_letter, " ", "no banner given, no letters")
        end)

        test.it("puts a context menu at the anchor and keeps it on the screen", function()
            local items = {
                {entry = "app:x", label = "Open", bold = true},
                {entry = "app:y", label = "Properties", separator_before = true},
            }
            local edge = menu_layout.layout(90, 24, items, nil, {}, 2, {anchor = {x = 88, y = 23}})
            local box = edge.panels[1]
            test.is_true(box.context == true)
            test.is_true(box.x + box.w - 1 <= 90, "at the right edge the panel shifts left")
            test.is_true(box.y + box.h - 1 <= 23, "and up, above the taskbar row")
            test.eq(box.banner, 0, "a context menu has no banner")
            test.eq(#edge.hits, 2)
            test.is_true(edge.hits[2].cursor == true)
            local roomy = menu_layout.layout(90, 24, items, nil, {}, 1, {anchor = {x = 10, y = 5}})
            test.eq(roomy.panels[1].x, 10)
            test.eq(roomy.panels[1].y, 5, "with room, exactly at the anchor")
        end)
    end)

    test.describe("placements library", function()
        local function rect(x, y, cols, rows) return {x = x, y = y, cols = cols, rows = rows} end

        test.it("subtract returns the very rectangle when the cover misses it", function()
            local r = rect(1, 1, 10, 5)
            local apart = placements.subtract(r, {x = 20, y = 1, w = 5, h = 5})
            test.eq(#apart, 1)
            test.is_true(apart[1] == r, "the same table, not a copy: identity says 'shown whole'")
            local touching = placements.subtract(r, {x = 11, y = 1, w = 5, h = 5})
            test.is_true(#touching == 1 and touching[1] == r, "a cover touching the edge does not overlap")
        end)

        test.it("subtract cuts the four overlap cases into what is left", function()
            local r = rect(1, 1, 10, 6)
            local top = placements.subtract(r, {x = 1, y = 1, w = 10, h = 2})
            test.eq(#top, 1)
            test.eq(top[1].y, 3)
            test.eq(top[1].rows, 4)
            test.eq(top[1].cols, 10)
            local bottom = placements.subtract(r, {x = 1, y = 5, w = 10, h = 5})
            test.eq(#bottom, 1)
            test.eq(bottom[1].y, 1)
            test.eq(bottom[1].rows, 4)
            local left = placements.subtract(r, {x = 1, y = 1, w = 3, h = 6})
            test.eq(#left, 1)
            test.eq(left[1].x, 4)
            test.eq(left[1].cols, 7)
            local right = placements.subtract(r, {x = 8, y = 1, w = 5, h = 6})
            test.eq(#right, 1)
            test.eq(right[1].x, 1)
            test.eq(right[1].cols, 7)
            local hole = placements.subtract(r, {x = 4, y = 3, w = 3, h = 2})
            test.eq(#hole, 4, "a hole in the middle leaves four pieces")
            local area = 0
            for _, piece in ipairs(hole) do area = area + piece.cols * piece.rows end
            test.eq(area, 10 * 6 - 3 * 2, "the pieces cover exactly what the hole did not")
        end)

        test.it("visible cuts a picture by the windows above its layer and by the menu, never the menu", function()
            local windows = {
                {id = "w1", x = 1, y = 1, w = 20, h = 10},
                {id = "w2", x = 11, y = 1, w = 20, h = 10},
                {id = "w3", x = 1, y = 1, w = 40, h = 20, minimized = true},
            }
            local low = {id = "low", x = 1, y = 1, cols = 20, rows = 10, layer = 1}
            local high = {id = "high", x = 11, y = 1, cols = 20, rows = 10, layer = 2}
            local menu = {id = "menu:1", x = 1, y = 5, cols = 8, rows = 4, top = true}
            local shown = placements.visible({low, high, menu}, windows, {{x = 1, y = 5, w = 8, h = 4}})
            local by: any = {low = {}, high = {}, ["menu:1"] = {}}
            for _, entry in ipairs(shown) do
                local list: any = by[entry.source.id]
                list[#list + 1] = entry
            end
            test.eq(#by.high, 1)
            test.is_nil(by.high[1].piece, "nothing above layer 2 but a minimized window: shown whole")
            test.eq(#by["menu:1"], 1)
            test.is_nil(by["menu:1"][1].piece, "the menu is the top layer and is never cut")
            test.eq(#by.low, 3, "layer 1 loses what window 2 covers, then what the menu covers")
            for _, entry in ipairs(by.low) do
                local piece: any = entry.piece
                test.not_nil(piece)
                test.is_true(piece.x + piece.cols - 1 <= 10, "nothing of window 2's area is left")
                local under_menu = piece.x <= 8 and piece.x + piece.cols - 1 >= 1
                    and piece.y <= 8 and piece.y + piece.rows - 1 >= 5
                test.is_true(not under_menu, "nothing under the menu is left")
            end
        end)

        test.it("names a crop after its source and offset, and keys it by the source's version", function()
            local source = {id = "win", x = 3, y = 2, cols = 10, rows = 4,
                raster = {version = function() return 7 end}}
            test.eq(placements.crop_id(source, {x = 5, y = 3, cols = 4, rows = 2}), "win:crop:2:1:4:2")
            test.eq(placements.crop_key(source), "10:4:7")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
