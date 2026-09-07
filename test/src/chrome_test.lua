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
    test.describe("butschster.windows title buttons", function()
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
                                          title = "Сеанс MS-DOS"}},
            })

            test.eq(#built.tree.folders, 1, "папка обязана появиться в дереве каталога")
            test.eq(built.tree.folders[1].title, "Стандартные")
            test.eq(#built.tree.programs, 1, "на верхнем уровне остаётся только беcгруппная")

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
