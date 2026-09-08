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
    -- Окно с фиксированным размером (`meta.resizable: false`) не
    -- разворачивается, и кнопки «развернуть» у него нет — как у калькулятора
    -- Windows 95. Признак кладёт композитор основы из записи; фильтр здесь,
    -- а не третий набор в BUTTON_SETS: размер фиксируют и обычные окна, и
    -- служебные, и заводить по набору на каждое сочетание значило бы
    -- размножить таблицу, которая обязана оставаться одной.
    if spec.resizable == false then
        local kept = {}
        for _, button in ipairs(set) do
            if button.id ~= "maximize" then kept[#kept + 1] = button end
        end
        set = kept
    end
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
-- С этой ширины в меню помещается вертикальная надпись.
--
-- Было 26, и это оказалось выше, чем бывают наши панели: надпись не
-- показывалась практически никогда, а на эталонном кадре Windows 95 она есть
-- всегда. Порог оставлен, но опущен до ширины, на которой панель ещё не
-- выглядит стиснутой.
local MENU_BANNER_AT = 18
-- Надпись вдоль меню. Это НЕ Windows: оболочка рисует стенд wippy, и
-- баннер называет его. Десять знаков, как у оригинала, — ровно столько
-- строк отдаёт панель на низком экране.
local MENU_BANNER = "WIPPY 2026"

-- Надпись отдана наружу: пиксельная тема рисует её поворотом целой строки, а
-- не по буквам, и своя копия текста разошлась бы с этой — тем же способом,
-- каким разошлись две таблицы стилей.
--
-- Стоит ЗДЕСЬ, а не выше по файлу, и это не вкусовщина: присвоение,
-- написанное до объявления локальной, читает её как глобальную, то есть
-- кладёт `nil`. Ровно это и случилось при первой попытке — полоса рисовалась,
-- надписи в ней не было, отказа не происходило. Третий раз за ночь один и тот
-- же класс.
chrome.MENU_BANNER = MENU_BANNER

local START_LABEL = " " .. glyphs.icons.start .. " Пуск "

-- Стили общие с `widgets`, а не свои. Своя копия здесь БЫЛА и разошлась: в
-- ней жил бирюзовый стол, которого не было у соседей, и пиксельная тема упала
-- на нём в первый же живой запуск. Две таблицы одного и того же расходятся
-- ровно на тех ключах, которые редко нужны обеим.
local styles = widgets.styles

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
-- PTY windows need stable defaults through SGR 0/39/49, independent of the
-- outer terminal theme. Explicit application colors remain authoritative.
local console_colors = {foreground = color.console_text, background = color.console_bg}
function chrome.content_colors(window)
    if window.entry == "butschster.tui_desktop.desktop:window_pty" then return console_colors end
    return nil
end

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
    local defaults = chrome.content_colors(window)
    if defaults then
        local width = w - inset.left - inset.right
        local blank = styles.console:render(string.rep(" ", width))
        for row = inset.top, h - inset.bottom - 1 do
            canvas:put(x + inset.left, y + row, blank, width)
        end
    end
    if window.rows then
        local room = h - inset.top - inset.bottom
        local body = window.rows
        if #body > room then
            body = {}
            for row = 1, room do body[row] = window.rows[row] end
        end
        canvas:put_rows(x + inset.left, y + inset.top, body, w - inset.left - inset.right, defaults)
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

    -- Утопленное поле часов открывает окно, объявленное хостом.
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
    if clock_cells > 0 then
        parts[#parts + 1] = clock_render
        if chrome.clock_entry then
            hits[#hits + 1] = {row = row, from = w - clock_cells + 1, to = w,
                -- Заголовка здесь нет нарочно: окно называет его запись, и
                -- «Часы» поверх «Дата и время» читалось бы как другое окно.
                entry = chrome.clock_entry}
        end
    end

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
    return {names = {}, groups = {}, programs = {}, order = math.huge}
end

-- Папка меню задаётся путём в `meta.group`, а не отдельной записью: папка
-- без программ бессмысленна, а объявленная отдельно — разъезжается со своим
-- содержимым при удалении модуля. Глубже трёх уровней путь схлопывается: в
-- терминале четвёртый отступ уже не читается.
-- Путь папок приходит УЖЕ РАЗОБРАННЫМ — списком сегментов, а не строкой.
--
-- Разбирала его эта функция, и разбирала ВТОРОЙ раз: каталог
-- (`butschster.windows.programs:catalog`) уже сделал это, с обрезкой по
-- глубине и по пробелам, и клал сюда таблицу. Строкой она никогда не была,
-- поэтому `type(item.group) == "string"` не срабатывал ни разу — путь выходил
-- пустым, папка не заводилась, программа ложилась на верхний уровень.
--
-- Ни отказа, ни следа: программа ВИДНА, просто не там, где просили. Тот же
-- класс, что и `id` вместо `action` в попадании, и что две таблицы стилей:
-- два представления одного и того же, и расхождение молчит.
--
-- Своей обрезки по глубине здесь тоже больше нет. Она была вторым числом
-- рядом с `catalog.MAX_DEPTH`, а два числа одного смысла однажды поменяют
-- поодиночке. Глубину ограничивает тот, кто путь разбирает; каскад
-- останавливает ширина экрана, и это ограничение настоящее.
local function place(root, index, item)
    local node = root
    local path: any = type(item.group) == "table" and item.group or {}
    local order = order_of(item)
    for _, part in ipairs(path) do
        local name = tostring(part)
        if name ~= "" then
            local child = node.groups[name]
            if not child then
                child = new_node()
                node.groups[name] = child
                node.names[#node.names + 1] = name
            end
            -- Папка встаёт туда, где её самая ранняя программа: «Программы»
            -- выше «Настройки» потому, что так расставлены их пункты, а не
            -- по алфавиту — алфавит ставил бы наоборот. То же правило, что
            -- у `catalog.tree`: два порядка одного меню разъехались бы молча.
            if order < child.order then child.order = order end
            node = child
        end
    end
    node.programs[#node.programs + 1] = {index = index, item = item}
end

-- Строки одной панели: папки и программы ВМЕСТЕ, по `order`; папка стоит
-- там, где её самая ранняя программа. Раньше папки шли первыми всегда, и
-- «Мой компьютер» нельзя было положить над «Программами», как в Windows.
-- Между равными — папка раньше программы, дальше алфавит. Отступов нет
-- НАРОЧНО: вложенность показывает отдельная панель, а не сдвиг вправо.
-- Отступами дерево читается как список, и это была не мелочь — по списку
-- не видно, что папка раскрывается.
local function panel_lines(node)
    local lines = {}
    for _, name in ipairs(node.names) do
        lines[#lines + 1] = {kind = "group", text = name, order = node.groups[name].order}
    end
    for _, program in ipairs(node.programs) do
        lines[#lines + 1] = {
            kind = "item", index = program.index, item = program.item,
            text = title_of(program.item), order = order_of(program.item),
        }
    end
    table.sort(lines, function(left, right)
        if left.order ~= right.order then return left.order < right.order end
        if left.kind ~= right.kind then return left.kind == "group" end
        return left.text < right.text
    end)
    -- Разделитель — свойство СТРОКИ, а не программы: его просит либо сама
    -- программа (`separator_before`, так у «Завершения работы»), либо
    -- предыдущая (`separator_after` — так «Мой компьютер» отделяется от
    -- папок под ним). Папке просить нечем, поэтому считается здесь.
    for index, line in ipairs(lines) do
        local own = line.item and line.item.separator_before
        local prev = lines[index - 1]
        local after = prev and prev.item and prev.item.separator_after
        line.separator_before = (own or after) and true or nil
    end
    return lines
end

-- Подпись строки без стиля: нужна дважды — чтобы померить панель и чтобы её
-- нарисовать. Считать её в двух местах значит однажды померить одно, а
-- нарисовать другое.
local function line_text(line)
    if line.kind == "item" then
        local item = line.item
        -- Цифры перед пунктом здесь БЫЛИ и убраны нарочно. Их не было в
        -- Windows 95, и человек, открывающий программы мышью, читает колонку
        -- цифр как вопрос «а зачем они». Завелись они не от замысла, а от
        -- инструмента: пробник не умел мышь, и других способов открыть окно
        -- в проверке не было. Ограничение инструмента протекло в интерфейс —
        -- инструмент починен, цифры ушли.
        local icon = type(item.icon) == "string" and item.icon ~= "" and item.icon or glyphs.icons.unknown
        return " " .. icon .. " " .. line.text, ""
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
-- `cursor` — номер выделенной строки в САМОЙ ГЛУБОКОЙ раскрытой панели, с
-- единицы. Меню его не хранит: тема рисует кадр и ничего не помнит между
-- кадрами, а помнит композитор — он же двигает курсор стрелками.
--
-- Выделенная строка помечается в разметке попаданий полем `cursor`, и это
-- существенно: композитор не считает заново, что сейчас выбрано, а читает то,
-- что НАРИСОВАНО. Второй счёт разъехался бы с первым, и Enter открывал бы не
-- ту строку, которая подсвечена.
--
-- У каждого попадания есть `level` и `slot` — уровень панели и номер строки в
-- ней. По ним композитор зажимает курсор, не зная устройства панелей.
-- menu_layout(width, height, items, failure, open, cursor) -> раскладка
--
-- ЧТО и ГДЕ, без единой краски. Вынесено из отрисовки по той же причине, что
-- и раскладка проводника: рисующих стало двое — символы и пиксели, — и «одна
-- таблица» означает теперь раскладку. Два бэкенда, считающие каскад каждый
-- по-своему, разъедутся молча, и щелчок попадёт на соседний пункт в одном из
-- двух режимов.
--
-- Отдаёт `{panels, hits, notice}`:
--
--   panels  список панелей от корня наружу: x, y, w, h, ширина колонки,
--           ширина вертикальной надписи и строки с их видом
--   hits    разметка попаданий, как раньше
--   notice  панель отказа или пустого каталога, когда каскада нет вовсе
function chrome.menu_layout(width: any, height: any, items, failure, open, cursor: any, metrics: any): any
    local out: any = {panels = {}, hits = {}, notice = nil}
    local sizing: any = type(metrics) == "table" and metrics or {}
    local compact = sizing.compact == true
    local minimum = compact and 12 or MENU_MIN
    local padding = compact and 0 or 2
    local w, h = whole(width), whole(height)
    if w < 8 or h < 4 then return out end

    local catalog = type(items) == "table" and items or {}
    local bottom = h - math.max(1, whole(sizing.bottom or 1))
    local room = bottom - 2
    if room < 1 then return out end

    -- Отказ реестра и пустой каталог обязаны различаться на экране:
    -- одинаковый вид отправляет человека искать ошибку в своём приложении,
    -- где её нет. Обоим хватает одной панели — каскаду тут неоткуда взяться.
    if failure or #catalog == 0 then
        local box_w = math.min(MENU_WIDTH, math.max(MENU_MIN, w - 2))
        if box_w > w then box_w = w end
        local list_w = box_w - 2
        if list_w < 4 then return out end

        local body = {}
        if failure then
            body[#body + 1] = {text = " каталог не прочитан:", alert = true}
            for _, piece in ipairs(wrap(tostring(failure), list_w - 2, 3)) do
                body[#body + 1] = {text = " " .. piece, alert = true}
            end
        else
            body[#body + 1] = {text = " приложения не зарегистрированы", dim = true}
        end
        if #body > room then for index = #body, room + 1, -1 do body[index] = nil end end

        out.notice = {x = 1, y = bottom - (#body + 2) + 1, w = box_w, h = #body + 2,
                      list_w = list_w, lines = body}
        return out
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
        local node = levels[#levels].groups[name]
        if not node then break end
        levels[#levels + 1] = node
        names[#names + 1] = name
    end

    local left, parent_row = 1, 0
    local deepest = #levels
    local at = whole(cursor)

    for level, node in ipairs(levels) do
        -- Номер строки внутри панели. Считается ЗДЕСЬ, а не по индексу в
        -- списке строк: подсказки и обрезка «…ещё N» строками тоже занимают
        -- место, а выбирать их нельзя.
        local slot = 0
        local lines: any = panel_lines(node)

        -- Ширина панели — по самой длинной подписи, не по константе:
        -- каскад из трёх панелей одинаковой ширины съедает экран, а узкая
        -- панель обрезает имена, которые в ней одни и есть.
        local widest = 0
        for _, line in ipairs(lines) do
            local text, tail = line_text(line)
            local size = cells(text) + cells(tail) + 1
            if type(sizing.measure) == "function" then
                size = whole(sizing.measure(tostring(line.text or "")))
            end
            if size > widest then widest = size end
        end

        local banner_w = 0
        if level == 1 and widest + 2 + 2 <= w and widest + 2 >= MENU_BANNER_AT then banner_w = 2 end
        local box_w = widest + banner_w + 2
        if box_w < minimum then box_w = minimum end
        if box_w > w - left + 1 then box_w = w - left + 1 end
        if box_w > w then box_w = w end
        local list_w = box_w - 2 - banner_w
        if list_w < 4 then break end

        local span = math.max(1, whole(level == 1 and sizing.root_rows or sizing.item_rows or 1))
        local capacity = math.max(1, room // span)
        if #lines > capacity then
            local last: any = lines[#lines]
            local footer = level == 1 and last.item and last.item.action == "quit" and last or nil
            local keep = math.max(0, capacity - (footer and 2 or 1))
            local hidden = #lines - keep - (footer and 1 or 0)
            for index = #lines, keep + 1, -1 do lines[index] = nil end
            if capacity > 1 or not footer then
                lines[#lines + 1] = {kind = "hint", text = "…ещё " .. hidden}
            end
            if footer then lines[#lines + 1] = footer end
        end

        local box_h = #lines * span + padding
        -- Корневая панель стоит над «Пуском»; подменю выравнивается своей
        -- первой строкой по строке той папки, которая его раскрыла.
        local top
        if level == 1 then
            top = bottom - box_h + 1
        else
            top = parent_row - (compact and 0 or 1)
            if top + box_h - 1 > bottom then top = bottom - box_h + 1 end
        end
        if top < 1 then top = 1 end

        local painted: any = {x = left, y = top, w = box_w, h = box_h,
                              list_w = list_w, banner = banner_w, level = level, lines = {}}

        for index, line in ipairs(lines) do
            local row = top + (index - 1) * span + (compact and 0 or 1)
            local text, tail = line_text(line)
            local selectable = line.kind == "item" or line.kind == "group"
            if selectable then slot = slot + 1 end
            local under_cursor = selectable and level == deepest and at > 0 and slot == at
            local expanded = line.kind == "group" and names[level] ~= nil
                and line.text == names[level]

            local letter = " "
            if banner_w > 0 then
                -- Надпись читается снизу вверх, как повёрнутая на 90°.
                -- Переменная названа НЕ `slot` нарочно: `slot` в этой же
                -- функции — номер выбираемой строки, и одно имя на два разных
                -- числа рано или поздно окажется прочитано не тем.
                local letter_at = #lines - index + 1
                if letter_at <= #MENU_BANNER then
                    letter = MENU_BANNER:sub(letter_at, letter_at)
                end
            end

            -- `label` и `text` — РАЗНЫЕ вещи, и различие не косметическое.
            -- `text` несёт значок символом (`▢`, `▤`) и годится только для
            -- ячеек. В шрифте геометрических символов нет: «отсутствующая
            -- руна advance-ится пробелом», то есть в пикселях на их месте
            -- пустота — на первом же снимке меню это и вышло. Пиксельный
            -- бэкенд рисует значок примитивом и берёт `label`.
            painted.lines[#painted.lines + 1] = {
                kind = line.kind, text = text, tail = tail, row = row, rows = span,
                label = tostring(line.text or ""),
                entry = line.item and line.item.entry, image = line.item and line.item.image,
                separator_before = line.separator_before,
                arrow = line.kind == "group",
                selected = under_cursor or expanded, bold = line.kind == "group",
                dim = line.kind == "hint", banner_letter = letter,
            }

            if line.kind == "item" then
                out.hits[#out.hits + 1] = {
                    row = row, bottom_row = span > 1 and row + span - 1 or nil, from = left + 1 + banner_w,
                    to = left + box_w - 2, index = line.index,
                    level = level, slot = slot, cursor = under_cursor or nil,
                }
            elseif line.kind == "group" then
                local target = {}
                for step = 1, level - 1 do target[step] = names[step] end
                target[level] = line.text
                out.hits[#out.hits + 1] = {
                    row = row, bottom_row = span > 1 and row + span - 1 or nil, from = left + 1 + banner_w,
                    to = left + box_w - 2, open = target,
                    level = level, slot = slot, cursor = under_cursor or nil,
                }
                if expanded then parent_row = row end
            end
        end

        out.panels[#out.panels + 1] = painted

        -- Следующая панель встаёт справа от этой.
        left = left + box_w
        if left > w then break end
    end

    return out
end

function chrome.menu(canvas, width: any, height: any, items, failure, open, cursor: any)
    local shown = chrome.menu_layout(width, height, items, failure, open, cursor, nil)

    if shown.notice then
        local body = {}
        for _, line in ipairs(shown.notice.lines) do
            local style = line.alert and styles.alert or styles.face_dim
            body[#body + 1] = fit(style, line.text, shown.notice.list_w)
        end
        panel(canvas, shown.notice.x, shown.notice.y, shown.notice.w, body, false)
        return shown.hits
    end

    for _, entry in ipairs(shown.panels) do
        local box: any = entry
        local body = {}
        for _, item in ipairs(box.lines) do
            local line: any = item
            local parts = {}
            if box.banner > 0 then
                parts[#parts + 1] = styles.banner:render(line.banner_letter .. " ")
            end

            local style = styles.face
            if line.bold then style = styles.face_bold end
            if line.dim then style = styles.face_dim end
            if line.selected then style = styles.select end

            local head = clip(line.text, math.max(0, box.list_w - cells(line.tail)))
            parts[#parts + 1] = style:render(head
                .. string.rep(" ", box.list_w - cells(head) - cells(line.tail)) .. line.tail)
            body[#body + 1] = table.concat(parts)
        end
        panel(canvas, box.x, box.y, box.w, body, false)
    end

    return shown.hits
end

-- ─── Пустой стол ─────────────────────────────────────────────────────────

-- Подсказка на пустом столе — серая табличка посреди бирюзового: белый текст
-- прямо на столе читается как обои, а не как сообщение.
-- Экран прощания после «Завершения работы»: чёрный экран и надпись, которую
-- Windows 95 показывала, когда уже можно выключать питание. Композитор
-- держит его FAREWELL_HOLD секунд и только потом гасит приложение — так
-- выключение выглядит выключением, а не обрывом.
chrome.FAREWELL_HOLD = 5
chrome.FAREWELL_TEXT = "Теперь питание компьютера можно отключить."

function chrome.farewell(canvas, width: any, height: any)
    canvas:clear(styles.farewell:render(" "))
    local w, h = whole(width), whole(height)
    if w < 4 or h < 1 then return nil end
    local message = clip(chrome.FAREWELL_TEXT, w - 2)
    local span = cells(message)
    local left = (w - span) // 2 + 1
    if left < 1 then left = 1 end
    local row = h // 2
    if row < 1 then row = 1 end
    canvas:put(left, row, styles.farewell:render(message), span)
    return nil
end

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
