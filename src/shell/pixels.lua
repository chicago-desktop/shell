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
local images = require("images")
local logger = require("logger")
local log = logger:named("windows.icons")
local reported = {}

local color = palette.exact

local pixels = {}

-- Толщина грани. Одна, а не «сколько получится»: в Windows 95 объём — это
-- ровно один пиксель светлого сверху-слева и один тёмного снизу-справа, и
-- вторая грань крупных рамок — это уже другой цвет, а не другая толщина.
pixels.EDGE = 1

local geometry = require("geometry")
local text_lib = require("text")
local whole = geometry.whole

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

-- Win95 controls have two distinct edges. Keep the one-pixel bevel for
-- separators and window trim; a pushbutton/edit field is a different detail.
local function edge_pair(r: any, x: any, y: any, w: any, h: any, near: any, far: any)
    x, y, w, h = whole(x), whole(y), whole(w), whole(h)
    if w < 2 or h < 2 then return end
    r:rect(x, y, w - 1, 1, near)
    r:rect(x, y, 1, h - 1, near)
    r:rect(x, y + h - 1, w, 1, far)
    r:rect(x + w - 1, y, 1, h, far)
end
function pixels.edge(r: any, x: any, y: any, w: any, h: any, raised: any)
    if raised then
        edge_pair(r, x, y, w, h, color.light, color.frame)
        edge_pair(r, whole(x) + 1, whole(y) + 1, whole(w) - 2, whole(h) - 2, color.face, color.shadow)
    else
        edge_pair(r, x, y, w, h, color.shadow, color.light)
        edge_pair(r, whole(x) + 1, whole(y) + 1, whole(w) - 2, whole(h) - 2, color.frame, color.face)
    end
end
function pixels.focus_rect(r: any, x: any, y: any, w: any, h: any)
    x, y, w, h = whole(x), whole(y), whole(w), whole(h)
    if w < 2 or h < 2 then return end
    for at = 0, w - 1, 2 do
        r:rect(x + at, y, 1, 1, color.frame)
        r:rect(x + at, y + h - 1, 1, 1, color.frame)
    end
    for at = 2, h - 2, 2 do
        r:rect(x, y + at, 1, 1, color.frame)
        r:rect(x + w - 1, y + at, 1, 1, color.frame)
    end
end

-- Поле списка: белое и вдавленное. Значки внутри окна лежат на нём, а не на
-- лице панели — в проводнике Windows 95 это разные поверхности.
function pixels.field(raster, x: any, y: any, w: any, h: any)
    raster:rect(whole(x), whole(y), whole(w), whole(h), color.field)
    pixels.edge(raster, x, y, w, h, false)
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

    local width = font:measure(caption)
    local height = font:height()
    local left = whole(x) + (whole(w) - whole(width)) // 2
    local top = whole(y) + (whole(h) - whole(height)) // 2
    return raster:text(left, top, caption, {font = font, color = tint or color.face_text})
end

