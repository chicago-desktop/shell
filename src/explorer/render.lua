-- Как выглядит содержимое «Моего компьютера».
--
-- Отделено от процесса окна по той же границе, по которой тема отделена от
-- композитора: здесь только строки и арифметика, ни одного обращения в
-- рантайм. Поэтому кадр можно посмотреть пробником `tools/themeprobe`, не
-- поднимая ни окна, ни стенда, — а полноэкранную программу иначе не
-- проверить вовсе.
--
-- Рисуется ТОЛЬКО содержимое: строка меню, панель инструментов, поле со
-- значками и статусная строка. Рамка, заголовок и кнопки заголовка — хром, он
-- за темой; композитор отдаёт окну весь прямоугольник внутри рамки, и что там
-- нарисовано — дело окна.
--
-- Примитивы общие с темой (`widgets`, `icons`): свои значило бы завести
-- вторую, чуть другую кнопку, и внутри окна Windows 95 оказалась бы другая
-- Windows. Разошлись бы они видом, а не отказом, — то есть заметили бы через
-- неделю.
--
-- ГЛАВНОЕ ЗДЕСЬ. Попадания возвращает та же функция, что рисует, и берёт их
-- у того же `icons.cell`, который положил значок. Посчитанные отдельно, они
-- разъезжаются с рисунком на ячейку, и щелчок попадает на соседа — молча.

local icons = require("icons")
local widgets = require("widgets")

local render = {}

render.MENU = {
    {text = "Файл", accel = 1},
    {text = "Правка", accel = 1},
    {text = "Вид", accel = 1},
    {text = "Справка", accel = 1},
}

-- Кнопок две, и обе что-то делают. Кнопка-бутафория выглядит как рабочая
-- часть системы, и первое, что о ней спросят, — почему она не работает.
render.TOOLS = {
    {id = "up", icon = "↑", label = "Вверх"},
    {sep = true},
    {id = "refresh", icon = "⟳", label = "Обновить"},
}

-- Строки, занятые не содержимым: строка меню, панель инструментов, статусная
-- строка. Объявлено числами, а не посчитано по месту, чтобы поле и попадания
-- считались из одного источника.
render.MENU_ROW = 1
render.TOOL_ROW = 2
render.FIELD_TOP = 3

-- Просвет между колонками значков. ШАГ сетки и ШИРИНА рисунка — разные числа,
-- и здесь это видно глазом: подпись, занявшая колонку целиком, упирается в
-- подпись соседа, и две становятся одной нечитаемой строкой. На столе такого
-- нет, потому что там место значку называет человек или композитор; сетку
-- строит только это окно, ему и держать просвет.
render.GAP = 1

