-- «Свойства: Экран», чистая модель: цвета стола, проверка формы цвета,
-- подписи разрешения. Ничего про базу и композитор — это у окна.
local geometry = require("geometry")
local whole = geometry.whole

local model = {}

model.DEFAULT = "#008080"

-- Цвета стола: набор стандартной палитры Windows 95, бирюзовый первым —
-- он стол по умолчанию. Пользовательский цвет из базы, которого здесь нет,
-- показывается отдельной строкой «Другой», а не подменяется ближайшим.
model.COLORS = {
    {id = "#008080", text = "Бирюзовый"},
    {id = "#000080", text = "Тёмно-синий"},
    {id = "#008000", text = "Зелёный"},
    {id = "#808080", text = "Серый"},
    {id = "#800000", text = "Тёмно-красный"},
    {id = "#808000", text = "Оливковый"},
    {id = "#800080", text = "Фиолетовый"},
    {id = "#000000", text = "Чёрный"},
    {id = "#c0c0c0", text = "Серебристый"},
    {id = "#0000ff", text = "Синий"},
    {id = "#00ffff", text = "Голубой"},
    {id = "#ffffff", text = "Белый"},
}

model.TABS = {{text = "Фон"}, {text = "Настройка"}}

function model.valid(hex: any): boolean
    return type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$") ~= nil
end

-- Строки списка: стандартные цвета плюс «Другой», если выбранный не из них.
function model.color_items(chosen: any): any
    local items = {}
    local known = false
    for _, entry in ipairs(model.COLORS) do
        items[#items + 1] = {id = entry.id, text = entry.text}
        if entry.id == chosen then known = true end
    end
    if model.valid(chosen) and not known then
        items[#items + 1] = {id = chosen, text = "Другой (" .. tostring(chosen) .. ")"}
    end
    return items
end

-- Разрешение: ячейки и пиксели одной строкой в поле, размер ячейки —
-- подписью под ним. Без размера ячейки пиксели не выдумываются: «80×24
-- ячеек» честнее, чем «640×480» из запасного значения.
function model.resolution(screen: any, cell: any): string
    local s: any = type(screen) == "table" and screen or {}
    local c: any = type(cell) == "table" and cell or {}
    local cols, rows = whole(s.width), whole(s.height)
    if cols < 1 or rows < 1 then return "неизвестно" end
    local text = string.format("%d × %d ячеек", cols, rows)
    if whole(c.w) > 0 and whole(c.h) > 0 then
        text = text .. string.format(", %d × %d px", cols * whole(c.w), rows * whole(c.h))
    end
    return text
end

function model.cell_text(cell: any): string
    local c: any = type(cell) == "table" and cell or {}
    if whole(c.w) > 0 and whole(c.h) > 0 then
        return string.format("Ячейка терминала %d × %d px", whole(c.w), whole(c.h))
    end
    return "Размер ячейки терминал не назвал"
end

-- Палитра: рантайм принудительно включает TrueColor; режим кадра называет
-- композитор и идёт подписью.
function model.palette(): string
    return "True Color (24 бит)"
end

function model.graphics(pixels: any): string
    if pixels == true then return "Пиксельная графика: есть" end
    return "Пиксельная графика: нет, только ячейки"
end

return model
