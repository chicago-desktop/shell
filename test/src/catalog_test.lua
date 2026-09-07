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

local function record(id, meta)
    return {id = id, kind = "process.lua", meta = meta}
end

local function define_tests()
    test.describe("butschster.windows catalog", function()
        test.it("собирает папки меню из meta.group", function()
            local built = catalog.build({
                record("app:net", {type = "tui_desktop.window", title = "Сеть",
                    group = "Служебные/Связь"}),
                record("app:disk", {type = "tui_desktop.window", title = "Диск",
                    group = "Служебные"}),
                record("app:root", {type = "tui_desktop.window", title = "Корень"}),
            })

            test.eq(#built.tree.programs, 1, "программа без группы лежит в корне")
            test.eq(built.tree.programs[1].title, "Корень")

            test.eq(#built.tree.folders, 1, "папка заводится тем, что в неё положили")
            local service = built.tree.folders[1]
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
                {id = "app:visible", meta = {type = "tui_desktop.window", title = "Видимая"}},
                {id = "app:hidden", meta = {type = "tui_desktop.window", title = "Скрытая",
                                            in_menu = false}},
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
            test.eq(#built.tree.programs, 2, "показываются обе")
            test.eq(#built.warnings, 1)
            test.eq(built.warnings[1].entry, "app:odd")
            test.eq(built.warnings[1].window_type, "popup")

            test.eq(catalog.find(built.programs, "app:odd").window_type, "app",
                "неизвестный тип считается обычным окном")
            test.eq(catalog.find(built.programs, "app:fine").window_type, "dialog")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
