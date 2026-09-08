-- Краски окна «Дата и время»: вкладки, календарь, аналоговые часы, кнопки.
--
-- Раскладку не считает: области, кнопки и сетка месяца приходят из `layout`,
-- оттуда же их читает поставщик, чтобы щелчок попадал туда, где нарисовано.
-- Здесь только пиксели — и потому это ЕДИНСТВЕННАЯ запись окна, объявившая
-- `gfx`: на рантайме без графики она не загрузится, а раскладка и поставщик
-- останутся живы.
--
-- Растры берутся у хранилища темы по ключу-отпечатку состояния и НЕ
-- пересоздаются (FR-005 §4). Нарезка — три растра (`layout.slices`): часы
-- тикают каждую секунду, и в своём растре они переотправляют себя, а не
-- календарь. Все три рисуют ОДНУ сцену со сдвигом: растр видит свой кусок,
-- остальное отсекает клиппинг растра. Дороже трёх отдельных рисовальщиков
-- на пару процентов, зато шов между кусками сойтись не может — сцены две не
-- бывает.

local palette = require("palette")
local pixels = require("pixels")
local layout = require("layout")

local color = palette.exact

local render = {}

local geometry = require("geometry")
local whole = geometry.whole

-- Растр со сдвигом: сцена рисует в координатах содержимого окна, кусок
-- видит её через своё окно. Методы те же, что у gfx.Raster, поэтому
-- примитивы `pixels` рисуют в него, не зная о сдвиге.
local function pane(raster: any, ox: any, oy: any): any
    local dx, dy = whole(ox), whole(oy)
    local self: any = {}
    function self.rect(_, x: any, y: any, w: any, h: any, tint)
        raster:rect(whole(x) - dx, whole(y) - dy, whole(w), whole(h), tint)
    end
    function self.set(_, x: any, y: any, tint)
        raster:set(whole(x) - dx, whole(y) - dy, tint)
    end
    function self.text(_, x: any, y: any, text, options)
        return raster:text(whole(x) - dx, whole(y) - dy, text, options)
    end
    function self.fill(_, tint) raster:fill(tint) end
    return self
end

-- Этчед-рамка: тёмная линия и светлая на пиксель ниже-правее. Так в
-- Windows 95 обведены группы «Дата» и «Время».
local function etched(r: any, x: any, y: any, w: any, h: any)
    local left, top = whole(x), whole(y)
    local width, height = whole(w), whole(h)
    r:rect(left + 1, top + 1, width, 1, color.light)
    r:rect(left + 1, top + 1, 1, height, color.light)
    r:rect(left + 1, top + height, width, 1, color.light)
    r:rect(left + width, top + 1, 1, height, color.light)
    r:rect(left, top, width, 1, color.shadow)
    r:rect(left, top, 1, height, color.shadow)
    r:rect(left, top + height - 1, width, 1, color.shadow)
    r:rect(left + width - 1, top, 1, height, color.shadow)
end

-- Группа с подписью, разрывающей верхнюю линию.
local function group(r: any, x: any, y: any, w: any, h: any, caption, font)
    etched(r, x, y, w, h)
    if font then
        local tw = whole(font:measure(caption))
        r:rect(whole(x) + 8, whole(y) - 7, tw + 6, 15, color.face)
        r:text(whole(x) + 11, whole(y) - 8, caption, {font = font, color = color.face_text})
    end
end

-- Стрелка вниз у выпадающего списка и стрелки счётчика — примитивами.
local function arrow_down(r: any, x: any, y: any, tint)
    for step = 0, 3 do
        r:rect(whole(x) + step, whole(y) + step, 7 - step * 2, 1, tint)
    end
end

local function arrow_up(r: any, x: any, y: any, tint)
    for step = 0, 3 do
        r:rect(whole(x) + step, whole(y) + 3 - step, 7 - step * 2, 1, tint)
    end
end

