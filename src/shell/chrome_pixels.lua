-- Пиксельная тема оболочки: то, что человек видит вместо сетки символов.
--
-- Отдельная запись, а не ветка внутри `chrome`, по тому же правилу, что и у
-- проводника: запись, объявившая `gfx`, на рантайме без него не грузится
-- ЦЕЛИКОМ. Положи пиксели в `chrome` — путь в ячейках умер бы вместе с
-- графикой, и запасного пути (FR-005 §8б) не осталось бы.
--
-- ─── ЗАЛИВКА ОСТАЁТСЯ ЯЧЕЙКАМИ, И ЭТО ГЛАВНОЕ ЗДЕСЬ ─────────────────────
--
-- Бирюзовый стол, серое лицо панели задач, фон меню — это стили ЯЧЕЕК, а не
-- картинки (FR-005 §3а). Пикселями рисуется только то, чья граница проходит
-- ВНУТРИ ячейки: фаски, значки, подписи.
--
-- Причина в цене: она идёт от числа пикселей, а не от сложности картинки.
-- Одноцветный стол 1000×540 кодируется 43 мс и весит 2.6 КБ — кодировщик
-- обходит каждый пиксель. А растр во весь стол накрывает строки содержимого
-- окон, и любое нажатие клавиши в bash перерисовывает эти строки, то есть
-- отправляет стол заново. Сорок семь миллисекунд на нажатие — ровно то, ради
-- ухода от чего мы и не рисуем весь экран.
--
-- `fill` заливает стол ячейками; `window_background` заливает каждое окно
-- перед его содержимым; `paint` возвращает растры и попадания.
--
-- ─── ЧТО НАРЕЗАНО ПО СТРОКАМ ────────────────────────────────────────────
--
-- Рамка окна режется на четыре куска (FR-005 §3), потому что боковые грани
-- делят строки с содержимым и уезжают на каждое нажатие, а заголовок и низ —
-- нет. Панель задач лежит на своей строке, куда окна не заходят. Каждый
-- значок стола — своё размещение: значок меняется, когда его переставили или
-- выделили, и не тянет за собой соседей.

local gfx = require("gfx")

local chrome = require("chrome")
local palette = require("palette")
local pixels = require("pixels")
local rasters = require("rasters")
local widgets = require("widgets")
local explorer_layout = require("explorer_layout")
local explorer_pixels = require("explorer_pixels")

-- Окна-виды: содержимое рисует не процесс, а чистая библиотека `render`,
-- названная в записи окна (FR-005 §4б). Композитор её позвать не может —
-- `require` умеет только объявленные imports, а не произвольный id из
-- реестра, — поэтому зовёт тема, и каждая такая библиотека импортирована
-- здесь СТАТИЧЕСКИ и названа в VIEWS по id своей записи. Окно, назвавшее
-- render, которого в VIEWS нет, получает не пустоту, а текст с причиной.
local picture_render = require("picture_render")
local sdk_render = require("sdk_render")

local color = palette.exact

local chrome_pixels = {}

-- Тема хранит растры между кадрами, и хранить их больше негде: контракт
-- `paint` состояния не носит. Значит это состояние модуля, по одному на
-- процесс — а процесс здесь один, оболочка.
local store = rasters.store()
local clients: any = {}

-- Признак для композитора: по нему он решает, что тема умеет пиксели.
chrome_pixels.pixel = true
chrome_pixels.content_colors = chrome.content_colors

-- Панель задач снизу, стол сверху. Пиксельная сетка учитывает размер ячейки.
local geometry = require("geometry")
local whole = geometry.whole

-- Paint and input share these cell rectangles. Pixel decoration stays inside.
local unit: any = {w = 10, h = 20}

-- id записи render → библиотека. Контракт у всех один:
--   lib.placement(window, inner, cell, fonts, store) -> размещение | список | nil, причина
-- `inner` — прямоугольник ВНУТРИ рамки в ячейках, `cell` — размер ячейки,
-- `fonts` — {face, bold} темы, `store` — хранилище растров темы (кто взял
-- растр из него, того размещение и переживёт кадр без своего хранилища).
-- Explorer shares layout with its controller and keeps four cached slices.
local function explorer_placement(window: any, inner: any, cell: any, fonts: any)
    local client = clients[window.id] or rasters.store()
    clients[window.id] = client
    local state: any = window.content_state or {title = "My Computer", objects = {}}
    local plan = explorer_layout.layout(state, inner.cols, inner.rows,
        explorer_layout.pixel_metrics(cell.w, cell.h))
    local placed = explorer_pixels.paint(client, plan, cell, fonts, "client:" .. window.id)
    for _, placement in ipairs(placed) do
        placement.x = placement.x + inner.x - 1
        placement.y = placement.y + inner.y - 1
    end
    return placed
end

local VIEWS: any = {
    ["butschster.windows.sdk:render"] = sdk_render,
    ["butschster.windows.explorer:render_pixels"] = {placement = explorer_placement},
    ["butschster.windows.viewers:picture_render"] = picture_render,
}
function chrome_pixels.forget(id)
    picture_render.forget(id)
end
function chrome_pixels.renders(reference)
    return VIEWS[tostring(reference)] ~= nil
end

