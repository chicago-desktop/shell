-- Раскладка окна «Дата и время» — чистая арифметика, без gfx и без рантайма.
--
-- Отсюда читают ДВОЕ: краски (`render`) и поставщик состояния (`state`),
-- который по этой же раскладке считает, куда пришёлся щелчок. Одна таблица
-- на обоих — иначе кнопка «ОК» однажды нарисуется на ячейку правее того
-- места, где нажимается, и промах будет выглядеть как «клик не сработал».
--
-- Всё, по чему щёлкают, названо в ЯЧЕЙКАХ (FR-005 §4а): мышь других
-- координат не знает. Календарь, часы и поля — только украшение, читать их
-- нельзя, и попаданий у них нет: окно объявлено только для чтения.

local layout = {}

-- Размер содержимого в ячейках. Окно объявляет размер с рамкой, тема
-- отнимает инсеты; при ячейке 10×20 это 400×320 px — размер диалога
-- «Свойства: Дата и время» в Windows 95 с точностью до полей.
layout.COLS = 40
layout.ROWS = 16

layout.MONTHS = {
    "Январь", "Февраль", "Март", "Апрель", "Май", "Июнь",
    "Июль", "Август", "Сентябрь", "Октябрь", "Ноябрь", "Декабрь",
}

-- Неделя с понедельника, как в русской Windows 95.
layout.WEEKDAYS = {"Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"}

layout.TABS = {"Дата и время", "Часовой пояс"}

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Области в ячейках содержимого, единичные. Каждая становится своим растром
-- (FR-005 §3): часы меняются каждую секунду, и в отдельном растре они
-- переотправляют себя, а не календарь и не кнопки.
function layout.regions(): any
    return {
        page   = {x = 1, y = 1, cols = layout.COLS, rows = 14},
        date   = {x = 2, y = 3, cols = 20, rows = 11},
        time   = {x = 23, y = 3, cols = 17, rows = 11},
        bottom = {x = 1, y = 15, cols = layout.COLS, rows = 2},
    }
end

-- Растры кадра: чем нарезано содержимое. `left` — вкладки и календарь,
-- `right` — часы и цифровое время, `bottom` — часовой пояс и кнопки.
-- Секунда трогает только `right`.
function layout.slices(): any
    return {
        {id = "left",   x = 1,  y = 1,  cols = 21, rows = 14},
        {id = "right",  x = 22, y = 1,  cols = 19, rows = 14},
        {id = "bottom", x = 1,  y = 15, cols = 40, rows = 2},
    }
end

-- Кнопки внизу. Три одной ширины, прижаты вправо, «Применить» выключена
-- навсегда: применять нечего, окно только показывает.
function layout.buttons(): any
    local span = 8
    local out = {}
    local labels = {
        {id = "ok", label = "ОК", enabled = true},
        {id = "cancel", label = "Отмена", enabled = true},
        {id = "apply", label = "Применить", enabled = false},
    }
    for index, spec in ipairs(labels) do
        local from = layout.COLS - 1 - (#labels - index + 1) * (span + 1) + 2
        out[#out + 1] = {
            id = spec.id, label = spec.label, enabled = spec.enabled,
            from = from, to = from + span - 1, row = 15, bottom_row = 16,
        }
    end
    return out
end

-- button_at(x, y) -> id кнопки или nil. Координаты — ячейки содержимого.
function layout.button_at(x: any, y: any): any
    local col, row = whole(x), whole(y)
    for _, button in ipairs(layout.buttons()) do
        if button.enabled and row >= button.row and row <= button.bottom_row
            and col >= button.from and col <= button.to then
            return button.id
        end
    end
    return nil
end

-- Сетка месяца: шесть недель по семь дней, число или nil.
--
-- `first` — день недели первого числа, 0 = понедельник; `days` — сколько
-- дней в месяце. Оба считает поставщик у модуля time — здесь календарной
-- арифметики нет нарочно: високосность и переходы посчитает библиотека, а
-- не таблица, которую однажды забудут поправить.
function layout.grid(first: any, days: any): any
    local start = whole(first) % 7
    local count = whole(days)
    local rows = {}
    local day = 1 - start
    for _ = 1, 6 do
        local row = {}
        for column = 1, 7 do
            if day >= 1 and day <= count then row[column] = day else row[column] = false end
            day = day + 1
        end
        rows[#rows + 1] = row
    end
    return rows
end

-- Подпись часового пояса. Пусто — окно так и скажет, а не подставит UTC.
function layout.zone_caption(zone: any)
    local given = type(zone) == "string" and zone or ""
    if given == "" then return "Текущий часовой пояс: не определён" end
    return "Текущий часовой пояс: " .. given
end

return layout
