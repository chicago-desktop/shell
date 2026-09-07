-- Пиксельные примитивы оболочки: объём, панель, поле, кнопка, заголовок.
--
-- Пиксельный двойник `widgets`, и написан по тому же правилу: НИЧЕГО, что
-- знает про экран целиком. Только арифметика и вызовы в растр, поэтому
-- проверяется подставкой без рантайма — `tools/pixelprobe`.
--
-- ─── Два правила, из-за которых этот файл выглядит именно так ───────────
--
-- ПЕРВОЕ. Украшение свободно, интерактив квантован (FR-005 §4а). Грань здесь
-- в ОДИН пиксель — ради этого весь переход и затеян, — но мышь шлёт координаты
-- в ЯЧЕЙКАХ, других SGR 1006 не знает. Поэтому всё, по чему щёлкают, отдаёт
-- попадание в ячейках, а не в пикселях. Отдай мы прямоугольники в пикселях и
-- подели их на размер ячейки — на границе двух соседних кнопок округление
-- решало бы, кому достался щелчок, и решало бы молча.
--
-- Отсюда форма: рисующая функция принимает ПИКСЕЛИ и возвращает попадание в
-- ЯЧЕЙКАХ, пересчитывая одно в другое ровно в одном месте — там, где рисует.
--
-- ВТОРОЕ. Растры переживают кадр (FR-005 §4). Ни одна функция здесь растров не
-- создаёт: растр приходит снаружи, от того, кто хранит его между кадрами.
-- Создавай примитив свой растр — тема переотправляла бы всё каждый кадр и
-- получила бы те же сорок семь миллисекунд, только по частям.
--
-- Цвета — точные значения из общей палитры, той же, что у темы в ячейках.
-- Своя копия значений разошлась бы с первой, и разошлась бы видом.

local palette = require("palette")

local color = palette.exact

local pixels = {}

-- Толщина грани. Одна, а не «сколько получится»: в Windows 95 объём — это
-- ровно один пиксель светлого сверху-слева и один тёмного снизу-справа, и
-- вторая грань крупных рамок — это уже другой цвет, а не другая толщина.
pixels.EDGE = 1

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Прямоугольник в пикселях -> прямоугольник в ЯЧЕЙКАХ, единичных.
--
-- Наружу отдаётся то, во что мышь умеет попадать. Ячейка считается занятой,
-- если рисунок её задел: кнопка, нарисованная от середины ячейки, всё равно
-- нажимается по всей ячейке — иначе половина кнопки мертва, а выглядит живой.
function pixels.cells(x: any, y: any, w: any, h: any, cell: any): any
    local unit: any = type(cell) == "table" and cell or {}
    local cw = whole(unit.w)
    local ch = whole(unit.h)
    if cw < 1 then cw = 1 end
    if ch < 1 then ch = 1 end

    local left = whole(x)
    local top = whole(y)
    local right = left + math.max(1, whole(w)) - 1
    local bottom = top + math.max(1, whole(h)) - 1

    return {
        from = (left - 1) // cw + 1,
        to = (right - 1) // cw + 1,
        row = (top - 1) // ch + 1,
        bottom_row = (bottom - 1) // ch + 1,
    }
end

-- box(col, row, cols, rows, cell) -> прямоугольник в ПИКСЕЛЯХ
--
-- Обратное к `cells`: место, названное в ячейках, превращается в пиксели.
-- Этим кладут всё, по чему щёлкают, и вот почему — а не ради удобства.
--
-- Правило «интерактив квантован» дисциплиной не держится. Три кнопки
-- заголовка шириной 16 px с шагом 18 px выглядят безупречно и дают ЗОНЫ
-- ПОПАДАНИЯ, КОТОРЫЕ ПЕРЕСЕКАЮТСЯ: при ячейке в 10 px первая занимает
-- колонки 24–26, вторая 26–28, третья 28–30, и щелчок по колонке 26
-- принадлежит двум кнопкам сразу. Выигрывает та, что нашлась первой, —
-- молча, и на снимке это не видно вовсе.
--
-- Поэтому место и размер интерактивной детали называются В ЯЧЕЙКАХ, а
-- свободным остаётся только рисунок ВНУТРИ неё: кнопка шириной в две ячейки
-- может нести картинку 16×14, посаженную по центру.
function pixels.box(col: any, row: any, cols: any, rows: any, cell: any): any
    local unit: any = type(cell) == "table" and cell or {}
    local cw = whole(unit.w)
    local ch = whole(unit.h)
    if cw < 1 then cw = 1 end
    if ch < 1 then ch = 1 end

    local span_x = math.max(1, whole(cols))
    local span_y = math.max(1, whole(rows))

    return {
        x = (whole(col) - 1) * cw + 1,
        y = (whole(row) - 1) * ch + 1,
        w = span_x * cw,
        h = span_y * ch,
    }
end

