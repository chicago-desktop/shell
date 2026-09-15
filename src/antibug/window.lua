-- AntiBug (FR-009 §4, §4a): the test scanner window, an SDK application.
--
-- The model is `windows.shell.antibug:scan`, pure; here are the window's
-- tree, its actions and the world it reads through `definition.deps.sys` (a
-- test replaces it):
--   the test entries and the declared targets from the registry;
--   one item at a time through the runner, `funcs.async` — never
--   `funcs.call`, which would block the window for the length of a test;
--   the events on the window's own topic, watched like the runner's answer,
--   so both arrive as `{type = "channel"}` actions; a target's process sends
--   them for minutes, and Stop asks that process to kill its child;
--   the drives and folders for Save… through the explorer's `sources`, and
--   the log written with `fs` under the window's own `fs.get`.
local fs = require("fs")
local funcs = require("funcs")
local process = require("process")
local registry = require("registry")
local time = require("time")

local app = require("app")
local ui = require("ui")
local filedialog = require("filedialog")
local scan = require("scan")
local targets = require("targets")
local sources = require("sources")
local explorer_model = require("explorer_model")

local RUNNER = "windows.shell.antibug:runner"
local STOP_TOPIC = "antibug.stop"
-- How long a stopped target's process gets to say it is gone.
local STOP_WAIT = "5s"
local LOG_NAME = "antibug.log"
local LOG_TYPES = {
    {id = "log", label = "Log Files (*.log)", ext = "log"},
    {id = "all", label = "All Files (*.*)"},
}
local TABS = {"Where & What", "Reports"}

local live: any = {}

function live.find(): (any, any)
    local found, err = registry.find({["meta.type"] = "test"})
    return found, err
end

function live.find_targets(): (any, any)
    local found, err = registry.find({["meta.type"] = targets.TYPE})
    return found, err
end

function live.listen(): any
    local inbox = process.listen(scan.TOPIC)
    return inbox
end

function live.launch(id: string): (any, any)
    local command, err = funcs.new():async(RUNNER, {entry = id, pid = process.pid(), topic = scan.TOPIC})
    return command, err
end

function live.launch_target(id: string): (any, any)
    local command, err = funcs.new():async(RUNNER, {target = id, pid = process.pid(), topic = scan.TOPIC})
    return command, err
end

function live.stop(child: any): boolean
    local sent = process.send(tostring(child), STOP_TOPIC, {})
    return sent == true
end

function live.now(): number
    return time.now():unix_nano() / 1000000000
end

function live.drives(): (any, any)
    local records, err = sources.drives()
    if not records then return nil, err end
    return explorer_model.drives(records), nil
end

function live.list(place: any): (any, any)
    local view: any, err = sources.list(filedialog.address(place), nil)
    if not view then return nil, err end
    return view.objects, view.notice
end

function live.exists(drive: any, path: any): boolean
    local handle: any, err = fs.get(tostring(drive))
    if err or not handle then return false end
    return type(handle:stat(tostring(path))) == "table"
end

function live.write(drive: any, path: any, text: any): (any, any)
    local handle: any, err = fs.get(tostring(drive))
    if err or not handle then return nil, "drive " .. tostring(drive) .. " not opened: " .. tostring(err or "no such entry") end
    local _, write_err = handle:writefile(tostring(path), tostring(text or ""))
    if write_err then return nil, "file " .. tostring(path) .. " not written: " .. tostring(write_err) end
    return true, nil
end

local definition: any = {}

definition.deps = {sys = live}

-- The elapsed time in the status bar moves while a scan runs.
definition.interval = "1s"

local function sys(): any
    return definition.deps.sys
end

local function read_registry(): (any, any, any)
    local found, err = sys().find()
    local declared, targets_err = sys().find_targets()
    local why = err or targets_err
    return scan.entries(found), targets.entries(declared), why and ("registry not read: " .. tostring(why)) or nil
end

