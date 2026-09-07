-- Тема оболочки: вид Windows 95 по контракту темы (FR-002, раздел 4).
--
-- Здесь нет ни одного вызова, уходящего в рантайм: только строки и
-- арифметика. Поэтому файл — библиотека, а не процесс, и его можно звать из
-- любой отрисовки и мерить в тесте без терминала.
--
-- Четыре правила, на которых стоит всё остальное:
--
--   * Рамка и содержимое окна кладутся на холст РАЗДЕЛЬНО. Слить их в одну
--     строку — значит принять решения об обрезке, которые принять уже
--     нельзя: содержимое приходит готовыми строками чужого процесса.
--   * Ширина считается в ЯЧЕЙКАХ. `#строка` считает байты и не видит SGR:
--     на кириллице врёт вдвое, на стилизованном тексте — втрое.
--   * И рисование, и попадание мыши считаются по ОДНОЙ таблице. Отдельная
--     формула для клика однажды разъедется с отрисовкой, и «закрыть»
--     окажется на символ левее, чем выглядит. Отсюда же правило для значков
--     стола: нарисованный значок ОБЯЗАН вернуть своё попадание, иначе он
--     мёртвый, и это не видно на экране.
--   * Сколько места рамка окна забирает у программы, объявляет
--     `window_insets()`, а не считает по месту тот, кому оно понадобилось.
--     Композитор по этим же числам заводит viewport и смещает курсор; два
--     представления о толщине рамки разъезжаются на одну строку, и лишняя
--     строка программы рисуется поверх нижней грани.
--
-- Объём даётся гранью в одну ячейку: светлая сверху и слева, тёмная снизу и
-- справа. Поменять их местами — получить вдавленную деталь тем же кодом;
-- на этом держится и нажатая кнопка, и утопленное поле.

local tty = require("tty")

local glyphs = require("glyphs")
local icons = require("icons")
local palette = require("palette")
local widgets = require("widgets")

-- Набор цветов. Точный RGB по умолчанию; `palette.basic` — та же палитра
-- индексами 0–15 для терминала без truecolor, замена в одну строку.
local color = palette.active

local chrome = {}

-- Короткие имена для примитивов, не знающих про экран. Объявлены ЗДЕСЬ, до
-- первого использования, и это не вкусовщина: локальная переменная видна
-- только ниже своего объявления, а обращение выше молча читается как
-- глобальное — то есть как nil. Пока эти строки лежали в середине файла,
-- `chrome.title_button_at` падал на первом же вызове с «attempt to call a
-- non-function object», и не падал раньше только потому, что его никто не
-- звал.
local whole = widgets.whole
local cells = widgets.cells
local clip = widgets.clip
local fit = widgets.fit
local bezel = widgets.bezel
local edge_top = widgets.edge_top
local edge_bottom = widgets.edge_bottom
local panel = widgets.panel
local wrap = icons.wrap

-- ─── Кнопки заголовка ────────────────────────────────────────────────────
--
-- Ровно три ячейки на кнопку: композитор ищет кнопку под точкой делением
-- отступа на три. Ширина здесь и шаг там — одно и то же число, и разъехаться
-- им нельзя.
-- Шаг кнопки в ячейках. Отдан наружу, потому что состав кнопок теперь не
-- один: у диалога их две, у окна три, и «делить отступ на три» перестало
-- быть верным. Считать шаг по месту — значит завести второе представление
-- о ширине кнопки, которое разъедется с этим на первой правке состава.
chrome.BUTTON_STEP = 3

chrome.BUTTONS = {
    {id = "minimize", glyph = glyphs.buttons.minimize},
    {id = "maximize", glyph = glyphs.buttons.maximize},
    {id = "close",    glyph = glyphs.buttons.close},
}

-- Диалог не сворачивают и не разворачивают: у него нет кнопки на панели
-- задач, и свёрнутый диалог было бы нечем достать. На эталоне в его
-- заголовке «что это?» и «закрыть».
chrome.DIALOG_BUTTONS = {
    {id = "help",  glyph = glyphs.buttons.help},
    {id = "close", glyph = glyphs.buttons.close},
}

