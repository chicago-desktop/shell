-- Мебель рабочего стола: что стоит на столе при первом запуске и почему оно
-- не возвращается, когда его выбросили.
--
-- Самое дорогое здесь — не «значок появился», а «значок появился ВТОРОЙ раз».
-- Первое видно сразу, второе — только через перезапуск, и выглядит оно как
-- сломанное удаление, а не как правило.
local test = require("test")
local repo = require("repo")
local chrome = require("chrome")
local defaults = require("defaults")
local seed = require("seed")

local function define_tests()
    test.describe("butschster.windows desktop furniture", function()
        test.it("не ставит на стол значка, за которым ничего не стоит", function()
            -- Корзины и «Сетевого окружения» в объявлении нет намеренно:
            -- значок-бутафория выглядит как работающая часть системы, и
            -- первое, что о нём спросят, — почему он не работает.
            for _, item in ipairs(defaults.ITEMS) do
                test.is_true(item.kind == "folder" or type(item.entry) == "string",
                    item.title .. ": ярлык обязан ссылаться на запись реестра")
            end
        end)

        test.it("даёт мебели имена, которые помещаются под значком", function()
            -- Проверяет ТА ЖЕ функция, которой тема рисует подпись, а не её
            -- копия здесь. Копия правила разошлась бы с оригиналом на первой
            -- правке, причём молча: тест остался бы зелёным, а на экране
            -- подпись поехала бы.
            --
            -- Мебель будет расти, и неудачное имя ловится либо здесь, либо
            -- глазами на кадре через неделю. Именем оно и ловится: подпись,
            -- не влезающая в колонку, обрезается — «Мой компьютер и всё
            -- остальное» встаёт как «Мой» / «компьютер и» и на этом кончается.
            -- Пустое объявление прошло бы этот цикл молча, ничего не проверив,
            -- — та же ловушка, что у любой проверки списком.
            test.is_true(#defaults.ITEMS > 0, "мебель не должна быть пустой")

            -- Проверка обязана уметь падать: имя, которое заведомо не влезает,
            -- обязано подниматься как overflow. Иначе зелёный цвет ничего не
            -- значит.
            local _, too_long = chrome.caption_lines("Мой компьютер и всё остальное")
            test.is_true(too_long, "длинное имя обязано подниматься как непоместившееся")

            for _, item in ipairs(defaults.ITEMS) do
                local _, overflow = chrome.caption_lines(item.title)
                test.is_false(overflow,
                    item.title .. ": подпись не помещается под значком")
            end
        end)

        test.it("пропускает ярлык на программу, которой нет в каталоге", function()
            -- Завести его битым значило бы поставить сломанный значок при
            -- первом же запуске. Пропущенный заведётся тогда, когда программа
            -- появится, — и это единственная причина не отмечать его здесь.
            local without = defaults.resolve({})
            for _, item in ipairs(without) do
                test.eq(item.kind, "folder", item.title .. ": без каталога остаются только папки")
            end

            -- Запись берётся у самой мебели, а не переписывается сюда: имя,
            -- списанное в тест, переживает переезд программы и продолжает
            -- проверять то, чего больше нет.
            local wanted = {}
            for _, item in ipairs(defaults.ITEMS) do
                if item.kind == "shortcut" then
                    wanted[#wanted + 1] = {entry = item.entry, title = item.title}
                end
            end
            test.is_true(#wanted > 0, "хоть один ярлык в мебели быть обязан")

            local with = defaults.resolve(wanted)
            test.is_true(#with > #without, "с программой в каталоге мебели становится больше")
        end)

        test.it("заводит мебель один раз и не возвращает выброшенную", function()
            local objects = {
                {key = "!furniture:probe", kind = repo.KIND_FOLDER, title = "Проба"},
            }

            local created, err = seed.furnish(objects)
            test.is_nil(err)
            test.eq(#created, 1, "мебель обязана появиться при первом запуске")
            local id = created[1].id
            test.eq(created[1].kind, "folder")
            test.is_nil(created[1].entry, "за папкой стола не стоит запись реестра")

            local again, aerr = seed.furnish(objects)
            test.is_nil(aerr)
            test.eq(#again, 0, "второй запуск не задваивает мебель")

            -- Главное. Человек выбросил значок — и он не возвращается ни на
            -- одном последующем старте.
            test.is_true(repo.delete(id).existed)
            local third, terr = seed.furnish(objects)
            test.is_nil(terr)
            test.eq(#third, 0, "выброшенная мебель не возвращается")
        end)

        test.it("заводит мебель раньше программ", function()
            -- Места оболочка не выбирает — их выберет композитор, — но порядок
            -- выбирает: значки он кладёт в том порядке, в каком их отдаёт
            -- раскладка, и «Мой компьютер» должен занять начало колонки, а не
            -- встать под тем, что подвернулось.
            local furniture, ferr = seed.furnish({
                {key = "!furniture:first", kind = repo.KIND_FOLDER, title = "Первая"},
            })
            test.is_nil(ferr)

            local program, perr = seed.ensure({
                {entry = "butschster.windows.test:second", title = "Вторая", desktop = true},
            })
            test.is_nil(perr)

            local items = repo.list()
            local at_furniture, at_program = nil, nil
            for index, item in ipairs(items or {}) do
                if item.id == furniture[1].id then at_furniture = index end
                if item.id == program[1].id then at_program = index end
            end
            test.is_true(at_furniture < at_program, "мебель идёт раньше программы")

            repo.delete(furniture[1].id)
            repo.delete(program[1].id)
        end)

        test.it("держит ключ мебели в форме, которой у записи реестра быть не может", function()
            -- Ключи мебели и ключи программ лежат в одной колонке
            -- `desktop_seeded`. Совпади они — удаление ярлыка программы
            -- погасило бы мебель, или наоборот.
            --
            -- Сторожить надо СВОЙСТВО, а не сегодняшнее соглашение. То, что мы
            -- пишем «!», — договорённость, её завтра можно поменять. Защищает
            -- другое: идентификатор записи реестра всегда `namespace:name` из
            -- букв, цифр, точки и подчёркивания, и ключ, не подходящий под эту
            -- форму, записью быть не может НИКОГДА. Проверяем это.
            for _, item in ipairs(defaults.ITEMS) do
                test.is_nil(item.key:match("^[%w_.]+:[%w_.]+$"),
                    item.title .. ": ключ мебели не должен быть похож на идентификатор записи")
            end
        end)

        test.it("не назначает мебели места вовсе", function()
            -- Раскладка не знает ширины экрана в момент старта, поэтому любое
            -- выбранное ею место — догадка, а догадка за краем стоит значка,
            -- исчезнувшего молча. Место назначает композитор, у которого
            -- ширина есть.
            local created, err = seed.furnish({
                {key = "!furniture:noplace", kind = repo.KIND_FOLDER, title = "Без места"},
            })
            test.is_nil(err)
            test.is_nil(created[1].x, "мебель заводится без координат")
            test.is_nil(created[1].y)
            repo.delete(created[1].id)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