function definition.init(args: any, context: any): any
    local entries, declared, notice = read_registry()
    local model: any = {scan = scan.new(entries, declared), tab = 1, sheet = nil, finding = nil,
        inbox = nil, command = nil, response = nil, notice = notice}
    -- The subscription exists before the first scan: an event that arrived
    -- before it would lie in the inbox, where nobody reads it.
    local inbox = sys().listen()
    model.inbox = inbox
    if inbox then context.watch(inbox) end
    return model
end

-- answer_of(command) -> `{error?, returned?, child?}`: what the runner returned.
local function answer_of(command: any): any
    local payload, err = command:result()
    if err then return {error = tostring(err)} end
    local value: any = payload
    if type(payload) == "userdata" then value = payload:data() end
    if type(value) == "table" then return {error = value.error, returned = value.returned, child = value.child} end
    return {returned = value}
end

local function ended(model: any)
    model.command, model.response = nil, nil
    if model.scan.box then model.sheet = {kind = "box"} end
end

-- launch(model, context, id) — run `id`; an item the runner refused to start
-- is a finding and the next one goes; no id — the scan ended.
local function launch(model: any, context: any, id: any)
    local next_id: any = id
    while next_id do
        local current: any = scan.current(model.scan)
        local command, err
        if current.target then command, err = sys().launch_target(next_id)
        else command, err = sys().launch(next_id) end
        if command then
            model.command = command
            model.response = command:response()
            context.watch(model.response)
            -- A target has no timeout: a module's suite runs for minutes.
            if not current.target then context.after(current.timeout, {kind = "timeout", seq = current.seq}) end
            return
        end
        next_id = scan.failed_to_start(model.scan, err, sys().now())
    end
    ended(model)
end

local function advance(model: any, context: any)
    launch(model, context, scan.finish(model.scan, sys().now()))
end

local function start(model: any, context: any): boolean
    if scan.scanning(model.scan) then return false end
    model.finding, model.notice = nil, nil
    local id = scan.start(model.scan, sys().now())
    if id then launch(model, context, id) end
    return true
end

-- stop(model, context) — Stop: no other item starts; a running target's
-- process is asked to kill its child and gets `STOP_WAIT` to say so.
local function stop(model: any, context: any): boolean
    local current: any = scan.current(model.scan)
    scan.stop(model.scan)
    if current and current.target and current.child and not current.completed then
        sys().stop(current.child)
        context.after(STOP_WAIT, {kind = "stopwait", seq = current.seq})
    end
    return true
end

local function quit(model: any, context: any): boolean
    if scan.scanning(model.scan) then
        model.sheet = {kind = "quit"}
        return true
    end
    context.close()
    return true
end

local function read_place(dialog: any, place: any)
    local objects, notice = sys().list(place)
    filedialog.arrive(dialog, place, objects, notice)
end

local function open_save(model: any): boolean
    local drives: any = sys().drives() or {}
    local place: any = drives[1] and {drive = drives[1].id, path = "/"} or nil
    local dialog: any = {title = "Save As", button = "Save", types = LOG_TYPES, type = "log", name = LOG_NAME,
        drives = drives, place = place}
    if place then read_place(dialog, place) else dialog.notice = "there is no drive to keep files on" end
    model.sheet = {kind = "save", dialog = dialog}
    return true
end

local function write_log(model: any, place: any): boolean
    local path = filedialog.clean(place.path)
    local ok, why = sys().write(place.drive, path, scan.log_text(model.scan))
    if not ok then
        model.sheet = {kind = "message", title = "Save As", lines = {tostring(why or "the log was not written")}}
        return true
    end
    model.sheet = nil
    model.notice = "The log was saved as " .. path .. "."
    return true
end

local ABOUT = {
    "AntiBug scans the application's tests — the",
    "registry entries with meta.type test — inside",
    "the running runtime, one entry at a time, and",
    "the targets it declares: module working copies",
    "through the wippy runner, Go modules through",
    "go test. Tests run under AntiBug's runner, which",
    "has its own actor and a wide scope; this window",
    "only asks it. The shell's own tests live in its",
    "harness and are not loaded by the application.",
}

