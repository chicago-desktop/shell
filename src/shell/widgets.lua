-- Примитивы Windows 95, не знающие про экран.
--
-- Отдельная библиотека, потому что рисуют ими ДВОЕ. Тема рисует рамку окна
-- и панель задач; окно «Мой компьютер» рисует внутри себя строку меню,
-- панель инструментов, вкладки и статусную строку — и делает это само, в
-- свой viewport, ничего не зная про тему. Своя копия объёма у второго
-- разошлась бы с рамкой вокруг него, и разошлась бы ВИДОМ, а не отказом:
-- две почти одинаковые кнопки замечают через неделю.
--
-- Граница проведена так: здесь то, что рисуется по своим координатам и не
-- спрашивает, какой ширины экран. Всё, что знает про экран целиком, —
-- рамка окна, панель задач, меню «Пуск», значки стола — остаётся в теме.
--
-- Цель рисования — любой `tty.canvas`: и тот, что держит композитор, и тот,
-- что окно заводит себе. Это один и тот же тип, поэтому сечение проходит
-- здесь, а не по границе процессов.

local tty = require("tty")
local text_lib = require("text")

local glyphs = require("glyphs")
local palette = require("palette")

local color = palette.active

local scroll = require("scroll")
local widgets = {}

-- ─── Мерки ───────────────────────────────────────────────────────────────

function widgets.whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local whole = widgets.whole

-- Ширина считается в ЯЧЕЙКАХ. `#строка` считает байты и не видит SGR: на
-- кириллице врёт вдвое, на стилизованном тексте — втрое.
function widgets.cells(text): integer
    return whole(tty.text.width(text))
end

local cells = widgets.cells

