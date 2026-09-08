local scroll = require("scroll")
-- Как выглядит содержимое «Моего компьютера».
--
-- Отделено от процесса окна по той же границе, по которой тема отделена от
-- композитора: здесь только строки и арифметика, ни одного обращения в
-- рантайм. Поэтому кадр можно посмотреть пробником, не поднимая ни окна, ни
-- стенда, — а полноэкранную программу иначе не проверить вовсе.
--
-- ─── ОДНА РАСКЛАДКА, ДВА БЭКЕНДА ────────────────────────────────────────
--
-- Файл разделён на три части, и разделение не косметическое.
--
--   `render.layout`  — ЧТО и ГДЕ. Чистые числа: строки, поле, сетка,
--                      прямоугольники значков, попадания. Ни одной краски.
--   `render.cells`   — рисует символами в холст `tty`.
--   `render.pixels`  — рисует пикселями в растры.
--
-- Оболочка обязана работать в обычном xterm, где графики нет вовсе (FR-005
-- §8б), и умереть там молча она не имеет права. Значит бэкендов два, и цена
-- второго уплачена ровно тем, что раскладка у них общая.
--
-- ПОПАДАНИЯ СЧИТАЕТ РАСКЛАДКА, А НЕ ОТРИСОВКА. Раньше их возвращал тот, кто
-- рисовал, — и это было верно, пока рисующий был один. С двумя рисующими
-- «одна таблица» означает уже не «функция, которая рисует», а раскладку: два
-- бэкенда, считающие попадания каждый по-своему, разъедутся молча, и щелчок
-- попадёт на соседа в одном из двух режимов.
--
-- Прямоугольник значка при этом всё равно берётся у `icons.box` — той же
-- функции, которой пользуется `icons.cell`, когда рисует.

local icons = require("icons")
local widgets = require("widgets")

local render = {}

render.MENU = {
    {text = "Файл", accel = 1},
    {text = "Правка", accel = 1},
    {text = "Вид", accel = 1},
    {text = "Справка", accel = 1},
}

-- Панель окна папки Windows 95: назад, вперёд, вверх · вырезать, копировать,
-- вставить · отменить · удалить, свойства · четыре вида. Работают те, у
-- которых есть действие: назад/вперёд по истории окна, вверх, обновить.
-- Остальные объявлены `disabled` и рисуются выцветшими — как в Windows 95,
-- где они серые, пока нечего вырезать. Бутафории здесь нет: недоступная
-- кнопка на щелчок отвечает в статусной строке, почему она недоступна.
-- Подписей нет — панель одна строка, и с подписями она не влезает в окно.
render.TOOLS = {
    {id = "back", icon = "←", title = "Назад"},
    {id = "forward", icon = "→", title = "Вперёд"},
    {id = "up", icon = "↑", title = "Вверх"},
    {sep = true},
    {id = "cut", icon = "✂", title = "Вырезать", disabled = true},
    {id = "copy", icon = "⧉", title = "Копировать", disabled = true},
    {id = "paste", icon = "⎘", title = "Вставить", disabled = true},
    {sep = true},
    {id = "undo", icon = "↶", title = "Отменить", disabled = true},
    {sep = true},
    {id = "delete", icon = "✕", title = "Удалить", disabled = true},
    {id = "properties", icon = "▤", title = "Свойства", disabled = true},
    {sep = true},
    {id = "view_large", icon = "▦", title = "Крупные значки", pressed = true},
    {id = "view_small", icon = "▩", title = "Мелкие значки", disabled = true},
    {id = "view_list", icon = "≡", title = "Список", disabled = true},
    {id = "view_details", icon = "☷", title = "Таблица", disabled = true},
}
-- «Обновить» на панели Windows 95 нет — оно в меню «Вид» и на F5; здесь
-- Ctrl+R. Кнопка не поместилась бы: панель — 64 ячейки, окно — 70.

-- Строки, занятые не содержимым: строка меню, панель инструментов, статусная
-- строка. Объявлено числами, а не посчитано по месту, чтобы поле и попадания
-- считались из одного источника.
render.MENU_ROW = 1
render.TOOL_ROW = 2
-- Адресная строка — своя строка под панелью (как в Windows 98; в 95 это
-- выпадающий список на самой панели, но в ячейках он туда не помещается).
render.ADDRESS_ROW = 3
render.FIELD_TOP = 4