local function command(model: any, context: any, id: any): boolean
    local s: any = model.scan
    if id == "scan" or id == "scan_now" then return start(model, context)
    elseif id == "stop" then return stop(model, context)
    elseif id == "new_scan" then
        if scan.scanning(s) then return false end
        scan.clear(s)
        model.finding, model.notice = nil, nil
        return true
    elseif id == "exit" then return quit(model, context)
    elseif id == "refresh" then
        if scan.scanning(s) then return false end
        local entries, declared, notice = read_registry()
        scan.refresh(s, entries, declared)
        model.notice = notice
        return true
    elseif id == "show_all" then s.show_all = not s.show_all; return true
    elseif id == "reports" then model.tab = 2; return true
    elseif id == "about" then model.sheet = {kind = "message", title = "About AntiBug", lines = ABOUT}; return true
    elseif id == "save" then return open_save(model)
    end
    return false
end

local function sheet_update(model: any, action: any, context: any): boolean
    local sheet: any = model.sheet
    local escape = action.type == "key" and action.key_type == "esc"
    local pressed = action.type == "activate" and action.id or nil
    if sheet.kind == "save" then
        local _, result = filedialog.update(sheet.dialog, action)
        if result == nil then return true end
        if result.read then read_place(sheet.dialog, result.read); return true end
        if result.cancel then model.sheet = nil; return true end
        if result.accept then
            local place: any = {drive = result.accept.drive, path = result.accept.path}
            if not tostring(place.path):match("%.[^/%.]+$") and sheet.dialog.type == "log" then
                place.path = place.path .. ".log"
            end
            if sys().exists(place.drive, filedialog.clean(place.path)) then
                model.sheet = {kind = "replace", place = place, back = sheet.dialog}
                return true
            end
            return write_log(model, place)
        end
        return true
    end
    if sheet.kind == "replace" then
        if pressed == "replace_yes" then return write_log(model, sheet.place) end
        if pressed == "replace_no" or escape then model.sheet = {kind = "save", dialog = sheet.back}; return true end
        return false
    end
    if sheet.kind == "quit" then
        if pressed == "quit_yes" then
            stop(model, context)
            context.close()
            return true
        end
        if pressed == "quit_no" or escape then model.sheet = nil; return true end
        return false
    end
    -- The box, Virus Info, About, a refusal: OK or Esc closes it.
    if pressed == "message_ok" or escape then model.sheet = nil; return true end
    return false
end

-- How often a scan redraws. Every case is an event, and a module's suite
-- sends hundreds a second: a frame per event made the window publish its
-- whole tree to the compositor as often (seen on the live shell, 2026-09-14,
-- with the shell unresponsive). An event marks the frame owed; one timer
-- draws it.
local FRAME_DELAY = "200ms"

-- owe(model, context) -> false: the change is drawn by the frame timer.
local function owe(model: any, context: any): boolean
    if not model.frame_owed then
        model.frame_owed = true
        context.after(FRAME_DELAY, {kind = "frame"})
    end
    return false
end

local function channel_update(model: any, action: any, context: any): boolean
    if action.channel == model.inbox then
        local changed = scan.event(model.scan, action.value)
        -- The runner answered first and `test:complete` came within the
        -- grace; a target's process said it exited. The end is drawn now.
        if changed and scan.settled(model.scan) then
            advance(model, context)
            return true
        end
        if changed then return owe(model, context) end
        return false
    end
    if model.response ~= nil and action.channel == model.response then
        context.unwatch(model.response)
        model.response = nil
        if scan.answered(model.scan, answer_of(model.command)) then
            advance(model, context)
        else
            local current: any = scan.current(model.scan)
            -- A target settles on its exit; a test entry gets the grace.
            if current.target then
                -- Stop pressed before the runner told the child's pid.
                if model.scan.run.stop and current.child then
                    sys().stop(current.child)
                    context.after(STOP_WAIT, {kind = "stopwait", seq = current.seq})
                end
            else
                context.after(scan.GRACE, {kind = "grace", seq = current.seq})
            end
        end
        return true
    end
    return false
end