-- Поле со стрелкой: месяц. Только для чтения — но выглядит как настоящее,
-- иначе окно читается как незаконченное.
local function combo(r: any, x: any, y: any, w: any, h: any, text, font)
    pixels.field(r, x, y, w, h)
    local button_w = 16
    pixels.button(r, whole(x) + whole(w) - button_w - 2, whole(y) + 2, button_w, whole(h) - 4, {}, {w = 1, h = 1})
    arrow_down(r, whole(x) + whole(w) - button_w + 3, whole(y) + whole(h) // 2 - 1, color.face_text)
    if font then
        r:text(whole(x) + 5, whole(y) + (whole(h) - 15) // 2, text,
            {font = font, color = color.field_text})
    end
end

-- Поле со счётчиком: год и время.
local function spinner(r: any, x: any, y: any, w: any, h: any, text, font)
    pixels.field(r, x, y, w, h)
    local button_w = 16
    local half = (whole(h) - 4) // 2
    local bx = whole(x) + whole(w) - button_w - 2
    pixels.button(r, bx, whole(y) + 2, button_w, half, {}, {w = 1, h = 1})
    pixels.button(r, bx, whole(y) + 2 + half, button_w, whole(h) - 4 - half, {}, {w = 1, h = 1})
    arrow_up(r, bx + 5, whole(y) + 2 + (half - 4) // 2, color.face_text)
    arrow_down(r, bx + 5, whole(y) + 2 + half + (half - 4) // 2, color.face_text)
    if font then
        r:text(whole(x) + 5, whole(y) + (whole(h) - 15) // 2, text,
            {font = font, color = color.field_text})
    end
end

-- Отрезок по Брезенхэму — стрелки часов. Толщина набирается соседними
-- отрезками, а не «жирным» алгоритмом: у стрелки часов Windows 95 ширина
-- два-три пикселя, и разница между ними видна.
local function line(r: any, x0: any, y0: any, x1: any, y1: any, tint)
    local ax, ay = whole(x0), whole(y0)
    local bx, by = whole(x1), whole(y1)
    local dx = math.abs(bx - ax)
    local dy = -math.abs(by - ay)
    local sx = ax < bx and 1 or -1
    local sy = ay < by and 1 or -1
    local err = dx + dy
    while true do
        r:set(ax, ay, tint)
        if ax == bx and ay == by then break end
        local twice = err * 2
        if twice >= dy then err = err + dy; ax = ax + sx end
        if twice <= dx then err = err + dx; ay = ay + sy end
    end
end

local function hand(r: any, cx: any, cy: any, angle: any, length: any, width: any, tint)
    local radians = math.rad(tonumber(angle) or 0)
    local ex = whole(cx) + math.floor(math.sin(radians) * whole(length) + 0.5)
    local ey = whole(cy) - math.floor(math.cos(radians) * whole(length) + 0.5)
    local thick = whole(width)
    for step = 0, thick - 1 do
        local shift = step - thick // 2
        -- Сдвиг поперёк стрелки: по x у вертикальных, по y у горизонтальных.
        if math.abs(math.sin(radians)) < 0.7071 then
            line(r, whole(cx) + shift, whole(cy), ex + shift, ey, tint)
        else
            line(r, whole(cx), whole(cy) + shift, ex, ey + shift, tint)
        end
    end
end

-- Циферблат: белое вдавленное поле, двенадцать делений и три стрелки.
local function clock_face(r: any, x: any, y: any, size: any, state: any)
    local side = whole(size)
    local left, top = whole(x), whole(y)
    pixels.field(r, left, top, side, side)
    local cx = left + side // 2
    local cy = top + side // 2
    local radius = side // 2 - 8
    for tick = 0, 11 do
        local radians = math.rad(tick * 30)
        local px = cx + math.floor(math.sin(radians) * radius + 0.5)
        local py = cy - math.floor(math.cos(radians) * radius + 0.5)
        local big = tick % 3 == 0
        local dot = big and 4 or 2
        r:rect(px - dot // 2, py - dot // 2, dot, dot, color.face_text)
    end
    local hour = whole(state.hour) % 12
    local minute = whole(state.minute)
    local second = whole(state.second)
    hand(r, cx, cy, hour * 30 + minute / 2, radius - 16, 3, color.face_text)
    hand(r, cx, cy, minute * 6 + second / 10, radius - 6, 2, color.face_text)
    hand(r, cx, cy, second * 6, radius - 4, 1, color.shadow)
    r:rect(cx - 2, cy - 2, 5, 5, color.face_text)
end

-- Календарь: заголовок дней недели и сетка из `layout.grid`; сегодняшнее
-- число выделено синим, как выбранная строка в списке.
local function calendar(r: any, x: any, y: any, w: any, h: any, state: any, font)
    if not font then return end
    local left, top = whole(x), whole(y)
    local column = whole(w) // 7
    local head_h = 18
    local row_h = (whole(h) - head_h) // 6
    for index, name in ipairs(layout.WEEKDAYS) do
        local tw = whole(font:measure(name))
        r:text(left + (index - 1) * column + (column - tw) // 2, top + 1, name,
            {font = font, color = color.face_text})
    end
    r:rect(left, top + head_h - 2, column * 7, 1, color.shadow)
    local rows = layout.grid(state.first_weekday, state.days)
    for row_index, row in ipairs(rows) do
        for column_index = 1, 7 do
            local day: any = row[column_index]
            if day then
                local text = tostring(day)
                local tw = whole(font:measure(text))
                local cx = left + (column_index - 1) * column
                local cy = top + head_h + (row_index - 1) * row_h
                local today = whole(day) == whole(state.day)
                if today then
                    r:rect(cx, cy, column, row_h, color.select_bg)
                end
                r:text(cx + (column - tw) // 2, cy + (row_h - 15) // 2, text,
                    {font = font, color = today and color.select_fg or color.face_text})
            end
        end
    end
end

-- Кнопка внизу: включённая — обычная; выключенная — серая подпись с белой
-- тенью, как рисует Windows 95 недоступный текст.
local function bottom_button(r: any, button: any, cell: any, font, pressed)
    local area = pixels.box(button.from, button.row, button.to - button.from + 1,
        button.bottom_row - button.row + 1, cell)
    local h = 23
    local y = area.y + (area.h - h) // 2
    local x, w = area.x + 2, area.w - 4
    -- `default` — чёрный контур: это то, что сделает Enter, и он один.
    pixels.button(r, x, y, w, h, {label = button.label, font = font,
        pressed = pressed, disabled = not button.enabled, default = button.default}, cell)
end

-- Вся сцена в координатах содержимого окна (пиксели, единичные).
local function scene(r: any, cell: any, state: any, fonts: any, inner: any)
    local face: any = type(fonts) == "table" and fonts.face or nil
    local regions = layout.regions()
    local width, height = whole(inner.cols) * whole(cell.w), whole(inner.rows) * whole(cell.h)
    r:fill(color.face)

    -- Страница вкладки: выпуклая панель под вкладками.
    local tab_h = 21
    local page = pixels.box(regions.page.x, regions.page.y, regions.page.cols, regions.page.rows, cell)
    local page_top = page.y + tab_h
    local page_h = page.h - tab_h - 2
    pixels.panel(r, page.x + 3, page_top, page.w - 6, page_h)

    -- Вкладки: активная выше и сливается со страницей, вторая позади.
    local tab_x = page.x + 5
    for index, caption in ipairs(layout.TABS) do
        local tw = face and whole(face:measure(caption)) or 60
        local w = tw + 18
        if index == 1 then
            r:rect(tab_x, page.y + 2, w, tab_h + 1, color.face)
            r:rect(tab_x, page.y + 2, w, 1, color.light)
            r:rect(tab_x, page.y + 2, 1, tab_h + 1, color.light)
            r:rect(tab_x + w - 1, page.y + 2, 1, tab_h + 1, color.shadow)
            r:rect(tab_x + w, page.y + 3, 1, tab_h, color.frame)
            if face then r:text(tab_x + 9, page.y + 5, caption, {font = face, color = color.face_text}) end
        else
            local y = page.y + 4
            r:rect(tab_x, y, w, tab_h - 2, color.face)
            r:rect(tab_x, y, w, 1, color.light)
            r:rect(tab_x, y, 1, tab_h - 2, color.light)
            r:rect(tab_x + w - 1, y, 1, tab_h - 2, color.shadow)
            r:rect(tab_x + w, y + 1, 1, tab_h - 3, color.frame)
            if face then r:text(tab_x + 9, y + 3, caption, {font = face, color = color.face_text}) end
        end
        tab_x = tab_x + w + 2
    end

    -- Группа «Дата».
    local date = pixels.box(regions.date.x, regions.date.y, regions.date.cols, regions.date.rows, cell)
    group(r, date.x, date.y, date.w - 4, date.h - 6, "Дата", face)
    local month = tostring(layout.MONTHS[whole(state.month)] or "—")
    local field_h = 21
    local inner_x = date.x + 8
    local inner_w = date.w - 20
    combo(r, inner_x, date.y + 12, inner_w * 3 // 5, field_h, month, face)
    spinner(r, inner_x + inner_w * 3 // 5 + 6, date.y + 12, inner_w - inner_w * 3 // 5 - 6, field_h,
        tostring(whole(state.year)), face)
    calendar(r, inner_x, date.y + 12 + field_h + 8, inner_w, date.h - 12 - field_h - 8 - 14, state, face)

    -- Группа «Время».
    local clock = pixels.box(regions.time.x, regions.time.y, regions.time.cols, regions.time.rows, cell)
    group(r, clock.x, clock.y, clock.w - 6, clock.h - 6, "Время", face)
    local side = math.min(whole(clock.w) - 30, whole(clock.h) - 12 - field_h - 24)
    local clock_x = clock.x + (clock.w - 6 - side) // 2
    clock_face(r, clock_x, clock.y + 12, side, state)
    local digital = string.format("%02d:%02d:%02d", whole(state.hour), whole(state.minute), whole(state.second))
    local digital_w = side * 3 // 4
    spinner(r, clock.x + (clock.w - 6 - digital_w) // 2, clock.y + 12 + side + 10, digital_w, field_h, digital, face)

    -- Часовой пояс — на странице, под группами.
    if face then
        r:text(page.x + 14, page_top + page_h - 22, layout.zone_caption(state.zone),
            {font = face, color = color.face_text})
    end

    -- Кнопки под страницей.
    for _, button in ipairs(layout.buttons()) do
        bottom_button(r, button, cell, face, state.pressed == button.id)
    end

    -- Ширина и высота содержимого не используются дальше, но названы: сцена
    -- рисуется в этих границах, и клиппинг растра отсекает всё за ними.
    return width, height
end

-- Отпечаток состояния для куска. Секунды входят только в `right`: ключ,
-- взявший лишнее, перерисовывает зря, забывший нужное — показывает вчерашнее.
local function key_for(slice_id, state: any, inner: any)
    local parts = {tostring(inner.cols), tostring(inner.rows), tostring(state.year),
        tostring(state.month), tostring(state.day), tostring(state.first_weekday),
        tostring(state.days)}
    if slice_id == "right" then
        parts[#parts + 1] = string.format("%s:%s:%s", tostring(state.hour),
            tostring(state.minute), tostring(state.second))
    elseif slice_id == "bottom" then
        parts[#parts + 1] = tostring(state.zone)
        parts[#parts + 1] = tostring(state.pressed)
    end
    return table.concat(parts, "\31")
end

-- placement(window, inner, cell, fonts, store) -> список размещений
--
-- Контракт хука темы. `inner` — прямоугольник внутри рамки в ячейках экрана,
-- `store` — хранилище растров темы: взятое из него размещается и выметается
-- вместе с окном.
function render.placement(window: any, inner: any, cell: any, fonts: any, store: any): (any, any)
    if type(store) ~= "table" or type(store.take) ~= "function" then
        return nil, "окну «Дата и время» не дали хранилища растров"
    end
    local state: any = type(window.content_state) == "table" and window.content_state or nil
    if not state then return nil, "часы ещё не ответили" end
    if whole(inner.cols) < layout.COLS or whole(inner.rows) < layout.ROWS then
        return nil, string.format("окну нужно %d×%d ячеек, дано %d×%d",
            layout.COLS, layout.ROWS, whole(inner.cols), whole(inner.rows))
    end

    local out = {}
    local prefix = "win:" .. tostring(window.id) .. ":view:"
    for _, slice in ipairs(layout.slices()) do
        local id = prefix .. slice.id
        local raster, dirty = store.take(id, slice.cols, slice.rows, cell, key_for(slice.id, state, inner))
        if dirty then
            local view = pane(raster, (slice.x - 1) * whole(cell.w), (slice.y - 1) * whole(cell.h))
            scene(view, cell, state, fonts, inner)
        end
        out[#out + 1] = {id = id, raster = raster,
            x = whole(inner.x) + slice.x - 1, y = whole(inner.y) + slice.y - 1,
            cols = slice.cols, rows = slice.rows}
    end
    return out, nil
end

return render
