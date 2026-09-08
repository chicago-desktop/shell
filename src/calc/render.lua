-- Краски калькулятора: строка меню, табло, окошко памяти, кнопки.
--
-- Раскладку не считает — кнопки, табло и нарезка приходят из `layout`,
-- оттуда же их читает поставщик. Здесь только пиксели, и потому это
-- единственная запись калькулятора, объявившая `gfx`.
--
-- Кадр нарезан по РЯДАМ (`layout.slices`): нажатие меняет табло и подсветку
-- одной кнопки, и переотправляются два растра, а не клавиатура целиком.
-- Растры берутся у хранилища темы по ключу-отпечатку и не пересоздаются.

local palette = require("palette")
local pixels = require("pixels")
local layout = require("layout")

local color = palette.exact

local render = {}

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Растр со сдвигом: рисуем в координатах содержимого окна, кусок видит свои
-- строки. Методы те же, что у gfx.Raster, — примитивы `pixels` о сдвиге не
-- знают.
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

local INK: any = {red = layout.RED, blue = layout.BLUE}

-- Кнопка: панель с отступом внутри своих ячеек, подпись цветом оригинала.
-- Нажатая — вдавленная грань и подпись на пиксель вниз-вправо.
local function key_button(r: any, button: any, cell: any, font, pressed)
    local area = pixels.box(button.from, button.row, button.to - button.from + 1,
        button.bottom_row - button.row + 1, cell)
    local h = math.min(29, whole(area.h) - 6)
    local x, y = area.x + 2, area.y + (area.h - h) // 2
    local w = area.w - 4
    pixels.panel(r, x, y, w, h)
    if pressed then pixels.bevel(r, x, y, w, h, false) end
    if not font then return end
    local tw = whole(font:measure(button.label))
    local shift = pressed and 1 or 0
    r:text(x + (w - tw) // 2 + shift, y + (h - 15) // 2 + shift, button.label,
        {font = font, color = INK[button.ink] or color.face_text})
end

local function scene(r: any, cell: any, state: any, fonts: any)
    local face: any = type(fonts) == "table" and fonts.face or nil
    r:fill(color.face)

    -- Строка меню: подписи без действия — калькулятор только считает, но
    -- без них он не читается как окно Windows 95.
    local menu = pixels.box(1, 1, layout.COLS, 1, cell)
    if face then
        local at = menu.x + 6
        for _, item in ipairs(layout.MENU) do
            at = at + whole(r:text(at, menu.y + (menu.h - 15) // 2, item,
                {font = face, color = color.face_text})) + 14
        end
    end

    -- Табло: белое вдавленное поле, число прижато вправо.
    local spec = layout.display()
    local display = pixels.box(spec.from, spec.row, spec.to - spec.from + 1, 1, cell)
    pixels.field(r, display.x, display.y + 1, display.w, display.h - 2)
    if face then
        local text = tostring(state.display or "0.")
        local tw = whole(face:measure(text))
        r:text(display.x + display.w - tw - 5, display.y + 1 + (display.h - 2 - 15) // 2, text,
            {font = face, color = color.field_text})
    end

    -- Окошко памяти: вдавленное, с буквой M, когда память занята.
    local slot = layout.memory_box()
    local box = pixels.box(slot.from, slot.row, slot.to - slot.from + 1,
        slot.bottom_row - slot.row + 1, cell)
    local mh = math.min(29, whole(box.h) - 6)
    pixels.field(r, box.x + 2, box.y + (box.h - mh) // 2, box.w - 4, mh)
    if face and state.memory then
        local tw = whole(face:measure("M"))
        r:text(box.x + 2 + (box.w - 4 - tw) // 2, box.y + (box.h - 15) // 2, "M",
            {font = face, color = color.field_text})
    end

    for _, button in ipairs(layout.buttons()) do
        key_button(r, button, cell, face, state.pressed == button.id)
    end
end

-- Отпечаток куска: табло зависит от числа и памяти, ряд кнопок — от того,
-- нажата ли кнопка в нём. Ключ, взявший лишнее, перерисовывает зря; забывший
-- нужное — показывает вчерашнее число.
local function key_for(slice: any, state: any, inner: any)
    local parts = {tostring(inner.cols), tostring(slice.rows)}
    if slice.id == "display" then
        parts[#parts + 1] = tostring(state.display)
    elseif slice.id == "row3" then
        parts[#parts + 1] = state.memory and "M" or "-"
    end
    if slice.id ~= "menu" and slice.id ~= "display" and slice.id ~= "foot" then
        local pressed = tostring(state.pressed or "")
        for _, button in ipairs(layout.buttons()) do
            if button.id == pressed and button.row == slice.y then
                parts[#parts + 1] = "pressed:" .. pressed
            end
        end
    end
    return table.concat(parts, "\31")
end

-- placement(window, inner, cell, fonts, store) -> список размещений
function render.placement(window: any, inner: any, cell: any, fonts: any, store: any): (any, any)
    if type(store) ~= "table" or type(store.take) ~= "function" then
        return nil, "калькулятору не дали хранилища растров"
    end
    local state: any = type(window.content_state) == "table" and window.content_state or nil
    if not state then return nil, "калькулятор ещё не ответил" end
    if whole(inner.cols) < layout.COLS or whole(inner.rows) < layout.ROWS then
        return nil, string.format("окну нужно %d×%d ячеек, дано %d×%d",
            layout.COLS, layout.ROWS, whole(inner.cols), whole(inner.rows))
    end

    local out = {}
    local prefix = "win:" .. tostring(window.id) .. ":view:"
    for _, slice in ipairs(layout.slices()) do
        local id = prefix .. slice.id
        local raster, dirty = store.take(id, inner.cols, slice.rows, cell, key_for(slice, state, inner))
        if dirty then
            scene(pane(raster, 0, (slice.y - 1) * whole(cell.h)), cell, state, fonts)
        end
        out[#out + 1] = {id = id, raster = raster,
            x = whole(inner.x), y = whole(inner.y) + slice.y - 1,
            cols = whole(inner.cols), rows = slice.rows}
    end
    return out, nil
end

return render
