-- Calculator arithmetic: pure, with no screen and no runtime.
--
-- It computes like the Windows 95 desktop calculator in standard view, not
-- like an expression: an operation is applied to the accumulated value
-- immediately, so 2 + 3 × 4 gives 20. That is how the buttons behave, and a
-- person pressing them expects exactly that.
--
-- Buttons are named by identifiers, not by captions: the caption is a matter
-- of layout and paint, and the "×" on a button does not have to match the
-- key character.

local engine = {}

engine.LIMIT = 15

function engine.new(): any
    return {
        entry = "0",      -- what is being typed now
        acc = nil,        -- accumulated value
        op = nil,         -- pending operation
        fresh = true,     -- the next digit starts a new entry
        failed = false,   -- failure (division by zero): until reset
        memory = nil,     -- memory M
        pressed = nil,    -- the last pressed button, for highlighting
    }
end

-- A number is shown the way a person would write it: an integer without a
-- tail, a fraction without the garbage of binary representation.
function engine.format(value: any): string
    local number = tonumber(value)
    if number == nil then return "0" end
    if number ~= number then return "Error" end
    if number == math.huge or number == -math.huge then return "Overflow" end
    if number == math.floor(number) and math.abs(number) < 1e15 then
        return string.format("%d", math.tointeger(number) or 0)
    end
    return (string.format("%.12g", number))
end

-- The display: an integer gets a dot at the end, as Windows 95 draws it
-- ("0."). A failure is a phrase, with no dot: a dot after "Cannot divide by
-- zero" reads as a typo.
function engine.display(state: any): string
    local entry = tostring(state.entry or "0")
    if state.failed then return entry end
    if entry:find(".", 1, true) or entry:find("e", 1, true) then return entry end
    return entry .. "."
end

local function apply(acc: any, op: any, value: any): any
    if op == "add" then return acc + value end
    if op == "sub" then return acc - value end
    if op == "mul" then return acc * value end
    if op == "div" then
        if value == 0 then return nil end
        return acc / value
    end
    return value
end

local function fail(state: any, text)
    state.entry, state.failed = text, true
    state.acc, state.op, state.fresh = nil, nil, true
    return state
end

local DIGITS: any = {["0"] = true, ["1"] = true, ["2"] = true, ["3"] = true, ["4"] = true,
    ["5"] = true, ["6"] = true, ["7"] = true, ["8"] = true, ["9"] = true}
local BINARY: any = {add = true, sub = true, mul = true, div = true}

-- press(state, id) -> state
function engine.press(state: any, id: any): any
    state.pressed = id

    if id == "c" then
        local fresh_state = engine.new()
        fresh_state.memory = state.memory
        fresh_state.pressed = id
        return fresh_state
    end

    -- After a failure only clear entry and full clear work: continuing to
    -- compute from a "division by zero" means producing a number that never
    -- existed.
    if id == "ce" then
        state.entry, state.fresh, state.failed = "0", true, false
        return state
    end
    if state.failed then return state end

    local entry = tostring(state.entry or "0")

    if id == "back" then
        if state.fresh then return state end
        entry = entry:sub(1, -2)
        if entry == "" or entry == "-" then
            state.entry, state.fresh = "0", true
        else
            state.entry = entry
        end
        return state
    end

    if DIGITS[id] then
        if state.fresh or entry == "0" then
            state.entry, state.fresh = id, false
        elseif #entry < engine.LIMIT then
            state.entry = entry .. id
        end
        return state
    end

    if id == "dot" then
        if state.fresh then
            state.entry, state.fresh = "0.", false
        elseif not entry:find(".", 1, true) then
            state.entry = entry .. "."
        end
        return state
    end

    local value = tonumber(entry) or 0

    if id == "neg" then
        if value ~= 0 then
            if entry:sub(1, 1) == "-" then state.entry = entry:sub(2)
            else state.entry = "-" .. entry end
        end
        return state
    end

    if id == "sqrt" then
        if value < 0 then return fail(state, "Invalid input") end
        state.entry, state.fresh = engine.format(math.sqrt(value)), true
        return state
    end

    if id == "inv" then
        if value == 0 then return fail(state, "Cannot divide by zero") end
        state.entry, state.fresh = engine.format(1 / value), true
        return state
    end

    if id == "pct" then
        -- Percent of the accumulated value, as in Windows 95: 50 + 10 % gives 5.
        local base = state.acc or 0
        state.entry, state.fresh = engine.format(base * value / 100), true
        return state
    end

    if id == "mc" then state.memory = nil; return state end
    if id == "mr" then
        state.entry, state.fresh = engine.format(state.memory or 0), true
        return state
    end
    if id == "ms" then state.memory = value; state.fresh = true; return state end
    if id == "mplus" then
        state.memory = (state.memory or 0) + value
        state.fresh = true
        return state
    end

    if id == "eq" then
        if state.op and state.acc then
            local result = apply(state.acc, state.op, value)
            if result == nil then return fail(state, "Cannot divide by zero") end
            state.entry = engine.format(result)
        end
        state.acc, state.op, state.fresh = nil, nil, true
        return state
    end

    if BINARY[id] then
        -- Operation: first the accumulated value is completed, then the new
        -- one is remembered. Two operations in a row without input are a
        -- replacement, not a recalculation.
        if state.op and state.acc and not state.fresh then
            local result = apply(state.acc, state.op, value)
            if result == nil then return fail(state, "Cannot divide by zero") end
            state.acc = result
            state.entry = engine.format(result)
        elseif not (state.op and state.acc) then
            state.acc = value
        end
        state.op, state.fresh = id, true
        return state
    end

    return state
end

-- A keyboard key maps to the same button as a click: one behaviour table
-- for both ways of input.
function engine.key(event: any): any
    if type(event) ~= "table" then return nil end
    local kind = event.key_type
    if kind == "enter" then return "eq" end
    if kind == "backspace" then return "back" end
    if kind == "esc" then return "c" end
    if kind == "delete" then return "ce" end
    local key = event.key
    if type(key) ~= "string" then return nil end
    if DIGITS[key] then return key end
    local map: any = {["."] = "dot", [","] = "dot", ["+"] = "add", ["-"] = "sub",
        ["*"] = "mul", ["/"] = "div", ["="] = "eq", ["%"] = "pct",
        ["r"] = "inv", ["@"] = "sqrt", ["c"] = "c", ["C"] = "c", ["с"] = "c", ["С"] = "c"}
    return map[key]
end

return engine
