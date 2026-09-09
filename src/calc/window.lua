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
local time = require("time")
local app = require("app")
local engine = require("engine")

local RED, BLUE = "#ff0000", "#0000ff"
local FLASH = "150ms"

local KEYPAD: any = {
    {memory = {"mc", "MC"}, keys = {{"7", "7", BLUE}, {"8", "8", BLUE}, {"9", "9", BLUE}, {"div", "/", RED}, {"sqrt", "sqrt", BLUE}}},
    {memory = {"mr", "MR"}, keys = {{"4", "4", BLUE}, {"5", "5", BLUE}, {"6", "6", BLUE}, {"mul", "*", RED}, {"pct", "%", BLUE}}},
    {memory = {"ms", "MS"}, keys = {{"1", "1", BLUE}, {"2", "2", BLUE}, {"3", "3", BLUE}, {"sub", "-", RED}, {"inv", "1/x", BLUE}}},
    {memory = {"mplus", "M+"}, keys = {{"0", "0", BLUE}, {"neg", "+/-", BLUE}, {"dot", ".", BLUE}, {"add", "+", RED}, {"eq", "=", RED}}},
}

local definition: any = {}

function definition.init(args: any, context: any): any
    return {calc = engine.new(), flash = nil}
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

function definition.view(state: any, context: any): any
    local rows: any = {
        {kind = "menu", id = "bar", size = 1, entries = {
            {title = "Edit", accel = 1, items = {{id = "copy", text = "Copy"}, {id = "paste", text = "Paste", disabled = true}}},
            {title = "View", accel = 1, items = {{id = "normal", text = "Standard"}}},
            {title = "Help", accel = 1, items = {{id = "about", text = "About"}}},
        }},
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
    elseif action.type == "activate" and action.menu == "bar" then
        if action.id == "copy" then return false end
        return false
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
