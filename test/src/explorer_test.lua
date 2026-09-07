-- Объекты «Моего компьютера».
--
-- Проверяется правило, а не картинка: что окно показывает сам стенд, что
-- диски берутся у реестра как есть, что двойной щелчок описан намерением, а не
-- выполнен по дороге, и что «пусто» ни в одном месте не подменяет
-- «не прочитали».
--
-- Здесь только чистая сборка — ни базы, ни реестра. Что записи `fs.*`
-- действительно находятся, а содержимое действительно читается, проверяет
-- sources_test на живом реестре.
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
        test.it("не показывает дисков, которых в реестре нет", function()
            -- Нарисованный диск C: — предмет, которого не существует, и первым
            -- вопросом было бы, почему он не открывается. Без записей корень
            -- показывает только то, что оболочка знает и так.
            local root = model.root({}, {})
            test.eq(#root, 3, "три источника, и все три оболочка уже читает")
            test.not_nil(by_id(root, "programs"))
            test.not_nil(by_id(root, "desktop"))
            test.not_nil(by_id(root, "windows"))
        end)

        test.it("делает диском каждую запись fs, ничего не заводя сам", function()
            -- Диск, объявленный установленным модулем, обязан появиться сам.
            -- Своя таблица дисков означала бы, что он не появится, пока
            -- кто-то не впишет его руками.
            local drives = model.drives({
                {id = "wippy.facade:public_files", kind = "fs.directory"},
                {id = "keeper:ui_static_fs", kind = "fs.embed"},
            })
            test.eq(#drives, 2)

            local first = by_id(drives, "keeper:ui_static_fs")
            test.eq(first.kind, "drive")
            test.eq(first.title, "ui_static_fs", "подписью служит имя записи")
            test.eq(first.open.path, "drive/keeper:ui_static_fs")
            test.is_true(first.detail:find("fs.embed", 1, true) ~= nil,
                "вид записи — это ответ на «почему он только на чтение»")
        end)

        test.it("подписывает полным именем диски, которых иначе не различить", function()
            -- Два одинаковых значка рядом — это не подпись, а загадка.
            -- Полным именем подписываются ОБА: подпись, зависящая от порядка
            -- чтения реестра, менялась бы сама по себе.
            local drives = model.drives({
                {id = "keeper:ui_static_fs", kind = "fs.directory"},
                {id = "vlad.doom:ui_static_fs", kind = "fs.directory"},
                {id = "app:one_of_a_kind", kind = "fs.directory"},
            })
            -- Пробелом, а не двоеточием: подпись переносится по пробелам, и
            -- «keeper ui_static_fs» ложится двумя строками, где первая
            -- читается целиком, а «keeper:ui_static_fs» обрезается в
            -- «keeper:ui_st» — ровно там, где начинается различие.
            test.eq(by_id(drives, "keeper:ui_static_fs").title, "keeper ui_static_fs")
            test.eq(by_id(drives, "vlad.doom:ui_static_fs").title, "vlad.doom ui_static_fs")
            test.eq(by_id(drives, "app:one_of_a_kind").title, "one_of_a_kind",
                "однозначное имя удлинять незачем")
        end)

        test.it("ставит диски раньше папок оболочки", function()
            local root = model.root({}, model.drives({
                {id = "app:probe", kind = "fs.directory"},
            }))
            test.eq(#root, 4)
            test.eq(root[1].kind, "drive", "сначала то, из чего стенд состоит")
            test.eq(root[2].id, "programs")
        end)

        test.it("читает путь одинаково для щелчка и для кнопки «Вверх»", function()
            -- Разойдись они — «Вверх» уводила бы не туда, куда ведёт двойной
            -- щелчок, и разошлись бы они молча.
            test.eq(model.parse(model.ROOT).view, "root")
            test.eq(model.parse("desktop").view, "desktop")
            test.eq(model.parse("desktop/f1").id, "f1")
            test.eq(model.parse("drive/app:fs").id, "app:fs",
                "двоеточие принадлежит идентификатору записи, а не пути")
            test.is_nil(model.parse("drive/app:fs").sub)
            test.eq(model.parse("drive/app:fs/ui/dist").sub, "ui/dist")
            test.eq(model.parse("что-то другое").view, "unknown",
                "молчаливый откат к корню превратил бы опечатку в переход")
        end)

        test.it("поднимает на уровень выше, а не сразу в корень", function()
            test.is_nil(model.parent(model.ROOT), "выше корня некуда")
            test.eq(model.parent("programs"), model.ROOT)
            test.eq(model.parent("desktop/f1"), "desktop")
            test.eq(model.parent("drive/app:fs"), model.ROOT)
            test.eq(model.parent("drive/app:fs/ui"), "drive/app:fs")
            test.eq(model.parent("drive/app:fs/ui/dist"), "drive/app:fs/ui")
        end)

        test.it("не обещает открыть файл, которого нечем открыть", function()
            -- Просмотрщика файлов нет. Намерение «открыть» было бы обещанием,
            -- которое некому исполнить, а двойной щелчок по нему —
            -- бездействием, неотличимым от незамеченного.
            local objects = model.files({
                {name = "app.js", type = "file"},
                {name = "ui", type = "directory"},
                {name = "README.md", type = "file"},
            }, "drive/app:fs")

            test.eq(objects[1].title, "ui", "папки раньше файлов, как в проводнике")
            test.eq(objects[1].open.path, "drive/app:fs/ui")
            test.eq(objects[2].title, "README.md", "дальше по имени")
            test.is_nil(objects[2].open)
            test.is_nil(objects[3].open)
        end)

        test.it("различает пустую папку и непрочитанную", function()
            -- Ноль сказал бы «пусто» — утверждение, которого мы не делали.
            local known = model.root({programs = 0, desktop = 4, windows = 1}, {})
            test.eq(by_id(known, "programs").detail, "0 объектов")
            test.eq(by_id(known, "desktop").detail, "4 объектов")

            local unread = model.root({}, {})
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
