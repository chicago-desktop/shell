-- Раскладка калькулятора — кнопки в ЯЧЕЙКАХ, без gfx и без рантайма.
--
-- Читают двое: краски рисуют кнопку по этой таблице, поставщик по ней же
-- считает, какая кнопка под щелчком. Одна таблица — иначе «7» однажды
-- нарисуется на ячейку левее того места, где нажимается.
--
-- Сетка та же, что в обычном виде калькулятора Windows 95: табло, строка
-- Back/CE/C с окошком памяти, четыре ряда клавиш с колонкой памяти слева.
-- Место названо в ячейках нарочно (FR-005 §4а): кнопка шириной в четыре
-- ячейки рисуется с отступом внутри, и две соседние не делят ячейку.

local layout = {}

layout.COLS = 31
layout.ROWS = 13

layout.MENU = {"Правка", "Вид", "Справка"}

-- Цвета подписей — как в оригинале: цифры и функции синие, операции,
-- сброс и память красные.
layout.RED = "#ff0000"
layout.BLUE = "#0000ff"

local KEY_COLS: any = {{7, 10}, {12, 15}, {17, 20}, {22, 25}, {27, 30}}
local MEMORY_COLS: any = {2, 5}

local KEYPAD: any = {
    {row = 5,  memory = {"mc", "MC"}, keys = {{"7", "7", "blue"}, {"8", "8", "blue"}, {"9", "9", "blue"}, {"div", "/", "red"}, {"sqrt", "sqrt", "blue"}}},
    {row = 7,  memory = {"mr", "MR"}, keys = {{"4", "4", "blue"}, {"5", "5", "blue"}, {"6", "6", "blue"}, {"mul", "*", "red"}, {"pct", "%", "blue"}}},
    {row = 9,  memory = {"ms", "MS"}, keys = {{"1", "1", "blue"}, {"2", "2", "blue"}, {"3", "3", "blue"}, {"sub", "-", "red"}, {"inv", "1/x", "blue"}}},
    {row = 11, memory = {"mplus", "M+"}, keys = {{"0", "0", "blue"}, {"neg", "+/-", "blue"}, {"dot", ".", "blue"}, {"add", "+", "red"}, {"eq", "=", "red"}}},
}

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

local cached: any = nil

-- buttons() -> список {id, label, ink, from, to, row, bottom_row}
function layout.buttons(): any
    if cached then return cached end
    local out = {}
    local function add(id: any, label: any, ink: any, from: any, to: any, row: any)
        out[#out + 1] = {id = id, label = label, ink = ink,
            from = from, to = to, row = row, bottom_row = row + 1}
    end
    add("back", "Back", "red", 11, 16, 3)
    add("ce", "CE", "red", 18, 23, 3)
    add("c", "C", "red", 25, 30, 3)
    for _, line in ipairs(KEYPAD) do
        add(line.memory[1], line.memory[2], "red", MEMORY_COLS[1], MEMORY_COLS[2], line.row)
        for index, key in ipairs(line.keys) do
            add(key[1], key[2], key[3], KEY_COLS[index][1], KEY_COLS[index][2], line.row)
        end
    end
    cached = out
    return out
end

-- Где табло и окошко памяти — тоже в ячейках, чтобы краски не считали сами.
function layout.display(): any
    return {from = 2, to = layout.COLS - 1, row = 2}
end

function layout.memory_box(): any
    return {from = 2, to = 4, row = 3, bottom_row = 4}
end

-- Строки растров: меню, табло и каждый ряд кнопок отдельно, чтобы нажатие
-- переотправляло табло и один ряд, а не всю клавиатуру.
function layout.slices(): any
    return {
        {id = "menu", y = 1, rows = 1},
        {id = "display", y = 2, rows = 1},
        {id = "row3", y = 3, rows = 2},
        {id = "row5", y = 5, rows = 2},
        {id = "row7", y = 7, rows = 2},
        {id = "row9", y = 9, rows = 2},
        {id = "row11", y = 11, rows = 2},
        {id = "foot", y = 13, rows = 1},
    }
end

-- button_at(x, y) -> id или nil. Координаты — ячейки содержимого.
function layout.button_at(x: any, y: any): any
    local col, row = whole(x), whole(y)
    for _, button in ipairs(layout.buttons()) do
        if row >= button.row and row <= button.bottom_row
            and col >= button.from and col <= button.to then
            return button.id
        end
    end
    return nil
end

return layout