-- Перенос по словам ПО ИЗМЕРЕННОЙ ширине, а не по числу символов.
--
-- Это половина того, ради чего переходили на пиксели: шрифт пропорциональный,
-- и «сколько символов влезет» — вопрос, у которого нет ответа. Посчитанная
-- по символам подпись промахивается на разную величину в каждом языке.
--
-- Длинное имя переносится по символам; последняя строка отмечает
-- многоточием часть, которой не хватило места.
function pixels.wrap(font, text, room: any, limit: any): any
    local out = {}
    if not font then return out end
    local width = whole(room)
    local max = whole(limit)
    if width <= 0 or max <= 0 then return out end

    local function fits(piece)
        local measured = font:measure(piece)
        return whole(measured) <= width
    end

    local function clip(word)
        local kept = ""
        for _, rune in ipairs(text_lib.runes(word)) do
            if not fits(kept .. rune) then break end
            kept = kept .. rune
        end
        return kept
    end

    local line = ""
    local words = {}
    for word in tostring(text or ""):gmatch("%S+") do words[#words + 1] = word end
    for index, word in ipairs(words) do
        local candidate = line == "" and word or (line .. " " .. word)
        if fits(candidate) then
            line = candidate
        else
            if line ~= "" then
                if #out == max - 1 then
                    out[#out + 1] = pixels.ellipsize(font, candidate, width)
                    return out
                end
                out[#out + 1] = line
                line = ""
            end
            local rest = word
            while not fits(rest) do
                if #out == max - 1 then
                    out[#out + 1] = pixels.ellipsize(font, rest, width)
                    return out
                end
                local part = clip(rest)
                if part == "" then return out end
                out[#out + 1] = part
                rest = rest:sub(#part + 1)
            end
            line = rest
        end
    end
    if line ~= "" and #out < max then out[#out + 1] = line end
    return out
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
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    local pressed = options.pressed and not options.disabled
    raster:rect(left, top, width, height, color.face)
    if options.default and not options.disabled then
        edge_pair(raster, left, top, width, height, color.frame, color.frame)
        left, top, width, height = left + 1, top + 1, width - 2, height - 2
    end
    if pressed then
        edge_pair(raster, left, top, width, height, color.frame, color.frame)
        edge_pair(raster, left + 1, top + 1, width - 2, height - 2, color.shadow, color.face)
    else
        pixels.edge(raster, left, top, width, height, true)
    end
    local shift = pressed and 1 or 0
    local label = options.font and pixels.ellipsize(options.font, tostring(options.label or ""), math.max(0, width - 10)) or ""
    if options.disabled then
        pixels.label(raster, whole(x) + 1, whole(y) + 1, w, h, label, options.font, color.light)
        pixels.label(raster, x, y, w, h, label, options.font, color.shadow)
    else
        local tint = options.color or color.face_text
        pixels.label(raster, whole(x) + shift, whole(y) + shift, w, h, label, options.font, tint)
        -- Акселератор — подчёркнутая буква, как в ячейках у `widgets.accel`.
        -- Считается той же арифметикой, что кладёт подпись `pixels.label`:
        -- второй расчёт положения текста разъехался бы с первым.
        local at = whole(options.accel)
        if at > 0 and options.font and label ~= "" then
            local runes = text_lib.runes(label)
            if at <= #runes then
                local font: any = options.font
                local before = whole(font:measure(table.concat(runes, "", 1, at - 1)))
                local glyph = math.max(1, whole(font:measure(runes[at])))
                local text_left = whole(x) + shift + (whole(w) - whole(font:measure(label))) // 2
                local text_top = whole(y) + shift + (whole(h) - whole(font:height())) // 2
                raster:rect(text_left + before, text_top + whole(font:height()) - 2, glyph, 1, tint)
            end
        end
        if options.focused then pixels.focus_rect(raster, left + 4, top + 4, width - 8, height - 8) end
    end

    local hit = pixels.cells(x, y, w, h, cell)
    hit.id = options.id
    return hit
end

-- Standard 13px checkbox, independent of font glyph coverage.
function pixels.checkbox(r: any, x: any, y: any, checked: any, disabled: any)
    x, y = whole(x), whole(y)
    r:rect(x, y, 13, 13, disabled and color.face or color.field)
    pixels.edge(r, x, y, 13, 13, false)
    if checked then
        local tint = disabled and color.shadow or color.face_text
        for step = 0, 2 do r:rect(x + 3 + step, y + 5 + step, 1, 3, tint) end
        for step = 0, 4 do r:rect(x + 5 + step, y + 7 - step, 1, 3, tint) end
    end
end

-- ─── Знаки кнопок заголовка ──────────────────────────────────────────────
--
-- Примитивами, а не шрифтом: в Windows 95 это были маленькие растры, и
-- нарисованные шрифтом они получаются другого веса и не садятся в сетку.
-- `gfx.image` пока нет, а `rect` и `set` есть.

-- Свернуть: короткая жирная линия у нижней грани.
function pixels.mark_minimize(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left + 2, top + side - 4, side - 5, 2, tint or color.face_text)
end

-- Развернуть: рамка с утолщённой верхней гранью — это заголовок окна,
-- нарисованный в шести пикселях.
function pixels.mark_maximize(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    raster:rect(left + 1, top + 1, side - 2, side - 2, ink)
    raster:rect(left + 2, top + 4, side - 4, side - 6, color.face)
end

-- Закрыть: две диагонали. Диагональ прямоугольниками не рисуется, поэтому
-- она кладётся по пикселям — ровно тот случай, ради которого `set` и есть.
-- Толщина в два пикселя: в один крестик читается как грязь на экране.
function pixels.mark_close(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local span = side - 4
    for step = 0, span - 1 do
        raster:set(left + 2 + step, top + 2 + step, ink)
        raster:set(left + 3 + step, top + 2 + step, ink)
        raster:set(left + 2 + span - 1 - step, top + 2 + step, ink)
        raster:set(left + 3 + span - 1 - step, top + 2 + step, ink)
    end
end

-- Стрелка подменю: треугольник вправо. Строится полосками разной длины —
-- диагонали нет, а треугольник из неё и состоит.
function pixels.mark_submenu(raster, x: any, y: any, size: any, tint)
    local side = math.max(4, whole(size))
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local half = side // 2
    for step = 0, half do
        local height = (half - step) * 2 + 1
        raster:rect(left + step, top + half - (half - step), 1, height, ink)
    end
end

-- Значок пункта меню: программа — маленькое окно с заголовком, папка —
-- та же папка, что на столе. Примитивами, а не символом: в шрифте
-- геометрических символов нет, и на их месте выходит пустота.
function pixels.mark_program(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left, top, side, side, color.field)
    pixels.bevel(raster, left, top, side, side, true)
    raster:rect(left + 1, top + 1, side - 2, 3, tint or color.title_active_bg)
end

function pixels.mark_folder(raster, x: any, y: any, size: any, tint)
    local side = math.max(6, whole(size))
    local left, top = whole(x), whole(y)
    raster:rect(left, top + 2, side, side - 3, "#c8a848")
    raster:rect(left, top, side // 2, 2, "#c8a848")
    pixels.bevel(raster, left, top + 2, side, side - 3, true)
end

pixels.MARKS = {
    minimize = pixels.mark_minimize,
    maximize = pixels.mark_maximize,
    close = pixels.mark_close,
}

-- Ряд кнопок ОДИНАКОВОЙ ширины — по самой широкой подписи.
--
-- В Windows 95 кнопки диалога были одной ширины, и разноширокие «ОК» и
-- «Отмена» — первое, что выдаёт подделку. Ширина считается по ИЗМЕРЕННОМУ
-- тексту, а потом округляется вверх до целых ячеек: место интерактивной
-- детали называется в ячейках, иначе соседние кнопки делят ячейку.
--
-- Возвращает ширину в ячейках; рисует вызывающий, по ней же.
function pixels.button_span(font, labels, cell: any, least: any): integer
    local unit: any = type(cell) == "table" and cell or {}
    local cw = math.max(1, whole(unit.w))

    local widest = whole(least)
    for _, label in ipairs(type(labels) == "table" and labels or {}) do
        local measured = font and font:measure(tostring(label)) or 0
        if whole(measured) > widest then widest = whole(measured) end
    end
    -- Поля по бокам подписи: без них текст упирается в грань.
    local span = (widest + 16 + cw - 1) // cw
    if span < 1 then span = 1 end
    return math.tointeger(span) or 1
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
    -- Полужирный, а не обычный: в Windows 95 подпись заголовка набрана
    -- полужирным, и это отдельный ФАЙЛ шрифта, а не опция — синтезировать его
    -- размазыванием пикселей значит перестать быть похожим.
    local font = options.bold or options.font
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

-- Clip captions using the actual font rather than character counts.
function pixels.ellipsize(font, text, room: any)
    local caption = tostring(text or "")
    if not font or whole(room) <= 0 then return "" end
    if whole(font:measure(caption)) <= whole(room) then return caption end
    local ending = "..."
    if whole(font:measure(ending)) > whole(room) then return "" end
    local kept = ""
    for _, rune in ipairs(text_lib.runes(caption)) do
        if whole(font:measure(kept .. rune .. ending)) > whole(room) then break end
        kept = kept .. rune
    end
    return kept .. ending
end

-- Native PNGs are cached by images for the lifetime of the process.
-- Keep primitives for missing assets and broken shortcuts; report failures once.
local function native_icon(raster, x: any, y: any, item: any, size: any)
    local name = images.name_for(item)
    if not name then return false end
    local ok, why = images.icon(raster, whole(x), whole(y), item, size)
    if ok then return true end
    local key = tostring(name) .. "@" .. tostring(size)
    if not reported[key] then
        reported[key] = true
        log:warn("значок не загружен", {icon = key, error = tostring(why)})
    end
    return false
end

function pixels.icon(raster, x: any, y: any, item: any, size: any)
    local side = whole(size or 32)
    if native_icon(raster, x, y, item, side) then return end
    if side == 16 then
        if item.kind == "folder" or item.kind == "directory" or item.kind == "group" then
            pixels.mark_folder(raster, whole(x), whole(y), side, color.face_text)
        else
            pixels.mark_program(raster, whole(x), whole(y), side, color.face_text)
        end
        if item.broken then
            for i = 0, 7 do
                raster:set(whole(x) + 4 + i, whole(y) + 4 + i, color.alert)
                raster:set(whole(x) + 11 - i, whole(y) + 4 + i, color.alert)
            end
        end
        return
    end
    local left, top = whole(x), whole(y)
    local function rect(dx, dy, w, h, ink)
        raster:rect(left + dx, top + dy, w, h, ink)
    end
    local kind = item.kind
    if kind == "folder" or kind == "directory" then
        rect(2, 6, 12, 2, "#000000")
        rect(1, 8, 28, 21, "#000000")
        rect(3, 7, 10, 3, "#ffff80")
        rect(2, 10, 26, 17, "#808000")
        rect(3, 10, 24, 2, "#ffff80")
        rect(4, 13, 27, 2, "#000000")
        rect(3, 15, 27, 5, "#000000")
        rect(2, 20, 27, 6, "#000000")
        rect(1, 26, 27, 3, "#000000")
        rect(5, 14, 25, 2, "#ffff80")
        rect(4, 16, 25, 4, "#ffff00")
        rect(3, 20, 25, 6, "#ffff00")
        rect(2, 26, 25, 2, "#c0c000")
    elseif item.entry == "butschster.windows.explorer:window" then
        rect(4, 0, 24, 22, "#000000")
        rect(5, 1, 22, 20, "#c0c0c0")
        rect(5, 1, 22, 1, "#ffffff")
        rect(5, 1, 1, 19, "#ffffff")
        rect(7, 3, 18, 15, "#808080")
        rect(8, 4, 16, 12, "#000000")
        rect(9, 5, 14, 10, "#000080")
        rect(10, 6, 12, 1, "#008080")
        rect(10, 7, 11, 5, "#008080")
        rect(10, 13, 12, 1, "#0080ff")
        rect(21, 19, 3, 1, "#00ff00")
        rect(12, 22, 8, 3, "#808080")
        rect(10, 24, 12, 2, "#000000")
        rect(1, 26, 29, 6, "#000000")
        rect(2, 26, 27, 4, "#ffffff")
        rect(3, 27, 25, 3, "#c0c0c0")
        rect(4, 28, 16, 1, "#808080")
        rect(23, 28, 3, 1, "#000000")
    elseif kind == "drive" then
        rect(3, 12, 26, 16, "#000000")
        rect(4, 10, 23, 3, "#000000")
        rect(5, 9, 21, 2, "#000000")
        rect(6, 10, 19, 3, "#ffffff")
        rect(5, 13, 22, 3, "#c0c0c0")
        rect(4, 17, 24, 9, "#c0c0c0")
        rect(4, 17, 24, 1, "#ffffff")
        rect(4, 18, 1, 8, "#ffffff")
        rect(7, 20, 14, 2, "#000000")
        rect(7, 22, 14, 1, "#ffffff")
        rect(24, 22, 2, 2, "#008000")
        rect(4, 26, 24, 1, "#808080")
    else
        rect(4, 2, 24, 28, "#000000")
        rect(5, 3, 22, 26, "#ffffff")
        rect(6, 4, 20, 5, "#000080")
        rect(7, 5, 3, 3, "#ffffff")
        rect(23, 5, 2, 3, "#c0c0c0")
        rect(8, 12, 15, 1, "#808080")
        rect(8, 15, 12, 1, "#808080")
        rect(8, 18, 15, 1, "#808080")
        rect(8, 21, 9, 1, "#808080")
        if item.broken then
            for i = 0, 8 do
                rect(12 + i, 13 + i, 2, 2, "#800000")
                rect(20 - i, 13 + i, 2, 2, "#800000")
            end
        end
    end
    if kind == "shortcut" and item.entry ~= "butschster.windows.explorer:window" then
        rect(0, 23, 10, 9, "#000000")
        rect(1, 24, 8, 7, "#ffffff")
        rect(3, 26, 4, 2, "#000000")
        rect(5, 25, 2, 4, "#000000")
        rect(2, 28, 2, 2, "#000000")
    end
end

-- ─── знаки панели инструментов ──────────────────────────────────────────
--
-- Символы панели (✂ ⧉ ⎘ ↶ ✕ ▤ ▦ ▩ ≡ ☷) — это глифы для ячеек; в Liberation их
-- нет, и отсутствующая руна рисуется пробелом. Поэтому в пикселях каждый
-- знак — примитивы в квадрате `size`, как у кнопок заголовка.

local function hline(raster, x: any, y: any, len: any, ink)
    raster:rect(whole(x), whole(y), math.max(1, whole(len)), 1, ink)
end

local function vline(raster, x: any, y: any, len: any, ink)
    raster:rect(whole(x), whole(y), 1, math.max(1, whole(len)), ink)
end

local function hollow(raster, x: any, y: any, w: any, h: any, ink)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    hline(raster, left, top, width, ink)
    hline(raster, left, top + height - 1, width, ink)
    vline(raster, left, top, height, ink)
    vline(raster, left + width - 1, top, height, ink)
end

-- Стрелки: древко в две линии и голова из полосок убывающей длины.
function pixels.mark_back(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = top + side // 2
    raster:rect(left + 5, mid - 1, side - 6, 3, ink)
    for step = 0, 4 do hline(raster, left + 1 + step, mid - step, 1 + step * 2 // 1, ink) end
    for step = 0, 4 do hline(raster, left + 1 + step, mid + step, 1, ink) end
    for step = 1, 4 do vline(raster, left + 1 + step, mid - step, step * 2 + 1, ink) end
end

function pixels.mark_forward(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = top + side // 2
    raster:rect(left + 1, mid - 1, side - 6, 3, ink)
    for step = 1, 4 do vline(raster, left + side - 2 - step, mid - step, step * 2 + 1, ink) end
    raster:set(left + side - 2, mid, ink)
end

function pixels.mark_up(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = left + side // 2
    raster:rect(mid - 1, top + 5, 3, side - 6, ink)
    for step = 1, 4 do hline(raster, mid - step, top + 1 + step, step * 2 + 1, ink) end
    raster:set(mid, top + 1, ink)
end

-- Ножницы: два лезвия крест-накрест и два кольца рукояток внизу.
function pixels.mark_cut(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    for step = 0, side - 7 do
        raster:set(left + 2 + step, top + step, ink)
        raster:set(left + side - 3 - step, top + step, ink)
    end
    hollow(raster, left + 1, top + side - 5, 4, 4, ink)
    hollow(raster, left + side - 5, top + side - 5, 4, 4, ink)
end

-- Копировать: два листа, второй выглядывает из-под первого.
function pixels.mark_copy(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 1, top + 1, side - 5, side - 5, ink)
    raster:rect(left + 5, top + 5, side - 6, side - 6, color.field)
    hollow(raster, left + 5, top + 5, side - 6, side - 6, ink)
end

-- Вставить: планшет с зажимом и лист на нём.
function pixels.mark_paste(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 1, top + 2, side - 4, side - 3, ink)
    raster:rect(left + side // 2 - 2, top + 1, 4, 2, ink)
    raster:rect(left + 5, top + 6, side - 6, side - 7, color.field)
    hollow(raster, left + 5, top + 6, side - 6, side - 7, ink)
end

-- Отменить: стрелка влево с хвостом, загнутым вниз и вправо.
function pixels.mark_undo(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local row = top + 4
    raster:rect(left + 4, row, side - 7, 2, ink)
    vline(raster, left + side - 4, row, 5, ink); vline(raster, left + side - 3, row, 5, ink)
    raster:rect(left + side - 8, row + 4, 5, 2, ink)
    for step = 1, 3 do vline(raster, left + 1 + step, row - step + 1, step * 2, ink) end
end

pixels.mark_delete = pixels.mark_close

-- Свойства: лист с тремя строками.
function pixels.mark_properties(raster, x: any, y: any, size: any, tint)
    local side = math.max(10, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    hollow(raster, left + 2, top + 1, side - 4, side - 2, ink)
    for line = 0, 2 do hline(raster, left + 4, top + 4 + line * 3, side - 8, ink) end
end

-- Четыре вида: крупные значки, мелкие, список, таблица.
function pixels.mark_view_large(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 1 do for col = 0, 1 do hollow(raster, left + 1 + col * 7, top + 1 + row * 7, 6, 6, ink) end end
end

function pixels.mark_view_small(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 2 do for col = 0, 2 do raster:rect(left + 1 + col * 5, top + 1 + row * 5, 3, 3, ink) end end
end

function pixels.mark_view_list(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 2 do
        raster:rect(left + 1, top + 2 + row * 5, 3, 3, ink)
        hline(raster, left + 6, top + 3 + row * 5, 8, ink)
    end
end

function pixels.mark_view_details(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y); local ink = tint or color.face_text
    for row = 0, 3 do hline(raster, left + 1, top + 1 + row * 4, 13, ink) end
    vline(raster, left + 1, top + 1, 13, ink); vline(raster, left + 6, top + 1, 13, ink); vline(raster, left + 13, top + 1, 13, ink)
end

-- Треугольник вниз — кнопка раскрытия списка.
function pixels.mark_drop(raster, x: any, y: any, size: any, tint)
    local side = math.max(8, whole(size)); local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    local mid = left + side // 2
    for step = 0, 3 do hline(raster, mid - 3 + step, top + side // 2 - 2 + step, 7 - step * 2, ink) end
end

pixels.MARKS.back = pixels.mark_back
pixels.MARKS.forward = pixels.mark_forward
pixels.MARKS.up = pixels.mark_up
pixels.MARKS.cut = pixels.mark_cut
pixels.MARKS.copy = pixels.mark_copy
pixels.MARKS.paste = pixels.mark_paste
pixels.MARKS.undo = pixels.mark_undo
pixels.MARKS.delete = pixels.mark_delete
pixels.MARKS.properties = pixels.mark_properties
pixels.MARKS.view_large = pixels.mark_view_large
pixels.MARKS.view_small = pixels.mark_view_small
pixels.MARKS.view_list = pixels.mark_view_list
pixels.MARKS.view_details = pixels.mark_view_details
pixels.MARKS.drop = pixels.mark_drop

-- Выцветший знак Windows 95: серый, с белой копией на пиксель ниже и правее.
function pixels.mark_disabled(raster, mark, x: any, y: any, size: any)
    if type(mark) ~= "function" then return end
    mark(raster, whole(x) + 1, whole(y) + 1, size, color.light)
    mark(raster, x, y, size, color.shadow)
end

function pixels.mark_help(raster, x: any, y: any, size: any, tint)
    local left, top = whole(x), whole(y)
    local ink = tint or color.face_text
    raster:rect(left + 3, top + 1, 4, 1, ink)
    raster:set(left + 2, top + 2, ink)
    raster:rect(left + 7, top + 2, 1, 2, ink)
    raster:rect(left + 5, top + 4, 2, 1, ink)
    raster:rect(left + 4, top + 5, 1, 2, ink)
    raster:set(left + 4, top + 8, ink)
end
pixels.MARKS.help = pixels.mark_help

function pixels.flag(raster, x: any, y: any)
    if native_icon(raster, x, y, {image = "windows"}, 16) then return end
    local left, top = whole(x), whole(y)
    raster:rect(left + 3, top, 12, 13, "#000000")
    raster:rect(left + 4, top + 1, 4, 4, "#ff0000")
    raster:rect(left + 10, top + 2, 4, 4, "#00ff00")
    raster:rect(left + 4, top + 7, 4, 4, "#0000ff")
    raster:rect(left + 10, top + 8, 4, 4, "#ffff00")
    raster:rect(left, top + 1, 2, 2, "#000000")
    raster:rect(left + 1, top + 5, 2, 2, "#000000")
    raster:rect(left, top + 9, 2, 2, "#000000")
end


-- ─── Полоса прокрутки и статусная строка ─────────────────────────────────
--
-- Одна полоса на всех: списки, таблицы и дерево SDK, поле проводника.
-- Шесть рисовалок над одним `scroll.bar` разъезжались по ширине ползунка и
-- виду стрелок; теперь геометрия приходит готовой (`bar` из `scroll.bar`:
-- start, size, limit — в строках), а вид у полосы один.
--
-- `row_h` — высота строки в пикселях, `arrow_h` — высота кнопки-стрелки.
function pixels.scrollbar(raster, x: any, y: any, w: any, h: any, bar: any, row_h: any, arrow_h: any)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    if width < 3 or height < 4 then return end
    local arrow = math.min(math.max(4, whole(arrow_h)), height // 2)
    raster:rect(left, top, width, height, color.face)
    pixels.panel(raster, left, top, width, arrow)
    pixels.panel(raster, left, top + height - arrow, width, arrow)
    local center = left + width // 2
    for step = 0, 3 do
        raster:rect(center - step, top + (arrow - 4) // 2 + step, step * 2 + 1, 1, color.face_text)
        raster:rect(center - step, top + height - (arrow - 4) // 2 - step - 1, step * 2 + 1, 1, color.face_text)
    end
    local thumb: any = type(bar) == "table" and bar or {}
    if whole(thumb.limit) > 0 and whole(thumb.size) > 0 then
        pixels.panel(raster, left, top + whole(thumb.start) * whole(row_h), width, whole(thumb.size) * whole(row_h))
    end
end

-- Статусная строка: вдавленные поля, последнее растягивается; у поля своя
-- ширина в пикселях (`width`) или по тексту.
function pixels.statusbar(raster, x: any, y: any, w: any, h: any, fields: any, font: any)
    local left, top, width, height = whole(x), whole(y), whole(w), whole(h)
    raster:rect(left, top, width, height, color.face)
    local list: any = type(fields) == "table" and fields or {}
    local at = left + 2
    local right = left + width - 2
    for index, entry in ipairs(list) do
        local field: any = type(entry) == "table" and entry or {text = tostring(entry)}
        local text = tostring(field.text or "")
        local text_w = font and whole(font:measure(text)) or 0
        local want = whole(field.width) > 0 and whole(field.width) or text_w + 12
        if index == #list then want = right - at end
        want = math.min(want, right - at)
        if want < 8 then break end
        pixels.bevel(raster, at, top + 1, want, height - 2, false)
        if font then
            raster:text(at + 4, top + (height - 15) // 2, pixels.ellipsize(font, text, want - 8),
                {font = font, color = color.face_text})
        end
        at = at + want + 2
    end
end

return pixels
