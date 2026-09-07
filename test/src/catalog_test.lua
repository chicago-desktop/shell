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
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
