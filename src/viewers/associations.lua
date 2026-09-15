-- File-type registry: which program opens which extension.
--
-- In the original this is HKEY_CLASSES_ROOT — a separate branch that programs
-- fill in at installation. Here there is no separate branch, and none is
-- needed: **a program declares by itself what it opens**, with the field
-- `meta.opens` in its registry entry, and the table is assembled from the
-- catalog at the moment it is needed. An installed module brings its types
-- by itself; a removed one takes them away with it; a second copy that would
-- have to be kept in sync does not exist.
--
-- Pure tables, not a single call into the runtime — checked directly.

local files = require("files")

local associations = {}

-- opens_of(item) -> list of extensions in lower case without dots
--
-- Accepts both forms in which a program arrives: a raw registry entry
-- (`meta.opens`) and a catalog item (`opens`). The form on the way out is
-- one and the same, and it is unwrapped here, not at every reader.
local function opens_of(item: any): {string}
    local list: any = nil
    if type(item) == "table" then
        if type(item.opens) == "table" then
            list = item.opens
        elseif type(item.meta) == "table" and type(item.meta.opens) == "table" then
            list = item.meta.opens
        elseif type(item.data) == "table" and type(item.data.meta) == "table"
            and type(item.data.meta.opens) == "table" then
            list = item.data.meta.opens
        end
    end
    local out: {string} = {}
    for _, ext in ipairs(type(list) == "table" and list or {}) do
        local text = tostring(ext):lower():gsub("^%.", "")
        if text ~= "" then out[#out + 1] = text end
    end
    return out
end

local function id_of(item: any): any
    if type(item) ~= "table" then return nil end
    local id = item.entry or item.id
    if type(id) ~= "string" or id == "" then return nil end
    return id
end

local function meta_of(item: any): any
    if type(item) ~= "table" then return {} end
    if type(item.meta) == "table" then return item.meta end
    if type(item.data) == "table" and type(item.data.meta) == "table" then return item.data.meta end
    return {}
end

local function field(item: any, name: string): any
    if type(item) ~= "table" then return nil end
    if item[name] ~= nil then return item[name] end
    return meta_of(item)[name]
end

-- table(programs) -> {ext -> program}, warnings
--
-- Two claimants to one extension are not a choice but a dispute, and the
-- dispute is named: the first by entry identifier wins (stable between runs,
-- unlike registry order), and the loser goes into the warnings. A silent
-- choice here would one day open a photograph with Notepad, and nobody would
-- understand why.
function associations.table(programs: any): (any, any)
    local claims: any = {}
    for _, item in ipairs(type(programs) == "table" and programs or {}) do
        local id = id_of(item)
        if id then
            for _, ext in ipairs(opens_of(item)) do
                local list: any = claims[ext] or {}
                -- The program's icon becomes the icon of its files: in the original
                -- a file type carries both the program and the picture, and
                -- that is one record, not two. But Notepad has its own icon (a
                -- notepad with a pencil), while its files have a text
                -- document; for that there is `meta.file_image`, and it takes
                -- precedence over `image` FOR FILES. The program in the menu
                -- and on the desktop keeps `image`.
                local image = field(item, "file_image")
                if type(image) ~= "string" or image == "" then image = field(item, "image") end
                -- The name of the program's documents, as the original's Type column
                -- showed it ("Text Document"): `meta.file_type`, one per program.
                local file_type = field(item, "file_type")
                list[#list + 1] = {
                    entry = id,
                    title = tostring(field(item, "title") or id),
                    width = tonumber(field(item, "width")),
                    height = tonumber(field(item, "height")),
                    image = type(image) == "string" and image ~= "" and image or nil,
                    file_type = type(file_type) == "string" and file_type ~= "" and file_type or nil,
                }
                claims[ext] = list
            end
        end
    end

    local out, warnings = {}, {}
    for ext, list in pairs(claims) do
        table.sort(list, function(left, right) return left.entry < right.entry end)
        out[ext] = list[1]
        if #list > 1 then
            local names = {}
            for _, claim in ipairs(list) do names[#names + 1] = claim.entry end
            warnings[#warnings + 1] = {ext = ext, entries = names, chosen = list[1].entry}
        end
    end
    return out, warnings
end

-- find(programs, name) -> program | nil, reason
function associations.find(programs: any, name: any): (any, any)
    local ext = files.ext(name)
    if ext == "" then
        return nil, "the file " .. tostring(files.name_of(name)) .. " has no extension"
    end
    local by_ext = associations.table(programs)
    local program = by_ext[ext]
    if not program then
        return nil, "nothing opens ." .. ext .. " files: no program declared them"
    end
    return program, nil
end

-- image_for(programs, name) -> the program's icon name or nil
--
-- nil means "there is nothing to open the file with" — and it has to be
-- drawn with the unknown-document icon, not with emptiness and not with a
-- neighbour's icon. Whoever draws decides what icon the unknown gets; here
-- there is only the fact.
function associations.image_for(programs: any, name: any): any
    local program = associations.find(programs, name)
    if not program then return nil end
    return program.image
end

-- open(programs, drive, path) -> window request | nil, reason
--
-- The request has the same form as a desktop shortcut and a menu item:
-- `open_window` with the entry, title, size and argument. The title is the
-- file name, as in the original: the window is named after what is open in it.
function associations.open(programs: any, drive: any, path: any): (any, any)
    local program, why = associations.find(programs, path)
    if not program then return nil, why end
    return {
        action = "open_window",
        entry = program.entry,
        title = files.name_of(path) .. " — " .. program.title,
        w = program.width,
        h = program.height,
        args = files.encode(drive, path),
    }, nil
end

return associations
