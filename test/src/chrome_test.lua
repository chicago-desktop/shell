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
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
