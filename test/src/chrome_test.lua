-- Кнопки заголовка окна.
--
-- Проверяется одно правило и его следствия: НАРИСОВАНО и НАЖИМАЕТСЯ обязано
-- быть одним и тем же. Разъехавшись, они дают кнопку на ячейку левее, чем
-- выглядит, — или, хуже, кнопку, которая нарисована и молча не работает.
-- Ни то, ни другое не выглядит ошибкой: выглядит, что «клик не сработал».
local test = require("test")
local chrome = require("chrome")
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

        test.it("уступает место имени, когда кнопки не помещаются", function()
            -- Заголовок без имени не говорит, какое это окно, а закрыть его
            -- можно и с панели задач.
            local narrow = {x = 1, y = 1, w = 10, h = 6, title = "Окно",
                            window_type = "app", rows = {}}
            test.is_nil(chrome.title_button_at(narrow, 8, 2),
                "кнопки не нарисованы — значит и попадания нет")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
