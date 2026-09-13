-- "My Computer" and every folder window (FR-008) — an SDK application.
--
-- A Windows 95 folder window: the menu bar `File Edit View Help`, an optional
-- toolbar, the objects in one of four views, and a status bar. Every folder
-- opens in its own window (the default browse mode); a folder whose window is
-- already open raises that window. The other mode, one window that changes, is
-- `View → Options…`.
--
-- What the window reads comes from `sources` (registry, `fs`, the shell's
-- settings) under the window's own policy; what it opens goes to the
-- compositor through the base's `window_api`. Both are reached through
-- `definition.deps`, so a test swaps them for stand-ins and checks what the
-- window asked for. The view reads nothing and sends nothing.
--
-- The model is plain data: the path, the objects read for it (sorted), the
-- selection SET, the view, the toggles, the open sheet or popup. The folder
-- rules — paths, parents, titles, pictures, Details cells, sorting, selection
-- operations and the open-or-focus intent — live in `explorer:model`, not here.

local app = require("app")
local ui = require("ui")
local desktop = require("desktop")
local model = require("model")
local sources = require("sources")

local definition: any = {}

definition.deps = {desktop = desktop, sources = sources}

-- "Properties" of My Computer and of a drive is the System Properties window
-- the desktop icon already names.
definition.SYSPROPS = "butschster.windows.sysprops:window"

definition.VIEWS = {"large", "small", "list", "details"}
local VIEW_TEXT: any = {large = "Large Icons", small = "Small Icons", list = "List", details = "Details"}
local SORT_TEXT: any = {name = "by Name", type = "by Type", size = "by Size", date = "by Date"}

-- The browse options, verbatim from Windows 95's View → Options… → Folder.
definition.BROWSE_TEXT = {
    separate = "Browse folders using a separate window for each folder.",
    single = "Browse folders by using a single window that changes as you open each folder.",
}

-- The compositor's reply arrives wrapped: the payload is userdata, and inside
-- there is sometimes an array of one element. A field read directly turns out
-- nil without an error — "the compositor answered with emptiness".
local function unwrap(got: any): any
    local value: any = got
    if type(got) == "userdata" or (type(got) == "table" and type(got.payload) == "function") then
        value = got:payload()
    end
    if type(value) == "userdata" then
        local ok, decoded = pcall(function() return value:data() end)
        value = ok and decoded or {}
    end
    if type(value) == "table" and value[1] ~= nil and #value > 0 then value = value[1] end
    return type(value) == "table" and value or {}
end

-- ─── reading ─────────────────────────────────────────────────────────────

local function find(state: any, id: any): any
    if id == nil then return nil end
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        if tostring(object.id) == tostring(id) then return object end
    end
    return nil
end

