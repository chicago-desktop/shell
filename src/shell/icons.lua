-- Значок с подписью — один на всю оболочку.
--
-- Отдельная библиотека, а не кусок темы, по одной причине: значок рисуют
-- ДВОЕ. Стол рисует его композитором, а окно «Мой компьютер» — само, изнутри
-- своего процесса, в свой tty. Повторённый у второго, он разошёлся бы с
-- первым на первой правке, и разошёлся бы ВИДОМ, а не отказом: внутри
-- Windows 95 оказался бы другой Windows 95, и заметили бы это через неделю.
--
-- Отсюда форма функций: они принимают ЦЕЛЬ рисования, а не чей-то холст.
-- Целью годится любой `tty.canvas` — и тот, что держит композитор, и тот,
-- что окно заводит себе под свой viewport; это один и тот же тип, поэтому
-- сечение проходит здесь, а не по границе процессов.
--
-- Поверхностей две, и их нельзя путать: на столе подпись белая на бирюзовом,
-- в окне — чёрная на белом поле списка.

local tty = require("tty")

local glyphs = require("glyphs")
local palette = require("palette")

local color = palette.active

local icons = {}

-- Ячейка значка. `w` и `h` — ШАГ сетки, `drawn` — сколько строк занято
-- рисунком. Числа разные нарочно: шагом раскладывают, по нарисованному
-- считают попадание. Возьми одно вместо другого — значки встанут вплотную,
-- и подпись одного упрётся в картинку следующего.
local CELL_W = 12
local CELL_H = 4
local CELL_DRAWN = 3
local CELL_CAPTION = 2
local CELL_LEFT = 2

function icons.grid()
    return {w = CELL_W, h = CELL_H, drawn = CELL_DRAWN, caption = CELL_CAPTION, left = CELL_LEFT}
end

local surfaces = {
    desktop = {
        back   = tty.style():background(color.desktop),
        icon   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        text   = tty.style():bold():foreground(color.desktop_text):background(color.desktop),
        broken = tty.style():bold():foreground(color.desktop_broken):background(color.desktop),
        select = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    },
    panel = {
        back   = tty.style():background(color.field),
        icon   = tty.style():foreground(color.field_text):background(color.field),
        text   = tty.style():foreground(color.field_text):background(color.field),
        -- На белом поле жёлтый не виден вовсе, поэтому битый здесь бордовый.
        -- Цвет разный, признак один: значок ▨ плюс отличная от прочих подпись.
        broken = tty.style():bold():foreground(color.alert):background(color.field),
        select = tty.style():bold():foreground(color.select_fg):background(color.select_bg),
    },
}

local geometry = require("geometry")
local whole = geometry.whole

local function cells(text): integer
    return whole(tty.text.width(text))
end

