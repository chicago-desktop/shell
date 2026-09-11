-- Кнопки заголовка окна.
--
-- Проверяется одно правило и его следствия: НАРИСОВАНО и НАЖИМАЕТСЯ обязано
-- быть одним и тем же. Разъехавшись, они дают кнопку на ячейку левее, чем
-- выглядит, — или, хуже, кнопку, которая нарисована и молча не работает.
-- Ни то, ни другое не выглядит ошибкой: выглядит, что «клик не сработал».
local test = require("test")
local catalog = require("catalog")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local tty = require("tty")
local pixels = require("pixels")
local fs = require("fs")
local gfx = require("gfx")
local desktop_pixels = require("desktop_pixels")

-- Что реально нарисовано в строке заголовка. Стиль вырезается: нас
-- интересуют символы и их места, а цвет проверяет пробник.
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

-- Какие кнопки НАРИСОВАНЫ в заголовке окна такого типа.
local function drawn_buttons(window_type)
    local canvas = tty.canvas(40, 8)
    local window = {x = 1, y = 1, w = 40, h = 8, title = "Окно",
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
                    -- Слитная пара, отдельная «закрыть» в двух синих пикселях от рамки.
                    local bw = caption - 2
                    test.eq(buttons[1].rect.w, bw)
                    test.eq(buttons[2].rect.w, bw)
                    test.eq(buttons[2].rect.x, buttons[1].rect.x + bw, "minimize and maximize touch")
                    test.is_true(buttons[3].rect.w >= bw - 2 and buttons[3].rect.w <= bw)
                    -- Просвет до «закрыть» — два пикселя плюс то, что пара не
                    -- добрала до целых ячеек (12 px в двух ячейках по 10 — восемь).
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
            test.eq(clipped[2]:sub(-3), "...")
        end)
    end)
    test.describe("Start footer and taskbar clock", function()
        test.it("keeps shutdown with its icon on a short screen", function()
            local programs = {}
            for index = 1, 30 do
                programs[index] = {entry = "app:p" .. index, title = "Программа " .. index,
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
        test.it("пиксельные кнопки имеют отдельные ячейки и выполняют объявленное действие", function()
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
                            test.is_nil(occupied[x], "две кнопки делят одну ячейку")
                            occupied[x] = true
                            test.eq(chrome_pixels.title_button_at(window, x, button.row), button.id)
                        end
                    end
                    test.is_nil(chrome_pixels.title_button_at(window, window.x + 2, window.y))
                end
            end
            chrome_pixels.use_cell_size(10, 20)
        end)

        test.it("пиксельная рамка и значок за передним окном обрезаются и не перерисовываются без изменений", function()
            local state = {width = 80, height = 24, bottom = 23, clock = "12:00", items = {
                {id = "icon", x = 2, y = 4, kind = "folder", title = "Folder"},
            }, windows = {
                {id = "back", x = 4, y = 3, w = 32, h = 14, title = "Сзади"},
                {id = "front", x = 20, y = 4, w = 25, h = 12, title = "Спереди"},
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
                        "нижнее размещение накрыло переднее окно: " .. item.id)
                end
            end
            test.is_true(cropped, "сцена должна проверить частичное перекрытие")
            local again = chrome_pixels.paint(state, 10, 20)
            test.eq(#again.placements, #first.placements)
            for _, item in ipairs(again.placements) do
                test.eq(item.raster, stored[item.id].raster)
                test.eq(item.raster:version(), stored[item.id].version)
            end
        end)

        test.it("панель и высокие пункты меню нажимаются по всей нарисованной высоте", function()
            for _, cell in ipairs({{10, 20}, {12, 23}, {8, 16}}) do
                chrome_pixels.use_cell_size(cell[1], cell[2])
                local layout = chrome_pixels.layout(100, 30)
                local state = {width = 100, height = 30, bottom = 30 - layout.bottom,
                    clock = "12:00", windows = {}, items = {},
                    menu = {items = {{entry = "app:test", title = "Программа", group = {"Programs"}}}, cursor = 1}}
                local painted = chrome_pixels.paint(state, cell[1], cell[2])
                local bar, menu = nil, nil
                for _, image in ipairs(painted.placements) do
                    if image.id == "bars" then bar = image end
                    if image.id == "menu:1" then menu = image end
                end
                test.not_nil(bar)
                test.not_nil(menu)
                test.is_true(bar.rows * cell[2] >= 28, "панель не должна сжиматься в тонкую полоску")
                test.eq(bar.y, state.bottom + 1)
                test.eq(bar.y + bar.rows - 1, state.height)
                test.eq(menu.y + menu.rows, bar.y, "меню стоит непосредственно над панелью")
                local start = painted.hits.bars[1]
                test.eq(start.row, bar.y)
                test.eq(start.bottom_row, state.height)
                test.eq(#painted.hits.menu, 1, "один пункт остаётся одним шагом клавиатуры")
                local choice = painted.hits.menu[1]
                test.eq(choice.row, menu.y)
                test.eq(choice.bottom_row, menu.y + menu.rows - 1)
                state.menu.open = {"Programs"}
                local expanded = chrome_pixels.paint(state, cell[1], cell[2])
                test.eq(#expanded.hits.menu, 2, "папка и программа — два логических попадания")
                local child = expanded.hits.menu[2]
                test.is_true((child.bottom_row - child.row + 1) * cell[2] >= 24,
                    "подменю сохраняет отступы, а не возвращается к тесной строке")

            end
        end)

        test.it("закрытый и открытый Пуск дают разные кадры панели задач", function()
            local state = {width = 80, height = 24, bottom = 23, clock = "12:00", windows = {}, items = {}}
            local first = chrome_pixels.paint(state, 10, 20)
            local bar = first.placements[1].raster
            local before = bar:version()
            state.menu = {items = {{entry = "app:test", title = "Программа"}}, cursor = 1}
            local after = chrome_pixels.paint(state, 10, 20)
            test.is_true(bar:version() > before, "Пуск должен стать нажатым")
            test.eq(after.hits.bars[1].action, "menu")
        end)

        test.it("даёт каждому типу окна свой состав кнопок", function()
            -- Три типа объявлены основой; тема выбирает по ним состав, а не
            -- выводит его из чего-то ещё.
            test.eq(#chrome.buttons_for({window_type = "app"}), 3)
            test.eq(#chrome.buttons_for({window_type = "dialog"}), 2,
                "диалог не сворачивают и не разворачивают")
            test.eq(#chrome.buttons_for({window_type = "tool"}), 1,
                "служебное окно только закрывают")
        end)

        test.it("считает неизвестный и неназванный тип обычным окном", function()
            -- Опечатка в объявлении не повод не нарисовать окно, а решает,
            -- что делать с неизвестным типом, основа — тема лишь не спорит.
            test.eq(#chrome.buttons_for({}), 3)
            test.eq(#chrome.buttons_for({window_type = "popup"}), 3)
            test.eq(#chrome.buttons_for(nil), 3)
        end)

        test.it("нажимается ровно то, что нарисовано", function()
            -- Главное здесь. У диалога рисовалось три кнопки, а нажималось
            -- две: рисование брало свой набор, попадание — свой.
            for _, window_type in ipairs({"app", "dialog", "tool"}) do
                local found, set, window = drawn_buttons(window_type)

                test.eq(#found and true, true)
                for _, button in ipairs(set) do
                    local at = found[button.glyph]
                    test.not_nil(at, window_type .. ": кнопка " .. button.id .. " не нарисована")
                    test.eq(chrome.title_button_at(window, at, window.y + 1), button.id,
                        window_type .. ": под кнопкой " .. button.id .. " попадание другое")
                end
            end
        end)

        test.it("не рисует диалогу кнопок, которых у него нет", function()
            -- Нарисованная кнопка, которая молча не работает, хуже её
            -- отсутствия: первое, что о ней спросят, — почему она не
            -- работает.
            local found = drawn_buttons("dialog")
            for _, button in ipairs(chrome.BUTTONS) do
                if button.id == "minimize" or button.id == "maximize" then
                    test.is_nil(found[button.glyph],
                        "у диалога нет кнопки " .. button.id)
                end
            end
        end)

        test.it("не рисует в меню цифровых сокращений", function()
            -- Их не было в Windows 95, и человек, открывающий программы
            -- мышью, читает колонку цифр как вопрос «а зачем они». Завелись
            -- они не от замысла, а от инструмента: пробник не умел мышь.
            local canvas = tty.canvas(60, 20)
            chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Калькулятор", icon = "▣"},
                {entry = "app:notepad", title = "Блокнот"},
                {entry = "app:paint", title = "Редактор"},
            }, nil, {})

            local rows = canvas:rows()
            for index = 1, 20 do
                local line = table.concat(visible(rows[index] or ""))
                test.is_true(line:find("%d") == nil or line:find("21:") ~= nil,
                    "строка " .. index .. " меню несёт цифру: " .. line)
            end
        end)

        test.it("подсвечивает ту строку меню, которую откроет Enter", function()
            -- Композитор не считает заново, что сейчас выбрано, а читает то,
            -- что НАРИСОВАНО: второй счёт разъехался бы с первым, и Enter
            -- открывал бы не ту строку, которая подсвечена.
            local canvas = tty.canvas(60, 20)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Калькулятор", icon = "▣"},
                {entry = "app:notepad", title = "Блокнот"},
                {entry = "app:ping", title = "Пинг", group = "Служебные"},
            }, nil, {}, 2)

            local under = nil
            local marked = 0
            for _, hit in ipairs(hits) do
                if hit.cursor then marked = marked + 1; under = hit end
            end
            test.eq(marked, 1, "подсвечена ровно одна строка")
            test.eq(under.slot, 2, "вторая выбираемая строка панели")
            test.eq(under.level, 1)
        end)

        test.it("не подсвечивает ничего, когда курсора нет", function()
            -- Мышь курсора не заводит: подсвеченная строка при работе мышью
            -- обещала бы, что Enter что-то откроет, а его никто не нажимал.
            local canvas = tty.canvas(60, 20)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Калькулятор"},
            }, nil, {})
            for _, hit in ipairs(hits) do
                test.is_nil(hit.cursor)
            end
        end)

        test.it("считает выбираемые строки, а не все подряд", function()
            -- Подсказки и обрезка «…ещё N» тоже занимают строки, а выбирать
            -- их нельзя: считай их — и курсор вставал бы на строку, которую
            -- нечем открыть.
            local many = {}
            for index = 1, 40 do
                many[index] = {entry = "app:p" .. index, title = "Программа " .. index}
            end
            local canvas = tty.canvas(60, 12)
            local hits = chrome.menu(canvas, 60, 12, many, nil, {}, 1)

            local slots = {}
            for _, hit in ipairs(hits) do slots[#slots + 1] = hit.slot end
            for index, slot in ipairs(slots) do
                test.eq(slot, index, "номера выбираемых строк идут подряд с единицы")
            end
        end)

        test.it("уступает место имени, когда кнопки не помещаются", function()
            -- Заголовок без имени не говорит, какое это окно, а закрыть его
            -- можно и с панели задач.
            local narrow = {x = 1, y = 1, w = 10, h = 6, title = "Окно",
                            window_type = "app", rows = {}}
            test.is_nil(chrome.title_button_at(narrow, 8, 2),
                "кнопки не нарисованы — значит и попадания нет")
        end)

        test.it("заливает стол и лицо панели задач в обоих режимах", function()
            -- ФУНКЦИЯ, КОТОРУЮ НЕ ЗОВУТ, ЗЕЛЁНАЯ В ЛЮБОМ НАБОРЕ.
            --
            -- `chrome_pixels.fill` была написана и не вызывалась ничем:
            -- композитор в пиксельном режиме её пропускал. В первый же живой
            -- запуск она упала на `widgets.styles.desktop`, которого не
            -- существовало, — стиль стола лежал во второй, почти такой же
            -- таблице у темы. Две таблицы одного и того же расходятся ровно
            -- на тех ключах, которые редко нужны обеим.
            --
            -- Поэтому здесь зовутся ОБЕ заливки: их не должно быть возможно
            -- сломать по отдельности.
            for _, theme in ipairs({chrome, chrome_pixels}) do
                local canvas = tty.canvas(40, 10)
                local hits = (theme :: any).fill(canvas, 40, 10, {top = 1, bottom = 9, items = {}})
                test.not_nil(hits, "заливка обязана вернуть разметку, пусть и пустую")

                local rows = canvas:rows()
                test.eq(#rows, 10)
                test.is_true(#tostring(rows[1]) > 0, "стол обязан быть закрашен")
                test.is_true(#tostring(rows[10]) > 0, "лицо панели задач обязано быть закрашено")
            end
        end)

        test.it("держит стили в одной таблице, а не в двух похожих", function()
            -- Ключ, живущий у одной темы и отсутствующий у другой, — это
            -- отказ на живом стенде, а не расхождение вида. Проверяется
            -- тождеством таблицы: две копии рано или поздно разойдутся, одна
            -- разойтись не может.
            local widgets_styles = require("widgets").styles
            for _, name in ipairs({"desktop", "desktop_text", "desktop_broken",
                                   "title", "title_idle", "banner", "face", "select"}) do
                test.not_nil(widgets_styles[name],
                    "стиль " .. name .. " обязан быть в общей таблице")
            end
        end)

        test.it("строки корня идут по order, программа может стоять над папкой, separator_after отделяет следующую", function()
            -- Как в Windows: «Мой компьютер» сверху, под ним черта, потом
            -- папки. Папка стоит там, где её самая ранняя программа.
            local items = {
                {entry = "app:calc", title = "Калькулятор", group = {"Programs"}, order = 20},
                {entry = "app:reg", title = "Registry", group = {"Settings"}, order = 110},
                {entry = "app:mycomp", title = "My Computer", group = {}, order = 5, separator_after = true},
                {entry = "app:run", title = "Выполнить…", group = {}, order = 900},
            }
            local shown = chrome.menu_layout(90, 24, items, nil, {})
            local lines = shown.panels[1].lines
            test.eq(lines[1].label, "My Computer")
            test.eq(lines[2].label, "Programs")
            test.eq(lines[3].label, "Settings")
            test.eq(lines[4].label, "Выполнить…")
            test.is_true(lines[2].separator_before == true, "черта под «Моим компьютером» — у следующей строки")
            test.is_nil(lines[1].separator_before)
            test.is_nil(lines[3].separator_before)
        end)

        test.it("вошедший пользователь — первой строкой корня, со значком, без попадания и без slot", function()
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
            test.is_true(lines[1].bold == true, "имя набрано жирным, как заголовок")
            test.is_true(not lines[1].dim, "имя не приглушено")
            test.is_true(lines[2].separator_before == true, "черта под именем — у следующей строки")
            test.eq(lines[2].label, "My Computer")
            -- Строка не выбирается: попаданий на её ряду нет, а курсор 1 —
            -- это по-прежнему первая ПРОГРАММА.
            for _, hit in ipairs(shown.hits) do
                test.is_true(hit.row ~= lines[1].row, "на строке пользователя не должно быть попадания")
            end
            test.eq(shown.hits[1].row, lines[2].row)
            test.is_true(shown.hits[1].cursor == true)
            test.eq(shown.hits[1].slot, 1)
            -- В подменю имени нет.
            local opened = chrome.menu_layout(90, 24, items, nil, {"Programs"}, 1, {user = {name = "butschster"}})
            test.eq(opened.panels[2].lines[1].kind, "item")
            -- Без пользователя строки нет вовсе; пустое имя — то же самое.
            test.eq(chrome.menu_layout(90, 24, items, nil, {}).panels[1].lines[1].label, "My Computer")
            test.eq(chrome.menu_layout(90, 24, items, nil, {}, 1, {user = {name = ""}}).panels[1].lines[1].label, "My Computer")
            -- Контекстное меню у якоря имени не показывает.
            local context = chrome.menu_layout(90, 24, {{entry = "app:x", label = "Open"}}, nil, {}, 1,
                {anchor = {x = 5, y = 5}, user = {name = "butschster"}})
            test.eq(context.panels[1].lines[1].label, "Open")
        end)

        test.it("chrome.use_user поднимает имя в общую сессию и снимает его", function()
            local items = {{entry = "app:run", title = "Run…", group = {}, order = 900}}
            chrome.use_user({id = "u1", name = "butschster"})
            test.eq(chrome.session.user.name, "butschster")
            test.eq(chrome.session.user.id, "u1")
            -- Обе темы передают в раскладку ровно эту таблицу.
            local shown = chrome.menu_layout(90, 24, items, nil, {}, 1, {user = chrome.session.user})
            test.eq(shown.panels[1].lines[1].kind, "user")
            chrome.use_user(nil)
            test.is_nil(chrome.session.user)
            chrome.use_user({name = 42})
            test.is_nil(chrome.session.user)
            chrome.use_user({name = ""})
            test.is_nil(chrome.session.user)
        end)

        test.it("в пикселях мерка получает уровень и вид, а попадания покрывают панель целиком", function()
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
            test.is_true(levels[1] and levels[2], "мерка видела корень и подменю")
            test.is_true(kinds.group and kinds.item, "мерка видела папку и программу")
            for _, hit in ipairs(shown.hits) do
                local panel = shown.panels[hit.level]
                test.eq(hit.from, panel.x + panel.banner, "попадание от первой ячейки списка")
                test.eq(hit.to, panel.x + panel.w - 1, "попадание до последней ячейки панели")
            end
            -- В ячейках крайние ячейки — рамка, и они не попадание.
            local cells_mode = chrome.menu_layout(90, 24, items, nil, {})
            local first = cells_mode.hits[1]
            test.eq(first.from, cells_mode.panels[1].x + 1 + cells_mode.panels[1].banner)
            test.eq(first.to, cells_mode.panels[1].x + cells_mode.panels[1].w - 2)
            -- Контекстное меню меряется уровнем 0.
            seen = {}
            chrome.menu_layout(90, 24, {{entry = "app:x", label = "Open"}}, nil, {}, 1,
                {anchor = {x = 5, y = 5}, compact = true, measure = measure})
            test.eq(seen[1].level, 0)
            test.eq(seen[1].kind, "context")
        end)

        test.it("контекстное меню значка — одна панель у якоря, без папок и банера, внутри экрана", function()
            local items = {
                {label = "Открыть", bold = true, entry = "app:mycomp", title = "My Computer"},
                {label = "Properties", entry = "app:sysprops", separator_before = true},
            }
            local shown = chrome.menu_layout(90, 24, items, nil, {}, 2, {anchor = {x = 10, y = 5}})
            test.eq(#shown.panels, 1)
            local panel = shown.panels[1]
            test.eq(panel.x, 10)
            test.eq(panel.y, 5)
            test.eq(panel.banner, 0, "у контекстного меню нет банера")
            test.is_true(panel.context == true)
            test.eq(#panel.lines, 2)
            test.eq(panel.lines[1].label, "Открыть", "подпись — label, а не title окна")
            test.is_true(panel.lines[1].bold == true, "действие по умолчанию жирное")
            test.is_true(panel.lines[2].separator_before == true)
            test.is_true(panel.lines[2].selected == true, "курсор 2 выделяет вторую строку")
            test.eq(#shown.hits, 2)
            test.eq(shown.hits[2].index, 2)
            test.eq(shown.hits[2].slot, 2)
            test.eq(shown.hits[2].cursor, true)
            test.is_true(shown.hits[1].from > panel.x and shown.hits[1].to < panel.x + panel.w)

            -- У края экрана панель сдвигается внутрь, а не режется.
            local edge = chrome.menu_layout(90, 24, items, nil, {}, 1, {anchor = {x = 88, y = 23}})
            local box = edge.panels[1]
            test.is_true(box.x + box.w - 1 <= 90, "панель не выходит за правый край")
            test.is_true(box.y + box.h - 1 <= 23, "панель не ложится на панель задач")

            -- Пиксельная тема: одна строка на пункт и якорь — из того же меню.
            local flat = chrome.menu_layout(90, 24, items, nil, {}, 1,
                {anchor = {x = 10, y = 5}, compact = true, context_rows = 1, bottom = 2})
            test.eq(flat.panels[1].h, 2, "в пикселях по строке на пункт и без рамки")
            test.eq(chrome.menu_layout(90, 24, {}, nil, {}, 1, {anchor = {x = 1, y = 1}}).panels[1], nil,
                "пустой список — панели нет")
        end)

        test.it("доводит группу от записи реестра до папки в меню", function()
            -- ВЕСЬ ЭТОТ ПУТЬ БЫЛ ЗЕЛЁНЫМ И НИ РАЗУ НЕ ПРОЙДЕННЫМ. Каталог
            -- разбирал `meta.group` в ТАБЛИЦУ сегментов, а тема ждала СТРОКУ
            -- и разбирала второй раз — то есть путь выходил пустым, папка не
            -- заводилась, программа ложилась на верхний уровень. Ни отказа, ни
            -- следа: программа видна, просто не там, где просили.
            --
            -- Проверяется от края до края, через обе чистые функции: реестр
            -- для этого не нужен, а по отдельности каждая половина была права.
            local built = catalog.build({
                {id = "app:calc", meta = {type = "tui_desktop.window",
                                          title = "Калькулятор", group = "Стандартные"}},
                {id = "app:bash", meta = {type = "tui_desktop.window",
                                          title = "Сеанс MS-DOS", group = ""}},
            })

            test.eq(#built.tree.folders, 1, "папка обязана появиться в дереве каталога")
            test.eq(built.tree.folders[1].title, "Стандартные")
            test.eq(#built.tree.programs, 1, "на верхнем уровне остаётся только та, что попросила корень")

            -- А теперь то же самое глазами темы: она получает пункты меню в
            -- том виде, в каком их кладёт оболочка.
            local items = {}
            for _, program in ipairs(catalog.listed(built.programs)) do
                items[#items + 1] = {
                    entry = program.entry, title = program.title,
                    group = program.group, order = program.order, icon = program.icon,
                }
            end

            local flat = chrome.menu_layout(90, 24, items, nil, {})
            test.eq(#flat.panels, 1, "без раскрытия панель одна")

            local folders, programs = 0, 0
            for _, line in ipairs(flat.panels[1].lines) do
                if line.kind == "group" then folders = folders + 1 end
                if line.kind == "item" then programs = programs + 1 end
            end
            test.eq(folders, 1, "тема обязана показать папку, а не разложить всё плоско")
            test.eq(programs, 1)

            -- И раскрытие: только тогда у стрелки появляется, с чем работать.
            local opened = chrome.menu_layout(90, 24, items, nil, {"Стандартные"})
            test.eq(#opened.panels, 2, "раскрытая папка обязана дать вторую панель")

            local inside = 0
            for _, line in ipairs(opened.panels[2].lines) do
                if line.kind == "item" then inside = inside + 1 end
            end
            test.eq(inside, 1, "внутри папки лежит то, что в неё положили")
        end)

        test.it("держит глубину меню одним числом, а не двумя", function()
            -- Обрезка по глубине жила ДВАЖДЫ: `catalog.MAX_DEPTH` и своя
            -- константа в теме. Два числа одного смысла однажды поменяют
            -- поодиночке — это та же беда, что две таблицы стилей, только про
            -- число.
            --
            -- Теперь глубину ограничивает тот, кто путь разбирает, а каскад
            -- останавливает ширина экрана. Проверяется тем, что тема
            -- показывает РОВНО столько уровней, сколько дал каталог.
            local built = catalog.build({
                {id = "app:deep", meta = {type = "tui_desktop.window",
                                          title = "Глубоко", group = "А/Б/В/Г/Д"}},
            })
            local program = catalog.find(built.programs, "app:deep")
            test.eq(#program.group, catalog.MAX_DEPTH,
                "каталог обязан обрезать путь сам, и обрезать до своего числа")

            local items = {{entry = program.entry, title = program.title,
                            group = program.group, order = program.order}}
            local opened = chrome.menu_layout(200, 24, items, nil, program.group)
            test.eq(#opened.panels, catalog.MAX_DEPTH + 1,
                "тема показывает ровно столько уровней, сколько дал каталог")
        end)
    end)

    -- Отказ раскладки и строка состояния — в пикселях.
    --
    -- Тема в ячейках рисовала обе вещи, пиксельная не читала ни одной:
    -- нечитаемая раскладка выглядела пустым столом без причины, а сообщения
    -- композитора — и его жалобы на негодный кадр самой темы — не видел никто.
    --
    -- Прочитать пиксель у растра нечем, поэтому сравниваются PNG-байты кадров,
    -- различающихся ПОСЛЕДНИМ словом. Одна проверка ловит и «текст не
    -- нарисован», и «текст срезан, а не перенесён»: срез съел бы именно конец,
    -- и оба кадра совпали бы.
    -- One value in two places: the taskbar layout and the desktop icon hit were
    -- computed by each theme on its own. `chrome` computes them now, so a
    -- mutation of the shared rule turns both themes red.
    test.describe("one taskbar and desktop layout for both themes", function()
        local WINDOWS: any = {}
        for index = 1, 5 do WINDOWS[index] = {id = "w" .. index, title = "Window " .. index} end

        local function use_fonts()
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
            {key = "weather", text = "+17°", entry = "app:weather"},
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
            test.is_true(row:find(" idle  +17°  3 new ", 1, true) ~= nil, "cells: the captions in order: " .. row)

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
            chrome_pixels.clock_entry = nil
            chrome_pixels.fonts = nil
            same_tray_plan(pixel_hits, {task_min = 16, task_max = 16, clock = 9, clock_gap = 1}, "pixels")
            test.is_true(with_tray ~= without, "pixels: the tray captions are drawn")
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

        -- The owner's rule (2026-09-11): no text next to Start while no window
        -- is open. With a window, the status line is still where messages such
        -- as "could not open: ..." are shown. The rule lives in the shared
        -- layout, and each theme is checked on its own.
        local STATUS = "could not open: app:gone"

        test.it("cells: the status line shows beside a window and not on an empty taskbar", function()
            local function row(windows: any): string
                local canvas = tty.canvas(80, 24)
                chrome.bars(canvas, 80, 24, {clock = "12:30", windows = windows, status = STATUS})
                local rows: any = canvas:rows()
                return (tostring(rows[24]):gsub("\27%[[%d;:]*m", ""))
            end
            test.is_true(row({WINDOWS[1]}):find(STATUS, 1, true) ~= nil, "the status is shown beside a window")
            test.is_nil(row({}):find("could not open", 1, true), "no windows, no text beside Start")
        end)

        test.it("pixels: the status line shows beside a window and not on an empty taskbar", function()
            local one, status = {WINDOWS[1]}, STATUS
            use_fonts()
            -- Bytes are taken right after each frame: the store paints the next
            -- frame into the same buffer.
            local function bar_png(windows: any, text: any): any
                local painted = chrome_pixels.paint({width = 80, height = 24, bottom = 22, clock = "12:00",
                    windows = windows, items = {}, status = text}, 10, 20)
                for _, image in ipairs(painted.placements) do
                    if image.id == "bars" then return assert(image.raster:encode("png")) end
                end
                return nil
            end
            local shown, bare = bar_png(one, status), bar_png(one, nil)
            local empty_with, empty_without = bar_png({}, status), bar_png({}, nil)
            chrome_pixels.fonts = nil
            test.is_true(shown ~= bare, "the status is drawn beside a window")
            test.eq(empty_with, empty_without, "no windows, no text beside Start")
            test.is_nil(chrome.taskbar_layout(80, {}, {start = 11, gap = 1, clock = 9}).status,
                "the layout gives an empty taskbar no status room")
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
        -- Байты снимаются СРАЗУ после кадра: хранилище рисует следующий кадр в
        -- тот же буфер, и растр из прошлого кадра показывает уже новый.
        local function png(painted: any, id)
            local item = find(painted, id)
            test.not_nil(item, "нет размещения " .. id)
            return assert(item.raster:encode("png"))
        end

        test.it("стол называет причину нечитаемой раскладки целиком, переносом, а не срезом", function()
            local face = use_fonts()
            -- Две строки, а не три: на третьей, у предела переноса, другой
            -- шрифт поставил бы многоточие вместо последнего слова, и кейс
            -- покраснел бы не за то.
            local reason = "database is locked: SELECT id, x, y, image FROM butschster_windows_desktop"
                .. " ORDER BY position, table "
            test.is_true(face:measure(reason .. "alpha") > 48 * 10,
                "сцена обязана быть шире таблички, иначе переносить нечего")
            local state: any = {width = 80, height = 24, top = 1, bottom = 22, clock = "12:00",
                items = {{id = "icon", x = 2, y = 4, kind = "folder", title = "Folder"}},
                windows = {{id = "w1", title = "Notepad", x = 30, y = 10, w = 40, h = 10}},
                focused_id = "w1", failure = reason .. "alpha",
                status = "could not open: app:gone — entry not found"}
            local painted = chrome_pixels.paint(state, 10, 20)

            -- Снимок — для глаз, из того же кадра, что проверяется ниже.
            local screen = gfx.raster(80 * 10, 24 * 20)
            screen:fill("#008080")
            for _, item in ipairs(painted.placements) do
                screen:blit(item.raster, (item.x - 1) * 10 + 1, (item.y - 1) * 20 + 1)
            end
            assert(assert(fs.get("app:shots")):writefile("layout-failure.png", assert(screen:encode("png"))))

            local plate = find(painted, "desk:failure")
            test.not_nil(plate, "отказ раскладки обязан быть на столе")
            test.eq(plate.x, 3)
            test.eq(plate.y, 2, "строка под верхом стола, как в ячейках")
            test.eq(plate.cols, 48)
            test.is_true(plate.y + plate.rows - 1 <= 22, "табличка не заходит на панель задач")
            test.is_nil(find(painted, "desk:icon"), "значков непрочитанной раскладки не рисуют")
            local first = assert(plate.raster:encode("png"))
            local version = plate.raster:version()

            local again = find(chrome_pixels.paint(state, 10, 20), "desk:failure")
            test.eq(again.raster, plate.raster, "тот же отказ — тот же растр")
            test.eq(again.raster:version(), version, "тот же отказ не перерисовывается")

            state.failure = reason .. "omega"
            test.is_true(png(chrome_pixels.paint(state, 10, 20), "desk:failure") ~= first,
                "конец причины не нарисован: срез вместо переноса")

            state.failure = nil
            local cleared = chrome_pixels.paint(state, 10, 20)
            test.is_nil(find(cleared, "desk:failure"), "раскладка прочиталась — таблички нет")
            test.not_nil(find(cleared, "desk:icon"))
            chrome_pixels.fonts = nil
        end)

        test.it("панель задач показывает строку состояния между окнами и часами", function()
            use_fonts()
            local state: any = {width = 80, height = 24, bottom = 22, clock = "12:00", items = {},
                windows = {{id = "w1", title = "Notepad", x = 5, y = 3, w = 30, h = 10}}, focused_id = "w1"}
            local bare = png(chrome_pixels.paint(state, 10, 20), "bars")

            state.status = "could not open: app:gone — entry not found"
            local painted = chrome_pixels.paint(state, 10, 20)
            local shown = png(painted, "bars")
            test.is_true(shown ~= bare, "строка состояния не нарисована")
            local version = find(painted, "bars").raster:version()
            test.eq(find(chrome_pixels.paint(state, 10, 20), "bars").raster:version(), version,
                "тот же статус — панель не перерисовывается")

            state.status = "could not open: app:gone — entry missing"
            test.is_true(png(chrome_pixels.paint(state, 10, 20), "bars") ~= shown,
                "другой конец статуса — другой кадр")

            -- Тесно: между кнопкой окна и часами меньше шести ячеек.
            state.width, state.status = 36, nil
            local narrow = chrome_pixels.paint(state, 10, 20)
            local task = narrow.hits.bars[#narrow.hits.bars]
            test.eq(task.id, "w1")
            test.is_true(36 - 8 - (task.to + 1) < 6, "сцена обязана оставить меньше шести ячеек")
            local empty = png(narrow, "bars")
            state.status = "could not open: app:gone"
            test.eq(png(chrome_pixels.paint(state, 10, 20), "bars"), empty, "в тесноте статус не рисуется")
            chrome_pixels.fonts = nil
        end)

        test.it("вид, бросивший ошибку, — текст отказа в окне, а не упавший кадр оболочки", function()
            use_fonts()
            -- `children` не списком: `ui.plan` бросает внутри библиотеки вида.
            local window = {id = "v", x = 5, y = 3, w = 30, h = 10, title = "View", content = "pixels",
                render = "butschster.windows.sdk:render",
                content_state = {sdk = 1, revision = 1, ui = {kind = "column", children = 42}}}
            local ok, painted = pcall(chrome_pixels.paint, {width = 80, height = 24, bottom = 22, clock = "12:00",
                items = {}, windows = {window}, focused_id = "v"}, 10, 20)
            chrome_pixels.fonts = nil
            test.is_true(ok, "кадр оболочки упал: " .. tostring(painted))
            test.not_nil(find(painted, "win:v:notice"), "отказ вида обязан быть текстом на лице окна")
            test.not_nil(find(painted, "win:v:head"), "рамка окна на месте")
        end)
    end)

    -- Меню «Пуск» и контекстное меню — поверх окон ВСЕГДА.
    --
    -- Поверхность рантайма переотправляет только новое, изменившееся или
    -- накрывающее перерисованную строку (surface.go, appendPlacements), а
    -- z-порядка у sixel нет. Открытое меню не меняется; растр окна под ним
    -- уезжает на каждом своём тике и ложится сверху. Поэтому проверяется не
    -- порядок списка, а то, что под меню нет НИ ОДНОГО куска чужого растра — ни
    -- в первом кадре, ни во втором, где окно изменилось, а меню нет.
    test.describe("menu above windows", function()
        local function load_fonts()
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
                        if overlaps(item, panel) then hits[#hits + 1] = item.id .. " под " .. panel.id end
                    end
                end
            end
            return hits
        end
        local function by_id(painted: any, id: string): any
            for _, item in ipairs(painted.placements) do if item.id == id then return item end end
            return nil
        end
        -- Окно в ячейках под меню и окно на SDK с пиксельным содержимым,
        -- верхнее — оно, чтобы его растр резало только меню.
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

        test.it("ни один кусок окна не лежит под меню, и изменение окна меню не трогает", function()
            load_fonts()
            local state: any = scene()
            local first = chrome_pixels.paint(state, 10, 20)
            local panels = menus_of(first)
            test.is_true(#panels >= 2, "сцена открывает каскад")
            test.eq(#below_menu(first), 0, table.concat(below_menu(first), "; "))
            local cropped = false
            for _, item in ipairs(first.placements) do
                if tostring(item.id):find("win:sdk:sdk:crop:", 1, true) == 1 then cropped = true end
            end
            test.is_true(cropped, "сцена обязана накрыть меню пиксельное содержимое окна")
            for _, panel in ipairs(panels) do
                test.is_nil(tostring(panel.id):find(":crop:", 1, true), "панель меню целая: " .. panel.id)
            end
            local kept: any = {}
            for _, panel in ipairs(panels) do kept[panel.id] = {raster = panel.raster, version = panel.raster:version()} end
            local crops: any = {}
            for _, item in ipairs(first.placements) do
                if tostring(item.id):find("win:sdk:sdk:crop:", 1, true) == 1 then crops[item.id] = item.raster:version() end
            end

            -- Второй кадр: окно изменилось (тик), меню — нет.
            state.windows[2].state_revision = 2
            state.windows[2].content_state = {sdk = 1, revision = 2, ui = {kind = "label", text = "tick 2"}}
            local second = chrome_pixels.paint(state, 10, 20)
            test.eq(#below_menu(second), 0, table.concat(below_menu(second), "; "))
            for _, panel in ipairs(menus_of(second)) do
                test.eq(panel.raster, kept[panel.id].raster, "растр панели тот же: " .. panel.id)
                test.eq(panel.raster:version(), kept[panel.id].version, "панель не перерисована: " .. panel.id)
            end
            local moved = false
            for _, item in ipairs(second.placements) do
                local was = crops[item.id]
                if was ~= nil and item.raster:version() ~= was then moved = true end
            end
            test.is_true(moved, "кропы окна ключуются версией его растра и перерисованы")

            -- Меню закрыто: кропов нет, окно вернулось целым с прежним id.
            state.menu = nil
            local closed = chrome_pixels.paint(state, 10, 20)
            test.not_nil(by_id(closed, "win:sdk:sdk"), "содержимое окна — снова одним размещением")
            for _, item in ipairs(closed.placements) do
                test.is_nil(tostring(item.id):find("win:sdk:sdk:crop:", 1, true), "кроп пережил меню: " .. item.id)
            end
            chrome_pixels.fonts = nil
        end)

        test.it("контекстное меню значка — тоже верхний слой", function()
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

        test.it("pixels.frame основы: под открытым меню канва пуста, после закрытия — снова содержимое", function()
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
            test.eq(visible(canvas:rows()[panel.y])[panel.x], " ", "ячейки под меню стёрты — не просвечивают")
            state.menu = nil
            local after = filled()
            desktop_pixels.frame(after, chrome_pixels.paint(state, 10, 20))
            test.eq(visible(after:rows()[panel.y])[panel.x], "X", "меню ушло — ячейки снова отдаются содержимому")
            chrome_pixels.fonts = nil
        end)

        test.it("в ячейках под меню — меню, а не окно", function()
            local canvas = tty.canvas(60, 20)
            local body = {}
            for index = 1, 17 do body[index] = string.rep("X", 58) end
            chrome.window(canvas, {x = 1, y = 1, w = 60, h = 19, title = "Под меню", rows = body}, false)
            local hits = chrome.menu(canvas, 60, 20, {
                {entry = "app:calc", title = "Калькулятор"},
                {entry = "app:notepad", title = "Блокнот"},
            }, nil, {})
            test.is_true(#hits > 0)
            local rows = canvas:rows()
            for _, hit in ipairs(hits) do
                local line = visible(rows[hit.row] or "")
                for col = hit.from, hit.to do
                    test.is_true(line[col] ~= "X", string.format("окно просвечивает в %d,%d", col, hit.row))
                end
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
