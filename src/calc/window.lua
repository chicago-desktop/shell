-- Calculator — a window on the shell SDK. `engine` computes, the SDK draws.
--
-- The grid is the same as in the standard view of the Windows 95 calculator,
-- and the same as the one its own renderer had: the display, the Back/CE/C
-- row with the memory box, four rows of keys with the memory column on the
-- left; a button is four cells, one between buttons. The layout is held by
-- `view`: both renderers and the hits read the same numbers, there is no
-- second table any more.
--
-- A key from the keyboard goes to the same button as a click (`engine.key`);
-- the button it pressed is highlighted for 150 ms — by a one-shot timer
-- (`context.after`), not by the tick: a tick with nothing to do would burn
-- frames. The timer's tag is the press number, so the timer of an earlier
-- press does not put out the highlight of a later one.
--
-- The menu has only what works: "Help → About". There is no Edit — the
-- window cannot reach the terminal's clipboard, and Copy/Paste would be mere
-- labels; "View" with a single standard view has nothing to switch.
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
    -- The key fills its whole rectangle with a two-pixel gap on each side:
    -- neighboring keys stand four pixels apart, as in the original; the
    -- caption is bold, the color — blue for digits and functions, red for
    -- operations.
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
        -- The display: two rows of cells, so the number has padding above and below.
        {kind = "row", size = 2, children = {spacer(1), {kind = "field", text = engine.display(state.calc), align = "right"}, spacer(1)}},
        -- The memory box is a sunken field in the face color; Back is wider than CE and C.
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
    -- The highlight goes out by its own timer, the same for mouse and keyboard.
    state.flash = (state.flash or 0) + 1
    context.after(FLASH, state.flash)
end

function definition.update(state: any, action: any, context: any)
    if action.type == "timer" then
        if action.tag ~= state.flash then return false end
        state.flash = nil
        state.calc.pressed = nil
        return true
    elseif action.type == "activate" and action.id == "about" then
        state.about = true
    elseif action.type == "activate" and action.id == "about_ok" then
        state.about = false
    elseif state.about then
        -- Under the "About" sheet keys do not count: the display is not
        -- visible, and a digit typed blind would stay in the number. Esc
        -- closes the sheet.
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

return {main = app.main(definition), definition = definition}
