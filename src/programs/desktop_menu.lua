local registry = require("registry")
local desktop_menu = {}
desktop_menu.TYPE = "chicago.desktop_menu"
function desktop_menu.read(find: any?, get: any?): (any, any)
    local lookup, fetch = find or registry.find, get or registry.get
    local records, err = lookup({[".kind"] = "registry.entry", ["meta.type"] = desktop_menu.TYPE})
    if err or type(records) ~= "table" then return {}, "Desktop menu not read: " .. tostring(err or "invalid registry response") end
    local items, problems = {}, {}
    for _, record in ipairs(records) do
        local data = type(record.data) == "table" and record.data or {}
        local meta = type(record.meta) == "table" and record.meta or {}
        local target = type(data.entry) == "string" and fetch(data.entry) or nil
        if type(data.text) ~= "string" or data.text == "" or type(target) ~= "table"
            or type(target.meta) ~= "table" or target.meta.type ~= "tui_desktop.window"
            or (data.args ~= nil and type(data.args) ~= "string") then
            problems[#problems+1] = "Invalid desktop menu entry: " .. tostring(record.id)
        else
            items[#items+1] = {id = tostring(record.id), label = data.text, entry = data.entry,
                image = type(data.image) == "string" and data.image or nil, args = data.args,
                order = tonumber(meta.order) or 100}
        end
    end
    table.sort(items,function(a,b) if a.order ~= b.order then return a.order < b.order end; return a.id < b.id end)
    return items, #problems > 0 and table.concat(problems,"; ") or nil
end
return desktop_menu
