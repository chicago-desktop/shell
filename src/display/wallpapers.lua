-- The wallpapers of "Display Properties → Background": the shell's own
-- pictures, drawn by `tools/wallpapers.py` into assets/wallpaper — original
-- pixel art in the Windows 95 palette, MIT like the weather icons, not
-- Microsoft's. Each carries the way it is meant to be shown: a tile for
-- "Tile", a picture for "Center". The setting stores the name.
--
-- A pure library: the display window lists the names, the shell looks the
-- chosen one up and hands its file to the theme (`chrome.use_wallpaper`),
-- which reads the picture through `images.wallpaper`.
local wallpapers = {}

wallpapers.NONE = "(None)"

wallpapers.LIST = {
    {name = "Rivets", file = "wallpaper_rivets", mode = "tile"},
    {name = "Sky", file = "wallpaper_sky", mode = "center"},
    {name = "Weave", file = "wallpaper_weave", mode = "tile"},
}

-- find(name) -> the wallpaper's entry, or nil for "(None)" and for a name
-- that is not in the list.
function wallpapers.find(name: any): any
    for _, entry in ipairs(wallpapers.LIST) do
        if entry.name == name then return entry end
    end
    return nil
end

-- items() -> list rows for the SDK: "(None)" first; the id is the name.
function wallpapers.items(): any
    local out: any = {{id = wallpapers.NONE, text = wallpapers.NONE}}
    for _, entry in ipairs(wallpapers.LIST) do out[#out + 1] = {id = entry.name, text = entry.name} end
    return out
end

return wallpapers
