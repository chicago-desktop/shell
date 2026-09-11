-- Раскладка сетки значков внутри окна.
--
-- Здесь считаются числа, из-за которых окно молча врёт: сколько объектов
-- поместилось, с какого ряда рисовать и нужна ли полоса прокрутки. Ошибка в
-- любом из них не выглядит ошибкой — она выглядит как «объектов больше нет».
local test = require("test")
local icons = require("icons")
local render = require("render")
local tty = require("tty")

local function define_tests()
    test.describe("butschster.windows explorer render", function()
        test.it("reserves address height for its icon and borders and shares all rows with hits", function()
            for _, ch in ipairs({12, 16, 18, 20, 22, 24, 32}) do
                local metrics = render.pixel_metrics(8, ch)
                local plan = render.layout({address_open = true, address_items = {{title = "Root"}}}, 50, 25, metrics)
                local address = plan.address
                test.is_true(address.rows * ch >= 24)
                test.is_true((address.rows - 1) * ch < 24)
                for _, hit in pairs(address.hits) do
                    test.eq(hit.row, address.row)
                    test.eq(hit.bottom_row, address.row + address.rows - 1)
                    test.is_true(hit.bottom_row < plan.field.y)
                end
                test.eq(address.dropdown[1].row, address.row + address.rows + 1, "dropdown border precedes its first item")
            end
            local cells = render.layout({}, 50, 25)
            test.eq(cells.address.rows, 1)
            test.eq(cells.field.y, 4)
        end)

        test.it("считает ряды по рисунку, а не по шагу сетки", function()
            -- Шаг сетки четыре строки, рисунок три: последнему ряду просвет
            -- под собой не нужен, под ним рамка поля. Считай по шагу — и
            -- целый ряд значков пропадёт, а вместе с ним появится прокрутка,
            -- которой без него не было бы.
            -- Высота 21: строка меню, панель, адресная строка, поле, статус.
            local shape = render.shape(64, 21, 0, 0)
            test.eq(shape.rows, 4, "в поле из пятнадцати строк помещается четыре ряда")
            test.eq(shape.columns, 5)
        end)

        test.it("не рисует ряда, которому не хватило строк", function()
            -- Ряд, которому не хватило строки, залез бы на статусную строку и
            -- остался бы там: диффер поверхности не знает, что это чужое.
            local shape = render.shape(64, 6, 10, 0)
            test.eq(shape.rows, 0)
        end)

        test.it("заводит прокрутку только когда есть что прокручивать", function()
            -- Полоса при полностью видимом содержимом — обещание, что где-то
            -- есть ещё, и человек будет её тянуть.
            test.is_false(render.shape(64, 21, 20, 0).scrolling,
                "двадцать объектов в четыре ряда по пять помещаются целиком")
            test.is_true(render.shape(64, 21, 71, 0).scrolling)
        end)

        test.it("отдаёт полосе колонку, а не рисует значки под ней", function()
            -- Посчитай ширину дважды — значки заедут под полосу ровно тогда,
            -- когда она появится.
            local roomy = render.shape(64, 20, 20, 0)
            local tight = render.shape(64, 20, 500, 0)
            test.eq(roomy.columns, 5)
            test.eq(tight.columns, 5, "шестьдесят две ячейки минус полоса — всё ещё пять колонок")

            -- А вот здесь колонка действительно теряется: ширина ровно на
            -- границе, и полоса съедает последнюю.
            local edge = render.shape(38, 20, 500, 0)
            test.eq(render.shape(38, 20, 4, 0).columns, 3, "без полосы три колонки")
            test.eq(edge.columns, 2, "с полосой помещается две")
        end)

        test.it("зажимает прокрутку, а не показывает пустоту за последним рядом", function()
            -- Окно, которое сузили после прокрутки, иначе показало бы пустое
            -- поле и счётчик, обещающий объекты.
            local shape = render.shape(64, 21, 71, 999)
            test.eq(shape.total, 15, "семьдесят один объект по пять в ряд — пятнадцать рядов")
            test.eq(shape.first, 11, "последний экран начинается с одиннадцатого ряда")
        end)

        test.it("не прокручивает того, что и так видно", function()
            test.eq(render.shape(64, 20, 3, 7).first, 0,
                "три объекта прокручивать некуда, какой бы сдвиг ни назвали")
        end)

        test.it("считает попадания раскладкой, а не отрисовкой", function()
            -- Раньше попадания возвращал тот, кто рисовал, и это было верно,
            -- пока рисующий был один. С двумя бэкендами «одна таблица»
            -- означает уже раскладку: два рисующих, считающие попадания
            -- каждый по-своему, разъедутся молча, и щелчок попадёт на соседа
            -- в одном из двух режимов.
            local view = {
                title = "My Computer",
                selected = 2,
                objects = {
                    {id = "a", kind = "drive", title = "app_fs"},
                    {id = "b", kind = "drive", title = "public_files"},
                    {id = "c", kind = "folder", title = "Programs"},
                },
            }

            local plan = render.layout(view, 46, 14)
            test.eq(#plan.cells, 3, "все три объекта помещаются")
            test.is_true(#plan.tools > 0, "панель инструментов размечена без отрисовки")

            -- А теперь то же самое НАРИСОВАННОЕ: прямоугольник, который
            -- вернул icons.cell, обязан совпасть с тем, что предсказал план.
            -- Разойдись они на ячейку — щелчок попал бы на соседа.
            local canvas = tty.canvas(46, 14)
            for _, cell in ipairs(plan.cells) do
                local box = icons.cell(canvas, cell.x, cell.y, cell.object,
                    {surface = "panel", room = cell.room, selected = cell.selected})
                test.not_nil(box, "значок обязан нарисоваться")
                test.eq(box.from, cell.from, "левый край разъехался с планом")
                test.eq(box.to, cell.to, "правый край разъехался с планом")
                test.eq(box.top, cell.top, "верх разъехался с планом")
                test.eq(box.bottom, cell.bottom, "низ разъехался с планом")
            end
        end)

        test.it("отдаёт бэкенду ячеек те же попадания, что и раскладка", function()
            local view = {
                title = "My Computer",
                objects = {{id = "a", kind = "drive", title = "app_fs"}},
            }
            local plan = render.layout(view, 46, 14)
            local canvas = tty.canvas(46, 14)
            local hits = render.cells(canvas, plan)

            test.eq(#hits.cells, #plan.cells)
            test.eq(hits.cells[1].from, plan.cells[1].from)
            test.eq(hits.cells[1].index, 1)
            test.eq(#hits.tools, #plan.tools)
        end)

        test.it("раскладывает строку меню и раскрытый список одной таблицей для обоих бэкендов", function()
            local plan = render.layout({menu_open = 3}, 46, 14)
            local titles = {}
            for _, hit in ipairs(plan.menu_hits) do titles[#titles + 1] = hit.menu end
            test.eq(table.concat(titles, " "), "File View Go Help", "в строке только меню с действиями, «Правки» нет")
            local ids = {}
            for _, row in ipairs(plan.menu_popup.hits) do ids[#ids + 1] = row.id end
            test.eq(table.concat(ids, " "), "back forward up")
            test.eq(plan.menu_popup.hits[1].row, render.MENU_ROW + 2, "рамка списка — строка под меню, пункт под ней")

            local canvas = tty.canvas(46, 14)
            local hits = render.cells(canvas, plan)
            test.eq(#hits.menu, #plan.menu_hits, "попадания заголовков — из плана")
            test.eq(#hits.menu_popup, 3)
            local rows: any = canvas:rows()
            for index, name in ipairs({"Back", "Forward", "Up One Level"}) do
                local row = plan.menu_popup.hits[index].row
                local line = tostring(rows[row]):gsub("\27%[[%d;:]*m", "")
                test.is_true(line:find(name, 1, true) ~= nil, name .. " нарисован в строке своего попадания: " .. line)
            end
            test.is_nil(render.layout({}, 46, 14).menu_popup, "закрытое меню списка не раскладывает")
        end)

        test.it("называет отказ вместо объектов, а не вместе с ними", function()
            -- «Не прочитали» и «прочитали пустоту» — разные утверждения, и
            -- значок рядом с причиной означал бы, что прочитали наполовину.
            local plan = render.layout({failure = "диск не открылся", objects = {}}, 46, 14)
            test.eq(#plan.cells, 0)
            test.eq(plan.status.count, "—", "счётчик не выдаёт отказ за ноль объектов")
            test.is_nil(plan.scroll, "прокручивать нечего")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