-- Служебное окно открывают из другого и закрывают, когда оно больше не
-- нужно. Свернуть его некуда — на панели задач его тоже нет, — а разворачивать
-- на весь экран палитру инструментов незачем.
chrome.TOOL_BUTTONS = {
    {id = "close", glyph = glyphs.buttons.close},
}

-- Наборы по типу окна. Таблицей, а не цепочкой if: третий тип добавляется
-- строкой, а не веткой, и «какой набор у tool» читается в одном месте.
--
-- Значения те же, что объявляет основа (`butschster.tui_desktop.desktop:programs`).
-- Тип, которого здесь нет, — это `app`: неизвестное значение не повод не
-- нарисовать окно, и решает это основа, а не тема.
chrome.BUTTON_SETS = {
    app = chrome.BUTTONS,
    dialog = chrome.DIALOG_BUTTONS,
    tool = chrome.TOOL_BUTTONS,
}

chrome.BUTTONS_WIDTH = #chrome.BUTTONS * chrome.BUTTON_STEP

-- Какой набор кнопок у этого окна и сколько он занимает. ОДНА таблица и для
-- рисования, и для попадания — иначе «закрыть» однажды окажется на символ
-- левее, чем выглядит, а у диалога нарисуются три кнопки, из которых
-- нажимаются две.
--
-- Читается `window_type` — поле, которое кладёт композитор основы. `dialog`
-- как булев признак больше не читается: два имени одного и того же
-- разъезжаются на первой правке, а окно, объявившее себя диалогом обоими
-- способами сразу, выглядело бы по-разному в зависимости от того, какое
-- чтение случилось первым.
function chrome.buttons_for(window)
    local spec: any = type(window) == "table" and window or {}
    local kind: any = spec.window_type
    local set: any = type(kind) == "string" and chrome.BUTTON_SETS[kind] or nil
    if not set then set = chrome.BUTTONS end
    return set, #set * chrome.BUTTON_STEP
end

-- Кнопка заголовка под точкой, или nil.
--
-- Живёт в теме, а не в композиторе, нарочно: после того как заголовок
-- переехал внутрь рамки, его строка — это `y + 1`, а не `y`, и правый край
-- кнопок отстоит от края окна на правый инсет. Оба числа знает тема;
-- повторённые в композиторе, они разъезжаются молча, и промах по кнопке
-- выглядит как «клик не сработал».
function chrome.title_button_at(window, x: any, y: any)
    local spec: any = type(window) == "table" and window or {}
    local wx, wy = whole(spec.x), whole(spec.y)
    local ww = whole(spec.w)
    local inset = chrome.window_insets(spec)
    local set, width = chrome.buttons_for(spec)

    if whole(y) ~= wy + 1 then return nil end
    local span = ww - 2
    if span < width + 6 then return nil end

    local last = wx + ww - inset.right          -- последняя ячейка перед правой гранью
    local from = last - width + 1
    local point = whole(x)
    if point < from or point > last then return nil end

    local slot = (point - from) // chrome.BUTTON_STEP + 1
    local button = set[slot]
    return button and button.id or nil
end

-- Клиентская область окна утоплена, как на эталоне: тёмная грань сверху и
-- слева, светлая снизу и справа. Стоит это программе одной строки и двух
-- колонок сверх выпуклой рамки. Выключается здесь одной строкой — тогда
-- рамка остаётся выпуклой, а содержимое лежит прямо на лице окна.
local SUNKEN_CLIENT = true

-- Кнопка панели задач. Меньше семи ячеек — это две грани и три буквы имени:
-- кнопка, по которой нельзя узнать окно, занимает место зря.
local TASK_MAX = 20
local TASK_MIN = 7

-- Значок рабочего стола рисует библиотека `icons` — та же, которой рисует
-- значки окно «Мой компьютер». Здесь только переадресация: два одинаковых
-- значка, нарисованных разным кодом, разойдутся видом, а не отказом.
local ICON_GRID: any = icons.grid()

function chrome.icon_grid()
    return icons.grid()
end

function chrome.caption_lines(title, room: any)
    return icons.caption_lines(title, room)
end

chrome.ICON_W = ICON_GRID.w
chrome.ICON_H = ICON_GRID.h
chrome.ICON_LEFT = ICON_GRID.left

