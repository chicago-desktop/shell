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
-- Поэтому у темы ДВА входа, и оба нужны:
--
--   `fill(canvas, w, h, state)` — заливка ячейками, как в режиме символов;
--   `paint(state, cell_w, cell_h)` — пиксельные размещения и попадания.
--
-- ВНИМАНИЕ ЧИТАТЕЛЮ КОНТРАКТА. Композитор основы в пиксельном режиме зовёт
-- только `paint`, а `fill` пропускает — и заливать фон теме нечем: в `paint`
-- холст не приезжает. Пока это не починено, стол остаётся цвета терминала.
-- Починка со стороны основы — одна строка: звать `fill` в обоих режимах.
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
local icons = require("icons")
local palette = require("palette")
local pixels = require("pixels")
local rasters = require("rasters")
local widgets = require("widgets")

local color = palette.exact

local chrome_pixels = {}

-- Тема хранит растры между кадрами, и хранить их больше негде: контракт
-- `paint` состояния не носит. Значит это состояние модуля, по одному на
-- процесс — а процесс здесь один, оболочка.
local store = rasters.store()

-- Признак для композитора: по нему он решает, что тема умеет пиксели.
chrome_pixels.pixel = true

-- Геометрия та же, что у темы в ячейках: панель задач снизу, стол сверху.
-- Числа общие нарочно — раскладка не зависит от того, чем рисуют.
function chrome_pixels.layout(width: any, height: any)
    return {top = 0, bottom = 1}
end

function chrome_pixels.window_insets(window)
    return {top = 3, bottom = 2, left = 2, right = 2}
end

function chrome_pixels.icon_grid()
    return icons.grid()
end

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
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

    -- Лицо панели задач: под картинками всё равно будут пробелы, но строка,
    -- не закрашенная лицом, светится цветом терминала в промежутках между
    -- размещениями.
    canvas:put(1, h, widgets.styles.face:render(string.rep(" ", w)), w)
    return {}
end

-- ─── значки стола ────────────────────────────────────────────────────────