local function timer_update(model: any, action: any, context: any): boolean
    local tag: any = action.tag
    -- The owed frame: whatever the events changed is drawn now, once.
    if type(tag) == "table" and tag.kind == "frame" then
        model.frame_owed = false
        return true
    end
    local current: any = scan.current(model.scan)
    -- A timer of an item that already finished: nothing to do.
    if type(tag) ~= "table" or not current or tag.seq ~= current.seq then return false end
    if tag.kind == "grace" then
        advance(model, context)
        return true
    end
    if tag.kind == "timeout" and not current.answered then
        if model.response then context.unwatch(model.response) end
        model.response = nil
        launch(model, context, scan.timed_out(model.scan, sys().now()))
        return true
    end
    if tag.kind == "stopwait" and not current.completed then
        -- The target's process did not answer the Stop: it is counted as
        -- stopped without it.
        scan.event(model.scan, {type = "antibug:exit", data = {ref_id = current.id, stopped = true}})
        advance(model, context)
        return true
    end
    return false
end

function definition.update(model: any, action: any, context: any): boolean
    local s: any = model.scan
    if action.type == "close" then
        -- A scan is running: ask first (C3, `context.stay()`); a running
        -- test entry finishes on its own, its events go to a pid that is gone.
        if scan.scanning(s) then
            model.sheet = {kind = "quit"}
            context.stay()
        end
        return true
    end
    if action.type == "channel" then return channel_update(model, action, context) end
    if action.type == "timer" then return timer_update(model, action, context) end
    if action.type == "tick" then return scan.scanning(s) end
    if model.sheet then return sheet_update(model, action, context) end
    if action.type == "activate" and action.menu == "menu" then return command(model, context, action.id) end
    if action.type == "activate" and (action.id == "scan_now" or action.id == "stop"
        or action.id == "new_scan" or action.id == "save") then
        return command(model, context, action.id)
    end
    if action.type == "key" and action.key_type == "f5" then return start(model, context) end
    if action.id == "tabs" and action.type == "select" then
        model.tab = math.tointeger(tonumber(action.index)) or 1
        return true
    end
    if action.type == "change" then
        if action.id == "target" then s.target, s.selected = tostring(action.value or scan.REGISTRY), nil
        elseif action.id == "other" then s.include_other = action.value == true
        elseif action.id == "all" then s.only_failed = false
        elseif action.id == "failed" then s.only_failed = true
        else return false end
        return true
    end
    if action.id == "tree" then
        local row: any = type(action.value) == "table" and action.value or {}
        if action.type == "toggle" then scan.toggle(s, row.id); return true end
        if action.type == "select" or action.type == "activate" then s.selected = row.id; return true end
        return false
    end
    if action.id == "findings" and (action.type == "select" or action.type == "activate") then
        local row: any = type(action.value) == "table" and action.value or {}
        -- Enter, or a click on the row already selected (a double click).
        local again = action.type == "select" and action.pointer == true and row.id ~= nil and row.id == model.finding
        model.finding = row.id
        if action.type == "activate" or again then
            local found = scan.finding_of(s, row.id)
            if found then model.sheet = {kind = "message", title = "Virus Info", lines = scan.info(found)} end
        end
        return true
    end
    return false
end

-- ─── the tree ───────────────────────────────────────────────────────────

local function menus(model: any): any
    local s: any = model.scan
    local scanning = scan.scanning(s)
    return {
        {title = "File", items = {
            {id = "scan", text = "Scan Now", shortcut = "F5", disabled = scanning},
            {id = "stop", text = "Stop", disabled = not scanning},
            {separator = true},
            {id = "exit", text = "Exit"},
        }},
        {title = "View", items = {
            {id = "refresh", text = "Refresh list", disabled = scanning},
            {separator = true},
            {id = "show_all", text = "Show all results", checked = s.show_all == true},
            {separator = true},
            {id = "reports", text = "Reports"},
        }},
        {title = "Help", items = {{id = "about", text = "About AntiBug"}}},
    }
end