-- Метрики заголовка — по Windows 95, в пикселях: над синей полосой две
-- строки рамки (лицо и свет), сама полоса 18 px, кнопки 16×14 в двух
-- пикселях от её краёв, рамка окна четыре пикселя.
--
-- Полоса живёт в ОДНОЙ строке терминала, пока строка не ниже 16 px, и
-- ужимается под неё: при ячейке в 20 px это ровно 18 px оригинала, при 16 —
-- 14 px с кнопками 12×10. Иначе заголовок брал бы две строки и оставлял под
-- собой серую ленту, которую читают как ошибку; вторую строку полоса берёт
-- только там, где в одну не входит и 14 px (ячейка ниже 16).
local TITLE_TOP = 3
local TITLE_HEIGHT = 18
local TITLE_LEAST = 14
local TITLE_BUTTON_H = 14
-- Синий зазор между кнопкой и рамкой; ширина рамки окна.
local TITLE_MARGIN = 2
local FRAME = 4
local function header_rows(): integer
    return whole(math.max(1, (TITLE_TOP - 1 + TITLE_LEAST + whole(unit.h) - 1) // whole(unit.h)))
end
local function title_height(): integer
    local room = header_rows() * whole(unit.h) - (TITLE_TOP - 1)
    return whole(math.max(TITLE_LEAST, math.min(TITLE_HEIGHT, room)))
end
-- Кнопка на четыре пикселя ниже полосы и на два шире своей высоты: 16×14
-- при полосе в 18, 12×10 при 14.
local function button_size(): (integer, integer)
    local h = whole(title_height() - (TITLE_HEIGHT - TITLE_BUTTON_H))
    return h + 2, h
end

function chrome_pixels.use_cell_size(w: any, h: any)
    unit = {w = math.max(1, whole(w)), h = math.max(1, whole(h))}
end

local function taskbar_rows(): integer
    return whole(math.max(1, (28 + whole(unit.h) - 1) // whole(unit.h)))
end

function chrome_pixels.layout(width: any, height: any)
    return {top = 0, bottom = taskbar_rows()}
end

function chrome_pixels.window_insets(window)
    return {top = header_rows(), bottom = 1, left = 1, right = 1}
end

function chrome_pixels.icon_grid()
    local drawn = math.max(3, (68 + whole(unit.h) - 1) // whole(unit.h))
    return {w = math.max(6, (88 + whole(unit.w) - 1) // whole(unit.w)),
            h = drawn, drawn = drawn, left = 2}
end

-- Кнопки заголовка: «свернуть» и «развернуть» стоят вплотную, «закрыть» —
-- отдельно, в двух синих пикселях от рамки. Всё это в пикселях, а мышь ходит
-- в ячейках, поэтому каждая кнопка получает СВОИ ячейки и рисуется только
-- внутри них: пиксель одной кнопки в ячейке соседки нажимал бы соседку.
--
-- Отсюда единственное отступление от оригинала при ячейке в 10 px: слитная
-- пара делится ровно по границе ячеек, а «закрыть» вместе с зазором и рамкой
-- должна уместиться в свои две ячейки — она на два пикселя уже, и просвет
-- перед ней четыре пикселя вместо двух. При ячейке в 8 px всё сходится
-- пиксель в пиксель.
function chrome_pixels.title_buttons(window: any): any
    local set = chrome.buttons_for(window)
    local out = {}
    if #set == 0 then return out end
    local cw = whole(unit.w)
    local bw, bh = button_size()
    local span = math.max(1, (bw + cw - 1) // cw)
    -- Последняя кнопка отдаёт до двух пикселей ширины прежде, чем возьмёт
    -- ещё ячейку.
    local last_span = span
    while last_span * cw - FRAME - TITLE_MARGIN < bw - 2 do last_span = last_span + 1 end
    local last_w = math.min(bw, last_span * cw - FRAME - TITLE_MARGIN)
    local total = (#set - 1) * span + last_span
    local from = whole(window.x) + whole(window.w) - total
    if from <= whole(window.x) + 3 then return out end
    local width = whole(window.w) * cw
    local top = TITLE_TOP + (title_height() - bh) // 2
    for index, button in ipairs(set) do
        local left = from + (index - 1) * span
        local cells = index == #set and last_span or span
        local rect: any
        if index == #set then
            rect = {x = width - FRAME - TITLE_MARGIN - last_w + 1, y = top, w = last_w, h = bh}
        else
            local start = (left - whole(window.x)) * cw + 1
            -- В слитной паре первая прижата к правому краю своих ячеек, вторая
            -- к левому: так они смыкаются ровно на границе ячеек.
            local joined = #set > 2 and index == #set - 1
            rect = {x = joined and start or start + span * cw - bw, y = top, w = bw, h = bh}
        end
        out[#out + 1] = {id = button.id, from = left, to = left + cells - 1, rect = rect,
            row = whole(window.y) + (rect.y - 1) // whole(unit.h),
            bottom_row = whole(window.y) + (rect.y + rect.h - 2) // whole(unit.h)}
    end
    return out
end

function chrome_pixels.title_button_at(window: any, x: any, y: any)
    for _, button in ipairs(chrome_pixels.title_buttons(window)) do
        if y >= button.row and y <= button.bottom_row and x >= button.from and x <= button.to then return button.id end
    end
    return nil
end

-- The compositor calls this immediately before each window's content, in z order.
function chrome_pixels.window_background(canvas, window: any)
    local style = chrome.content_colors(window) and widgets.styles.console
        or (window.window_type == "dialog" and widgets.styles.face or widgets.styles.field)
    local blank = style:render(string.rep(" ", math.max(0, whole(window.w))))
    for row = 0, whole(window.h) - 1 do
        canvas:put(whole(window.x), whole(window.y) + row, blank, whole(window.w))
    end
end

-- ─── заливка ячейками ────────────────────────────────────────────────────
--
-- Ровно то же, что делает `chrome.fill` в режиме символов, и НИЧЕГО больше:
-- значков здесь нет, они пикселями.
function chrome_pixels.fill(canvas, width: any, height: any, state)
    canvas:clear(widgets.styles.desktop:render(" "))

    local h = whole(height)
    local w = whole(width)
    if h < 1 or w < 1 then return {} end
    if type(state) == "table" and state.bare then return {} end

    -- Лицо панели задач: под картинками всё равно будут пробелы, но строка,
    -- не закрашенная лицом, светится цветом терминала в промежутках между
    -- размещениями.
    for row = math.max(1, h - taskbar_rows() + 1), h do
        canvas:put(1, row, widgets.styles.face:render(string.rep(" ", w)), w)
    end
    return {}
end

-- Экран прощания пикселями: чёрная заливка ячейками, надпись — растром
-- полужирным шрифтом темы. Без шрифта — надпись ячейками, как в теме
-- символов; чёрный экран без слов читался бы как повисший терминал.
chrome_pixels.FAREWELL_HOLD = chrome.FAREWELL_HOLD

-- farewell_raster(cell, width, height) -> растр, колонка, строка | nil
--
-- Надпись крупным шрифтом в две-три строки по центру, как в оригинале. Отдельно
-- от `farewell`, чтобы PNG-пробник мог нарисовать её без холста.
function chrome_pixels.farewell_raster(cell: any, width: any, height: any): (any, any, any)
    local fonts: any = chrome_pixels.fonts
    local font: any = type(fonts) == "table" and (fonts.display or fonts.bold or fonts.face) or nil
    if not font then return nil, nil, nil end
    local w, h = whole(width), whole(height)
    local cw, ch = whole(cell.w), whole(cell.h)

    -- Строки ломаются по измеренной ширине, не шире двух третей экрана:
    -- в оригинале надпись занимает середину, а не тянется от края до края.
    local room = (w * cw) * 2 // 3
    local lines = pixels.wrap(font, chrome.FAREWELL_TEXT, room, 4)
    if #lines == 0 then return nil, nil, nil end
    local line_h = whole(font:height())
    local widest = 0
    for _, line in ipairs(lines) do
        widest = math.max(widest, whole(font:measure(line)))
    end
    local cols = (widest + cw - 1) // cw + 2
    local rows = (line_h * #lines + ch - 1) // ch + 1
    if cols > w or rows > h then return nil, nil, nil end

    local key = chrome.FAREWELL_TEXT .. "\31" .. tostring(font:size()) .. "\31" .. tostring(cols)
    local raster, dirty = store.take("farewell", cols, rows, cell, key)
    if dirty then
        raster:fill(color.farewell_bg)
        local top = (rows * ch - line_h * #lines) // 2
        for index, line in ipairs(lines) do
            local tw = whole(font:measure(line))
            raster:text((cols * cw - tw) // 2, top + (index - 1) * line_h, line,
                {font = font, color = color.farewell_text})
        end
    end
    return raster, (w - cols) // 2 + 1, math.max(1, (h - rows) // 2 + 1)
end

function chrome_pixels.farewell(canvas, width: any, height: any)
    canvas:clear(widgets.styles.farewell:render(" "))
    store.begin()
    local raster, col, row = chrome_pixels.farewell_raster(unit, width, height)
    if not raster then return chrome.farewell(canvas, width, height) end
    store.place("farewell", col, row)
    return {placements = store.frame(unit), hits = {desktop = {}, bars = {}, menu = {}}}
end

-- ─── значки стола ────────────────────────────────────────────────────────

local function icon_key(item: any, selected)
    return table.concat({
        tostring(item.id), tostring(item.title or ""), tostring(item.kind or ""),
        tostring(item.icon or ""), tostring(item.image or ""), tostring(item.entry or ""), item.broken and "!" or "",
        selected and "1" or "0",
        -- Цвет стола запечён в растр значка: сменили цвет — растр другой.
        tostring(color.desktop),
    }, "\30")
end

-- Значок целиком: рисунок и подпись, каждый своим размещением.
--
-- Своё размещение у каждого значка нарочно. Один растр на весь стол стоил бы
-- сорока трёх миллисекунд и уезжал бы на каждое нажатие клавиши в окне,
-- которое накрыло хоть одну его строку.
local function paint_icon(cell: any, item: any, selected, grid: any)
    local id = "desk:" .. tostring(item.id)
    local cols = grid.w - 1
    local raster, dirty = store.take(id, cols, grid.drawn, cell, icon_key(item, selected))
    if dirty then
        local box = pixels.box(1, 1, cols, grid.drawn, cell)
        -- Фон совпадает с заливкой стола; перекрытые окнами части растра
        -- обрезаются перед размещением.
        raster:rect(1, 1, box.w, box.h, color.desktop)
        chrome_pixels.draw_icon(raster, box, item, selected)
    end
    return id, raster
end

-- Рисунок значка ВМЕСТЕ С ПОДПИСЬЮ.
--
-- Подпись здесь не украшение: значок без неё — это картинка, про которую
-- нечего сказать. Первый снимок всего экрана показал ровно это — ряд
-- безымянных квадратиков, — и не показал бы ни пробник, ни куски по
-- отдельности: каждый из них был правильным.
--
-- Выделение — инверсией по ТЕКСТУ, а не по всей колонке: в Windows 95 синий
-- прямоугольник обнимает подпись, и по нему видно, где она кончается.
function chrome_pixels.draw_icon(raster, box: any, item: any, selected)
    local side = 32
    local left = box.x + (box.w - side) // 2
    local top = box.y + 2
    pixels.icon(raster, left, top, item, 32)
    local fonts: any = chrome_pixels.fonts
    local face: any = type(fonts) == "table" and fonts.face or nil
    if not face then return end
    local lines = pixels.wrap(face, item.title, box.w - 4, 2)
    local at = top + side + 3
    for _, line in ipairs(lines) do
        local width = whole(face:measure(line))
        local from = box.x + (box.w - width) // 2
        if selected then raster:rect(from - 2, at - 1, width + 4, 15, color.select_bg) end
        local tint = selected and color.select_fg or color.desktop_text
        if item.broken and not selected then tint = color.desktop_broken end
        raster:text(from, at, line, {font = face, color = tint})
        at = at + 15
    end
end

-- ─── рамка окна ──────────────────────────────────────────────────────────

-- Содержимое окна-вида. Отказ любой природы — нет библиотеки, вид ещё ждёт
-- состояния, библиотека отказала — превращается в текст на лице окна, а не в
-- пустоту: пустое окно неотличимо от «вид нарисован, но данных нет», и
-- человек пойдёт искать поломку не там.
local function paint_view(cell: any, window: any, fonts: any, out, inner: any)
    local lib: any = VIEWS[tostring(window.render)]
    local state: any = type(window.content_state) == "table" and window.content_state or {}
    local placed: any, why: any = nil, nil
    if not lib then
        why = "no renderer for " .. tostring(window.render)
    elseif window.waiting then
        why = type(state.caption) == "string" and state.caption ~= "" and state.caption
            or "waiting for data…"
    else
        placed, why = lib.placement(window, inner, cell, fonts, store)
    end

    if type(placed) == "table" then
        if placed.raster then
            out[#out + 1] = placed
        else
            for _, item in ipairs(placed) do out[#out + 1] = item end
        end
        return
    end

    local face: any = type(fonts) == "table" and fonts.face or nil
    local id = "win:" .. tostring(window.id) .. ":notice"
    local text = tostring(why or "the view returned nothing")
    local raster, dirty = store.take(id, inner.cols, inner.rows, cell,
        text .. "\31" .. tostring(inner.cols) .. "x" .. tostring(inner.rows))
    if dirty then
        raster:fill(color.face)
        if face then
            local lines = pixels.wrap(face, text, inner.cols * cell.w - 16, 6)
            local top = 8
            for _, line in ipairs(lines) do
                raster:text(8, top, line, {font = face, color = color.face_text})
                top = top + 15
            end
        end
    end
    out[#out + 1] = {id = id, raster = raster, x = inner.x, y = inner.y,
                     cols = inner.cols, rows = inner.rows}
end

local function paint_window(cell: any, window: any, focused, fonts: any, out)
    local id = "win:" .. tostring(window.id)
    local w, h = whole(window.w), whole(window.h)
    local head_rows = header_rows()
    if w < 4 or h <= head_rows + 1 then return end
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face
    local inside = chrome.content_colors(window) and color.console_bg
        or ((window.window_type == "dialog" or window.content == "pixels") and color.face or color.field)
    local buttons = chrome_pixels.title_buttons(window)
    local key = table.concat({tostring(window.title), tostring(window.window_type), tostring(window.entry), tostring(window.image),
        focused and "1" or "0", window.maximized and "1" or "0",
        window.resizable == false and "fixed" or "free"}, "\30")
    local head_id = id .. ":head"
    local head, dirty = store.take(head_id, w, head_rows, cell, key)
    if dirty then
        local width, height = w * cell.w, head_rows * cell.h
        head:fill(inside)
        -- Рамка Windows 95: снаружи лицо и чёрный, внутри свет и тень —
        -- порядок обратный кнопке, у которой снаружи свет.
        head:rect(1, 1, width, TITLE_TOP - 1 + title_height(), color.face)
        head:rect(1, 1, FRAME, height, color.face)
        head:rect(width - FRAME + 1, 1, FRAME, height, color.face)
        head:rect(2, 2, width - 2, 1, color.light)
        head:rect(2, 2, 1, height - 1, color.light)
        head:rect(width - 1, 2, 1, height - 1, color.shadow)
        head:rect(width, 1, 1, height, color.frame)
        local title_top, title_h = TITLE_TOP, title_height()
        head:rect(FRAME + 1, title_top, width - FRAME * 2, title_h,
            focused and color.title_active_bg or color.title_idle_bg)
        -- Reserve actual title-button rectangles before clipping text.
        local text_right = #buttons > 0 and buttons[1].rect.x - 4 or width - FRAME - TITLE_MARGIN
        local caption_x = FRAME + 5
        -- Значок 16 px есть только там, где входит в полосу: в 14 px он
        -- лёг бы на рамку.
        if (window.window_type == nil or window.window_type == "app") and title_h >= 16 then
            pixels.icon(head, FRAME + 3, title_top + (title_h - 16) // 2, {kind = "window", image = window.image}, 16)
            caption_x = FRAME + 3 + 16 + 4
        end
        if bold then
            local caption = pixels.ellipsize(bold, window.title, text_right - caption_x)
            head:text(caption_x, title_top + (title_h - whole(bold:height())) // 2, caption,
                {font = bold, color = focused and color.title_active_fg or color.title_idle_fg})
        end
        for _, button in ipairs(buttons) do
            local rect = button.rect
            pixels.button(head, rect.x, rect.y, rect.w, rect.h, {}, cell)
            pixels.caption_mark(head, button.id, rect.x, rect.y, rect.w, rect.h, color.face_text)
        end
    end
    out[#out + 1] = {id = head_id, raster = head, x = window.x, y = window.y, cols = w, rows = head_rows}
    local body = h - head_rows - 1
    for _, side in ipairs({"left", "right"}) do
        local edge_id = id .. ":" .. side
        local edge, edge_dirty = store.take(edge_id, 1, body, cell, inside)
        if edge_dirty then
            local width, height = cell.w, body * cell.h
            edge:fill(inside)
            if side == "left" then
                edge:rect(1, 1, FRAME, height, color.face)
                edge:rect(2, 1, 1, height, color.light)
            else
                edge:rect(width - FRAME + 1, 1, FRAME, height, color.face)
                edge:rect(width - 1, 1, 1, height, color.shadow)
                edge:rect(width, 1, 1, height, color.frame)
            end
        end
        out[#out + 1] = {id = edge_id, raster = edge,
            x = side == "left" and window.x or window.x + w - 1,
            y = window.y + head_rows, cols = 1, rows = body}
    end
    local foot_id = id .. ":foot"
    local foot, foot_dirty = store.take(foot_id, w, 1, cell, inside)
    if foot_dirty then
        local width, height = w * cell.w, cell.h
        foot:fill(inside)
        foot:rect(1, 1, FRAME, height, color.face)
        foot:rect(width - FRAME + 1, 1, FRAME, height, color.face)
        foot:rect(1, height - FRAME + 1, width, FRAME, color.face)
        foot:rect(2, 1, 1, height - 2, color.light)
        foot:rect(2, height - 1, width - 2, 1, color.shadow)
        foot:rect(width - 1, 1, 1, height - 1, color.shadow)
        foot:rect(1, height, width, 1, color.frame)
        foot:rect(width, 1, 1, height, color.frame)
    end
    out[#out + 1] = {id = foot_id, raster = foot, x = window.x, y = window.y + h - 1, cols = w, rows = 1}

    -- Окно-вид: внутри рамки процесса нет, содержимое кладёт тема. Прямоугольник
    -- тот же, что получил бы viewport обычного окна, — по инсетам темы.
    if window.content == "pixels" and w > 2 and body > 0 then
        paint_view(cell, window, fonts, out,
            {x = window.x + 1, y = window.y + head_rows, cols = w - 2, rows = body})
    end
end

local function paint_bars(cell: any, state: any, fonts: any, out, hits)
    local w, h = whole(state.width), whole(state.height)
    local rows = taskbar_rows()
    local top = h - rows + 1
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face
    local key = {tostring(w), tostring(state.clock or ""), tostring(state.focused_id or ""),
                 (state.menu and not state.menu.anchor) and "open" or "closed"}
    for _, window in ipairs(state.windows or {}) do
        key[#key + 1] = tostring(window.id) .. ":" .. tostring(window.title)
            .. ":" .. tostring(window.image) .. ":" .. tostring(window.minimized)
    end
    local bar, dirty = store.take("bars", w, rows, cell, table.concat(key, "\30"))
    local width, height = w * whole(cell.w), rows * whole(cell.h)
    local button_h = height - 6
    local button_y = 1 + (height - button_h) // 2
    local start_span = math.max(6, (whole(bold and bold:measure("Start") or 28) + 44 + whole(cell.w) - 1) // whole(cell.w))
    if dirty then
        bar:fill(color.face)
        bar:rect(1, 1, width, 1, color.light)
        bar:rect(1, 2, width, 1, color.face)
        -- Та же кнопка, что везде: нажата, пока меню открыто.
        pixels.button(bar, 3, button_y, start_span * cell.w - 5, button_h,
            {label = "", pressed = state.menu ~= nil and state.menu.anchor == nil}, cell)
        local shift = (state.menu and not state.menu.anchor) and 1 or 0
        pixels.flag(bar, 9 + shift, button_y + (button_h - 16) // 2 + shift)
        if bold then bar:text(31 + shift, button_y + (button_h - 15) // 2 + shift,
            "Start", {font = bold, color = color.face_text}) end
    end
    hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
        from = 1, to = start_span, action = "menu"}
    local at = start_span + 1
    for _, window in ipairs(state.windows or {}) do
        local span = 16
        if at + span - 1 > w - 10 then break end
        if dirty then
            local left = (at - 1) * cell.w + 1
            local pressed = window.id == state.focused_id and not window.minimized
            local shift = pressed and 1 or 0
            pixels.button(bar, left, button_y, span * cell.w - 2, button_h,
                {id = window.id, label = "", font = face, pressed = pressed}, cell)
            pixels.icon(bar, left + 6 + shift, button_y + (button_h - 16) // 2 + shift,
                {kind = "window", image = window.image}, 16)
            if face then
                bar:text(left + 28 + shift, button_y + (button_h - 15) // 2 + shift,
                    pixels.ellipsize(face, window.title, span * cell.w - 36),
                    {font = face, color = color.face_text})
            end
        end
        hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
            from = at, to = at + span - 1, id = window.id}
        at = at + span
    end
    if dirty then
        local x, cw = (w - 9) * cell.w + 1, 9 * cell.w - 4
        pixels.bevel(bar, x, button_y, cw, button_h, false)
        pixels.label(bar, x, button_y, cw, button_h,
            tostring(state.clock or ""), face, color.face_text)
    end
    if chrome_pixels.clock_entry then
        hits.bars[#hits.bars + 1] = {row = top, bottom_row = rows > 1 and h or nil,
            from = w - 8, to = w, entry = chrome_pixels.clock_entry}
    end
    out[#out + 1] = {id = "bars", raster = bar, x = 1, y = top, cols = w, rows = rows}
end

-- ─── меню «Пуск» ─────────────────────────────────────────────────────────
--
-- Раскладку каскада считает `chrome.menu_layout` — та же функция, по которой
-- меню рисуется символами. Второй расчёт разъехался бы с первым, и щелчок
-- попадал бы на соседний пункт в одном из двух режимов, а оба кадра выглядели
-- бы правильными.
--
-- Каждая панель — своё размещение. Панели каскада делят строки между собой, и
-- это неизбежно: они стоят рядом. Но меню открыто ровно тогда, когда человек
-- на него смотрит, — набора текста в это время нет, и перерисовывать их
-- нечему.
--
-- Закрытое меню исчезает ОТСУТСТВИЕМ в списке размещений, а не рисованием
-- поверх: `store.frame` выбрасывает то, чего в кадре не назвали.

local function menu_key(box: any)
    local parts = {tostring(box.x), tostring(box.y), tostring(box.w), tostring(box.h),
                   tostring(box.banner), box.context and "ctx" or ""}
    for _, entry in ipairs(box.lines) do
        local line: any = entry
        parts[#parts + 1] = table.concat({
            tostring(line.kind), tostring(line.text), tostring(line.tail), tostring(line.rows),
            tostring(line.entry), tostring(line.image), tostring(line.separator_before),
            line.selected and "1" or "0", line.bold and "b" or "",
            line.dim and "d" or "", tostring(line.banner_letter),
        }, "\30")
    end
    return table.concat(parts, "\31")
end

local function paint_menu_panel(cell: any, box: any, id, fonts: any)
    local face: any = type(fonts) == "table" and fonts.face or nil
    -- Тип НАЗВАН, а не сглажен `any`, и приведение здесь честнее заглушки.
    --
    -- Шрифт приезжает полем обычной таблицы, через `use_fonts`, поэтому у него
    -- нет типа. Без имени типа пришлось бы объявить `any` у самого растра —
    -- и выключить заодно проверку КООРДИНАТ, а на вызове ниже недавно стоял
    -- `y = 0`, из-за которого строка уходила за край растра целиком, молча.
    --
    -- Приведение утверждает ровно то, что и так обязано быть верным:
    -- `use_fonts` зовут результатом `gfx.font`, и всё остальное упало бы в
    -- рантайме на первом же вызове.
    local given: any = type(fonts) == "table" and fonts.bold or face
    local bold = given :: gfx.Font

    local raster, dirty = store.take(id, box.w, box.h, cell, menu_key(box))
    if dirty then
        local area = pixels.box(1, 1, box.w, box.h, cell)
        pixels.panel(raster, 1, 1, area.w, area.h)

        -- Вертикальная надпись «Windows 95» — ПОВЁРНУТАЯ СТРОКА, а не колонка
        -- букв.
        --
        -- В ячейках иначе было нельзя: там буква занимает клетку, и надпись
        -- складывалась по строкам панели — а когда панель становилась короче
        -- девяти строк, надпись пропадала МОЛЧА, по букве за строку. В
        -- пикселях у неё своя высота, не связанная с числом пунктов меню.
        --
        -- Текст рисуется горизонтально во временный растр и кладётся
        -- повёрнутым на 270°: так он читается снизу вверх, как на эталоне.
        -- Временный растр не размещается на экране и живёт только внутри
        -- перерисовки — версия от него не двигается ни у кого.
        if whole(box.banner) > 0 and bold then
            local strip = pixels.box(1, 1, box.banner, box.h, cell)
            raster:rect(2, 2, strip.w - 2, strip.h - 4, color.shadow)

            -- Тот же текст, что у темы в ячейках, только не капителью: в
            -- пикселях надпись набирается шрифтом, а не по букве на строку.
            local label = "Wippy 2026"
            local text_w = whole(bold:measure(label))
            local text_h = 16
            if label ~= "" and text_w > 0 then
                local temp = gfx.raster(text_w, text_h)
                temp:fill(color.shadow)

                -- Перо вынесено в переменную с `any` НАРОЧНО и точечно.
                --
                -- `temp` — настоящий `gfx.Raster`, а не растр из хранилища,
                -- поэтому его аргументы проверяются по-настоящему; шрифт же
                -- приезжает сюда через `use_fonts`, полем обычной таблицы, и
                -- типа `gfx.Font` у него нет. Заглушить это, объявив `any` у
                -- самого растра, значило бы выключить заодно проверку
                -- КООРДИНАТ — на этом самом вызове недавно стоял `y = 0`, и
                -- строка уходила за край растра целиком, молча.
                --
                -- Координаты ЕДИНИЧНЫЕ, и теперь это проверяет линтер.
                temp:text(1, 1, label, {font = bold, color = color.select_fg})

                -- После поворота ширина и высота меняются местами: ширина
                -- рисунка на экране — это высота строки, и наоборот.
                local room = strip.h - 6
                local at_y = 3
                if text_w < room then at_y = strip.h - 3 - text_w end
                raster:blit(temp, 2 + (strip.w - 2 - text_h) // 2, at_y, {rotate = 270})
            end
        end

        local text_left = pixels.box(whole(box.banner) + 1, 1, 1, 1, cell).x + 8
        for index, entry in ipairs(box.lines) do
            local line: any = entry
            local top = (whole(line.row or (box.y + index)) - box.y) * cell.h + 1
            local line_h = math.max(1, whole(line.rows or 1)) * cell.h
            local inset = line_h >= 28 and 4 or 2

            -- Выделение — полосой во всю ширину списка, как в Windows 95:
            -- в меню синий прямоугольник обнимает строку целиком, а не
            -- подпись, в отличие от значка на столе.
            local tint = color.face_text
            if line.selected then
                local strip = pixels.box(whole(box.banner) + 1, 1, box.list_w, 1, cell)
                raster:rect(strip.x + 3, top + inset, strip.w - 2, line_h - inset * 2, color.select_bg)
                tint = color.select_fg
            elseif line.dim then
                tint = color.shadow
            end

            -- Root entries use their native 32px frame; submenus use 16px.
            local mark_size = whole(box.banner) > 0 and 32 or 16
            local mark_top = top + (line_h - mark_size) // 2
            -- У контекстного меню значков нет, как в Windows 95.
            if box.context then
                mark_size = 0
            elseif line.kind == "group" then
                pixels.icon(raster, text_left, mark_top, {kind = "group", image = "programs"}, mark_size)
            elseif line.kind == "item" then
                pixels.icon(raster, text_left, mark_top,
                    {kind = "program", entry = line.entry, image = line.image}, mark_size)
            end

            if line.separator_before then
                raster:rect(text_left, top, area.w - text_left - 3, 1, color.shadow)
                raster:rect(text_left, top + 1, area.w - text_left - 3, 1, color.light)
            end
            local font = line.bold and bold or face
            if font then
                local label_left = text_left
                if line.kind ~= "hint" then label_left = text_left + mark_size + (box.context and 6 or 10) end
                raster:text(label_left, top + (line_h - 15) // 2, line.label or line.text,
                    {font = font, color = tint})

                -- Стрелка подменю — тем же примитивом и по правому краю
                -- списка, как в Windows 95.
                if line.arrow then
                    local right = pixels.box(whole(box.banner) + whole(box.list_w), 1, 1, 1, cell)
                    pixels.mark_submenu(raster, right.x - 8, top + (line_h - 8) // 2, 8, tint)
                end
            end
        end
    end
    return raster
end

-- ─── кадр целиком ────────────────────────────────────────────────────────
--
-- paint(state, cell_w, cell_h) -> {placements, hits}
--
-- Попадания приезжают ГРУППАМИ `{desktop, bars, menu}`, а не плоским списком:
-- `id` в трёх списках значит разное, и плоский пришлось бы разбирать по
-- догадке.
-- Subtract higher windows in cell space before handing images to the surface.
-- Otherwise a lower window's border or a desktop icon erases the foreground text.
local function subtract(rect: any, cover: any): any
    local x, y = whole(rect.x), whole(rect.y)
    local right, bottom = x + whole(rect.cols), y + whole(rect.rows)
    local cx, cy = whole(cover.x), whole(cover.y)
    local left = math.max(x, cx)
    local top = math.max(y, cy)
    local far = math.min(right, cx + whole(cover.w))
    local low = math.min(bottom, cy + whole(cover.h))
    if left >= far or top >= low then return {rect} end
    local pieces = {}
    if top > y then pieces[#pieces + 1] = {x = x, y = y, cols = right - x, rows = top - y} end
    if low < bottom then pieces[#pieces + 1] = {x = x, y = low, cols = right - x, rows = bottom - low} end
    if left > x then pieces[#pieces + 1] = {x = x, y = top, cols = left - x, rows = low - top} end
    if far < right then pieces[#pieces + 1] = {x = far, y = top, cols = right - far, rows = low - top} end
    return pieces
end

local function visible_placements(placements: any, windows: any, cell: any): any
    local out = {}
    for _, source in ipairs(placements) do
        local pieces = {source}
        if source.layer ~= nil then
            for index = whole(source.layer) + 1, #windows do
                local cover = windows[index]
                if not cover.minimized then
                    local next_pieces = {}
                    for _, piece in ipairs(pieces) do
                        for _, kept in ipairs(subtract(piece, cover)) do next_pieces[#next_pieces + 1] = kept end
                    end
                    pieces = next_pieces
                end
            end
        end
        for _, piece in ipairs(pieces) do
            if piece == source then
                out[#out + 1] = source
            else
                local dx, dy = piece.x - source.x, piece.y - source.y
                local id = source.id .. ":crop:" .. dx .. ":" .. dy .. ":" .. piece.cols .. ":" .. piece.rows
                local key = tostring(source.cols) .. ":" .. source.rows .. ":" .. source.raster:version()
                local raster, dirty = store.take(id, piece.cols, piece.rows, cell, key)
                if dirty then raster:blit(source.raster, 1 - dx * cell.w, 1 - dy * cell.h) end
                out[#out + 1] = {id = id, raster = raster, x = piece.x, y = piece.y,
                    cols = piece.cols, rows = piece.rows}
            end
        end
    end
    return out
end

function chrome_pixels.paint(state: any, cell_w: any, cell_h: any)
    chrome_pixels.use_cell_size(cell_w, cell_h)
    local cell = unit
    local view: any = type(state) == "table" and state or {}
    local fonts = chrome_pixels.fonts
    local grid = chrome_pixels.icon_grid()

    store.begin()
    local out = {}
    local hits: any = {desktop = {}, bars = {}, menu = {}}

    -- Значки стола — под окнами, поэтому первыми: порядок списка и есть
    -- порядок рисования.
    for _, entry in ipairs(view.items or {}) do
        local item: any = entry
        local x = whole(item.x)
        local y = whole(item.y)
        if x >= 1 and y >= 1 and y + grid.drawn - 1 <= whole(view.bottom) then
            local selected = view.selected ~= nil and item.id == view.selected
            local id, raster = paint_icon(cell, item, selected, grid)
            store.place(id, x, y)
            out[#out + 1] = {id = id, raster = raster, x = x, y = y,
                             cols = grid.w - 1, rows = grid.drawn, layer = 0}
            -- Попадание на КАЖДУЮ строку значка, а не одно на всю высоту.
            --
            -- Композитор сверяет `event.y == spot.row` — ровно одну строку, —
            -- и поля `bottom_row` не знает вовсе. Одно попадание на три
            -- строки означало бы значок, который нажимается по картинке и не
            -- нажимается по подписи. Молча: щелчок по подписи просто ничего
            -- не делает.
            --
            -- Форма та же, что у `chrome.fill` в режиме символов, и это не
            -- совпадение: composer один на оба режима, и попадание, которое
            -- он не умеет читать, неотличимо от отсутствующего.
            for row = y, y + grid.drawn - 1 do
                hits.desktop[#hits.desktop + 1] = {
                    row = row, from = x, to = x + grid.w - 2,
                    id = item.id, kind = item.kind,
                    broken = item.broken and true or false,
                    entry = item.entry, title = item.title,
                    w = tonumber(item.w), h = tonumber(item.h), args = item.args,
                    properties = item.properties,
                }
            end
        end
    end

    local live_clients: any = {}
    for index, entry in ipairs(view.windows or {}) do
        local window: any = entry
        if clients[window.id] then live_clients[window.id] = clients[window.id] end
        if not window.minimized then
            local first = #out + 1
            paint_window(cell, window, view.focused_id == window.id, fonts, out)
            if clients[window.id] then live_clients[window.id] = clients[window.id] end
            for at = first, #out do out[at].layer = index end
        end
    end

    clients = live_clients
    -- Голый стол — без панели задач: так рисуется экран входа, где «Пуска»
    -- ещё нет, потому что нет и пользователя.
    if not view.bare then paint_bars(cell, view, fonts, out, hits) end

    -- Меню поверх всего: оно и на экране поверх всего, а порядок списка и есть
    -- порядок рисования.
    if view.menu then
        local menu: any = view.menu
        local shown = chrome.menu_layout(view.width, view.height,
            menu.items, menu.failure, menu.open, menu.cursor, {
                compact = true, bottom = taskbar_rows(),
                anchor = menu.anchor, context_rows = 1,
                root_rows = math.max(1, (32 + cell.h - 1) // cell.h),
                item_rows = math.max(1, (24 + cell.h - 1) // cell.h),
                measure = function(label)
                    local font: any = fonts and fonts.face
                    return (whole(font and font:measure(label) or 0) + 64 + cell.w - 1) // cell.w
                end,
            })

        if shown.notice then
            local id = "menu:notice"
            local raster = paint_menu_panel(cell, shown.notice, id, fonts)
            out[#out + 1] = {id = id, raster = raster, x = shown.notice.x,
                             y = shown.notice.y, cols = shown.notice.w, rows = shown.notice.h}
        end

        for index, entry in ipairs(shown.panels) do
            local box: any = entry
            -- Имя размещения — по УРОВНЮ, а не по порядку: уровень не меняется,
            -- пока панель на экране, и поверхность узнаёт ту же картинку.
            local id = "menu:" .. tostring(index)
            local raster = paint_menu_panel(cell, box, id, fonts)
            out[#out + 1] = {id = id, raster = raster, x = box.x, y = box.y,
                             cols = box.w, rows = box.h}
        end

        for _, hit in ipairs(shown.hits) do hits.menu[#hits.menu + 1] = hit end
    end

    -- Размещения объявляются через хранилище, чтобы `sweep` выбросил то, чего
    -- в кадре не назвали: закрытое меню исчезает отсутствием в списке, а не
    -- рисованием поверх.
    out = visible_placements(out, view.windows or {}, cell)
    for _, item in ipairs(out) do store.place(item.id, item.x, item.y) end
    store.frame(cell)

    return {placements = out, hits = hits}
end

-- Шрифты приносит тот, кто умеет читать файлы: у темы нет ни прав, ни
-- модуля `fs`, и это не оплошность — шрифт приезжает БАЙТАМИ, потому что
-- чтение файла управляется правами процесса, а модуль, открывающий пути сам,
-- был бы дорогой мимо них.
-- `display` — крупный полужирный для экрана прощания; без него надпись
-- набирается обычным полужирным и выглядит подписью, а не экраном.
function chrome_pixels.use_fonts(face, bold, display)
    chrome_pixels.fonts = {face = face, bold = bold or face, display = display or bold or face}
end

return chrome_pixels
