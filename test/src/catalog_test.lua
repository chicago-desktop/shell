-- Каталог программ: папки меню из meta.group, порядок из meta.order.
--
-- Правило раскладки меню проверяется без живого реестра — на записях,
-- собранных здесь же. Правило, проверяемое только через реестр, проверяется
-- один раз, а потом никогда: подставить в реестр запись с нужной группой
-- дороже, чем не проверить.
--
-- Отдельно закреплено главное свойство `list`: пустой каталог и нечитаемый
-- реестр возвращаются РАЗНЫМИ значениями. Одинаковые, они отправляют человека
-- искать ошибку в своём приложении, где её нет.
local test = require("test")
local catalog = require("catalog")
local view = require("view")
local chrome = require("chrome")
local model = require("model")

local function record(id, meta)
    return {id = id, kind = "process.lua", meta = meta}
end

local function define_tests()
    test.describe("butschster.windows catalog", function()
    test.it("reads the host's exact clock entry", function()
        local entry, err = catalog.taskbar_clock()
        test.is_nil(err)
        test.eq(entry, "app:grouped_probe")
    end)

        test.it("сохраняет meta.image до стола, меню и проводника", function()
            for _, name in ipairs({"printer", "unknown_icon"}) do
                -- `group = ""` держит программу на корне: проверка про значок,
                -- а первая строка корня иначе была бы папкой по умолчанию.
                local built = catalog.build({record("app:printer", {
                    type = "tui_desktop.window", title = "Печать", image = name, group = "",
                })})
                local items = {{id = "print", kind = "shortcut", entry = "app:printer"}}
                test.eq(built.programs[1].image, name)
                test.eq(view.join(items, built)[1].image, name)
                local menu = chrome.menu_layout(100, 30, catalog.menu_items(built.programs), nil, nil, 1, nil)
                test.eq(menu.panels[1].lines[1].image, name)
                test.eq(model.programs(built.programs)[1].image, name)
                test.eq(model.desktop(items, built.programs)[1].image, name)
            end
        end)

        test.it("объявление стенда даёт значок одному entry, сохраняя meta.image программы", function()
            local built = catalog.build({
                record("app:a", {title = "Одинаковое имя"}),
                record("app:b", {title = "Одинаковое имя", image = "printer"}),
            })
            local ok, why = catalog.assign_images(built.programs, {{data = {images = {
                ["app:a"] = "clock", ["app:b"] = "calculator",
            }}}})
            test.is_nil(why)
            test.is_true(ok)
            test.eq(catalog.find(built.programs, "app:a").image, "clock")
            test.eq(catalog.find(built.programs, "app:b").image, "printer")
            ok, why = catalog.assign_images(built.programs, {
                {data = {images = {["app:a"] = "clock"}}},
                {data = {images = {["app:a"] = "calculator"}}},
            })
            test.is_nil(ok)
            test.not_nil(why)
        end)

        test.it("читает значки стенда из реестра и одинаково передаёт их столу и Пуску", function()
            local found, why = catalog.list()
            test.is_nil(why)
            local probe = catalog.find(found.programs, "app:grouped_probe")
            test.eq(probe.image, "clock")
            local menu = catalog.menu_items(found.programs)
            test.eq(catalog.find(menu, probe.entry).image, probe.image)
            local joined = view.join({{id = "probe", kind = "shortcut", entry = probe.entry}}, found)
            test.eq(joined[1].image, probe.image)
            local computer = catalog.find(found.programs, "butschster.windows.explorer:window")
            test.eq(computer.image, "my_computer")
        end)

        test.it("собирает папки меню из meta.group", function()
            local built = catalog.build({
                record("app:net", {type = "tui_desktop.window", title = "Сеть",
                    group = "Служебные/Связь"}),
                record("app:disk", {type = "tui_desktop.window", title = "Диск",
                    group = "Служебные"}),
                record("app:root", {type = "tui_desktop.window", title = "Корень", group = ""}),
                record("app:plain", {type = "tui_desktop.window", title = "Безымянная"}),
            })

            -- Корень — только по явному `group = ""`. Программа, не назвавшая
            -- папку, ложится в DEFAULT_GROUP: иначе каждое окно из мастерской
            -- (у него `meta.group` взяться неоткуда) росло бы корнем.
            test.eq(#built.tree.programs, 1, "на корне только та, что попросила корень")
            test.eq(built.tree.programs[1].title, "Корень")

            test.eq(#built.tree.folders, 2, "папка заводится тем, что в неё положили")
            local default = built.tree.folders[1]
            test.eq(default.title, catalog.DEFAULT_GROUP, "безымянная — в папке по умолчанию")
            test.eq(default.programs[1].title, "Безымянная")
            local service = built.tree.folders[2]
            test.eq(service.title, "Служебные")
            test.eq(#service.programs, 1)
            test.eq(service.programs[1].title, "Диск")
            test.eq(#service.folders, 1, "вложенная папка приходит из пути")
            test.eq(service.folders[1].title, "Связь")
            test.eq(service.folders[1].path, "Служебные/Связь")
            test.eq(service.folders[1].programs[1].title, "Сеть")
        end)

        test.it("сводит путь глубже трёх уровней к третьему, а не теряет программу", function()
            -- Глубже меню в терминале не читается, но потерять программу хуже,
            -- чем потерять папку: её было бы нечем запустить и негде искать.
            local built = catalog.build({
                record("app:deep", {type = "tui_desktop.window", title = "Глубокая",
                    group = "А/Б/В/Г/Д"}),
            })
            local program = built.programs[1]
            test.eq(#program.group, 3, "путь сводится к трём уровням")
            test.eq(program.group[3], "В")
        end)

        test.it("выбрасывает пустые сегменты пути", function()
            -- «Служебные//Сеть» — опечатка, а не безымянная папка посередине.
            local built = catalog.build({
                record("app:x", {type = "tui_desktop.window", title = "Икс",
                    group = "Служебные//Сеть"}),
            })
            test.eq(#built.programs[1].group, 2)
            test.eq(built.programs[1].group[2], "Сеть")
        end)

        test.it("ставит order впереди алфавита, а безпорядковые — по алфавиту", function()
            local built = catalog.build({
                record("app:b", {type = "tui_desktop.window", title = "Бета"}),
                record("app:a", {type = "tui_desktop.window", title = "Альфа"}),
                record("app:z", {type = "tui_desktop.window", title = "Зет", order = 1}),
            })
            test.eq(built.programs[1].title, "Зет", "order идёт первым")
            test.eq(built.programs[2].title, "Альфа")
            test.eq(built.programs[3].title, "Бета")
        end)

        test.it("подставляет значок и имя, когда их не объявили", function()
            local built = catalog.build({record("app:bare", {type = "tui_desktop.window"})})
            local program = built.programs[1]
            test.eq(program.title, "app:bare", "без title именем служит идентификатор")
            test.eq(program.icon, catalog.DEFAULT_ICON)
            test.is_false(program.desktop, "ярлык на столе заводится только по просьбе")
        end)

        test.it("читает desktop как просьбу, а не как утверждение", function()
            local built = catalog.build({
                record("app:d", {type = "tui_desktop.window", desktop = true}),
            })
            test.is_true(built.programs[1].desktop)
        end)

        test.it("различает пустой каталог и нечитаемый реестр", function()
            -- В харнессе окон не зарегистрировано, поэтому list обязан вернуть
            -- ТАБЛИЦУ и nil-причину. Отказ выглядел бы иначе: nil и строка.
            -- Это и есть критерий приёмки №4 на уровне библиотеки.
            local found, err = catalog.list()
            test.is_nil(err, "пустой каталог — не отказ")
            test.not_nil(found, "пустой каталог всё равно таблица")
            test.not_nil(found.programs, "и в ней есть список программ")
            test.not_nil(found.tree, "и корень меню")
        end)

        test.it("не теряет программы, пришедшие без идентификатора", function()
            -- Запись без id запустить нечем: она пропускается молча, но и
            -- соседей за собой не уносит.
            local built = catalog.build({
                {kind = "process.lua", meta = {type = "tui_desktop.window", title = "Без id"}},
                record("app:ok", {type = "tui_desktop.window", title = "С id"}),
            })
            test.eq(#built.programs, 1)
            test.eq(built.programs[1].entry, "app:ok")
        end)

        test.it("не показывает в меню того, кто просил себя спрятать", function()
            -- Признак про МЕНЮ, а не про запуск: программа остаётся в
            -- каталоге, и ярлык на неё продолжает работать. Отфильтруй мы её
            -- из каталога — ярлык на столе стал бы битым, и человек прочитал
            -- бы это как «программы больше нет».
            local built = catalog.build({
                {id = "app:visible", meta = {type = "tui_desktop.window", title = "Видимая", group = ""}},
                {id = "app:hidden", meta = {type = "tui_desktop.window", title = "Скрытая",
                                            group = "", in_menu = false}},
            })
            test.eq(#built.programs, 2, "каталог держит обе")
            test.eq(#built.tree.programs, 1, "в меню только одна")
            test.eq(built.tree.programs[1].entry, "app:visible")
            test.not_nil(catalog.find(built.programs, "app:hidden"),
                "ярлык обязан находить скрытую программу")

            local listed = catalog.listed(built.programs)
            test.eq(#listed, 1, "«Программы» в «Моём компьютере» — тот же выбор, что и меню")
        end)

        test.it("читает in_menu полем, а не через and-or", function()
            -- Ловушка тише, чем кажется: `meta.in_menu` через `x and x.f or
            -- nil` даёт РОВНО ОБРАТНЫЙ ответ — false уходит в ветку «значения
            -- нет» и превращается в умолчание true, то есть окно, которое
            -- просили спрятать, показывается.
            local strings = catalog.build({
                {id = "app:yaml", meta = {type = "tui_desktop.window", in_menu = "false"}},
            })
            test.eq(#strings.tree.programs, 0,
                "строка «false» приезжает из YAML и значит то же самое")
        end)

        test.it("не заводит в меню папку, у которой все дети скрыты", function()
            -- Пустая папка в «Пуске» — это пункт, который раскрывается в
            -- ничто, и первым вопросом будет, куда делось её содержимое.
            -- Папка заводится тем, что в неё положили; скрытую программу мы
            -- не кладём — значит и папки не возникает.
            local built = catalog.build({
                {id = "app:tool", meta = {type = "tui_desktop.window", title = "Служебное",
                                          group = "Служебные/Внутреннее", in_menu = false}},
            })
            test.eq(#built.tree.folders, 0, "папки без содержимого в меню нет")
            test.eq(#built.programs, 1, "но сама программа в каталоге есть")
        end)

        test.it("называет неизвестный тип окна, но программу показывает", function()
            -- Запись объявлена кем-то другим, и опечатка в одном поле не
            -- повод спрятать окно, которое в остальном исправно. Но
            -- неназванная опечатка живёт вечно.
            local built = catalog.build({
                {id = "app:odd", meta = {type = "tui_desktop.window", window_type = "popup"}},
                {id = "app:fine", meta = {type = "tui_desktop.window", window_type = "dialog"}},
            })
            test.eq(#built.tree.folders, 1, "обе без папки — в папке по умолчанию")
            test.eq(#built.tree.folders[1].programs, 2, "показываются обе")
            test.eq(#built.warnings, 1)
            test.eq(built.warnings[1].entry, "app:odd")
            test.eq(built.warnings[1].window_type, "popup")

            test.eq(catalog.find(built.programs, "app:odd").window_type, "app",
                "неизвестный тип считается обычным окном")
            test.eq(catalog.find(built.programs, "app:fine").window_type, "dialog")
        end)

        test.it("собирает папку из настоящей записи реестра", function()
            -- До этого места каталог проверялся только на выдуманных
            -- таблицах: в харнессе не было ни одной записи с `meta.group`.
            -- Промежуток между реестром и деревом папок был зелёным и ни разу
            -- не пройденным, и дефект жил именно в нём.
            local found, err = catalog.list()
            test.is_nil(err, "каталог обязан прочитаться")
            test.not_nil(found)

            local probe = catalog.find(found.programs, "app:grouped_probe")
            test.not_nil(probe, "запись с группой обязана быть в каталоге харнесса")
            test.eq(#probe.group, 2, "путь обязан приехать РАЗОБРАННЫМ, а не строкой")
            test.eq(probe.group[1], "Служебные")
            test.eq(probe.group[2], "Проверка")

            local outer = nil
            for _, folder in ipairs(found.tree.folders) do
                if folder.title == "Служебные" then outer = folder end
            end
            test.not_nil(outer, "папка обязана появиться в дереве")
            test.eq(#outer.folders, 1, "и вложенная в неё тоже")
            test.eq(outer.folders[1].title, "Проверка")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