local function where_page(model: any): any
    local s: any = model.scan
    local scanning = scan.scanning(s)
    local current: any = scan.current(s)
    local stop_text = "Stop"
    if scanning then stop_text = current and current.target and "Stop" or "Stop after current" end
    return {kind = "row", gap = 1, children = {
        {kind = "column", gap = 0, children = {
            {kind = "row", size = 2, gap = 1, children = {
                {kind = "label", size = 8, text = "Scan in:"},
                {kind = "select", id = "target", value = s.target, options = scan.options(s), disabled = scanning},
            }},
            {kind = "checkbox", id = "other", size = 1, text = "Include suites without a group",
                checked = s.include_other == true, disabled = scanning or not scan.registry_shown(s)},
            {kind = "row", size = 1, gap = 2, children = {
                {kind = "radio", id = "all", size = 11, text = "All tests", checked = not s.only_failed, disabled = scanning},
                {kind = "radio", id = "failed", text = "Only failed last time", checked = s.only_failed == true, disabled = scanning},
            }},
            {kind = "tree", id = "tree", rows = scan.tree(s), selected = s.selected},
        }},
        {kind = "column", size = 19, gap = 0, children = {
            {kind = "button", id = "scan_now", size = 2, text = "Scan Now", default = true, disabled = scanning},
            {kind = "button", id = "stop", size = 2, text = stop_text,
                disabled = not scanning or s.phase == "stopping"},
            {kind = "button", id = "new_scan", size = 2, text = "New Scan", disabled = scanning},
        }},
    }}
end

local function reports_page(model: any): any
    local s: any = model.scan
    return {kind = "column", gap = 0, children = {
        {kind = "text", id = "log", text = #s.log > 0 and scan.log_text(s) or "No scan yet."},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = "save", size = 10, text = "Save…", disabled = #s.log == 0},
        }},
    }}
end

local function sheet_tree(model: any): any
    local sheet: any = model.sheet
    if sheet.kind == "save" then return filedialog.sheet(sheet.dialog) end
    if sheet.kind == "replace" then
        return ui.confirm({title = "Save As", image = "find", icon = "¤", yes = "replace_yes", no = "replace_no",
            lines = {tostring(sheet.place.path):match("[^/]*$") .. " already exists.", "Do you want to replace it?"}})
    end
    if sheet.kind == "quit" then
        return ui.confirm({title = "AntiBug", image = "find", icon = "¤", yes = "quit_yes", no = "quit_no",
            lines = {"A scan is running. Stop and exit?"}})
    end
    if sheet.kind == "box" then
        local box: any = model.scan.box or scan.summary(model.scan)
        return ui.message({title = box.title, lines = box.lines, image = "find", icon = "¤"})
    end
    return ui.message({title = sheet.title, lines = sheet.lines, image = "find", icon = "¤"})
end

function definition.view(model: any, context: any): any
    if model.sheet then return sheet_tree(model) end
    local s: any = model.scan
    local value, ceiling, caption = scan.progress(s)
    local counts, phase = scan.status(s, sys().now())
    if model.notice or s.notice then caption = tostring(model.notice or s.notice) end
    return {kind = "column", gap = 0, children = {
        {kind = "menu", id = "menu", size = 1, entries = menus(model)},
        {kind = "tabs", id = "tabs", labels = TABS, active = model.tab, padding = 1, padding_bottom = 0,
            children = {model.tab == 2 and reports_page(model) or where_page(model)}},
        {kind = "table", id = "findings", size = 6, columns = scan.COLUMNS, rows = scan.rows(s), selected = model.finding},
        {kind = "row", size = 1, gap = 1, children = {
            {kind = "label", size = 30, text = caption},
            {kind = "gauge", value = value, ceiling = ceiling, orient = "horizontal"},
        }},
        {kind = "statusbar", size = 1, fields = {
            {text = counts, width = math.max(10, (tonumber(context.width) or 62) - 13)},
            {text = phase},
        }},
    }}
end

-- The caption of the Save As sheet while it is up; the entry's title else.
function definition.title(model: any): any
    if model.sheet and model.sheet.kind == "save" then return filedialog.title(model.sheet.dialog) end
    return nil
end

return {main = app.main(definition), definition = definition}