-- window(canvas, view, width, height) -> {cells = …, tools = …}
--
-- `view`: objects, title, failure, notice, selected.
--
-- `failure` — «не прочитали», и тогда объектов нет вовсе. `notice` — третье
-- состояние между ним и «показано всё»: прочитали, но не всё, или двойной
-- щелчок не сработал. Замечание не прячет объектов и не выдаёт себя за отказ.
function render.window(canvas, view: any, width: any, height: any)
    local state: any = type(view) == "table" and view or {}
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local grid = icons.grid()

    canvas:clear(widgets.styles.face:render(" "))

    widgets.menu_bar(canvas, 1, render.MENU_ROW, w, render.MENU)
    local tools = widgets.toolbar(canvas, 1, render.TOOL_ROW, w, render.TOOLS)

    -- Поле списка: вдавленная рамка от темы, белая изнанка своя. Значки
    -- лежат на белом, как в проводнике, а не на сером лице панели.
    local field_bottom = h - 1
    local field_h = field_bottom - render.FIELD_TOP + 1
    widgets.field(canvas, 1, render.FIELD_TOP, w, field_h)

    local inner_x, inner_y = 2, render.FIELD_TOP + 1
    local inner_w, inner_h = w - 2, field_h - 2
    if inner_w > 0 and inner_h > 0 then
        local blank = widgets.styles.field:render(string.rep(" ", inner_w))
        for row = 0, inner_h - 1 do canvas:put(inner_x, inner_y + row, blank, inner_w) end
    end

    local cells = {}
    local scroll = {}
    local objects: any = type(state.objects) == "table" and state.objects or {}

    if state.failure then
        canvas:put(inner_x + 1, inner_y,
            widgets.fit(widgets.styles.field, tostring(state.failure), inner_w - 2), inner_w - 2)
    elseif inner_w > 0 and inner_h > 0 then
        local shape = render.shape(width, height, #objects, state.offset)

        -- Полоса прокрутки съедает колонку у поля, поэтому и ширина её
        -- отнимает `shape`, а не эта функция: посчитай их двое — значки
        -- заедут под полосу ровно тогда, когда она появится.
        if shape.scrolling then
            scroll = widgets.scrollbar(canvas, inner_x + inner_w - 1, inner_y, inner_h, {
                first = shape.first, visible = shape.rows, total = shape.total,
            })
        end

        for index, object in ipairs(objects) do
            local slot = index - 1
            local column = slot % shape.columns
            local row = slot // shape.columns - shape.first
            if row >= 0 and row < shape.rows then
                local box = icons.cell(canvas,
                    inner_x + column * grid.w, inner_y + row * grid.h,
                    object,
                    {surface = "panel", room = grid.w - render.GAP,
                     selected = index == state.selected})
                if box then
                    cells[#cells + 1] = {
                        index = index, from = box.from, to = box.to,
                        top = box.top, bottom = box.bottom,
                    }
                end
            end
        end
    end

    -- Счётчик — содержимое окна, а не хрома: он пересчитывается на каждое
    -- открытие папки, и канал «окно сообщает теме свою строку» означал бы,
    -- что композитор знает про устройство чужого окна.
    local count = state.failure and "—" or (tostring(#objects) .. " объектов")

    -- Правое поле рассказывает про то, на что смотрят. Порядок не
    -- произвольный: замечание важнее выделенного объекта, а выделенный объект
    -- важнее заголовка, который и так виден в рамке окна. Так `detail`
    -- перестаёт быть данными, которые некому показать: полный идентификатор
    -- диска не помещается в подпись, а здесь помещается.
    local right: any = state.notice
    if not right and widgets.whole(state.selected) > 0 then
        local chosen: any = objects[state.selected]
        right = type(chosen) == "table" and chosen.detail or nil
    end

    widgets.statusbar(canvas, 1, h, w, {
        {text = count, width = 16},
        {text = right or tostring(state.title or "")},
    })

    return {cells = cells, tools = tools, scroll = scroll}
end

-- Раскладка сетки: сколько колонок, сколько рядов видно, сколько их всего и
-- с какого начинать. Считается ОДИН раз и здесь — потому что этими же числами
-- живут клавиши «вверх» и «вниз» (они ходят по сетке, а не по списку) и
-- прокрутка. Посчитанные в трёх местах, они разъезжаются, и стрелка вниз
-- уводит выделение за край видимого.
--
-- `first` приходит в `state.offset` и здесь ЗАЖИМАЕТСЯ: окно, которое сузили
-- после прокрутки, иначе показало бы пустоту ниже последнего ряда.
function render.shape(width: any, height: any, count: any, offset: any): any
    local grid = icons.grid()
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local total_objects = widgets.whole(count)

    local inner_w = w - 2
    local inner_h = h - 1 - render.FIELD_TOP - 1

    -- ШАГ сетки и ВЫСОТА рисунка — разные числа, и здесь это стоит целого
    -- ряда: шаг четыре строки, рисунок три, и последнему ряду просвет под
    -- собой не нужен — под ним рамка поля. Считай по шагу — и в поле из
    -- пятнадцати строк поместились бы три ряда вместо четырёх, а четвёртый
    -- уехал бы под прокрутку, которой без него не было бы вовсе.
    local rows = (inner_h - grid.drawn) // grid.h + 1
    -- Ноль — это «рисунок не помещается целиком». Не единица: ряд, которому
    -- не хватило строки, залез бы на статусную строку и остался бы там.
    if rows < 0 or inner_h < grid.drawn then rows = 0 end

    local function columns_in(room: any): integer
        local columns = widgets.whole(room) // grid.w
        if columns < 1 then columns = 1 end
        return columns
    end

    local columns = columns_in(inner_w)
    local total = (total_objects + columns - 1) // columns
    local scrolling = total > rows

    -- Появившаяся полоса забирает колонку, и в оставшуюся ширину может
    -- поместиться на одну колонку значков меньше — от чего рядов станет
    -- больше. Второй проход это и учитывает; третьего не нужно: полоса уже
    -- есть, и уже, чем на одну колонку, поле не станет.
    if scrolling then
        columns = columns_in(inner_w - 1)
        total = (total_objects + columns - 1) // columns
        scrolling = total > rows
    end

    local first = widgets.whole(offset)
    local last = total - rows
    if last < 0 then last = 0 end
    if first > last then first = last end
    if first < 0 then first = 0 end

    return {
        columns = columns, rows = rows, total = total,
        first = scrolling and first or 0, scrolling = scrolling,
    }
end

-- Сколько объектов помещается в ряд. Клавишам «влево» и «вправо» этого не
-- нужно, а «вверх» и «вниз» ходят по сетке — на столько же, на сколько её
-- разложили.
function render.columns(width: any, height: any, count: any): integer
    local shape: any = render.shape(width, height, count, 0)
    return (math.tointeger(shape.columns) or 1)
end

return render
