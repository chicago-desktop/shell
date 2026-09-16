-- Inline PNGs carried as plain data; bounded cache, no filesystem access.
local base64 = require("base64")
local gfx = require("gfx")
local bitmap = {}
local cache = {}
local serial = {value = 0}
function bitmap.source(data: any): (any, any)
    if type(data) ~= "string" or #data > 1400000 then return nil, "PNG data is missing or too large" end
    serial.value = serial.value + 1
    local kept = cache[data]
    if kept then kept.at = serial.value; return kept.raster, kept.error end
    local raster: any, why: any = nil, nil
    local bytes, err = base64.decode(data)
    if err or type(bytes) ~= "string" or #bytes < 24 or bytes:sub(1,8) ~= "\137PNG\13\10\26\10" then
        why = "Invalid base64 PNG"
    else
        local function dimension(at: integer): number
            local a,b,c,e = string.byte(bytes,at,at+3)
            return (a or 0)*16777216+(b or 0)*65536+(c or 0)*256+(e or 0)
        end
        local w,h = dimension(17),dimension(21)
        if w < 1 or h < 1 or w > 1024 or h > 1024 then why = "PNG dimensions must be at most 1024 by 1024"
        else raster, why = gfx.image(bytes) end
    end
    local count, oldest, age = 0, nil, math.huge
    for key, entry in pairs(cache) do
        count = count + 1
        if entry.at < age then oldest,age = key,entry.at end
    end
    if count >= 8 and oldest then cache[oldest] = nil end
    cache[data] = {raster = raster, error = why, at = serial.value}
    return raster, why
end
return bitmap
