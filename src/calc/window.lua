-- Калькулятор — окно на SDK оболочки. Считает `engine`, рисует SDK.
--
-- Сетка та же, что в обычном виде калькулятора Windows 95, и та же, что
-- была у собственного отрисовщика: табло, строка Back/CE/C с окошком памяти,
-- четыре ряда клавиш с колонкой памяти слева; кнопка — четыре ячейки,
-- между кнопками одна. Раскладку держит `view`: те же числа читают оба
-- отрисовщика и попадания, второй таблицы больше нет.
--
-- Клавиша с клавиатуры идёт в ту же кнопку, что и щелчок (`engine.key`);
-- нажатая ею кнопка подсвечивается на 150 мс — своим каналом-таймером,
-- а не тиком: тик без дела жёг бы кадры.
--
-- В меню только то, что работает: «Справка → О программе». Правки нет —
-- буфера обмена терминала окну не достать, и Copy/Paste были бы надписями;
-- «Вид» с единственным обычным видом переключать нечего.
local time = require("time")
local app = require("app")
local ui = require("ui")
local engine = require("engine")

local RED, BLUE = "#ff0000", "#0000ff"
local FLASH = "150ms"

local KEYPAD: any = {
    {memory = {"mc", "MC"}, keys = {{"7", "7", BLUE}, {"8", "8", BLUE}, {"9", "9", BLUE}, {"div", "/", RED}, {"sqrt", "sqrt", BLUE}}},
    {memory = {"mr", "MR"}, keys = {{"4", "4", BLUE}, {"5", "5", BLUE}, {"6", "6", BLUE}, {"mul", "*", RED}, {"pct", "%", BLUE}}},
    {memory = {"ms", "MS"}, keys = {{"1", "1", BLUE}, {"2", "2", BLUE}, {"3", "3", BLUE}, {"sub", "-", RED}, {"inv", "1/x", BLUE}}},
    {memory = {"mplus", "M+"}, keys = {{"0", "0", BLUE}, {"neg", "+/-", BLUE}, {"dot", ".", BLUE}, {"add", "+", RED}, {"eq", "=", RED}}},
}

local MENU: any = {
    {title = "Help", accel = 1, items = {{id = "about", text = "About Calculator"}}},
}

-- In cells the client is 25x11: the cell theme's insets take 4 columns and 5
-- rows of the 29x16 window, so the pixel grid (26 wide, 14 high, keys of 4x2
-- cells) does not fit there at all, and a cell key needs its caption plus two
-- bevels. Cells get one-row keys in columns as wide as their longest caption
-- — "+/-" needs 5, "sqrt" 6 — which with the memory column and one gap is
-- exactly 25. Pixels keep the Windows 95 grid.
local CELL_COLUMNS: any = {3, 5, 3, 3, 6}

local definition: any = {}

function definition.init(args: any, context: any): any
    return {calc = engine.new(), flash = nil, about = false}
end

local function spacer(size: any): any
    return {kind = "label", size = size, text = ""}
end

local function key(state: any, id: any, label: any, ink: any, size: any): any
    -- Клавиша на весь свой прямоугольник с зазором в два пикселя с каждой
    -- стороны: соседние стоят в четырёх пикселях, как в оригинале; подпись
    -- жирная, цвет — синий у цифр и функций, красный у операций.
    return {kind = "button", id = id, text = label, ink = ink, size = size,
        fill = true, inset = 2, bold = true, pressed = state.calc.pressed == id}
end

-- The calculator in cells: the same keys and ids, one row each.
local function cell_view(state: any): any
    local rows: any = {
        {kind = "menu", id = "bar", size = 1, entries = MENU},
        {kind = "field", size = 1, text = engine.display(state.calc), align = "right"},
        spacer(1),
        {kind = "row", size = 1, children = {
            {kind = "field", size = 4, face = true, text = state.calc.memory ~= nil and "M" or "", align = "left"},
            spacer(8), key(state, "back", "Back", RED, 6), key(state, "ce", "CE", RED, 4), key(state, "c", "C", RED, 3),
        }},
        spacer(1),
    }
    for _, line in ipairs(KEYPAD) do
        local children: any = {key(state, line.memory[1], line.memory[2], RED, 4), spacer(1)}
        for index, button in ipairs(line.keys) do
            children[#children + 1] = key(state, button[1], button[2], button[3], CELL_COLUMNS[index])
        end
        rows[#rows + 1] = {kind = "row", size = 1, children = children}
    end
    rows[#rows + 1] = {kind = "label", text = ""}
    return {kind = "column", children = rows}
end

function definition.view(state: any, context: any): any
    if state.about then
        return ui.message({title = "Calculator", image = "calculator", icon = "▦", ok = "about_ok",
            lines = {"Standard view, memory.", "Counts as a desk", "calculator does."}})
    end
    -- `native` is set by the SDK loop when the window is drawn in pixels.
    if not (type(context) == "table" and context.native) then return cell_view(state) end
    local rows: any = {
        {kind = "menu", id = "bar", size = 1, entries = MENU},
        -- Табло: две строки ячеек, чтобы у числа был отступ сверху и снизу.
        {kind = "row", size = 2, children = {spacer(1), {kind = "field", text = engine.display(state.calc), align = "right"}, spacer(1)}},
        -- Окошко памяти — вдавленное поле цвета лица; Back шире CE и C.
        {kind = "row", size = 2, children = {
            spacer(1), {kind = "field", size = 4, face = true, text = state.calc.memory ~= nil and "M" or "", align = "left"}, spacer(7),
            key(state, "back", "Back", RED, 6), key(state, "ce", "CE", RED, 4), key(state, "c", "C", RED, 4),
        }},
    }
    for _, line in ipairs(KEYPAD) do
        local children: any = {spacer(1), key(state, line.memory[1], line.memory[2], RED, 4), spacer(1)}
        for _, button in ipairs(line.keys) do
            children[#children + 1] = key(state, button[1], button[2], button[3], 4)
        end
        rows[#rows + 1] = {kind = "row", size = 2, children = children}
    end
    rows[#rows + 1] = {kind = "label", size = 1, text = ""}
    return {kind = "column", children = rows}
end

local function press(state: any, id: any, context: any)
    state.calc = engine.press(state.calc, id)
    -- Подсветка гаснет своим таймером, одинаково для мыши и клавиатуры.
    state.flash = time.after(FLASH)
    if context.watch then context.watch(state.flash) end
end

function definition.update(state: any, action: any, context: any)
    if action.type == "channel" then
        if action.channel ~= state.flash then return false end
        state.flash = nil
        state.calc.pressed = nil
        return true
    elseif action.type == "activate" and action.id == "about" then
        state.about = true
    elseif action.type == "activate" and action.id == "about_ok" then
        state.about = false
    elseif state.about then
        -- Под листом «О программе» клавиши не считают: табло не видно, и
        -- цифра, набранная вслепую, осталась бы в числе. Esc закрывает лист.
        if action.type == "key" and action.key_type == "esc" then state.about = false
        else return false end
    elseif action.type == "activate" and action.id then
        press(state, action.id, context)
    elseif action.type == "key" then
        local id = engine.key({key_type = action.key_type, key = action.key})
        if not id then return false end
        press(state, id, context)
    else return false end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