-- Просвет между колонками значков. ШАГ сетки и ШИРИНА рисунка — разные числа,
-- и здесь это видно глазом: подпись, занявшая колонку целиком, упирается в
-- подпись соседа, и две становятся одной нечитаемой строкой. На столе такого
-- нет, потому что там место значку называет человек или композитор; сетку
-- строит только это окно, ему и держать просвет.
render.GAP = 1

-- layout(view, width, height) -> план
--
-- План — единственная таблица, из которой считают оба бэкенда:
--
--   rows      номера строк: меню, панель инструментов, поле, статусная
--   field     прямоугольник поля списка, в ячейках
--   inner     его внутренность, куда ложатся значки
--   shape     сетка: колонки, ряды, всего рядов, с какого начинать
--   tools     кнопки панели инструментов, с попаданиями
--   cells     значки: индекс объекта, его место и его попадание
--   scroll    полоса прокрутки, если она нужна
--   status    два поля статусной строки, уже готовым текстом
--
-- Ни одного обращения к холсту и ни одной краски: план считается и когда
-- рисовать некуда.
-- Shared by the pixel state provider and the painter. Hits remain cell-aligned.
function render.pixel_metrics(cell_w: any, cell_h: any): any
    local cw, ch = math.max(1, widgets.whole(cell_w)), math.max(1, widgets.whole(cell_h))
    local tool_rows = math.max(1, (26 + ch - 1) // ch)
    local address_rows = math.max(1, (24 + ch - 1) // ch)
    return {grid = {w = (88 + cw - 1) // cw, h = (72 + ch - 1) // ch,
            drawn = (66 + ch - 1) // ch},
        padding = 0, address_row = 2 + tool_rows, field_top = 2 + tool_rows + address_rows,
        address_rows = address_rows, tool_rows = tool_rows,
        -- Кнопка панели 23×22 px, как в Windows 95; место — целые ячейки.
        tool_span = math.max(1, (24 + cw - 1) // cw),
        scroll_cols = math.max(1, (16 + cw - 1) // cw),
        arrow_rows = math.max(1, (16 + ch - 1) // ch), icon_size = 32}
end

function render.layout(view: any, width: any, height: any, metrics: any?): any
    local state: any = type(view) == "table" and view or {}
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local sizing: any = type(metrics) == "table" and metrics or {}
    local grid = sizing.grid or icons.grid()
    local padding = sizing.padding or 1
    local field_top = math.min(widgets.whole(sizing.field_top or render.FIELD_TOP), math.max(2, widgets.whole(height) - 1))
    local scroll_cols = sizing.scroll_cols or 1
    local objects: any = type(state.objects) == "table" and state.objects or {}

    local field_h = h - field_top
    local inner_x, inner_y = padding + 1, field_top + padding
    local inner_w, inner_h = w - padding * 2, field_h - padding * 2

    local plan: any = {
        width = w, height = h,
        rows = {menu = render.MENU_ROW, tool = render.TOOL_ROW,
                field = field_top, status = h},
        -- Высота панели — из метрик, а не «всё между меню и полем»: в ячейках
        -- между ними лежит ещё адресная строка, и панель в две строки ловила
        -- бы её щелчки.
        tool_rows = widgets.whole(sizing.tool_rows or 1), icon_size = sizing.icon_size or 16,
        field = {x = 1, y = field_top, w = w, h = field_h},
        inner = {x = inner_x, y = inner_y, w = inner_w, h = inner_h},
        menu = render.MENU,
        tools = {},
        cells = {},
        scroll = nil,
        failure = state.failure,
        -- Адресная строка: строка — из метрик у пикселей, константа у ячеек;
        -- попадания поля, кнопки ▾ и строк списка считаются ЗДЕСЬ и одни на
        -- оба бэкенда.
        address = {
            row = widgets.whole(sizing.address_row or render.ADDRESS_ROW),
            rows = widgets.whole(sizing.address_rows or 1),
            text = tostring(state.address or state.title or ""),
            items = type(state.address_items) == "table" and state.address_items or {},
            open = state.address_open == true,
        },
    }
    plan.address.hits = widgets.address_hits(1, plan.address.row, w)
    for _, hit in pairs(plan.address.hits) do
        hit.bottom_row = hit.row + plan.address.rows - 1
    end
    if plan.address.open and plan.address.hits.field and #plan.address.items > 0 then
        local field: any = plan.address.hits.field
        plan.address.dropdown = widgets.dropdown_hits(field.from, plan.address.row + plan.address.rows,
            field.to - field.from + 1, #plan.address.items)
    end

    -- Панель инструментов раскладывается той же функцией, что её рисует:
    -- ширина кнопки считается по подписи, и своя формула здесь дала бы
    -- кнопку на ячейку левее, чем выглядит.
    if plan.tool_rows > 0 then plan.tools = widgets.toolbar_hits(1, render.TOOL_ROW, w, render.TOOLS, sizing.tool_span) end
    for _, button in ipairs(plan.tools) do
        button.bottom_row = button.row + plan.tool_rows - 1
        -- Взведённая мышью кнопка нарисована вдавленной до отпускания.
        if state.armed_tool ~= nil and button.id == state.armed_tool then button.pressed = true end
    end

    if not state.failure and inner_w > 0 and inner_h > 0 then
        local shape = render.shape(width, height, #objects, state.offset, metrics)
        plan.shape = shape

        if shape.scrolling and shape.rows > 0 and inner_h >= 2 * (sizing.arrow_rows or 1) then
            plan.scroll = {x = inner_x + inner_w - scroll_cols, y = inner_y, h = inner_h,
                           w = scroll_cols, arrow_rows = sizing.arrow_rows or 1,
                           first = shape.first, visible = shape.rows, total = shape.total}
        end

        for index = 1, #objects do
            local slot = index - 1
            local column = slot % shape.columns
            local row = slot // shape.columns - shape.first
            if row >= 0 and row < shape.rows then
                local x = inner_x + column * grid.w
                local y = inner_y + row * grid.h
                -- Прямоугольник — у `icons.box`, той же функции, которой
                -- пользуется `icons.cell`, когда рисует.
                local box: any = icons.box(x, y, grid.w - render.GAP)
                if sizing.grid then
                    box = {from = x, to = x + grid.w - render.GAP - 1,
                        top = y, bottom = y + grid.drawn - 1}
                end
                if box then
                    plan.cells[#plan.cells + 1] = {
                        index = index, object = objects[index],
                        x = x, y = y, room = grid.w - render.GAP,
                        selected = index == state.selected,
                        from = box.from, to = box.to,
                        top = box.top, bottom = box.bottom,
                    }
                end
            end
        end
    else
        plan.shape = render.shape(width, height, #objects, state.offset, metrics)
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
    plan.status = {count = count, detail = right or tostring(state.title or "")}

    return plan
end

-- Попадания из плана. Собраны в одном месте, чтобы бэкенду не приходилось их
-- пересобирать: пересоберёт — разойдётся.
function render.hits(plan: any): any
    local address: any = plan.address or {}
    local out: any = {cells = {}, tools = plan.tools or {}, scroll = {},
        address = address.hits or {}, dropdown = address.dropdown or {}}
    if plan.scroll then
        local bar: any = plan.scroll
        local rows = math.min(bar.arrow_rows or 1, math.max(1, bar.h // 2))
        local width = bar.w or 1
        out.scroll = {
            {id = "scroll_up", row = bar.y, bottom_row = bar.y + rows - 1,
                from = bar.x, to = bar.x + width - 1},
            {id = "scroll_down", row = bar.y + bar.h - rows, bottom_row = bar.y + bar.h - 1,
                from = bar.x, to = bar.x + width - 1},
        }
    end
    for _, cell in ipairs(plan.cells or {}) do
        out.cells[#out.cells + 1] = {
            index = cell.index, from = cell.from, to = cell.to,
            top = cell.top, bottom = cell.bottom,
        }
    end
    return out
end

-- ─── бэкенд ячеек ────────────────────────────────────────────────────────

-- cells(canvas, plan) -> {cells = …, tools = …, scroll = …}
--
-- Рисует символами. Попадания НЕ считает — берёт из плана; исключение одно и
-- названо: полоса прокрутки возвращает попадания стрелок оттуда же, откуда
-- рисуется.
function render.cells(canvas, plan: any): any
    local hits = render.hits(plan)

    canvas:clear(widgets.styles.face:render(" "))

    widgets.menu_bar(canvas, 1, plan.rows.menu, plan.width, plan.menu)
    widgets.toolbar(canvas, 1, plan.rows.tool, plan.width, render.TOOLS)

    -- Поле списка: вдавленная рамка от темы, белая изнанка своя. Значки
    -- лежат на белом, как в проводнике, а не на сером лице панели.
    widgets.field(canvas, plan.field.x, plan.field.y, plan.field.w, plan.field.h)

    local inner: any = plan.inner
    if inner.w > 0 and inner.h > 0 then
        local blank = widgets.styles.field:render(string.rep(" ", inner.w))
        for row = 0, inner.h - 1 do canvas:put(inner.x, inner.y + row, blank, inner.w) end
    end

    if plan.failure then
        canvas:put(inner.x + 1, inner.y,
            widgets.fit(widgets.styles.field, tostring(plan.failure), inner.w - 2), inner.w - 2)
    else
        if plan.scroll then
            hits.scroll = widgets.scrollbar(canvas, plan.scroll.x, plan.scroll.y, plan.scroll.h, {
                first = plan.scroll.first, visible = plan.scroll.visible,
                total = plan.scroll.total,
            })
        end

        for _, cell in ipairs(plan.cells) do
            icons.cell(canvas, cell.x, cell.y, cell.object,
                {surface = "panel", room = cell.room, selected = cell.selected})
        end
    end

    widgets.statusbar(canvas, 1, plan.rows.status, plan.width, {
        {text = plan.status.count, width = 16},
        {text = plan.status.detail},
    })

    -- Адресная строка и её список рисуются последними: список ложится
    -- поверх поля, и рисовать его раньше значило бы закрасить его значками.
    if plan.address then
        widgets.address_bar(canvas, 1, plan.address.row, plan.width, plan.address.text)
        if plan.address.dropdown and #plan.address.dropdown > 0 then
            local field: any = plan.address.hits.field
            widgets.dropdown(canvas, field.from, plan.address.row + 1,
                field.to - field.from + 1, plan.address.items, #plan.address.items)
        end
    end

    return hits
end

-- window(canvas, view, width, height) -> {cells = …, tools = …, scroll = …}
--
-- Прежний вход, оставленный окну: раскладка плюс бэкенд ячеек.
--
-- `view`: objects, title, failure, notice, selected, offset.
--
-- `failure` — «не прочитали», и тогда объектов нет вовсе. `notice` — третье
-- состояние между ним и «показано всё»: прочитали, но не всё, или двойной
-- щелчок не сработал. Замечание не прячет объектов и не выдаёт себя за отказ.
function render.window(canvas, view: any, width: any, height: any)
    local plan = render.layout(view, width, height)
    local hits = render.cells(canvas, plan)
    return hits
end

-- Раскладка сетки: сколько колонок, сколько рядов видно, сколько их всего и
-- с какого начинать. Считается ОДИН раз и здесь — потому что этими же числами
-- живут клавиши «вверх» и «вниз» (они ходят по сетке, а не по списку) и
-- прокрутка. Посчитанные в трёх местах, они разъезжаются, и стрелка вниз
-- уводит выделение за край видимого.
--
-- `first` приходит в `state.offset` и здесь ЗАЖИМАЕТСЯ: окно, которое сузили
-- после прокрутки, иначе показало бы пустоту ниже последнего ряда.
function render.shape(width: any, height: any, count: any, offset: any, metrics: any?): any
    local sizing: any = type(metrics) == "table" and metrics or {}
    local grid = sizing.grid or icons.grid()
    local padding = sizing.padding or 1
    local field_top = math.min(widgets.whole(sizing.field_top or render.FIELD_TOP), math.max(2, widgets.whole(height) - 1))
    local w = widgets.whole(width)
    local h = widgets.whole(height)
    local total_objects = widgets.whole(count)

    local inner_w = w - padding * 2
    local inner_h = h - field_top - padding * 2

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
        columns = columns_in(inner_w - (sizing.scroll_cols or 1))
        total = (total_objects + columns - 1) // columns
        scrolling = total > rows
    end

    local first = scroll.clamp(offset, total, rows)

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