-- Меню «Пуск».
local MENU_WIDTH = 38
local MENU_MIN = 22
local MENU_BANNER_AT = 26   -- с этой ширины в меню помещается вертикальная надпись
local MENU_BANNER = "WINDOWS 95"
local MAX_DEPTH = 3         -- глубже меню в терминале не читается (FR 5.4)

local START_LABEL = " " .. glyphs.icons.start .. " Пуск "

local styles = {
    desktop        = tty.style():background(color.desktop),
    desktop_text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
    desktop_broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
    face           = tty.style():foreground(color.face_text):background(color.face),
    face_bold      = tty.style():bold():foreground(color.face_text):background(color.face),
    face_dim       = tty.style():foreground(color.shadow):background(color.face),
    accel          = tty.style():underline():foreground(color.face_text):background(color.face),
    light          = tty.style():foreground(color.light):background(color.face),
    shadow         = tty.style():foreground(color.shadow):background(color.face),
    frame          = tty.style():foreground(color.frame):background(color.face),
    etched         = tty.style():foreground(color.shadow):background(color.light),
    title          = tty.style():bold():foreground(color.title_active_fg):background(color.title_active_bg),
    title_idle     = tty.style():foreground(color.title_idle_fg):background(color.title_idle_bg),
    select         = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    banner         = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    alert          = tty.style():bold():foreground(color.alert):background(color.face),
}

-- ─── Общие мерки и детали ────────────────────────────────────────────────
--
-- Всё, что не знает про экран, живёт в `widgets` и рисуется тем же кодом у
-- окна. Короткие имена для них объявлены в начале файла.

chrome.clip = clip
chrome.panel = panel
chrome.field = widgets.field
chrome.accel = widgets.accel
chrome.button = widgets.button
chrome.button_width = widgets.button_width
chrome.etched = widgets.etched
chrome.tabs = widgets.tabs

-- Стили темы — общие плюс те, которых у окна не бывает: рабочий стол и
-- полоса заголовка принадлежат только раме.
local styles: any = {}
for name, style in pairs(widgets.styles) do styles[name] = style end

styles.desktop = tty.style():background(color.desktop)
styles.desktop_text = tty.style():bold():foreground(color.desktop_text):background(color.desktop)
styles.title = tty.style():bold():foreground(color.title_active_fg):background(color.title_active_bg)
styles.title_idle = tty.style():foreground(color.title_idle_fg):background(color.title_idle_bg)
-- Вертикальная надпись в меню и выделение — одна и та же пара цветов: в
-- Windows 95 это одна величина, и заводить вторую незачем.
styles.banner = styles.select

-- ─── Геометрия хрома ─────────────────────────────────────────────────────

-- Панель задач занимает нижнюю строку и только её. Сверху хром не берёт
-- ничего: полосы окон в Windows 95 нет, её роль исполняют кнопки на панели.
function chrome.layout(width: any, height: any)
    return {top = 0, bottom = 1}
end

-- Сколько ячеек рамка окна забирает у программы с каждой стороны.
--
-- Сверху две строки — выпуклая грань и полоса заголовка под ней: на эталоне
-- заголовок лежит ВНУТРИ рамки, а не заменяет её верх, и без этой строки
-- окно читается как панель с текстом. С утопленной клиентской областью
-- сверху три, снизу и по бокам по две.
--
-- Композитор обязан считать по этим числам размер viewport и смещение
-- курсора. Отсюда же нижняя граница размера окна: окно, у которого
-- содержимого не осталось ни одной строки, — это `tty.viewport` с нулевой
-- высотой, то есть отказ на открытии.
function chrome.window_insets(window)
    -- Строка меню окна сюда БОЛЬШЕ НЕ ВХОДИТ. Композитор отдаёт окну весь
    -- прямоугольник внутри рамки, и что там нарисовано — дело окна: пункты
    -- меню свои у каждого, а «6 объектов» пересчитывается на каждое
    -- открытие папки. Рисуй их тема — понадобился бы канал «окно сообщает
    -- теме свои строки», то есть композитор начал бы знать про устройство
    -- чужого окна.
    if SUNKEN_CLIENT then
        return {top = 3, bottom = 2, left = 2, right = 2}
    end
    return {top = 2, bottom = 1, left = 1, right = 1}