local function icon_key(item: any, selected)
    return table.concat({
        tostring(item.id), tostring(item.title or ""), tostring(item.kind or ""),
        tostring(item.icon or ""), item.broken and "!" or "",
        selected and "1" or "0",
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
        -- Прозрачный фон: под значком бирюзовый стол, залитый ячейками, и
        -- закрашивать его здесь значило бы нарисовать прямоугольник другого
        -- оттенка вокруг каждой подписи.
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
    local side = 16
    local left = box.x + (box.w - side) // 2
    local top = box.y + 2

    if item.kind == "folder" then
        raster:rect(left, top + 3, side, side - 5, "#c8a848")
        raster:rect(left, top + 1, 7, 3, "#c8a848")
        pixels.bevel(raster, left, top + 3, side, side - 5, true)
    elseif item.broken then
        raster:rect(left + 2, top, side - 4, side, color.field)
        pixels.bevel(raster, left + 2, top, side - 4, side, false)
        raster:rect(left + 4, top + 4, side - 8, 2, color.alert)
        raster:rect(left + 4, top + 9, side - 8, 2, color.alert)
    else
        raster:rect(left + 1, top + 1, side - 2, side - 4, color.face)
        pixels.bevel(raster, left + 1, top + 1, side - 2, side - 4, true)
        raster:rect(left + 4, top + side - 8, side - 8, 3, "#404040")
    end

    local fonts: any = chrome_pixels.fonts
    local face: any = type(fonts) == "table" and fonts.face or nil
    if not face then return end

    local lines = pixels.wrap(face, item.title, box.w - 2, 2)
    local at = top + side + 2
    for _, line in ipairs(lines) do
        local width = whole(face:measure(line))
        local from = box.x + (box.w - width) // 2
        if selected then
            raster:rect(from - 2, at - 1, width + 4, 16, color.select_bg)
        end
        local tint = color.desktop_text
        if item.broken then tint = color.desktop_broken end
        if selected then tint = color.select_fg end
        raster:text(from, at, line, {font = face, color = tint})
        at = at + 15
    end
end

-- ─── рамка окна ──────────────────────────────────────────────────────────

local function paint_window(cell: any, window: any, focused, fonts: any, out)
    local id = "win:" .. tostring(window.id)
    local w = whole(window.w)
    local h = whole(window.h)
    if w < 4 or h < 4 then return end

    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face

    -- Заголовок: свои строки, содержимым не задеваются. Ключ — всё, от чего
    -- зависит картинка: имя, ширина, фокус, тип окна.
    local head_id = id .. ":head"
    local head_key = table.concat({tostring(window.title), tostring(w),
        focused and "1" or "0", tostring(window.window_type or "app")}, "\30")
    -- Состав кнопок берётся у темы в ячейках — ОДНА таблица на оба режима.
    -- Второй список кнопок разошёлся бы с первым, и у диалога в пикселях
    -- оказалось бы три кнопки, а в ячейках две.
    local buttons, button_cells = chrome.buttons_for(window)

    local head, head_dirty = store.take(head_id, w, 2, cell, head_key)
    if head_dirty then
        local box = pixels.box(1, 1, w, 2, cell)
        pixels.panel(head, 1, 1, box.w, box.h)

        -- Кнопки занимают целое число ячеек, и место под них отнимается у
        -- полосы заголовка ДО того, как она нарисована: иначе имя окна
        -- уезжает под кнопки, а обрезать его будет уже нечем.
        local room = w - 3 - #buttons
        pixels.title(head, 5, cell.h - 2, room * cell.w, cell.h,
            {text = window.title, font = face, bold = bold, focused = focused}, cell)

        for index, button in ipairs(buttons) do
            local col = w - #buttons + index - 1
            local area = pixels.box(col, 1, 1, 1, cell)
            pixels.panel(head, area.x, area.y + cell.h - 4, area.w - 1, cell.h - 4)
            local mark: any = pixels.MARKS[(button :: any).id]
            if type(mark) == "function" then
                local size = 10
                mark(head, area.x + (area.w - 1 - size) // 2,
                    area.y + cell.h - 4 + (cell.h - 4 - size) // 2, size, color.face_text)
            end
        end
    end
    out[#out + 1] = {id = head_id, raster = head, x = window.x, y = window.y, cols = w, rows = 2}

    -- Боковые грани: они и только они делят строки с содержимым, поэтому
    -- узкие. Нажатие клавиши в окне стоит ровно этих двух полосок.
    local body = h - 3
    if body > 0 then
        for _, side in ipairs({{"left", window.x}, {"right", window.x + w - 1}}) do
            local edge_id = id .. ":" .. side[1]
            local edge, edge_dirty = store.take(edge_id, 1, body, cell, tostring(body))
            if edge_dirty then
                local box = pixels.box(1, 1, 1, body, cell)
                edge:rect(1, 1, box.w, box.h, color.face)
                if side[1] == "left" then
                    edge:rect(1, 1, 1, box.h, color.light)
                    edge:rect(box.w - 1, 1, 1, box.h, color.shadow)
                else
                    edge:rect(1, 1, 1, box.h, color.light)
                    edge:rect(box.w - 1, 1, 1, box.h, color.frame)
                end
            end
            out[#out + 1] = {id = edge_id, raster = edge, x = side[2],
                             y = window.y + 2, cols = 1, rows = body}
        end
    end

    local foot_id = id .. ":foot"
    local foot, foot_dirty = store.take(foot_id, w, 1, cell, tostring(w))
    if foot_dirty then
        local box = pixels.box(1, 1, w, 1, cell)
        pixels.panel(foot, 1, 1, box.w, box.h)
    end
    out[#out + 1] = {id = foot_id, raster = foot, x = window.x,
                     y = window.y + h - 1, cols = w, rows = 1}
end

-- ─── панель задач ────────────────────────────────────────────────────────

local function paint_bars(cell: any, state: any, fonts: any, out, hits)
    local w = whole(state.width)
    local h = whole(state.height)
    local face: any = type(fonts) == "table" and fonts.face or nil
    local bold: any = type(fonts) == "table" and fonts.bold or face

    local key = {tostring(w), tostring(state.clock or ""), tostring(state.focused_id or "")}
    for _, window in ipairs(state.windows or {}) do
        key[#key + 1] = tostring((window :: any).id) .. ":" .. tostring((window :: any).title)
    end

    local id = "bars"
    local bar, dirty = store.take(id, w, 1, cell, table.concat(key, "\30"))
    local box = pixels.box(1, 1, w, 1, cell)

    -- Кнопка «Пуск» и кнопки окон: ширина в ЯЧЕЙКАХ, потому что по ним
    -- щёлкают. Считается один раз и здесь — попадания уезжают из той же
    -- таблицы, из которой рисуется.
    local start_span = pixels.button_span(bold, {"Пуск"}, cell, 56)
    if dirty then
        bar:rect(1, 1, box.w, box.h, color.face)
        pixels.button_at(bar, 1, 1, start_span, 1,
            {id = "menu", label = "Пуск", font = bold, inset = 2}, cell)
    end
    hits.bars[#hits.bars + 1] = {row = h, from = 1, to = start_span, id = "menu"}

    local at = start_span + 2
    for _, entry in ipairs(state.windows or {}) do
        local window: any = entry
        local span = 14
        if at + span - 1 > w - 8 then break end
        if dirty then
            pixels.button_at(bar, at, 1, span, 1,
                {id = window.id, label = window.title, font = face, inset = 2,
                 pressed = window.id == state.focused_id}, cell)
        end
        hits.bars[#hits.bars + 1] = {row = h, from = at, to = at + span - 1,
                                     id = window.id, window = window.id}
        at = at + span + 1
    end

    if dirty then
        local clock_at = pixels.box(w - 7, 1, 7, 1, cell)
        pixels.field(bar, clock_at.x - 1, 3, clock_at.w, box.h - 6)
        pixels.label(bar, clock_at.x - 1, 3, clock_at.w, box.h - 6,
            tostring(state.clock or ""), face, color.face_text)
    end

    out[#out + 1] = {id = id, raster = bar, x = 1, y = h, cols = w, rows = 1}
end

-- ─── кадр целиком ────────────────────────────────────────────────────────
--
-- paint(state, cell_w, cell_h) -> {placements, hits}
--
-- Попадания приезжают ГРУППАМИ `{desktop, bars, menu}`, а не плоским списком:
-- `id` в трёх списках значит разное, и плоский пришлось бы разбирать по
-- догадке.
function chrome_pixels.paint(state: any, cell_w: any, cell_h: any)
    local cell = {w = whole(cell_w), h = whole(cell_h)}
    local view: any = type(state) == "table" and state or {}
    local fonts = chrome_pixels.fonts
    local grid = icons.grid()

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
                             cols = grid.w - 1, rows = grid.drawn}
            hits.desktop[#hits.desktop + 1] = {
                row = y, from = x, to = x + grid.w - 2,
                bottom_row = y + grid.drawn - 1,
                id = item.id, kind = item.kind, entry = item.entry,
                title = item.title, broken = item.broken and true or false,
                w = tonumber(item.w), h = tonumber(item.h), args = item.args,
            }
        end
    end

    for _, entry in ipairs(view.windows or {}) do
        local window: any = entry
        if not window.minimized then
            paint_window(cell, window, view.focused_id == window.id, fonts, out)
        end
    end

    paint_bars(cell, view, fonts, out, hits)

    -- Размещения объявляются через хранилище, чтобы `sweep` выбросил то, чего
    -- в кадре не назвали: закрытое меню исчезает отсутствием в списке, а не
    -- рисованием поверх.
    for _, item in ipairs(out) do store.place(item.id, item.x, item.y) end
    store.frame(cell)

    return {placements = out, hits = hits}
end

-- Шрифты приносит тот, кто умеет читать файлы: у темы нет ни прав, ни
-- модуля `fs`, и это не оплошность — шрифт приезжает БАЙТАМИ, потому что
-- чтение файла управляется правами процесса, а модуль, открывающий пути сам,
-- был бы дорогой мимо них.
function chrome_pixels.use_fonts(face, bold)
    chrome_pixels.fonts = {face = face, bold = bold or face}
end

return chrome_pixels
