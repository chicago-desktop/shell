-- Объекты «Моего компьютера».
--
-- Проверяется правило, а не картинка: что окно показывает сам стенд, что
-- двойной щелчок описан намерением, а не выполнен по дороге, и что «пусто» ни
-- в одном месте не подменяет «не прочитали».
local test = require("test")
local model = require("model")

local function by_id(objects, id)
    for _, object in ipairs(objects) do
        if object.id == id then return object end
    end
    return nil
end

local function define_tests()
    test.describe("butschster.windows explorer", function()
        test.it("не показывает дисков, которых на стенде нет", function()
            -- Нарисованный диск C: — предмет, которого не существует, и первым
            -- вопросом было бы, почему он не открывается. Корень показывает
            -- то, из чего стенд действительно состоит.
            local root = model.root({})
            test.eq(#root, 3, "три источника, и все три оболочка уже читает")
            test.not_nil(by_id(root, "programs"))
            test.not_nil(by_id(root, "desktop"))
            test.not_nil(by_id(root, "windows"))
        end)

        test.it("различает пустую папку и непрочитанную", function()
            -- Ноль сказал бы «пусто» — утверждение, которого мы не делали.
            local known = model.root({programs = 0, desktop = 4, windows = 1})
            test.eq(by_id(known, "programs").detail, "0 объектов")
            test.eq(by_id(known, "desktop").detail, "4 объектов")

            local unread = model.root({})
            test.eq(by_id(unread, "programs").detail, "не прочитано",
                "источник без числа не выдаёт себя за пустой")
        end)

        test.it("описывает двойной щелчок намерением, а не действием", function()
            -- Окно не порождает процессов и не открывает соседей само: оно
            -- просит об этом композитор. Намерение, собранное в одном месте,
            -- не даёт окну решать по дороге, что значит «открыть».
            local programs = model.programs({
                {entry = "app:clock", title = "Часы", icon = "◷", width = 30, height = 6},
            })
            test.eq(#programs, 1)
            local open = programs[1].open
            test.eq(open.action, "open_window")
            test.eq(open.entry, "app:clock")
            test.eq(open.w, 30)
            test.eq(open.h, 6)
        end)

        test.it("поднимает открытое окно, а не открывает второе такое же", function()
            -- Список показывает то, что уже на экране; «открыть» здесь значит
            -- «показать». Второе окно того же вида было бы не тем, о чём
            -- просили двойным щелчком по строке списка.
            local windows = model.windows({
                {id = "w1", title = "bash"},
                {id = "w2", title = "Часы", minimized = true},
            })
            test.eq(windows[1].open.action, "raise")
            test.eq(windows[1].open.id, "w1")
            test.eq(windows[1].detail, "на экране")
            test.eq(windows[2].detail, "свёрнуто")
        end)

        test.it("показывает битый ярлык битым и не даёт его открыть", function()
            -- Пропавшая строка читается как «я его случайно удалил», битая —
            -- как «программы больше нет». А открывать нечего: записи нет, и
            -- намерение открыть было бы обещанием, которое некому исполнить.
            local objects = model.desktop({
                {id = "s1", kind = "shortcut", entry = "app:ghost", title = "Призрак"},
            }, {})
            test.eq(#objects, 1)
            test.eq(objects[1].icon, model.BROKEN_ICON)
            test.is_nil(objects[1].open, "у битого ярлыка нечего открывать")
            test.is_true(objects[1].detail:find("нет программы", 1, true) ~= nil,
                "причина названа текстом, а не оставлена на догадку")
        end)

        test.it("не выдаёт исправный ярлык за битый, когда каталог не прочитан", function()
            -- Обвинить исправную программу на основании непрочитанного
            -- каталога хуже, чем промолчать. Но и открывать вслепую нельзя:
            -- размеров окна взять неоткуда.
            local blind = model.desktop({
                {id = "s1", kind = "shortcut", entry = "app:real", title = "Настоящий"},
            }, nil)
            test.eq(#blind, 1)
            test.eq(blind[1].title, "Настоящий")
        end)

        test.it("открывает папку стола её собственным окном", function()
            local objects = model.desktop({
                {id = "f1", kind = "folder", title = "Программы"},
            }, {})
            test.eq(objects[1].kind, "folder")
            test.eq(objects[1].open.action, "folder")
            test.is_true(objects[1].open.path:find("f1", 1, true) ~= nil,
                "путь обязан называть саму папку, иначе откроется не та")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