function widgets.clip(text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    return tty.text.truncate(tostring(text or ""), width)
end

local clip = widgets.clip

-- fit(style, text, room) — строка РОВНО в `room` ячеек одним стилем.
--
-- Дополнять пробелами приходится вручную: `style:width(n)` кладёт свой фон
-- под чужие SGR-последовательности только до первого сброса, и хвост строки
-- остаётся с фоном терминала — на серой панели это видно как дыра.
function widgets.fit(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local clipped = clip(text, width)
    local gap = width - cells(clipped)
    if gap > 0 then clipped = clipped .. string.rep(" ", gap) end
    return style:render(clipped)
end

local fit = widgets.fit

function widgets.centered(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local body = clip(text, width)
    local left = (width - cells(body)) // 2
    return style:render(string.rep(" ", left) .. body
        .. string.rep(" ", width - left - cells(body)))
end

-- runes(text) — разбор на символы. Нужен там, где важен НОМЕР символа, а не
-- его смещение в байтах: подчёркнутая буква акселератора — четвёртая буква,
-- а не четвёртый байт, и на кириллице это разные места.
local runes = text_lib.runes

-- ─── Стили ───────────────────────────────────────────────────────────────
--
-- Общая таблица, а не копия у каждого: два одинаковых серых на глаз
-- отличаются, а в коде — нет.
-- Стили — ОДНА таблица на всю оболочку.
--
-- Их было две: эта и своя у темы, почти такая же. Разошлись они не сразу, и
-- обнаружилось это отказом на живом стенде: пиксельная тема взяла
-- `widgets.styles.desktop`, которого здесь не было, потому что бирюзовый стол
-- лежал в чужой копии. Две таблицы одного и того же расходятся ровно на тех
-- ключах, которые редко нужны обеим.
widgets.styles = {
    -- Рабочий стол. Здесь, а не у темы: им красит и тема, и пиксельная
    -- заливка, и обе обязаны брать один и тот же цвет.
    desktop        = tty.style():background(color.desktop),
    desktop_text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
    desktop_broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
    -- Заголовок окна. Разница активного и неактивного — по ФОНУ, а не по
    -- яркости текста: иначе на тёмной теме терминала оба сливаются.
    title          = tty.style():bold():foreground(color.title_active_fg):background(color.title_active_bg),
    title_idle     = tty.style():foreground(color.title_idle_fg):background(color.title_idle_bg),
    banner         = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    face      = tty.style():foreground(color.face_text):background(color.face),
    face_bold = tty.style():bold():foreground(color.face_text):background(color.face),
    face_dim  = tty.style():foreground(color.shadow):background(color.face),
    accel     = tty.style():underline():foreground(color.face_text):background(color.face),
    light     = tty.style():foreground(color.light):background(color.face),
    shadow    = tty.style():foreground(color.shadow):background(color.face),
    frame     = tty.style():foreground(color.frame):background(color.face),
    etched    = tty.style():foreground(color.shadow):background(color.light),
    console   = tty.style():foreground(color.console_text):background(color.console_bg),
    field     = tty.style():foreground(color.field_text):background(color.field),
    select    = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    alert     = tty.style():bold():foreground(color.alert):background(color.face),
    farewell  = tty.style():bold():foreground(color.farewell_text):background(color.farewell_bg),
}
-- Цвет стола меняет человек («Свойства: Экран»), и стили, снятые с палитры
-- при загрузке, обязаны пересняться: иначе стол в ячейках останется
-- прежним, а значки в пикселях уже перекрасятся — два представления одного
-- значения разошлись бы молча.
function widgets.use_desktop(hex: any)
    color.desktop = tostring(hex)
    widgets.styles.desktop = tty.style():background(color.desktop)
    widgets.styles.desktop_text = tty.style():bold():foreground(color.desktop_text):background(color.desktop)
    widgets.styles.desktop_broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop)
end


local styles = widgets.styles

-- ─── Объём ───────────────────────────────────────────────────────────────
--
-- Объём даётся гранью в одну ячейку: светлая сверху и слева, тёмная снизу и
-- справа. Поменять их местами — получить вдавленную деталь тем же кодом; на
-- этом держится и нажатая кнопка, и утопленное поле.

-- bezel(body, sunken) — деталь с гранью слева и справа, в одну строку.
--
-- `body` приходит УЖЕ отрисованным: наложить стиль поверх стилизованной
-- строки значит обернуть её вторым SGR-конвертом, и первый же внутренний
-- сброс оставит хвост с фоном терминала. Ширина результата — ширина тела
-- плюс две ячейки.
function widgets.bezel(body, sunken)
    local left = sunken and styles.shadow or styles.light
    local right = sunken and styles.light or styles.shadow
    return left:render(glyphs.bevel.left) .. body .. right:render(glyphs.bevel.right)
end

local bezel = widgets.bezel

function widgets.edge_top(width: any, sunken)
    local w = whole(width)
    if w <= 0 then return "" end
    local style = sunken and styles.shadow or styles.light
    if w == 1 then return style:render(glyphs.bevel.corner_light) end
    return style:render(glyphs.bevel.corner_light .. string.rep(glyphs.bevel.top, w - 1))
end

function widgets.edge_bottom(width: any, sunken)
    local w = whole(width)
    if w <= 0 then return "" end
    local style = sunken and styles.light or styles.shadow
    if w == 1 then return style:render(glyphs.bevel.corner_shadow) end
    return style:render(string.rep(glyphs.bevel.bottom, w - 1) .. glyphs.bevel.corner_shadow)
end

-- panel(target, x, y, box_w, body, sunken) — прямоугольник с объёмом.
--
-- `body` — уже отрисованные строки РОВНО в `box_w - 2` ячеек. Высота —
-- `#body + 2`. Выпуклый и вдавленный отличаются только тем, какая грань
-- светлая: одна форма на меню, табличку, поле часов и поле списка. Три
-- разные таблички разъехались бы по виду на первой же правке.
function widgets.panel(target, x: any, y: any, box_w: any, body, sunken)
    local left, top, span = whole(x), whole(y), whole(box_w)
    if span < 3 then return end
    target:put(left, top, widgets.edge_top(span, sunken), span)
    for index, row in ipairs(body) do
        target:put(left, top + index, bezel(row, sunken), span)
    end
    target:put(left, top + #body + 1, widgets.edge_bottom(span, sunken), span)
end

-- Вдавленное поле под чужое содержимое: рисуется рамка, внутренность
-- остаётся вызывающему.
function widgets.field(target, x: any, y: any, box_w: any, box_h: any)
    local w, h = whole(box_w), whole(box_h)
    if w < 3 or h < 2 then return end
    local body = {}
    for row = 1, h - 2 do body[row] = styles.face:render(string.rep(" ", w - 2)) end
    widgets.panel(target, x, y, w, body, true)
end

-- ─── Части диалога ───────────────────────────────────────────────────────

-- accel(style, text, position) — текст с подчёркнутой буквой-акселератором.
--
-- Позиция считается в БУКВАХ. Нулевая или выходящая за строку означает
-- «акселератора нет» и отрисовывается обычным текстом: подчеркнуть не ту
-- букву хуже, чем не подчеркнуть ни одной — человек нажмёт её и ничего не
-- произойдёт.
function widgets.accel(style, text, position: any)
    local at = whole(position)
    local list = runes(text)
    if at < 1 or at > #list then return style:render(tostring(text)) end
    local head, tail = {}, {}
    for index = 1, at - 1 do head[#head + 1] = list[index] end
    for index = at + 1, #list do tail[#tail + 1] = list[index] end
    return style:render(table.concat(head))
        .. styles.accel:render(list[at])
        .. style:render(table.concat(tail))
end

-- Ширина кнопки: две грани, два пробела вокруг подписи и сама подпись;
-- у кнопки по умолчанию ещё две ячейки чёрного контура.
function widgets.button_width(label, opts): integer
    local extra = (type(opts) == "table" and opts.default) and 2 or 0
    return cells(tostring(label or "")) + 4 + extra
end

-- button(label, opts) — выпуклая кнопка в одну строку.
--
-- opts.pressed — нажата (грани меняются местами), opts.default — кнопка по
-- умолчанию: в Windows 95 у неё сверх объёма ещё чёрный контур, и это не
-- украшение, а единственный признак того, что сделает Enter.
-- opts.accel — номер подчёркиваемой буквы. opts.disabled — недоступная:
-- подпись тусклая (белой тени в ячейках нет, этчед — только в пикселях).
-- opts.focused — в фокусе: подпись инверсией, грани остаются; пунктирной
-- рамки в ячейках нарисовать нечем, а инверсия всей кнопки читалась бы как
-- выделенная строка списка.
--
-- `opts.room` is the cells the button has. Two bevels and a space on each
-- side are the full look; a caption that does not fit with the spaces is
-- drawn without them, and one that does not fit even so is cut, never
-- replaced by an ellipsis. So a four-cell calculator key shows "MC" whole
-- instead of " MC" with the right bevel cut off.
function widgets.button(label, opts)
    local options: any = type(opts) == "table" and opts or {}
    local caption = tostring(label or "")
    local text, lead = " " .. caption .. " ", 1
    local room = whole(options.room)
    if room > 0 then
        local inner = room - 2 - (options.default and 2 or 0)
        if cells(text) > inner then
            text, lead = cells(caption) <= inner and caption or clip(caption, math.max(0, inner)), 0
        end
    end
    local face = styles.face
    if options.disabled then face = styles.face_dim elseif options.focused then face = styles.select end
    local body = (options.accel and not options.disabled)
        and widgets.accel(face, text, whole(options.accel) + lead)
        or face:render(text)
    local out = bezel(body, options.pressed and true or false)
    if options.default then
        out = styles.frame:render(glyphs.bevel.left) .. out
            .. styles.frame:render(glyphs.bevel.right)
    end
    return out
end

-- etched(width) — разделитель диалога в одну строку.
--
-- Половинка блока красит верх ячейки цветом текста, низ — цветом фона:
-- тёмная грань над светлой, то есть настоящий этчед Windows 95, а не просто
-- тонкая черта. Двух строк на разделитель не нужно.
function widgets.etched(width: any)
    local w = whole(width)
    if w <= 0 then return "" end
    return styles.etched:render(string.rep(glyphs.shade.half_top, w))
end

-- ─── Полосы окна ─────────────────────────────────────────────────────────
--
-- Рисует их САМО окно, внутри своего viewport: пункты меню свои у каждого
-- окна, а «6 объектов» пересчитывается на каждое открытие папки. Отдай их
-- теме — и композитор начал бы знать про устройство чужого окна.

-- Строка меню: `File Edit View Help` с подчёркнутой буквой.
--
-- Возвращает попадания. Пункт, нарисованный без попадания, — это слово, по
-- которому щёлкают и ничего не происходит, а отличить его от «меню
-- сломалось» с экрана нельзя.
--
-- menu_hits(x, y, width, entries) -> {row, from, to, menu, index, accel}
-- Раскладка без отрисовки: по ней рисуют оба бэкенда окна и по ней же окно
-- считает щелчок — как у панели инструментов.
function widgets.menu_hits(x: any, y: any, width: any, entries): any
    local hits: any = {}
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 1 then return hits end
    local used = 0
    for index, entry in ipairs(type(entries) == "table" and entries or {}) do
        local record: any = entry
        local text = type(record) == "table" and tostring(record.text or "?") or tostring(record)
        local at = type(record) == "table" and whole(record.accel) or 1
        if at < 1 then at = 1 end
        local room = cells(" " .. text .. " ")
        if used + room > span then break end
        hits[#hits + 1] = {row = row, from = left + used, to = left + used + room - 1,
            menu = text, index = index, accel = at}
        used = used + room
    end
    return hits
end

function widgets.menu_bar(target, x: any, y: any, width: any, entries)
    local left, row, span = whole(x), whole(y), whole(width)
    local hits = widgets.menu_hits(x, y, width, entries)
    if span < 1 then return hits end

    local parts, used = {}, 0
    for _, entry in ipairs(hits) do
        local hit: any = entry
        -- Ведущий пробел сдвигает букву на одну: акселератор считается по
        -- ИМЕНИ пункта, а не по нарисованной строке.
        parts[#parts + 1] = widgets.accel(styles.face, " " .. hit.menu .. " ", hit.accel + 1)
        used = used + (hit.to - hit.from + 1)
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
    return hits
end

-- Панель инструментов: кнопки со значком и подписью в одну строку.
-- Раскладка панели инструментов БЕЗ отрисовки.
--
-- Вынесено, потому что читателей стало двое: рисует `widgets.toolbar`, а
-- раскладку окна считает `render.layout` — и считает до того, как что-то
-- нарисовано, потому что второй бэкенд рисует не в холст. Своя формула у
-- второго читателя дала бы кнопку на ячейку левее, чем выглядит.
--
-- Возвращает попадания и подписи: подпись нужна тому, кто будет рисовать,
-- чтобы не собирать её заново по тем же правилам.
-- `fixed` — ширина кнопки в ячейках, одна на все: пиксельная панель рисует
-- кнопки 23×22 по образцу Windows 95 и называет им место в ячейках сама,
-- а не по длине подписи, которой в пикселях нет.
function widgets.toolbar_hits(x: any, y: any, width: any, buttons, fixed: any?): any
    local hits: any = {}
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 3 then return hits end
    local fixed_room = whole(fixed)

    local used = 0
    for _, entry in ipairs(type(buttons) == "table" and buttons or {}) do
        local button: any = entry
        if button.sep then
            if used + 1 > span then break end
            used = used + 1
        else
            local icon = type(button.icon) == "string" and button.icon or glyphs.icons.program
            local label = type(button.label) == "string" and button.label or ""
            local text = label ~= "" and (" " .. icon .. " " .. label .. " ") or (" " .. icon .. " ")
            local room = fixed_room > 0 and fixed_room or cells(text) + 2
            if used + room > span then break end
            hits[#hits + 1] = {
                row = row, from = left + used, to = left + used + room - 1,
                id = button.id, text = text, icon = icon, label = label,
                pressed = button.pressed and true or false,
                -- Недоступная кнопка рисуется выцветшей, а не прячется, как в
                -- Windows 95: панель не меняет форму от того, что выделено.
                -- Щелчок по ней — не действие, и попадание это говорит.
                disabled = button.disabled and true or false,
                title = type(button.title) == "string" and button.title or label,
            }
            used = used + room
        end
    end
    return hits
end

function widgets.toolbar(target, x: any, y: any, width: any, buttons)
    local left, row, span = whole(x), whole(y), whole(width)
    local hits = widgets.toolbar_hits(x, y, width, buttons)
    if span < 3 then return hits end

    -- Рисуется по ТЕМ ЖЕ числам, что вернула раскладка: разделители между
    -- кнопками восстанавливаются по промежуткам, а не считаются заново.
    local parts, used = {}, 0
    for _, entry in ipairs(hits) do
        local button: any = entry
        local at = button.from - left
        while used < at do
            parts[#parts + 1] = styles.shadow:render(glyphs.bevel.left)
            used = used + 1
        end
        local face = button.disabled and styles.face_dim or styles.face
        parts[#parts + 1] = bezel(face:render(button.text), button.pressed)
        used = used + (button.to - button.from + 1)
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
    return hits
end

-- Адресная строка: подпись «Адрес», вдавленное поле со значком папки и
-- путём, справа кнопка ▾, раскрывающая список. Как у окна папки Windows 95
-- (там это выпадающий список на панели инструментов; в 98 — своя строка).
--
-- Возвращает попадания: `field` — само поле, `drop` — кнопка. Оба открывают
-- список: в Windows щелчок по полю выделяет текст, но текст здесь не
-- редактируется, и поле, которое ни на что не отвечает, хуже поля-кнопки.
widgets.ADDRESS_LABEL = " Address "
widgets.ADDRESS_DROP = " ▾ "

-- address_hits(x, y, width) -> {field, drop} | {}
--
-- Геометрия адресной строки в ячейках — ОДНА на оба бэкенда: по ней рисует
-- `address_bar`, по ней же пиксельный рисовальщик кладёт растр, и по ней
-- окно считает щелчок. Своя формула у любого из трёх дала бы кнопку ▾ на
-- ячейку левее, чем выглядит.
function widgets.address_hits(x: any, y: any, width: any): any
    local left, row, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    if span < 12 then return hits end
    local label_w = cells(widgets.ADDRESS_LABEL)
    local drop_w = cells(widgets.ADDRESS_DROP) + 2
    local field_w = span - label_w - drop_w
    if field_w < 4 then return hits end
    hits.field = {row = row, from = left + label_w, to = left + label_w + field_w - 1}
    hits.drop = {row = row, from = left + label_w + field_w, to = left + span - 1}
    return hits
end

function widgets.address_bar(target, x: any, y: any, width: any, text: any, icon: any?): any
    local left, row, span = whole(x), whole(y), whole(width)
    local hits: any = widgets.address_hits(x, y, width)
    if not hits.field then return hits end
    local field_w = hits.field.to - hits.field.from + 1

    local mark = type(icon) == "string" and icon ~= "" and icon or glyphs.icons.folder
    local body = fit(styles.field, " " .. mark .. " " .. tostring(text or ""), field_w - 2)
    local line = styles.face:render(widgets.ADDRESS_LABEL) .. bezel(body, true)
        .. bezel(styles.face:render(widgets.ADDRESS_DROP), false)
    target:put(left, row, line, span)
    return hits
end

-- dropdown_hits(x, y, width, count) -> строки списка: {row, from, to, index}
function widgets.dropdown_hits(x: any, y: any, width: any, count: any): any
    local left, top, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    local total = whole(count)
    if span < 6 or total < 1 then return hits end
    for index = 1, total do
        hits[#hits + 1] = {row = top + index, from = left, to = left + span - 1, index = index}
    end
    return hits
end

-- Выпадающий список: белое поле с рамкой, строка на пункт, текущий выделен.
-- Рисуется поверх того, что под ним, — как и положено списку.
-- Возвращает попадания строк: {row, from, to, index}.
function widgets.dropdown(target, x: any, y: any, width: any, items: any, current: any): any
    local left, top, span = whole(x), whole(y), whole(width)
    local hits: any = {}
    local list: any = type(items) == "table" and items or {}
    hits = widgets.dropdown_hits(x, y, width, #list)
    if #hits == 0 then return hits end
    local body = {}
    local chosen = whole(current)
    for index, item in ipairs(list) do
        local record: any = item
        local text = type(record) == "table" and tostring(record.title or "?") or tostring(record)
        local style = index == chosen and styles.select or styles.field
        body[#body + 1] = fit(style, " " .. text, span - 2)
    end
    widgets.panel(target, left, top, span, body, true)
    return hits
end

-- Статусная строка: вдавленные поля. Последнее забирает остаток — иначе на
-- широком окне справа остаётся полоса голого лица, и строка выглядит
-- недорисованной.
function widgets.statusbar(target, x: any, y: any, width: any, fields)
    local left, row, span = whole(x), whole(y), whole(width)
    if span < 3 then return end

    local list: any = type(fields) == "table" and fields or {}
    local parts, used = {}, 0
    for index, entry in ipairs(list) do
        local field: any = entry
        local text = type(field) == "table" and tostring(field.text or "") or tostring(field)
        local want = type(field) == "table" and whole(field.width) or 0
        if want <= 0 then want = cells(text) + 2 end
        if index == #list then want = span - used - 2 end
        if want < 1 then break end
        if used + want + 2 > span then want = span - used - 2 end
        if want < 1 then break end
        parts[#parts + 1] = bezel(fit(styles.face, " " .. text, want), true)
        used = used + want + 2
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end

    target:put(left, row, table.concat(parts), span)
end

-- Вертикальная полоса прокрутки: стрелка, дорожка с ползунком, стрелка.
--
-- Рисуется ТОЛЬКО когда есть что прокручивать. Полоса при полностью видимом
-- содержимом — обещание, что где-то есть ещё, и человек будет её тянуть.
--
-- `state`: first — первая видимая строка считая с нуля, visible — сколько
-- строк помещается, total — сколько их всего.
--
-- Возвращает попадания стрелок. Стрелка, по которой нельзя щёлкнуть, — та же
-- бутафория, что и кнопка, которая ничего не делает.
function widgets.scrollbar(target, x: any, y: any, box_h: any, state)
    local hits = {}
    local col, top, height = whole(x), whole(y), whole(box_h)
    if height < 3 then return hits end

    local bar: any = type(state) == "table" and state or {}
    local total = whole(bar.total)
    local visible = whole(bar.visible)
    if visible < 1 or total <= visible then return hits end

    local first = whole(bar.first)
    local last = total - visible
    if first < 0 then first = 0 end
    if first > last then first = last end

    target:put(col, top, styles.face:render(glyphs.scrollbar.up), 1)
    target:put(col, top + height - 1, styles.face:render(glyphs.scrollbar.down), 1)
    hits[#hits + 1] = {row = top, from = col, to = col, id = "scroll_up"}
    hits[#hits + 1] = {row = top + height - 1, from = col, to = col, id = "scroll_down"}

    -- Ползунок ростом не меньше одной ячейки: выродившись в ноль, он исчезает
    -- ровно там, где прокручивать больше всего.
    local track = height - 2
    local thumb_data = scroll.bar(first, total, visible, height)
    local thumb, offset = thumb_data.size, thumb_data.start - 1

    for row = 0, track - 1 do
        local inside = row >= offset and row < offset + thumb
        local glyph = inside and glyphs.scrollbar.thumb or glyphs.scrollbar.track
        target:put(col, top + 1 + row, styles.face:render(glyph), 1)
    end

    return hits
end

-- Вкладки со страницей под ними.
--
-- Весь приём — РАЗРЫВ: рамка страницы прерывается ровно под активной
-- вкладкой, и от этого вкладка сливается со страницей. Без разрыва это
-- просто ряд кнопок над прямоугольником, и какая выбрана — видно только по
-- жирности.
--
-- Рисует ряд вкладок, рамку страницы и её пустую внутренность; содержимое
-- страницы кладёт вызывающий по (x + 1, y + 2).
function widgets.tabs(target, x: any, y: any, box_w: any, box_h: any, labels, active: any)
    local hits = {}
    local left, top = whole(x), whole(y)
    local span, height = whole(box_w), whole(box_h)
    if span < 6 or height < 4 then return hits end

    local list: any = type(labels) == "table" and labels or {}
    local current = whole(active)
    if current < 1 then current = 1 end

    local parts, used = {}, 0
    local gap: any = {}
    for index, entry in ipairs(list) do
        local label = type(entry) == "table" and tostring(entry.text or "?") or tostring(entry)
        local text = " " .. label .. " "
        local room = cells(text) + 2
        if used + room > span then break end
        local style = index == current and styles.face_bold or styles.face_dim
        parts[#parts + 1] = bezel(style:render(text), false)
        hits[#hits + 1] = {row = top, from = left + used, to = left + used + room - 1,
                           index = index, tab = label}
        if index == current then gap.from, gap.to = used, used + room - 1 end
        used = used + room
    end
    if used < span then parts[#parts + 1] = styles.face:render(string.rep(" ", span - used)) end
    target:put(left, top, table.concat(parts), span)

    local edge = {}
    for column = 0, span - 1 do
        if gap.from ~= nil and column >= gap.from and column <= gap.to then
            edge[#edge + 1] = styles.face:render(" ")
        elseif column == 0 then
            edge[#edge + 1] = styles.light:render(glyphs.bevel.corner_light)
        else
            edge[#edge + 1] = styles.light:render(glyphs.bevel.top)
        end
    end
    target:put(left, top + 1, table.concat(edge), span)

    local blank = bezel(styles.face:render(string.rep(" ", span - 2)), false)
    for row = 2, height - 2 do
        target:put(left, top + row, blank, span)
    end
    target:put(left, top + height - 1, widgets.edge_bottom(span, false), span)

    return hits
end

return widgets
