-- Окна-виды оболочки: «Дата и время» и калькулятор.
--
-- Проверяется то, из-за чего такое окно молча врёт: кнопка, нарисованная не
-- там, где нажимается; ряд растров, уезжающий заново без изменений; секунда,
-- перерисовывающая календарь; арифметика, которая считает не как кнопки.
local test = require("test")
local gfx = require("gfx")
local rasters = require("rasters")
local chrome = require("chrome")
local dt_layout = require("dt_layout")
local dt_render = require("dt_render")
local engine = require("engine")
local calc_layout = require("calc_layout")
local calc_render = require("calc_render")

local CELL = {w = 10, h = 20}

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
        if not was then names[#names + 1] = id .. " (появился)"
        elseif was.raster ~= now.raster then names[#names + 1] = id .. " (ПЕРЕСОЗДАН)"
        elseif was.version ~= now.version then names[#names + 1] = id end
    end
    table.sort(names)
    return names
end

-- Кнопки, названные в ячейках, не делят ячейку: иначе щелчок по границе
-- принадлежит двум сразу, и выигрывает та, что нашлась первой.
local function assert_disjoint(buttons: any)
    for i = 1, #buttons do
        for j = i + 1, #buttons do
            local a, b = buttons[i], buttons[j]
            local rows = a.row <= b.bottom_row and b.row <= a.bottom_row
            local cols = a.from <= b.to and b.from <= a.to
            test.is_false(rows and cols, a.id .. " и " .. b.id .. " делят ячейку")
        end
    end
end

local function define_tests()
    test.describe("butschster.windows окно «Дата и время»", function()
        test.it("сетка месяца начинается с нужного дня и кончается последним", function()
            -- Сентябрь 2026: первое — вторник, тридцать дней.
            local grid = dt_layout.grid(1, 30)
            test.eq(#grid, 6)
            test.is_false(grid[1][1], "понедельник перед первым числом пуст")
            test.eq(grid[1][2], 1)
            test.eq(grid[5][3], 30, "тридцатое — среда пятой недели")
            test.is_false(grid[5][4])
            test.is_false(grid[6][1])
        end)

        test.it("кнопки внизу не делят ячеек, «Применить» не нажимается", function()
            local buttons = dt_layout.buttons()
            test.eq(#buttons, 3)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do
                test.is_true(button.to <= dt_layout.COLS, button.id .. " за краем окна")
            end
            test.eq(dt_layout.button_at(buttons[1].from, buttons[1].row), "ok")
            test.eq(dt_layout.button_at(buttons[2].to, buttons[2].bottom_row), "cancel")
            test.is_nil(dt_layout.button_at(buttons[3].from, buttons[3].row),
                "выключенная кнопка не отвечает на щелчок")
            test.is_nil(dt_layout.button_at(1, 1), "календарь только для чтения")
        end)

        test.it("секунда переотправляет часы, а не календарь и не кнопки", function()
            local store = rasters.store()
            local window: any = {id = "w7", content_state = {
                year = 2026, month = 9, day = 8, hour = 21, minute = 47, second = 5,
                first_weekday = 1, days = 30, zone = "UTC+04:00"}}
            local inner = {x = 2, y = 2, cols = dt_layout.COLS, rows = dt_layout.ROWS}

            store.begin()
            local first, err = dt_render.placement(window, inner, CELL, nil, store)
            test.is_nil(err)
            test.eq(#first, 3, "три куска: календарь, часы, низ")
            for _, item in ipairs(first) do store.place(item.id, item.x, item.y) end
            store.frame(CELL)
            local before = versions(first)

            store.begin()
            local again = dt_render.placement(window, inner, CELL, nil, store)
            for _, item in ipairs(again) do store.place(item.id, item.x, item.y) end
            store.frame(CELL)
            test.eq(#moved(before, versions(again)), 0, "кадр без изменений ничего не двигает")

            window.content_state.second = 6
            store.begin()
            local ticked = dt_render.placement(window, inner, CELL, nil, store)
            for _, item in ipairs(ticked) do store.place(item.id, item.x, item.y) end
            store.frame(CELL)
            local changed = moved(before, versions(ticked))
            test.eq(#changed, 1, "секунда трогает один кусок: " .. table.concat(changed, ", "))
            test.eq(changed[1], "win:w7:view:right")
        end)

        test.it("размещения ложатся внутрь рамки и покрывают её без щелей", function()
            local store = rasters.store()
            local window: any = {id = "w1", content_state = {
                year = 2026, month = 2, day = 1, hour = 0, minute = 0, second = 0,
                first_weekday = 6, days = 28, zone = ""}}
            local inner = {x = 5, y = 3, cols = dt_layout.COLS, rows = dt_layout.ROWS}
            store.begin()
            local placed = dt_render.placement(window, inner, CELL, nil, store)
            local covered = 0
            for _, item in ipairs(placed) do
                test.is_true(item.x >= inner.x and item.x + item.cols - 1 <= inner.x + inner.cols - 1,
                    item.id .. " вылез по x")
                test.is_true(item.y >= inner.y and item.y + item.rows - 1 <= inner.y + inner.rows - 1,
                    item.id .. " вылез по y")
                covered = covered + item.cols * item.rows
            end
            test.eq(covered, inner.cols * inner.rows, "куски покрывают содержимое ровно один раз")
        end)

        test.it("окно меньше раскладки не рисуется молча, а называет размер", function()
            local store = rasters.store()
            local window: any = {id = "w1", content_state = {year = 2026, month = 1, day = 1,
                hour = 0, minute = 0, second = 0, first_weekday = 3, days = 31, zone = ""}}
            store.begin()
            local placed, why = dt_render.placement(window, {x = 1, y = 1, cols = 20, rows = 10}, CELL, nil, store)
            test.is_nil(placed)
            test.is_true(tostring(why):find("40", 1, true) ~= nil, "причина называет нужный размер")
            local none, waiting = dt_render.placement({id = "w2"}, {x = 1, y = 1, cols = 40, rows = 16}, CELL, nil, store)
            test.is_nil(none)
            test.not_nil(waiting)
        end)
    end)

    test.describe("butschster.windows калькулятор", function()
        test.it("считает как кнопки, а не как выражение", function()
            local state = engine.new()
            for _, id in ipairs({"2", "add", "3", "mul", "4", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "20.", "2 + 3 × 4 у настольного — двадцать")
            test.is_true(state.fresh)
        end)

        test.it("табло у целого с точкой, у дробного без второй", function()
            local state = engine.new()
            test.eq(engine.display(state), "0.")
            for _, id in ipairs({"1", "dot", "5", "dot"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "1.5")
            state = engine.press(state, "neg")
            test.eq(engine.display(state), "-1.5")
        end)

        test.it("деление на ноль — фраза, а после неё работает только сброс", function()
            local state = engine.new()
            for _, id in ipairs({"8", "div", "0", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "Деление на ноль")
            state = engine.press(state, "5")
            test.eq(engine.display(state), "Деление на ноль", "цифра после отказа не считается")
            state = engine.press(state, "ce")
            test.eq(engine.display(state), "0.")
            state = engine.press(state, "inv")
            test.eq(engine.display(state), "Деление на ноль")
            state = engine.press(state, "c")
            test.eq(engine.display(state), "0.")
        end)

        test.it("память переживает сброс C и показывается табло", function()
            local state = engine.new()
            for _, id in ipairs({"4", "2", "ms", "c"}) do state = engine.press(state, id) end
            test.eq(state.memory, 42)
            state = engine.press(state, "mplus")
            test.eq(state.memory, 42, "M+ нуля не меняет память")
            state = engine.press(state, "mr")
            test.eq(engine.display(state), "42.")
            state = engine.press(state, "mc")
            test.is_nil(state.memory)
        end)

        test.it("Back, CE, корень и процент ведут себя как в оригинале", function()
            local state = engine.new()
            for _, id in ipairs({"1", "2", "3", "back"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "12.")
            state = engine.press(state, "back"); state = engine.press(state, "back")
            test.eq(engine.display(state), "0.", "стёртое до конца — ноль, а не пусто")
            for _, id in ipairs({"8", "1", "sqrt"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "9.")
            for _, id in ipairs({"5", "0", "add", "1", "0", "pct"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "5.", "10 % от накопленных 50 — пять")
            state = engine.press(state, "eq")
            test.eq(engine.display(state), "55.")
            for _, id in ipairs({"7", "add", "ce", "3", "eq"}) do state = engine.press(state, id) end
            test.eq(engine.display(state), "10.", "CE стирает ввод, но не операцию")
        end)

        test.it("клавиши приходят в те же кнопки, что и мышь", function()
            test.eq(engine.key({key_type = "runes", key = "7"}), "7")
            test.eq(engine.key({key_type = "runes", key = "*"}), "mul")
            test.eq(engine.key({key_type = "enter", key = "enter"}), "eq")
            test.eq(engine.key({key_type = "backspace"}), "back")
            test.eq(engine.key({key_type = "esc"}), "c")
            test.eq(engine.key({key_type = "runes", key = "с"}), "c", "русская «с» тоже сброс")
            test.is_nil(engine.key({key_type = "runes", key = "q"}))
        end)

        test.it("кнопки раскладки не делят ячеек и помещаются в окно", function()
            local buttons = calc_layout.buttons()
            test.eq(#buttons, 3 + 4 * 6)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do
                test.is_true(button.to <= calc_layout.COLS and button.bottom_row <= calc_layout.ROWS,
                    button.id .. " за краем")
            end
            test.eq(calc_layout.button_at(7, 5), "7")
            test.eq(calc_layout.button_at(30, 12), "eq")
            test.eq(calc_layout.button_at(2, 11), "mplus")
            test.is_nil(calc_layout.button_at(6, 5), "промежуток между кнопками пуст")
            test.is_nil(calc_layout.button_at(10, 2), "табло не кнопка")
        end)

        test.it("нажатие переотправляет табло и один ряд", function()
            local store = rasters.store()
            local window: any = {id = "c1", content_state = {display = "0.", memory = false}}
            local inner = {x = 1, y = 1, cols = calc_layout.COLS, rows = calc_layout.ROWS}
            local function frame()
                store.begin()
                local placed = calc_render.placement(window, inner, CELL, nil, store)
                for _, item in ipairs(placed) do store.place(item.id, item.x, item.y) end
                store.frame(CELL)
                return placed
            end
            local first = frame()
            test.eq(#first, 8)
            local before = versions(first)
            test.eq(#moved(before, versions(frame())), 0)

            window.content_state = {display = "7.", memory = false, pressed = "7"}
            local changed = moved(before, versions(frame()))
            test.eq(#changed, 2, "табло и ряд «7»: " .. table.concat(changed, ", "))
            test.eq(changed[1], "win:c1:view:display")
            test.eq(changed[2], "win:c1:view:row5")

            local pressed = versions(frame())
            window.content_state = {display = "7.", memory = false}
            local released = moved(pressed, versions(frame()))
            test.eq(#released, 1, "отпускание трогает только свой ряд")
        end)
    end)


end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
