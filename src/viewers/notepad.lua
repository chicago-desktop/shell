-- Notepad as in the original (FR-007 §6): an SDK application.
--
-- The shared renderer draws the tree this process publishes (`pixel_render:
-- chicago.shell.sdk:render`, and this same entry is its state provider);
-- in cells the SDK draws it into the window's own viewport. The model —
-- menus, sheets, the clipboard, the gate — is `notepad_model`, pure; here are
-- only the five functions it reads the world through:
--   files on a registry drive through the `fs` module, under the window's own
--   permission (`fs.get` on the drive entry, not a path on the machine);
--   the drive list and a folder's objects through the explorer's `sources`,
--   so the file dialog shows what My Computer shows;
--   the time from `time`, in the local zone.
local fs = require("fs")
local time = require("time")

local app = require("app")
local notepad = require("notepad_model")
local sources = require("sources")
local explorer_model = require("explorer_model")
local filedialog = require("filedialog")

local sys: any = {}

function sys.read(drive: any, path: any): (any, any, any)
    local text, why, kind = notepad.read_file(fs.get, drive, path)
    return text, why, kind
end

function sys.write(drive: any, path: any, text: any): (any, any)
    local ok, why = notepad.write_file(fs.get, drive, path, text)
    return ok, why
end

function sys.exists(drive: any, path: any): boolean
    return notepad.exists_file(fs.get, drive, path)
end

function sys.drives(): (any, any)
    local records, err = sources.drives()
    if not records then return nil, err end
    return explorer_model.drives(records), nil
end

function sys.list(place: any): (any, any)
    local view: any, err = sources.list(filedialog.address(place), nil)
    if not view then return nil, err end
    return view.objects, view.notice
end

function sys.now(): string
    return time.now():in_local():format(notepad.TIME_LAYOUT)
end

local definition: any = {}

function definition.init(args: any, context: any): any
    return notepad.init(sys, args, context)
end

function definition.view(state: any, context: any): any
    return notepad.view(state, context)
end

function definition.update(state: any, action: any, context: any): boolean
    return notepad.update(state, action, context)
end

-- The window's caption: "Untitled - Notepad", "<name> - Notepad", or the
-- sheet's while one is up. The SDK publishes it with every frame.
function definition.title(state: any, context: any): string
    return notepad.title(state)
end

return {main = app.main(definition), definition = definition}