-- Объёмная грань в один пиксель. Выпуклая и вдавленная — одна и та же
-- функция с переставленными цветами, ровно как `DrawEdge` в GDI.
function pixels.bevel(raster, x: any, y: any, w: any, h: any, raised)
    local left, top = whole(x), whole(y)
    local width, height = whole(w), whole(h)
    if width < 2 or height < 2 then return end

    local near = raised and color.light or color.shadow
    local far = raised and color.shadow or color.light

    raster:rect(left, top, width, pixels.EDGE, near)
    raster:rect(left, top, pixels.EDGE, height, near)
    raster:rect(left, top + height - pixels.EDGE, width, pixels.EDGE, far)
    raster:rect(left + width - pixels.EDGE, top, pixels.EDGE, height, far)
end

-- Панель: лицо и выпуклая грань. Из неё сделано всё серое — рамка окна,
-- панель задач, кнопка, панель меню.
function pixels.panel(raster, x: any, y: any, w: any, h: any)
    raster:rect(whole(x), whole(y), whole(w), whole(h), color.face)
    pixels.bevel(raster, x, y, w, h, true)
end

-- Поле списка: белое и вдавленное. Значки внутри окна лежат на нём, а не на
-- лице панели — в проводнике Windows 95 это разные поверхности.
function pixels.field(raster, x: any, y: any, w: any, h: any)
    raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
    pixels.bevel(raster, x, y, w, h, false)
end

-- Надпись по центру прямоугольника.
--
-- Ширину даёт САМ шрифт (`font:measure`), а не число символов на ширину
-- глифа: пропорциональный шрифт — половина смысла пикселей, и посчитанная
-- ширина промахивается на разную величину в каждом языке.
function pixels.label(raster, x: any, y: any, w: any, h: any, text, font, tint)
    if not font then return 0 end
    local caption = tostring(text or "")
    if caption == "" then return 0 end

    local width, height = font:measure(caption)
    local left = whole(x) + (whole(w) - whole(width)) // 2
    local top = whole(y) + (whole(h) - whole(height)) // 2
    return raster:text(left, top, caption, {font = font, color = tint or color.face_text})
end

-- Кнопка, занимающая целое число ЯЧЕЕК. Место называется в ячейках нарочно —
-- см. `pixels.box`: кнопка, поставленная по пикселям, делит ячейку с соседкой,
-- и щелчок по этой ячейке принадлежит обеим.
--
-- `spec.inset` — насколько рисунок меньше своей ячейки. Так кнопка заголовка
-- рисуется настоящей 16×14 внутри двух ячеек, а нажимается по всем двум.
function pixels.button_at(raster, col: any, row: any, cols: any, rows: any,
                          spec: any, cell: any): any
    local options: any = type(spec) == "table" and spec or {}
    local area = pixels.box(col, row, cols, rows, cell)
    local pad = whole(options.inset)

    local hit = pixels.button(raster,
        area.x + pad, area.y + pad,
        area.w - pad * 2, area.h - pad * 2, options, cell)

    -- Попадание — ВСЯ ячейка, а не нарисованный прямоугольник: иначе кайма
    -- вокруг кнопки мертва, а выглядит частью кнопки.
    hit.from = whole(col)
    hit.to = whole(col) + math.max(1, whole(cols)) - 1
    hit.row = whole(row)
    hit.bottom_row = whole(row) + math.max(1, whole(rows)) - 1
    return hit
end

-- Кнопка по пикселям. Годится для того, что не нажимают, и как основа для
-- `button_at`; для нажимаемого берут её.
function pixels.button(raster, x: any, y: any, w: any, h: any, spec: any, cell: any): any
    local options: any = type(spec) == "table" and spec or {}
    pixels.panel(raster, x, y, w, h)
    if options.pressed then
        -- Нажатая — та же деталь с переставленными гранями, и надпись
        -- уезжает на пиксель вниз-вправо: в Windows 95 кнопка вдавливается
        -- вместе с содержимым.
        pixels.bevel(raster, x, y, w, h, false)
        pixels.label(raster, whole(x) + 1, whole(y) + 1, w, h,
            options.label, options.font, color.face_text)
    else
        pixels.label(raster, x, y, w, h, options.label, options.font, color.face_text)
    end

    local hit = pixels.cells(x, y, w, h, cell)
    hit.id = options.id
    return hit
end

-- Полоса заголовка: тёмно-синяя при фокусе, серая без него. Разница по ФОНУ,
-- а не по яркости текста — иначе на тёмной теме терминала оба заголовка
-- сливаются. В пикселях терминальной темы нет вовсе, но правило остаётся: по
-- фону разница видна и на снимке, и в глазах.
function pixels.title(raster, x: any, y: any, w: any, h: any, spec: any, cell: any): any
    local options: any = type(spec) == "table" and spec or {}
    local focused = options.focused and true or false

    local left, top = whole(x), whole(y)
    local width, height = whole(w), whole(h)

    raster:rect(left, top, width, height,
        focused and color.title_active_bg or color.title_idle_bg)

    local tint = focused and color.title_active_fg or color.title_idle_fg
    local font = options.font
    if font then
        local _, text_h = font:measure(tostring(options.text or ""))
        -- Текст прижат влево и центрирован по высоте полосы: заголовок в
        -- эталоне начинается с отступа в пару пикселей, а не с середины.
        raster:text(left + whole(options.pad or 4),
            top + (height - whole(text_h)) // 2,
            tostring(options.text or ""), {font = font, color = tint})
    end

    return pixels.cells(x, y, w, h, cell)
end

return pixels