local function clip(text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    return tty.text.truncate(tostring(text or ""), width)
end

-- Перенос по словам. Вторым значением — признак того, что текст НЕ
-- поместился: слово длиннее строки пришлось резать или строк не хватило.
-- Без него «влезло» и «влезло наполовину» на выходе неразличимы, а разница
-- ровно в том, увидит человек имя целиком или нет.
function icons.wrap(text, room: any, limit: any)
    local width = whole(room)
    local max = whole(limit)
    local out = {}
    if width <= 0 or max <= 0 then return out, true end

    local overflow = false
    local line = ""

    local function flush(): boolean
        if line == "" then return true end
        if #out >= max then
            overflow = true
            return false
        end
        out[#out + 1] = line
        line = ""
        return true
    end

    for word in tostring(text):gmatch("%S+") do
        local candidate = line == "" and word or (line .. " " .. word)
        if cells(candidate) <= width then
            line = candidate
        else
            if not flush() then return out, true end
            if cells(word) > width then
                -- Слово, которое само шире строки, переносить некуда.
                overflow = true
                line = clip(word, width)
            else
                line = word
            end
        end
    end
    flush()
    return out, overflow
end

-- caption_lines(title, room) — подпись так, как её нарисует значок.
--
-- Отдана наружу нарочно: повторить это правило у себя — значит завести
-- копию, которая разъедется молча, потому что тест на копии останется
-- зелёным, а на экране будет другое. Второе значение — «имя не
-- поместилось», по нему и проверяют мебель.
function icons.caption_lines(title, room: any)
    local width = whole(room)
    if width <= 0 then width = CELL_W end
    return icons.wrap(title or "?", width, CELL_CAPTION)
end

local function centered(style, text, room: any)
    local width = whole(room)
    if width <= 0 then return "" end
    local body = clip(text, width)
    local left = (width - cells(body)) // 2
    return style:render(string.rep(" ", left) .. body
        .. string.rep(" ", width - left - cells(body)))
end

-- Значок: картинка строкой и подпись до двух строк под ней, по центру.
--
-- Возвращает занятый прямоугольник — {from, to, top, bottom} — или nil,
-- если места не хватило. Попадание из него строит ВЫЗЫВАЮЩИЙ: у стола в
-- попадании едут entry, w, h и args, у окна — свой набор, и навязывать
-- одному форму другого значит сделать обоим неудобно.
--
-- `state`: `selected` — выделен, `surface` — "desktop" или "panel",
-- `room` — ширина колонки, если она уже, чем ячейка (у правого края).
-- box(x, y, room) -> прямоугольник значка в ЯЧЕЙКАХ
--
-- Вынесено из отрисовки, потому что читателей стало двое: рисует `icons.cell`,
-- а раскладку окна считает `render.layout` — и считает ДО того, как что-то
-- нарисовано, потому что пиксельный бэкенд рисует не сюда.
--
-- Посчитай они порознь — попадание разъедется с рисунком на ячейку, и это
-- ровно тот дефект, из-за которого правило «рисование и хит-тест из одной
-- таблицы» здесь вообще появилось. Теперь таблица одна и она тут.
--
-- `room` — ширина колонки, `CELL_DRAWN` — сколько строк занимает рисунок.
-- Высота НЕ равна шагу сетки: шагом раскладывают, по нарисованному считают
-- попадание.
function icons.box(x: any, y: any, room: any): any
    local col, row = whole(x), whole(y)
    local span = whole(room)
    if span <= 0 then span = CELL_W end
    if span < 3 then return nil end
    return {from = col, to = col + span - 1, top = row, bottom = row + CELL_DRAWN - 1}
end

function icons.cell(target, x: any, y: any, item, state)
    local opts: any = type(state) == "table" and state or {}
    local surface: any = surfaces[opts.surface] or surfaces.desktop

    local col, row = whole(x), whole(y)
    local span = whole(opts.room)
    if span <= 0 then span = CELL_W end
    local box = icons.box(col, row, span)
    if not box then return nil end

    local record: any = type(item) == "table" and item or {}

    -- Битый ярлык виден и значком, и цветом подписи. Одного значка мало на
    -- мелком шрифте, одного цвета — на монохромном терминале; пропасть же он
    -- не имеет права: пропавший значок читается как «я его случайно удалил»,
    -- битый — как «программы больше нет».
    local broken = record.broken and true or false
    local glyph
    if broken then glyph = glyphs.icons.broken
    elseif record.kind == "folder" then glyph = glyphs.icons.folder
    elseif type(record.icon) == "string" and record.icon ~= "" then glyph = record.icon
    else glyph = glyphs.icons.unknown end

    target:put(col, row, centered(surface.icon, glyph, span), span)

    -- Выделение — инверсией по ТЕКСТУ, а не по всей колонке: в проводнике
    -- Windows 95 синий прямоугольник обнимает подпись, и по нему видно, где
    -- она кончается.
    local caption = broken and surface.broken or surface.text
    if opts.selected then caption = surface.select end

    local lines = icons.caption_lines(record.title, span)
    for line = 1, CELL_CAPTION do
        local text = lines[line]
        if text then
            local pad = (span - cells(text)) // 2
            target:put(col, row + line,
                surface.back:render(string.rep(" ", pad))
                .. caption:render(text)
                .. surface.back:render(string.rep(" ", span - pad - cells(text))),
                span)
        end
    end

    return box
end

return icons