local function selected_objects(state: any): any
    local out = {}
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        if state.selection[tostring(object.id)] then out[#out + 1] = object end
    end
    return out
end

-- The places of the toolbar's folder combo: the way from My Computer to the
-- current folder, then the drives, as the original's list did.
local function places(state: any): any
    local out: any = {}
    local seen: any = {}
    for depth, step in ipairs(model.ancestors(state.path)) do
        local place: any = step
        if not seen[place.path] then
            seen[place.path] = true
            out[#out + 1] = {value = place.path, label = string.rep("  ", depth - 1) .. model.folder_title(place.path)}
        end
    end
    for _, entry in ipairs(state.drives) do
        local drive: any = entry
        local path = "drive/" .. tostring(drive.id)
        if not seen[path] then
            seen[path] = true
            out[#out + 1] = {value = path, label = "  " .. tostring(drive.title)}
        end
    end
    return out
end

-- load(state) — read the current path. A failure is shown as its reason in
-- place of the objects: an unreadable folder is not an empty one. The
-- selection keeps the objects that are still there.
local function load(state: any)
    local shown, err = definition.deps.sources.list(state.path, {})
    if err or type(shown) ~= "table" then
        state.objects, state.failure, state.cut = {}, tostring(err or "not read"), nil
    else
        state.objects = model.sort(shown.objects, state.sort)
        state.failure, state.cut = nil, shown.notice
    end
    local kept = {}
    for id, on in pairs(state.selection) do
        if on and find(state, id) then kept[id] = true end
    end
    state.selection = kept
end

local function go(state: any, path: any)
    state.path = path
    state.selection, state.last_click, state.notice = {}, nil, nil
    load(state)
end

-- ─── the compositor ──────────────────────────────────────────────────────

-- perform(state, intent) — an intent of the model (`open_window`, `focus`,
-- `raise`) sent to the compositor. A refusal goes into the status bar: a
-- command that silently did nothing is indistinguishable from an unnoticed
-- click.
local function perform(state: any, intent: any): boolean
    local api: any = definition.deps.desktop
    if intent.action == "focus" or intent.action == "raise" then
        local ok, err = api.focus(intent.id)
        if not ok then state.notice = model.refusal("desktop.focus", err) end
    elseif intent.action == "open_window" then
        local ok, err = api.open({entry = intent.entry, title = intent.title, image = intent.image,
            w = intent.w, h = intent.h, args = intent.args})
        if not ok then state.notice = model.refusal("desktop.open", err) end
    end
    return true
end

-- open_folder(state, path, title) — a folder is entered in place in the
-- single-window mode; in the separate mode the window first asks the
-- compositor what is open (`desktop.list`, answered on the reply channel) and
-- then raises the window already showing that path or opens a new one.
local function open_folder(state: any, path: any, title: any): boolean
    if state.browse == "single" then
        go(state, path)
        return true
    end
    if state.replies_error == nil then
        local ok = definition.deps.desktop.request("desktop.list", {})
        if ok then
            state.pending = {path = path, title = title}
            return true
        end
    end
    -- Without an answer channel the window cannot look for an open one; it
    -- opens a new window rather than doing nothing.
    return perform(state, model.open_folder(path, nil, title))
end

local function activate(state: any, object: any): boolean
    if type(object) ~= "table" then return false end
    local open: any = object.open
    if type(open) ~= "table" then
        state.notice = "nothing to open it with: " .. tostring(object.detail or object.title)
        return true
    end
    if open.action == "folder" then return open_folder(state, open.path, object.title) end
    if open.action == "raise" then return perform(state, {action = "focus", id = open.id}) end
    return perform(state, open)
end

-- Backspace and Up One Level: the parent folder by the same rule as a double
-- click — its own window in the separate mode, in place in the single one.
local function up(state: any): boolean
    local parent = model.parent(state.path)
    if parent == nil then return false end
    return open_folder(state, parent, nil)
end

-- ─── sheets ──────────────────────────────────────────────────────────────

local function message(state: any, spec: any): boolean
    spec.ok = "sheet_ok"
    state.sheet = {kind = "message", spec = spec}
    return true
end

-- Properties of the selection, or of the folder itself when nothing is
-- selected. My Computer and a drive are the System Properties window; a folder
-- or a file is a sheet with its name, type, location, size and date.
local function properties(state: any): boolean
    local chosen = selected_objects(state)
    local where: any = model.parse(state.path)
    if #chosen == 0 then
        if where.view == "root" or (where.view == "drive" and not where.sub) then
            return perform(state, {action = "open_window", entry = definition.SYSPROPS})
        end
        local parent = model.parent(state.path)
        return message(state, {title = model.folder_title(state.path), image = model.folder_image(state.path),
            icon = model.DIR_ICON, lines = {
                "Type: " .. (where.view == "control" and "System Folder" or "File Folder"),
                "Location: " .. (parent and model.address(parent) or ""),
                "Contains: " .. tostring(#state.objects) .. " object(s)",
            }})
    end
    if #chosen == 1 then
        local object: any = chosen[1]
        if object.kind == "drive" then return perform(state, {action = "open_window", entry = definition.SYSPROPS}) end
        local cells: any = model.details(object)
        local lines = {"Type: " .. cells.type, "Location: " .. model.address(state.path)}
        if cells.size ~= "" then lines[#lines + 1] = "Size: " .. cells.size end
        if cells.modified ~= "" then lines[#lines + 1] = "Modified: " .. cells.modified end
        if cells.comment ~= "" then lines[#lines + 1] = cells.comment end
        return message(state, {title = cells.name, image = object.image, icon = object.icon, lines = lines})
    end
    return message(state, {title = tostring(#chosen) .. " objects", icon = model.FILE_ICON, lines = {
        model.selected_summary(state.selection, state.objects),
        "Location: " .. model.address(state.path),
    }})
end

local function options_tree(state: any): any
    local choice = state.sheet.choice
    return {kind = "column", padding = 1, gap = 1, padding_bottom = 0, children = {
        {kind = "label", size = 1, text = "Browsing options"},
        {kind = "radio", id = "browse_separate", size = 2, text = definition.BROWSE_TEXT.separate,
            checked = choice == "separate"},
        {kind = "radio", id = "browse_single", size = 2, text = definition.BROWSE_TEXT.single,
            checked = choice == "single"},
        {kind = "label", text = ""},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "options_ok", size = 10, text = "OK", default = true},
            {kind = "button", id = "options_cancel", size = 10, text = "Cancel"},
        }},
    }}
end

-- ─── the view ────────────────────────────────────────────────────────────

local SEP = {separator = true}

local function menu_bar(state: any): any
    local any_selected = next(state.selection) ~= nil
    local function view_item(key: string): any
        return {id = "view_" .. key, text = VIEW_TEXT[key], bullet = state.view == key}
    end
    local function arrange(): any
        return {
            {id = "arrange_name", text = SORT_TEXT.name}, {id = "arrange_type", text = SORT_TEXT.type},
            {id = "arrange_size", text = SORT_TEXT.size}, {id = "arrange_date", text = SORT_TEXT.date},
            SEP,
            -- The only arrangement there is: icons here cannot be dragged loose.
            {id = "arrange_auto", text = "Auto Arrange", checked = true, disabled = true},
        }
    end
    return {kind = "menu", id = "bar", size = 1, entries = {
        {title = "File", accel = 1, items = {
            {id = "file_open", text = "Open", disabled = not any_selected},
            SEP,
            {id = "file_shortcut", text = "Create Shortcut", disabled = true},
            {id = "file_delete", text = "Delete", disabled = true},
            {id = "file_rename", text = "Rename", disabled = true},
            {id = "file_properties", text = "Properties"},
            SEP,
            {id = "file_close", text = "Close"},
        }},
        {title = "Edit", accel = 1, items = {
            {id = "edit_undo", text = "Undo", disabled = true},
            SEP,
            {id = "edit_cut", text = "Cut", disabled = true},
            {id = "edit_copy", text = "Copy", disabled = true},
            {id = "edit_paste", text = "Paste", disabled = true},
            {id = "edit_paste_shortcut", text = "Paste Shortcut", disabled = true},
            SEP,
            {id = "edit_select_all", text = "Select All", shortcut = "Ctrl+A"},
            {id = "edit_invert", text = "Invert Selection"},
        }},
        {title = "View", accel = 1, items = {
            {id = "view_toolbar", text = "Toolbar", checked = state.toolbar == true},
            {id = "view_statusbar", text = "Status Bar", checked = state.statusbar == true},
            SEP,
            view_item("large"), view_item("small"), view_item("list"), view_item("details"),
            SEP,
            {id = "view_arrange", text = "Arrange Icons", items = arrange()},
            {id = "view_lineup", text = "Line up Icons", disabled = true},
            SEP,
            {id = "view_refresh", text = "Refresh", shortcut = "F5"},
            {id = "view_options", text = "Options..."},
        }},
        {title = "Help", accel = 1, items = {
            {id = "help_topics", text = "Help Topics"},
            SEP,
            {id = "help_about", text = "About Windows"},
        }},
    }}
end

-- The toolbar, when on: the folder combo, Up One Level, then the buttons of
-- the original. The pack has no pictures for Cut … Details yet, so they carry
-- their captions; what does not fit the width is not drawn (the SDK clips a
-- row), as a narrow Windows 95 window lost its last buttons.
local function toolbar(state: any): any
    local function tool(id: string, text: string, extra: any?): any
        local node: any = {kind = "button", id = id, size = #text + 2, text = text}
        for key, value in pairs(extra or {}) do node[key] = value end
        return node
    end
    return {kind = "row", size = 2, gap = 0, children = {
        {kind = "select", id = "tb_places", size = 16, value = state.path, options = places(state)},
        tool("tb_up", "Up", {image = "folder", disabled = model.parent(state.path) == nil, size = 4}),
        tool("tb_cut", "Cut", {disabled = true}),
        tool("tb_copy", "Copy", {disabled = true}),
        tool("tb_paste", "Paste", {disabled = true}),
        tool("tb_undo", "Undo", {disabled = true}),
        tool("tb_delete", "Delete", {disabled = true}),
        tool("tb_properties", "Properties"),
        tool("tb_large", "Large", {pressed = state.view == "large"}),
        tool("tb_small", "Small", {pressed = state.view == "small"}),
        tool("tb_list", "List", {pressed = state.view == "list"}),
        tool("tb_details", "Details", {pressed = state.view == "details"}),
    }}
end

local function icon_items(state: any): any
    local out = {}
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        out[#out + 1] = {id = tostring(object.id), title = tostring(object.title or object.id),
            image = object.image, icon = object.icon, kind = object.kind, broken = object.broken}
    end
    return out
end

local function details_table(state: any): any
    local control = model.parse(state.path).view == "control"
    local columns: any
    if control then
        columns = {{title = "Name", weight = 2}, {title = "Type", width = 18}, {title = "Comment", weight = 3}}
    else
        columns = {{title = "Name", weight = 3}, {title = "Size", width = 7, align = "right"},
            {title = "Type", weight = 2}, {title = "Modified", width = 15}}
    end
    local rows = {}
    for _, entry in ipairs(state.objects) do
        local object: any = entry
        local cells: any = model.details(object)
        local name: any = {text = cells.name, image = object.image, icon = object.icon, kind = object.kind}
        rows[#rows + 1] = {id = tostring(object.id), cells = control and {name, cells.type, cells.comment}
            or {name, cells.size, cells.type, cells.modified}}
    end
    return {kind = "table", id = "objects", columns = columns, rows = rows, selected = state.selection}
end

-- The objects in the chosen view. List is Small Icons for now: the SDK has no
-- column-filled list, and Small Icons is the nearer of the two.
local function body(state: any): any
    if state.failure then return {kind = "label", alert = true, wrap = true, text = state.failure} end
    if state.view == "details" then return details_table(state) end
    return {kind = "icons", id = "objects", items = icon_items(state), selected = state.selection,
        small = state.view ~= "large" or nil}
end

local function right_field(state: any): string
    if state.notice then return tostring(state.notice) end
    local summary = model.selected_summary(state.selection, state.objects)
    if summary ~= "" then return summary end
    if state.cut then return tostring(state.cut) end
    local where: any = model.parse(state.path)
    if where.view == "drive" and not where.sub then
        for _, entry in ipairs(state.drives) do
            local drive: any = entry
            if drive.id == where.id then return tostring(drive.detail or "") end
        end
    end
    return ""
end

-- The context menu (FR-008 §4): on an object Open and Properties, on the
-- empty field View, Arrange Icons, Refresh and Properties. The SDK's floating
-- menu, at the cell the right press carried.
local function popup_tree(state: any): any
    local items: any
    if state.popup.target == "object" then
        items = {{id = "file_open", text = "Open"}, SEP, {id = "file_properties", text = "Properties"}}
    else
        local views, sorts = {}, {}
        for _, key in ipairs(definition.VIEWS) do
            views[#views + 1] = {id = "view_" .. key, text = VIEW_TEXT[key], bullet = state.view == key}
        end
        for _, key in ipairs(model.SORT_KEYS) do sorts[#sorts + 1] = {id = "arrange_" .. key, text = SORT_TEXT[key]} end
        items = {
            {id = "ctx_view", text = "View", items = views},
            {id = "ctx_arrange", text = "Arrange Icons", items = sorts},
            SEP,
            {id = "view_refresh", text = "Refresh"},
            SEP,
            {id = "field_properties", text = "Properties"},
        }
    end
    return ui.context_menu({id = "context", x = state.popup.x, y = state.popup.y, items = items})
end

function definition.view(state: any, context: any): any
    if state.sheet then
        if state.sheet.kind == "options" then return options_tree(state) end
        return ui.message(state.sheet.spec)
    end
    local children: any = {menu_bar(state)}
    if state.toolbar then children[#children + 1] = toolbar(state) end
    children[#children + 1] = body(state)
    if state.statusbar then
        children[#children + 1] = {kind = "statusbar", size = 1, fields = {
            {text = " " .. tostring(#state.objects) .. " object(s)", width = 18},
            {text = " " .. right_field(state)},
        }}
    end
    if state.popup then children[#children + 1] = popup_tree(state) end
    return {kind = "column", gap = 0, children = children}
end

-- The window's caption: the folder it shows. The opener names a new window
-- when it opens it; this is the caption for the start path and for a window
-- that navigates in place.
function definition.title(state: any): string
    return model.folder_title(state.path)
end

-- ─── actions ─────────────────────────────────────────────────────────────

function definition.init(args: any, context: any): any
    local path, notice = model.start(args)
    local browse, why = definition.deps.sources.browse()
    local state: any = {
        path = path, objects = {}, selection = {}, drives = {},
        view = "large", sort = "name", toolbar = false, statusbar = true,
        browse = browse, notice = notice or why,
        sheet = nil, popup = nil, pending = nil, last_click = nil,
    }
    local replies, rerr = definition.deps.desktop.replies()
    if replies then context.watch(replies) else state.replies_error = tostring(rerr or "no reply channel") end
    local records = definition.deps.sources.drives()
    state.drives = model.drives(records or {})
    load(state)
    return state
end

local function command(state: any, id: any, context: any): boolean
    if id == "file_open" then
        local opened = false
        for _, object in ipairs(selected_objects(state)) do opened = activate(state, object) or opened end
        return opened
    elseif id == "file_properties" or id == "field_properties" or id == "tb_properties" then
        if id == "field_properties" then state.selection = {} end
        return properties(state)
    elseif id == "file_close" then
        context.close()
        return true
    elseif id == "edit_select_all" then
        state.selection = model.select_all(state.objects)
        return true
    elseif id == "edit_invert" then
        state.selection = model.invert(state.selection, state.objects)
        return true
    elseif id == "view_toolbar" then
        state.toolbar = not state.toolbar
        return true
    elseif id == "view_statusbar" then
        state.statusbar = not state.statusbar
        return true
    elseif id == "view_refresh" then
        state.notice = nil
        load(state)
        return true
    elseif id == "view_options" then
        state.sheet = {kind = "options", choice = state.browse}
        return true
    elseif id == "help_topics" then
        return message(state, {title = "Help", icon = "?", image = "help", lines = {"Help is not available."}})
    elseif id == "help_about" then
        return message(state, {title = "About Windows", image = "windows", icon = "▩", lines = {
            "The Windows 95 shell for Wippy (butschster/windows).",
            "Icons: Microsoft artwork from shell32.dll, not under the module's MIT licence.",
        }})
    elseif id == "tb_up" then
        return up(state)
    end
    local key = type(id) == "string" and (id:match("^view_(%a+)$") or id:match("^tb_(%a+)$")) or nil
    if key and VIEW_TEXT[key] then
        state.view = key
        return true
    end
    local sort = type(id) == "string" and id:match("^arrange_(%a+)$") or nil
    if sort and SORT_TEXT[sort] then
        state.sort = sort
        state.objects = model.sort(state.objects, sort)
        return true
    end
    return false
end

local function sheet_update(state: any, action: any): boolean
    local sheet: any = state.sheet
    local escape = action.type == "key" and action.key_type == "esc"
    if sheet.kind == "message" then
        if escape or (action.type == "activate" and action.id == "sheet_ok") then state.sheet = nil; return true end
        return false
    end
    if action.type == "change" and action.id == "browse_separate" then sheet.choice = "separate"; return true end
    if action.type == "change" and action.id == "browse_single" then sheet.choice = "single"; return true end
    if escape or (action.type == "activate" and action.id == "options_cancel") then state.sheet = nil; return true end
    if action.type == "activate" and action.id == "options_ok" then
        local ok, err = definition.deps.sources.set_browse(sheet.choice)
        if ok then state.browse = sheet.choice else state.notice = tostring(err) end
        state.sheet = nil
        return true
    end
    return false
end

-- A reply on the compositor's channel: the window list an open is waiting
-- for, or a refusal of a command sent earlier (it goes to the status bar).
local function reply(state: any, action: any): boolean
    local taken = model.take_reply(state, unwrap(action.value))
    if taken == "list" and state.pending then
        local pending: any = state.pending
        state.pending = nil
        -- A refused list still opens the folder: the window cannot see what is
        -- open, and opening a second window beats doing nothing.
        return perform(state, model.open_folder(pending.path, state.windows_error == nil and state.windows or nil,
            pending.title))
    end
    return taken ~= nil
end

local function key_action(state: any, action: any): boolean
    local key = action.key_type or action.key
    if key == "esc" then
        if state.popup then state.popup = nil; return true end
        return false
    elseif key == "backspace" then
        return up(state)
    elseif key == "f5" or action.key == "F5" then
        return command(state, "view_refresh", nil)
    elseif key == "enter" and action.alt then
        return properties(state)
    elseif action.ctrl and tostring(action.key or ""):lower() == "a" then
        return command(state, "edit_select_all", nil)
    end
    return false
end

function definition.update(state: any, action: any, context: any): any
    local kind, id = action.type, action.id
    if kind == "channel" then return reply(state, action) end
    if kind == "timer" or kind == "tick" or kind == "resize" or kind == "close" then return false end
    -- The SDK closes its floating menu on Esc, F10 or a press outside and
    -- says so: the window drops the node.
    if kind == "dismiss" then
        if id == "context" and state.popup then
            state.popup = nil
            return true
        end
        return false
    end
    if state.sheet then return sheet_update(state, action) end

    -- An action from the popup is its choice; any other pointer or key action
    -- dismisses it, as a click elsewhere does in Windows.
    local from_popup = action.menu == "context"
    if state.popup and not from_popup and kind ~= "key" then state.popup = nil end

    if id == "objects" and kind == "context" then
        local value: any = action.value
        if value ~= nil then
            if not state.selection[tostring(value.id)] then state.selection = {[tostring(value.id)] = true} end
            state.popup = {x = action.x, y = action.y, target = "object"}
        else
            state.popup = {x = action.x, y = action.y, target = "field"}
        end
        state.last_click = nil
        return true
    end
    if id == "objects" and kind == "select" then
        local value: any = action.value
        if type(action.selected) == "table" then
            local set = {}
            for key, on in pairs(action.selected) do if on then set[tostring(key)] = true end end
            state.selection = set
        elseif value ~= nil then
            state.selection = {[tostring(value.id)] = true}
        else
            state.selection = {}
        end
        -- A double click is a second CLICK on the same object: the arrows
        -- select too, and must not open.
        local clicked = action.pointer == true and value ~= nil and tostring(value.id) or nil
        if clicked ~= nil and clicked == state.last_click then
            state.last_click = nil
            return activate(state, find(state, clicked))
        end
        state.last_click = clicked
        state.notice = nil
        return true
    end
    if id == "objects" and kind == "activate" then
        local value: any = action.value
        return activate(state, value ~= nil and find(state, value.id) or nil)
    end
    if id == "tb_places" and kind == "change" then
        if action.value == state.path then return false end
        return open_folder(state, action.value, nil)
    end
    if kind == "activate" then
        if from_popup then state.popup = nil end
        return command(state, id, context)
    end
    if kind == "key" and action.action ~= "release" then return key_action(state, action) end
    return false
end

-- Esc closes a menu, a popup or a sheet; it does not close the folder window.
definition.close_on_escape = false

return {main = app.main(definition), definition = definition}
