-- Окна-виды оболочки: «Дата и время» и калькулятор.
--
-- Проверяется то, из-за чего такое окно молча врёт: кнопка, нарисованная не
-- там, где нажимается; ряд растров, уезжающий заново без изменений; секунда,
-- перерисовывающая календарь; арифметика, которая считает не как кнопки.
local test = require("test")
local gfx = require("gfx")
local tty = require("tty")
local rasters = require("rasters")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local datetime = require("datetime_window")
local engine = require("engine")
local reg_model = require("reg_model")
local regedit = require("regedit_window")
local registry = require("registry")
local calc_window = require("calc_window")
local ui = require("ui")

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
        local function clock_state(): any
            return {clock = {year = 2026, month = 9, day = 8, hour = 21, minute = 47, second = 5,
                first_weekday = 1, days = 30, zone = "UTC+04:00"}, tab = 1}
        end

        test.it("сетка месяца начинается с нужного дня и кончается последним", function()
            -- Сентябрь 2026: первое — вторник, тридцать дней.
            local grid = ui.month_grid(1, 30)
            test.eq(#grid, 6)
            test.is_false(grid[1][1], "понедельник перед первым числом пуст")
            test.eq(grid[1][2], 1)
            test.eq(grid[5][3], 30, "тридцатое — среда пятой недели")
            test.is_false(grid[5][4])
            test.is_false(grid[6][1])
        end)

        test.it("кнопки внизу не делят ячеек, «ОК» по умолчанию, «Применить» не нажимается", function()
            local plan = ui.plan(datetime.definition.view(clock_state(), {width = 42, height = 20}), 42, 20, ui.interaction())
            local buttons = {}
            for _, item in ipairs(plan.items) do
                if item.node.kind == "button" then
                    buttons[#buttons + 1] = {id = item.node.id, from = item.rect.x, to = item.rect.x + item.rect.w - 1,
                        row = item.rect.y, bottom_row = item.rect.y + item.rect.h - 1}
                end
            end
            test.eq(#buttons, 3)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do test.is_true(button.to <= 42, button.id .. " за краем окна") end
            test.is_true(ui.default_look(plan, plan.by_id.ok.node, false), "«ОК» по умолчанию")
            test.is_true(plan.by_id.apply.node.disabled, "«Применить» выключена")
            local interaction = ui.interaction()
            plan = ui.plan(datetime.definition.view(clock_state(), {width = 42, height = 20}), 42, 20, interaction)
            local apply = plan.by_id.apply.rect
            test.is_nil(ui.event(plan, interaction, {type = "mouse", action = "press", button = "left", x = apply.x, y = apply.y}))
            test.is_nil(interaction.armed, "выключенная кнопка не взводится")
            local kinds = {}
            for _, item in ipairs(plan.items) do kinds[item.node.kind] = true end
            test.is_true(kinds.calendar and kinds.clock and kinds.tabs, "календарь, часы и вкладки на месте")
        end)

        test.it("та же секунда не перерисовывает, «ОК» и Esc закрывают", function()
            local state = clock_state()
            local closed = 0
            local context = {width = 42, height = 20, close = function() closed = closed + 1 end}
            state.clock = datetime.snapshot()
            local verdict = datetime.definition.update(state, {type = "tick"}, context)
            test.is_true(verdict == false or verdict == true)
            datetime.definition.update(state, {type = "activate", id = "ok"}, context)
            datetime.definition.update(state, {type = "key", key_type = "esc", key = "esc"}, context)
            test.eq(closed, 2)
            test.eq(datetime.definition.update(state, {type = "activate", id = "apply"}, context), false)
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
            test.eq(engine.display(state), "Cannot divide by zero")
            state = engine.press(state, "5")
            test.eq(engine.display(state), "Cannot divide by zero", "цифра после отказа не считается")
            state = engine.press(state, "ce")
            test.eq(engine.display(state), "0.")
            state = engine.press(state, "inv")
            test.eq(engine.display(state), "Cannot divide by zero")
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

        test.it("кнопки на SDK стоят в сетке оригинала, не делят ячеек и помещаются в окно", function()
            local state = calc_window.definition.init(nil, {})
            local tree = calc_window.definition.view(state, {width = 27, height = 14})
            local plan = ui.plan(tree, 27, 14, ui.interaction())
            local buttons = {}
            for _, item in ipairs(plan.items) do
                if item.node.kind == "button" then
                    buttons[#buttons + 1] = {id = item.node.id, from = item.rect.x, to = item.rect.x + item.rect.w - 1,
                        row = item.rect.y, bottom_row = item.rect.y + item.rect.h - 1}
                end
            end
            test.eq(#buttons, 3 + 4 * 6)
            assert_disjoint(buttons)
            for _, button in ipairs(buttons) do
                test.is_true(button.to <= 27 and button.bottom_row <= 14, button.id .. " за краем")
            end
            test.eq(ui.hit(plan, 7, 6).node.id, "7")
            test.eq(ui.hit(plan, 26, 13).node.id, "eq")
            test.eq(ui.hit(plan, 2, 12).node.id, "mplus")
            test.eq(ui.hit(plan, 6, 6).node.kind, "label", "промежуток между памятью и клавишами пуст")
            test.eq(ui.hit(plan, 10, 2).node.kind, "field", "табло не кнопка")
        end)

        test.it("щелчок и клавиша считают одинаково, подсветка гаснет своим таймером", function()
            local watched: any = {}
            local context: any = {watch = function(ch) watched[#watched + 1] = ch end, close = function() end}
            local state = calc_window.definition.init(nil, context)
            calc_window.definition.update(state, {type = "activate", id = "7"}, context)
            calc_window.definition.update(state, {type = "key", key_type = "runes", key = "*"}, context)
            calc_window.definition.update(state, {type = "activate", id = "6"}, context)
            calc_window.definition.update(state, {type = "key", key_type = "enter", key = "enter"}, context)
            test.eq(engine.display(state.calc), "42.")
            test.eq(state.calc.pressed, "eq", "последняя кнопка подсвечена")
            test.eq(#watched, 4, "каждое нажатие заводит таймер подсветки")
            local tree = calc_window.definition.view(state, {width = 27, height = 14})
            local plan = ui.plan(tree, 27, 14, ui.interaction())
            test.is_true(plan.by_id.eq.node.pressed == true)
            test.eq(calc_window.definition.update(state, {type = "channel", channel = watched[4], ok = true}, context), true)
            test.is_nil(state.calc.pressed, "таймер гасит подсветку")
        end)
    end)

    test.describe("butschster.windows просмотрщик реестра", function()
        local records = {
            {id = "app:db", kind = "db.sql.sqlite", meta = {comment = "база"}, data = {file = ":memory:"}},
            {id = "butschster.windows.shell:chrome", kind = "library.lua", meta = {comment = "тема"},
                data = {source = "file://chrome.lua", modules = {"tty"}}},
            {id = "butschster.windows.shell:pixels", kind = "library.lua", meta = {}, data = {}},
            {id = "butschster.windows:shell", kind = "process.lua", meta = {title = "Оболочка"}, data = {}},
            {id = "app.desktop:window_calc", kind = "process.lua", meta = {type = "tui_desktop.window"}, data = {}},
        }

        test.it("раскладывает пространства имён по точкам, папки раньше записей", function()
            local root = reg_model.build(records)
            test.eq(#root.children, 2, "два корневых пространства: app и butschster")
            test.eq(root.children[1].label, "app")
            local app = root.children[1]
            test.eq(app.children[1].kind, "folder", "папка desktop раньше записи db")
            test.eq(app.children[1].label, "desktop")
            test.eq(app.children[2].label, "db")
            local windows = reg_model.find(root, "butschster.windows")
            test.not_nil(windows)
            test.eq(#windows.children, 2, "папка shell и запись shell рядом")
            test.eq(windows.children[1].kind, "folder")
            test.eq(windows.children[2].key, "butschster.windows:shell")
        end)

        test.it("видимые строки зависят от раскрытых ключей, путь пишется как в regedit", function()
            local root = reg_model.build(records)
            local expanded: any = {}
            expanded[""] = true
            local rows = reg_model.flatten(root, expanded)
            test.eq(#rows, 3, "корень и два пространства")
            test.eq(rows[2].depth, 1)
            test.is_true(rows[2].has_children)
            test.is_false(rows[2].expanded)
            expanded["butschster"] = true
            expanded["butschster.windows"] = true
            rows = reg_model.flatten(root, expanded)
            test.eq(rows[#rows].label, "shell")
            test.eq(rows[#rows].kind, "entry")
            test.is_false(rows[#rows].trail[#rows[#rows].trail], "последний брат — линия вниз не идёт")
            test.eq(reg_model.path("butschster.windows.shell:chrome"), "Registry\\butschster\\windows\\shell\\chrome")
            test.eq(reg_model.path(""), "Registry")
            test.eq(reg_model.parent_key("butschster.windows.shell:chrome"), "butschster.windows.shell")
            test.eq(reg_model.parent_key("butschster.windows"), "butschster")
            test.eq(reg_model.parent_key("app"), "")
        end)

        test.it("поля записи — вид, meta и data по алфавиту, таблицы одной строкой", function()
            local root = reg_model.build(records)
            local node = reg_model.find(root, "butschster.windows.shell:chrome")
            local values = reg_model.values(node, function(v) return "{json}" end)
            test.eq(values[1].name, "kind")
            test.eq(values[1].data, "library.lua")
            test.eq(values[2].name, "meta.comment")
            test.eq(values[2].data, "\"тема\"")
            test.eq(values[3].name, "data.modules")
            test.eq(values[3].data, "{json}", "таблица кодируется тем, что дали")
            test.eq(values[4].name, "data.source")
            local folder = reg_model.values(reg_model.find(root, "app"), nil)
            test.eq(folder[1].name, "(Default)")
            test.eq(folder[2].data, "2")
            test.eq(reg_model.stringify("первая\nвторая", nil), "\"первая…\"", "исходник — первой строкой")
        end)

        test.it("крестик и клавиши дерева на SDK раскрывают, ходят и держат выбор", function()
            local state = regedit.session(records)
            local context = {width = 78, height = 22, close = function() end}
            test.eq(#state.rows, 3)
            local function plan_now()
                return ui.plan(regedit.definition.view(state, context), 78, 22, ui.interaction())
            end
            local plan = plan_now()
            local tree = plan.by_id.tree
            -- Строка 2 — «app» глубины 1; крестик в колонке expander глубины 1.
            local columns = ui.tree_columns(1)
            local interaction = ui.interaction()
            local toggled = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + columns.expander, y = tree.rect.y + 1})
            test.eq(toggled.type, "toggle")
            regedit.definition.update(state, toggled, context)
            test.is_true(state.expanded["app"], "крестик раскрыл app")
            test.eq(state.selected, "", "крестик не меняет выбор")
            plan = plan_now()
            local picked = ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + 10, y = tree.rect.y + 4})
            test.eq(picked.type, "select")
            regedit.definition.update(state, picked, context)
            test.eq(state.selected, "butschster")
            interaction.focus = "tree"
            local function key(name)
                plan = plan_now()
                local action = ui.event(plan, interaction, {type = "key", action = "press", key_type = name, key = name})
                if action then regedit.definition.update(state, action, context) end
            end
            key("right")
            test.is_true(state.expanded["butschster"], "вправо у закрытой — раскрыть")
            key("right")
            test.eq(state.selected, "butschster.windows", "вправо у раскрытой — к первому ребёнку")
            key("right")
            test.is_true(state.expanded["butschster.windows"])
            key("left")
            test.is_nil(state.expanded["butschster.windows"], "влево у раскрытой — закрыть")
            key("left")
            test.eq(state.selected, "butschster", "влево у закрытой — к родителю")
            key("end")
            test.eq(state.selected, "butschster.windows", "end — последняя видимая строка")
            local tree_view = regedit.definition.view(state, context)
            test.eq(tree_view.children[3].fields[1].text, "Registry\\butschster\\windows")
        end)

        test.it("длинное дерево прокручивается и держит выбор на экране", function()
            local many = {}
            for index = 1, 60 do many[index] = {id = "ns" .. string.format("%02d", index) .. ":x", kind = "k", meta = {}, data = {}} end
            local state = regedit.session(many)
            local context = {width = 78, height = 22, close = function() end}
            test.eq(#state.rows, 61)
            local interaction = ui.interaction()
            interaction.focus = "tree"
            for _ = 1, 40 do
                local plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
                local action = ui.event(plan, interaction, {type = "key", action = "press", key_type = "down", key = "down"})
                regedit.definition.update(state, action, context)
            end
            test.eq(state.selected, "ns40")
            local plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
            local tree = plan.by_id.tree
            local lines = tree.page
            test.eq(interaction.offsets.tree, 41 - lines, "выбор на последней строке экрана")
            ui.event(plan, interaction, {type = "mouse", action = "wheel", button = "wheel_down", x = tree.rect.x + 2, y = tree.rect.y + 2})
            test.eq(interaction.offsets.tree, 41 - lines + 3)
            plan = ui.plan(regedit.definition.view(state, context), 78, 22, interaction)
            ui.event(plan, interaction, {type = "mouse", action = "press", button = "left",
                x = tree.rect.x + tree.rect.w - 1, y = tree.rect.y})
            test.eq(interaction.offsets.tree, 41 - lines + 2, "стрелка полосы — на строку")
            -- Окно растянули: сдвиг зажался по новой высоте.
            plan = ui.plan(regedit.definition.view(state, {width = 100, height = 40}), 100, 40, interaction)
            test.is_true(interaction.offsets.tree <= 61 - plan.by_id.tree.page, "сдвиг зажат по новой высоте")
        end)

        test.it("пустой фильтр отдаёт весь реестр, и дерево из него строится", function()
            -- Поставщик читает реестр именно так; если пустой фильтр однажды
            -- станет означать «ничего», окно покажет пустое дерево и назовёт
            -- его реестром.
            local found, err = registry.find({})
            test.is_nil(err)
            test.is_true(#found > 30, "в харнессе больше тридцати записей, найдено " .. tostring(#found))
            local root = reg_model.build(found)
            local shell = reg_model.find(root, "butschster.windows.shell:chrome")
            test.not_nil(shell, "запись темы обязана найтись в дереве")
            test.eq(shell.record.kind, "library.lua")
        end)

    end)

    test.describe("butschster.windows экран прощания", function()
        test.it("после «Завершения работы» — чёрный экран с надписью посередине", function()
            -- Композитор держит этот кадр FAREWELL_HOLD секунд; кадр без
            -- надписи читался бы как повисший терминал, а не как выключение.
            local canvas = tty.canvas(80, 10)
            local painted = chrome.farewell(canvas, 80, 10)
            test.is_nil(painted, "в ячейках размещений нет")
            local rows = canvas:rows()
            local found: any = nil
            for index, row in ipairs(rows) do
                if tostring(row):find("safe to turn off", 1, true) then found = index end
            end
            test.eq(found, 5, "надпись стоит в средней строке")
            test.is_true(tostring(rows[5]):find("\27[", 1, true) ~= nil, "строка окрашена, а не голая")
            test.is_true(tonumber(chrome.FAREWELL_HOLD) == 5, "пять секунд, как просили")
            test.eq(chrome_pixels.FAREWELL_HOLD, chrome.FAREWELL_HOLD, "обе темы держат одинаково")
        end)

        test.it("узкий экран получает обрезанную надпись, а не пустоту", function()
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

    test.describe("butschster.windows фиксированный размер", function()
        test.it("у окна с resizable false нет кнопки «развернуть»", function()
            local set = chrome.buttons_for({window_type = "app", resizable = false})
            test.eq(#set, 2)
            test.eq(set[1].id, "minimize")
            test.eq(set[2].id, "close")
            local free = chrome.buttons_for({window_type = "app"})
            test.eq(#free, 3, "молчащее окно тянется и разворачивается, как раньше")
            local dialog = chrome.buttons_for({window_type = "dialog", resizable = false})
            test.eq(#dialog, 2, "у диалога и так нет «развернуть» — набор не меняется")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
