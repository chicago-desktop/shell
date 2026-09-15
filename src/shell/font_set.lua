-- chicago.shell.theme:font_set — the font store the pixel theme reads and the
-- faces it makes of it.
--
-- The store is named by the environment, CHICAGO_FONTS; without it the shell
-- reads the module's own `chicago.shell.theme:fonts` — Liberation Sans and
-- Liberation Mono under the SIL Open Font License, in assets/fonts — so the
-- pixel theme needs no font package on the machine.
--
-- The font arrives as BYTES through `fs`, not as a path inside `gfx`: file
-- reads are governed by the calling process's permissions, and a module that
-- opens paths itself would be a road around them. As a side effect the font
-- can arrive from anywhere — the module's own directory, an embedded
-- filesystem, the database.
--
-- Bold is a SEPARATE file, not an option: in the original the title bar is set
-- in it, and synthesizing it by smearing pixels means ceasing to look alike.
local environment = require("environment")
local fs = require("fs")
local gfx = require("gfx")

local font_set = {}

font_set.STORE = "chicago.shell.theme:fonts"
font_set.FACE = "LiberationSans-Regular.ttf"
font_set.BOLD = "LiberationSans-Bold.ttf"
-- The fixed-pitch face of the multi-line editor (FR-007 §4), from the same
-- store: Notepad draws its text in it.
font_set.MONO = "LiberationMono-Regular.ttf"
font_set.SIZE = 13

-- store(from?) -> the store's registry id, where the name came from, and
-- whether the variable was refused. Via `read_or`, not `read(...) or …`: the
-- default is substituted, but a permission denial is named in the log instead
-- of passing for "the person did not override it". `from` stands in for the
-- env module in tests.
function font_set.store(from: any?): (string, string, boolean)
    local id, source, denied = environment.read_or("CHICAGO_FONTS", font_set.STORE, from)
    return id, source, denied
end

local function whole_cell(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- The large font is for the farewell screen: in the original "It's now safe to
-- turn off your computer" is set large, in two lines, across the whole
-- screen. The size is computed from the cell height, not a constant: on a
-- terminal with a different cell, a 34-pixel caption would be either tiny or
-- wider than the screen.
function font_set.display_size(cell_h: any): integer
    local size = (whole_cell(cell_h) * 17) // 10
    if size < 20 then size = 20 end
    if size > 64 then size = 64 end
    return math.tointeger(size) or 34
end

-- load(store, cell_h, log?) -> {face, bold, display, mono}, or nil and the
-- reason. A failure is NOT a reason to take the shell down: the shell comes up
-- in cells and states the reason. An empty screen instead of a desktop reads
-- as a broken stand, not as a file that was not found.
function font_set.load(store: string, cell_h: any, log: any?)
    local files, err = fs.get(store)
    if err or not files then
        return nil, "fonts not opened (" .. store .. "): " .. tostring(err)
    end

    local face_data, ferr = files:readfile(font_set.FACE)
    if ferr or not face_data then
        return nil, font_set.FACE .. " not read: " .. tostring(ferr)
    end
    local bold_data, berr = files:readfile(font_set.BOLD)
    if berr or not bold_data then
        return nil, font_set.BOLD .. " not read: " .. tostring(berr)
    end

    -- A set without the fixed-pitch file is not a reason to stay in cells:
    -- `mono` stays nil, the editor draws with the interface face, and the
    -- log says so here, once — a Notepad in the wrong font is better than no
    -- Notepad.
    local mono: any = nil
    local mono_data, merr = files:readfile(font_set.MONO)
    if (merr or not mono_data) and log then
        log:warn("no fixed-pitch font: the editor draws with the interface face",
            {file = font_set.MONO, error = tostring(merr)})
    end

    -- Thresholding small TrueType glyphs erases thin strokes. Set smoothing
    -- once on each face so the shell and every client share readable text.
    local size = font_set.SIZE
    if mono_data then mono = gfx.font(mono_data, {size = size, smooth = true}) end
    return {face = gfx.font(face_data, {size = size, smooth = true}),
            bold = gfx.font(bold_data, {size = size, smooth = true}),
            display = gfx.font(bold_data, {size = font_set.display_size(cell_h), smooth = true}),
            mono = mono}, nil
end

return font_set