end

-- ─── Рабочий стол ────────────────────────────────────────────────────────

-- Стол: заливка, значки раскладки и попадания по ним.
--
-- Заливается весь холст: панель задач и окна лягут поверх, а незалитая
-- полоса под панелью отличалась бы цветом на один кадр при смене размера.
--
-- Раскладку тема не хранит и не придумывает — она приходит в `state.items`.
-- Каждый нарисованный значок возвращает попадание; открывает его двойной
-- щелчок, выделяет одиночный, и решает это композитор, а не тема.
function chrome.fill(canvas, width: any, height: any, state)
    canvas:clear(styles.desktop:render(" "))

    local hits = {}
    local w, h = whole(width), whole(height)
    local desk = type(state) == "table" and state or {}
    if w < 4 or h < 2 then return hits end

    local top = whole(desk.top)
    if top < 1 then top = 1 end
    local bottom = whole(desk.bottom)
    if bottom < 1 or bottom > h then bottom = h end

    -- «Раскладка не прочитана» и «на столе пусто» — разные утверждения.
    -- Пустой стол молчит; отказ называет причину, иначе человек пойдёт
    -- искать пропавшие ярлыки, которых он не терял.
    if desk.failure then
        local box_w = math.min(48, w - 4)
        if box_w >= 12 then
            local body = {fit(styles.alert, " раскладка не прочитана:", box_w - 2)}
            local reason = wrap(tostring(desk.failure), box_w - 4, 3)
            for _, piece in ipairs(reason) do
                body[#body + 1] = fit(styles.face, " " .. piece, box_w - 2)
            end
            panel(canvas, 3, top + 1, box_w, body, false)
        end
        return hits
    end

    local selected = desk.selected

    for _, item in ipairs(type(desk.items) == "table" and desk.items or {}) do
        local x = whole(item.x)
        if x < 1 then x = 1 end
        local y = whole(item.y)
        if y < top then y = top end
        local span = math.min(whole(ICON_GRID.w), w - x + 1)

        local drawn = nil
        if y + whole(ICON_GRID.drawn) - 1 <= bottom then
            drawn = icons.cell(canvas, x, y, item, {
                surface = "desktop",
                selected = selected ~= nil and item.id == selected,
                room = span,
            })
        end

        if drawn then
            -- Попадание на все строки элемента: щёлкают и по картинке, и по
            -- подписи, в том числе по её второй строке. Прямоугольник берётся
            -- у того, кто рисовал, — своя формула разъехалась бы с рисунком.
            for row = drawn.top, drawn.bottom do
                hits[#hits + 1] = {
                    row = row, from = drawn.from, to = drawn.to,
                    id = item.id, kind = item.kind,
                    broken = item.broken and true or false,
                    entry = item.entry, title = item.title,
                    w = tonumber(item.w), h = tonumber(item.h), args = item.args,
                }
            end
        end
    end

    return hits
end

-- ─── Окно ────────────────────────────────────────────────────────────────

-- Полоса заголовка: идёт в ширину ВНУТРЕННЕЙ области, не касаясь граней.
-- Возвращает строку ровно в `span` ячеек.
local function title_bar(title, span: any, focused, window)
    local width = whole(span)
    if width <= 0 then return "" end

    local bar = focused and styles.title or styles.title_idle

    -- Набор берётся у того же `buttons_for`, что и попадание. Рисовать
    -- всегда три, а нажимать по набору типа — значит нарисовать диалогу
    -- «свернуть», которая молча не работает; ровно за этим сюда и приехало
    -- окно, а не одно его имя.
    local set, set_width = chrome.buttons_for(window)

    -- Кнопки уступают место имени: заголовок без имени не говорит, какое это
    -- окно, а закрыть его можно и с панели задач.
    local buttons = width >= set_width + 6 and set_width or 0
    local room = width - buttons - 2
    local name = room > 0 and clip(title or "", room) or ""

    local parts = {bar:render(" " .. name)}
    local used = 1 + cells(name)

    local tail = width - used - buttons
    if tail > 0 then parts[#parts + 1] = bar:render(string.rep(" ", tail)) end

    if buttons > 0 then
        for _, button in ipairs(set) do
            -- Кнопка — та же выпуклая деталь, что и всё остальное: светлая
            -- грань слева, тёмная справа. Три ячейки на каждую.
            parts[#parts + 1] = bezel(styles.face:render(button.glyph), false)
        end
    end

    return table.concat(parts)
end

chrome.title_bar = title_bar

-- Окно целиком: выпуклая рамка, заголовок внутри неё, утопленная клиентская
-- область и содержимое.
--
-- `rows` — массив строк, как его отдаёт viewport:snapshot(). Он общий и
-- неизменяемый, поэтому кладётся как есть: put_rows сам обрежет по ширине.
function chrome.window(canvas, window, focused)
    local hits = {}
    local x, y = whole(window.x), whole(window.y)
    local w, h = whole(window.w), whole(window.h)
    local inset = chrome.window_insets(window)
    if w < inset.left + inset.right + 1 or h < inset.top + inset.bottom + 1 then return hits end

    -- Выпуклая рамка окна.
    canvas:put(x, y, edge_top(w, false), w)
    canvas:put(x, y + 1, bezel(title_bar(window.title, w - 2, focused, window), false), w)
    local blank = bezel(styles.face:render(string.rep(" ", w - 2)), false)
    for row = 2, h - 2 do
        canvas:put(x, y + row, blank, w)
    end
    canvas:put(x, y + h - 1, edge_bottom(w, false), w)

    -- Утопленная клиентская область внутри неё.
    if SUNKEN_CLIENT then
        widgets.field(canvas, x + 1, y + 2, w - 2, h - 3)
    end

    -- Содержимое кладётся отдельно и обрезается по высоте рамки. Обычно
    -- viewport окна ровно в неё и сделан, но в момент смены размера кадр
    -- приходит от прежней геометрии: `put_rows` держит границу ХОЛСТА, а не
    -- рамки, поэтому лишняя строка нарисовалась бы поверх нижней грани и за
    -- пределами окна. Читается это как сломанная рамка, а не как отставший
    -- кадр.
    if window.rows then
        local room = h - inset.top - inset.bottom
        local body = window.rows
        if #body > room then
            body = {}
            for row = 1, room do body[row] = window.rows[row] end
        end
        canvas:put_rows(x + inset.left, y + inset.top, body, w - inset.left - inset.right)
    end

    return hits
end

-- ─── Панель задач ────────────────────────────────────────────────────────

-- Панель: «Пуск» слева, кнопки открытых окон, часы справа.
--
-- Возвращает разметку попаданий — по ней композитор находит, во что попал
-- клик: {row, from, to, action = "menu"} у «Пуска» и {row, from, to, id} у
-- кнопки окна. Что делать с попаданием, решает композитор: поднять окно и
-- развернуть свёрнутое — его работа, не темы.
function chrome.bars(canvas, width: any, height: any, state)
    local hits = {}
    local w, h = whole(width), whole(height)
    if w < 1 or h < 1 then return hits end

    local bar = type(state) == "table" and state or {}
    local row = h
    local parts, used = {}, 0

    -- «Пуск». Открытое меню держит кнопку нажатой: иначе по экрану не
    -- сказать, меню это или окно, всплывшее над панелью.
    local pressed = bar.menu_open and true or false
    local face = pressed and styles.face_bold or styles.face
    local label = START_LABEL
    if w < cells(START_LABEL) + 2 + TASK_MIN then label = glyphs.icons.start end
    if cells(label) + 2 <= w then
        parts[#parts + 1] = bezel(face:render(label), pressed)
        used = cells(label) + 2
    else
        parts[#parts + 1] = face:render(glyphs.icons.start)
        used = 1
    end
    hits[#hits + 1] = {row = row, from = 1, to = used, action = "menu"}

    -- Часы. Утопленное поле, а не кнопка: нажимать не на что.
    local clock = type(bar.clock) == "string" and bar.clock or ""
    local clock_render, clock_cells = "", 0
    if clock ~= "" then
        local padded = " " .. clock .. " "
        if used + cells(padded) + 2 <= w then
            clock_render = bezel(styles.face:render(padded), true)
            clock_cells = cells(padded) + 2
        elseif used + cells(clock) <= w then
            clock_render = styles.face:render(clock)
            clock_cells = cells(clock)
        end
    end

    -- Кнопки окон. Экран уже панели — они исчезают ПЕРВЫМИ: «Пуск» и часы
    -- остаются единственным признаком того, что оболочка жива, а список
    -- окон можно узнать и alt+tab'ом.
    local windows = type(bar.windows) == "table" and bar.windows or {}
    local room = w - used - clock_cells
    if room >= TASK_MIN + 1 and #windows > 0 then
        parts[#parts + 1] = styles.face:render(" ")
        used, room = used + 1, room - 1

        local share = room // #windows
        if share > TASK_MAX then share = TASK_MAX end
        if share < TASK_MIN then share = TASK_MIN end

        for _, window in ipairs(windows) do
            local span = share
            if span > room then span = room end
            if span < TASK_MIN then break end

            local active = bar.focused_id ~= nil and window.id == bar.focused_id
            -- Свёрнутое окно — приглушённой подписью. Формально этого не
            -- требуют, но иначе «поднять» и «развернуть» на экране
            -- неразличимы, а это разные ожидания от одного клика.
            local face_style = styles.face
            if active then face_style = styles.face_bold
            elseif window.minimized then face_style = styles.face_dim end

            -- На узкой кнопке значка нет: он одинаковый у всех окон и
            -- отнимает две ячейки у имени, по которому окно и узнают.
            local body = " " .. tostring(window.title or "?")
            if span >= TASK_MIN + 5 then
                local icon = type(window.icon) == "string" and window.icon or glyphs.icons.program
                body = " " .. icon .. " " .. tostring(window.title or "?")
            end
            parts[#parts + 1] = bezel(fit(face_style, body, span - 2), active)
            hits[#hits + 1] = {row = row, from = used + 1, to = used + span, id = window.id}
            used, room = used + span, room - span
        end
    end

    -- Строка состояния занимает то, что осталось. Своей строки у неё больше
    -- нет — панель заняла единственную нижнюю, — а выбросить её значит
    -- потерять сообщения вроде «не открылось: …», которые больше нигде не
    -- показываются.
    local rest = w - used - clock_cells
    local status = type(bar.status) == "string" and bar.status or ""
    if status ~= "" and rest >= 6 then
        parts[#parts + 1] = fit(styles.face_dim, " " .. status, rest)
        used = used + rest
        rest = 0
    end

    if rest > 0 then
        parts[#parts + 1] = styles.face:render(string.rep(" ", rest))
        used = used + rest
    end
    if clock_cells > 0 then parts[#parts + 1] = clock_render end

    canvas:put(1, row, table.concat(parts), w)
    return hits
end

-- ─── Меню «Пуск» ─────────────────────────────────────────────────────────

local function title_of(item)
    local title = item.title
    if type(title) == "string" and title ~= "" then return title end
    return tostring(item.entry or "?")
end

local function order_of(item)
    return tonumber(item.order) or math.huge
end

local function new_node()
    return {names = {}, groups = {}, programs = {}}
end

-- Папка меню задаётся путём в `meta.group`, а не отдельной записью: папка
-- без программ бессмысленна, а объявленная отдельно — разъезжается со своим
-- содержимым при удалении модуля. Глубже трёх уровней путь схлопывается: в
-- терминале четвёртый отступ уже не читается.
local function place(root, index, item)
    local node = root
    local path = type(item.group) == "string" and item.group or ""
    local depth = 0
    for part in path:gmatch("[^/]+") do
        if depth >= MAX_DEPTH then break end
        local child = node.groups[part]
        if not child then
            child = new_node()
            node.groups[part] = child
            node.names[#node.names + 1] = part
        end
        node = child
        depth = depth + 1
    end
    node.programs[#node.programs + 1] = {index = index, item = item}
end

-- Строки одной панели: сперва папки, потом программы. Отступов нет
-- НАРОЧНО: вложенность показывает отдельная панель, а не сдвиг вправо.
-- Отступами дерево читается как список, и это была не мелочь — по списку
-- не видно, что папка раскрывается.
local function panel_lines(node)
    local lines = {}
    table.sort(node.names)
    for _, name in ipairs(node.names) do
        lines[#lines + 1] = {kind = "group", text = name}
    end
    table.sort(node.programs, function(left, right)
        local lo, ro = order_of(left.item), order_of(right.item)
        if lo ~= ro then return lo < ro end
        return title_of(left.item) < title_of(right.item)
    end)
    for _, program in ipairs(node.programs) do
        lines[#lines + 1] = {
            kind = "item", index = program.index, item = program.item,
            text = title_of(program.item),
        }
    end
    return lines
end

-- Подпись строки без стиля: нужна дважды — чтобы померить панель и чтобы её
-- нарисовать. Считать её в двух местах значит однажды померить одно, а
-- нарисовать другое.
local function line_text(line)
    if line.kind == "item" then
        local item = line.item
        local key = line.index <= 9 and tostring(line.index) or " "
        local icon = type(item.icon) == "string" and item.icon ~= "" and item.icon or glyphs.icons.unknown
        return " " .. key .. " " .. icon .. " " .. line.text, ""
    end
    if line.kind == "group" then
        return " " .. glyphs.icons.folder .. " " .. line.text, glyphs.icons.submenu .. " "
    end
    return " " .. tostring(line.text or ""), ""
end

-- Меню «Пуск»: каскад панелей, наполняется каталогом реестра.
--
-- `open` — путь раскрытых папок от корня наружу, например {"Программы",
-- "Стандартные"}. Тема ничего про раскрытие не помнит: что раскрыто,
-- держит композитор, и он же получает готовый путь в попадании — ему
-- достаточно положить его себе, не разбирая дерева.
--
-- Разметка попаданий различает два действия, а не одно:
--   программа — {row, from, to, index = <номер в переданном массиве>}
--   папка     — {row, from, to, open = {…полный путь…}, level = k}
-- Номер программы — именно в ПЕРЕДАННОМ массиве, а не в порядке показа: тот
-- же номер стоит в строке акселератором, и разъехаться им нечем.
function chrome.menu(canvas, width: any, height: any, items, failure, open)
    local hits = {}
    local w, h = whole(width), whole(height)
    if w < 8 or h < 4 then return hits end

    local catalog = type(items) == "table" and items or {}
    local room = h - 1 - 2
    if room < 1 then return hits end

    -- Отказ реестра и пустой каталог обязаны различаться на экране:
    -- одинаковый вид отправляет человека искать ошибку в своём приложении,
    -- где её нет. Обоим хватает одной панели — каскаду тут неоткуда взяться.
    if failure or #catalog == 0 then
        local box_w = math.min(MENU_WIDTH, math.max(MENU_MIN, w - 2))
        if box_w > w then box_w = w end
        local list_w = box_w - 2
        if list_w < 4 then return hits end

        local body = {}
        if failure then
            body[#body + 1] = fit(styles.alert, " каталог не прочитан:", list_w)
            local reason = wrap(tostring(failure), list_w - 2, 3)
            for _, piece in ipairs(reason) do
                body[#body + 1] = fit(styles.alert, " " .. piece, list_w)
            end
        else
            body[#body + 1] = fit(styles.face_dim, " приложения не зарегистрированы", list_w)
        end
        if #body > room then for index = #body, room + 1, -1 do body[index] = nil end end
        panel(canvas, 1, h - 1 - (#body + 2) + 1, box_w, body, false)
        return hits
    end

    local root = new_node()
    for index, item in ipairs(catalog) do place(root, index, item) end

    -- Раскрытые уровни. Путь, который больше не разрешается (папку удалили
    -- вместе с модулем), обрывается молча: показать три панели вместо двух
    -- нельзя, а ругаться на исчезнувшую папку не за что.
    local path = type(open) == "table" and open or {}
    local levels: any = {root}
    local names = {}
    for _, name in ipairs(path) do
        if #levels > MAX_DEPTH then break end
        local node = levels[#levels].groups[name]
        if not node then break end
        levels[#levels + 1] = node
        names[#names + 1] = name
    end

    local left, parent_row = 1, 0

    for level, node in ipairs(levels) do
        local lines: any = panel_lines(node)
        if level == 1 then
            lines[#lines + 1] = {kind = "hint", text = "цифра — открыть · esc — закрыть"}
        end

        -- Ширина панели — по самой длинной подписи, не по константе:
        -- каскад из трёх панелей одинаковой ширины съедает экран, а узкая
        -- панель обрезает имена, которые в ней одни и есть.
        local widest = 0
        for _, line in ipairs(lines) do
            local text, tail = line_text(line)
            local size = cells(text) + cells(tail) + 1
            if size > widest then widest = size end
        end

        local banner_w = 0
        if level == 1 and widest + 2 + 2 <= w and widest + 2 >= MENU_BANNER_AT then banner_w = 2 end
        local box_w = widest + banner_w + 2
        if box_w < MENU_MIN then box_w = MENU_MIN end
        if box_w > w - left + 1 then box_w = w - left + 1 end
        if box_w > w then box_w = w end
        local list_w = box_w - 2 - banner_w
        if list_w < 4 then break end

        if #lines > room then
            local shown = 0
            for index = 1, room - 1 do
                if lines[index].kind == "item" then shown = shown + 1 end
            end
            for index = #lines, room, -1 do lines[index] = nil end
            lines[room] = {kind = "hint", text = "…ещё " .. (#node.programs - shown)}
        end

        local box_h = #lines + 2
        -- Корневая панель стоит над «Пуском»; подменю выравнивается своей
        -- первой строкой по строке той папки, которая его раскрыла.
        local top
        if level == 1 then
            top = h - 1 - box_h + 1
        else
            top = parent_row - 1
            if top + box_h - 1 > h - 1 then top = h - 1 - box_h + 1 end
        end
        if top < 1 then top = 1 end

        local body = {}
        for index, line in ipairs(lines) do
            local row = top + index
            local parts = {}

            if banner_w > 0 then
                -- Надпись читается снизу вверх, как повёрнутая на 90°.
                local slot = #lines - index + 1
                local letter = slot <= #MENU_BANNER and MENU_BANNER:sub(slot, slot) or " "
                parts[#parts + 1] = styles.banner:render(letter .. " ")
            end

            local text, tail = line_text(line)
            local style = styles.face
            if line.kind == "group" then
                style = styles.face_bold
                -- Раскрытая папка остаётся подсвеченной: иначе по каскаду
                -- не видно, из какой строки выехала правая панель.
                if names[level] ~= nil and line.text == names[level] then style = styles.select end
            elseif line.kind == "hint" then
                style = styles.face_dim
            end

            local head = clip(text, math.max(0, list_w - cells(tail)))
            parts[#parts + 1] = style:render(head
                .. string.rep(" ", list_w - cells(head) - cells(tail)) .. tail)

            if line.kind == "item" then
                hits[#hits + 1] = {
                    row = row, from = left + 1 + banner_w,
                    to = left + box_w - 2, index = line.index,
                }
            elseif line.kind == "group" then
                local target = {}
                for step = 1, level - 1 do target[step] = names[step] end
                target[level] = line.text
                hits[#hits + 1] = {
                    row = row, from = left + 1 + banner_w,
                    to = left + box_w - 2, open = target, level = level,
                }
                if names[level] ~= nil and line.text == names[level] then parent_row = row end
            end

            body[#body + 1] = table.concat(parts)
        end

        panel(canvas, left, top, box_w, body, false)

        -- Следующая панель встаёт справа от этой.
        left = left + box_w
        if left > w then break end
    end

    return hits
end

-- ─── Пустой стол ─────────────────────────────────────────────────────────

-- Подсказка на пустом столе — серая табличка посреди бирюзового: белый текст
-- прямо на столе читается как обои, а не как сообщение.
function chrome.empty_desktop(canvas, width: any, height: any, text)
    local w, h = whole(width), whole(height)
    if w < 6 or h < 3 then return end

    local message = clip(text or "", w - 4)
    local box_w = cells(message) + 4
    if box_w > w then box_w = w end
    local left = (w - box_w) // 2 + 1
    if left < 1 then left = 1 end
    local top = h // 2 - 1
    if top < 1 then top = 1 end

    panel(canvas, left, top, box_w, {fit(styles.face, " " .. message, box_w - 2)}, false)
end

return chrome
