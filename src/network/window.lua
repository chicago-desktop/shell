-- Network Neighborhood — the mesh, the way Windows 95 showed a workgroup:
-- a grid of icons, "Entire Network" first, one computer per node, and a
-- status bar that says how many objects are there and whether one is picked.
--
-- Every reading goes through `butschster.windows.config:system`: a value OR a
-- reason, never a silent blank. `system.cluster.members()` answers an error
-- while membership is still forming, on a runtime with clustering switched
-- off, and when the policy denies `system.read` — the status bar names which,
-- and the window keeps showing the node it runs on.
local facts = require("facts")
local app = require("app")
local ui = require("ui")
local model = require("model")

local definition: any = {interval = "2s"}

-- One snapshot per tick. Two reads of the same fact inside one frame can
-- disagree — membership changes between them — and a window that shows four
-- computers and "3 object(s)" is worse than one that is a tick stale.
local function text_of(value: any): string
    return value ~= nil and tostring(value) or ""
end

local function snapshot(from: any?): any
    local snap: any = facts.read({"node_id", "node_addr", "node_role", "hostname", "members", "leader"}, from)
    -- Why a field is blank travels with the snapshot: the view shows the
    -- reason where it used to say "unnamed" or "no leader elected yet".
    local out: any = {problems = snap.problems}
    out.node_id = text_of(snap.node_id)
    out.node_addr = text_of(snap.node_addr)
    out.node_role = text_of(snap.node_role)
    -- The machine name, for the case the runtime has no cluster name yet.
    out.hostname = text_of(snap.hostname)
    out.members = type(snap.members) == "table" and snap.members or {}
    out.failure = snap.problems.members

    -- Clustering off: membership answers nothing, but the runtime is still a
    -- node. Showing an empty window there would say "the network is gone",
    -- when the truth is "this computer is the whole network".
    if #out.members == 0 and out.node_id ~= "" then
        out.members = {{id = out.node_id, is_local = true, addr = out.node_addr}}
    end

    out.leader = text_of(snap.leader)
    return out
end
-- For tests: the same snapshot over a stand-in `system`.
definition.snapshot = snapshot

function definition.init(args: any, context: any): any
    return {snapshot = snapshot(), selected = nil, sheet = nil, about = false}
end

-- The properties of one object, as a sheet inside the window. What a node can
-- honestly show from here is what gossip carries about it: its name, its
-- address and its part in the Raft quorum. Anything deeper about a REMOTE
-- node has to be asked of that node — `system.*` reads this runtime only.
local function sheet_lines(snap: any, id: any): any
    if id == model.ENTIRE_NETWORK then
        local rows = model.rows(snap)
        local leader = tostring(snap.leader or "")
        return {
            "The whole mesh as gossip currently sees it.",
            "Nodes: " .. tostring(#rows),
            "Leader: " .. (leader ~= "" and leader or ((snap.problems or {}).leader or "none elected yet")),
            snap.failure and ("Membership: " .. tostring(snap.failure)) or "Membership: gossip (SWIM)",
        }, "network"
    end
    for _, row in ipairs(model.rows(snap)) do
        local line: any = row
        if line.id == id then
            return {
                "Address: " .. (line.addr ~= "" and line.addr or "not advertised"),
                "Role: " .. model.role_text(line, snap),
                "Status: " .. model.status_text(line),
                line.is_local and "Processes and memory: see System Properties"
                    or "Processes and memory: held by that node, not readable from here",
            }, "my_computer"
        end
    end
    return {"This object is gone from the workgroup."}, "my_computer"
end

function definition.view(state: any, context: any): any
    local snap: any = state.snapshot

    if state.sheet or state.about then
        local id = state.sheet or model.ENTIRE_NETWORK
        local title = state.about and "Network Neighborhood" or tostring(id)
        local lines, image = sheet_lines(snap, id)
        if state.about then
            lines = {"Wippy mesh: gossip membership, Raft leadership.",
                "This node: " .. (snap.node_id ~= "" and snap.node_id or ((snap.problems or {}).node_id or "unnamed")),
                "Read-only: this window joins nothing and evicts nobody."}
            image = "network_neighborhood"
        end
        return ui.message({title = title, image = image, icon = "▩", lines = lines, ok = "sheet_ok"})
    end

    return {kind = "column", gap = 0, children = {
        {kind = "menu", id = "bar", size = 1, entries = {
            {title = "File", accel = 1, items = {
                {id = "open", text = "Open", disabled = state.selected == nil},
                {separator = true},
                {id = "close", text = "Close"},
            }},
            -- Только работающие пункты: «Выделить всё» и «Крупные значки» были
            -- выключены навсегда — выделять здесь нечего, вид один.
            {title = "View", accel = 1, items = {{id = "refresh", text = "Refresh"}}},
            {title = "Help", accel = 1, items = {{id = "about", text = "About"}}},
        }},
        {kind = "icons", id = "objects", items = model.objects(snap), selected = state.selected},
        {kind = "statusbar", size = 1, fields = {
            {text = " " .. model.objects_status(snap, state.selected), width = 24},
            {text = " " .. model.detail(snap, state.selected)},
        }},
    }}
end

local function open_selected(state: any)
    if state.selected == nil then return false end
    state.sheet = state.selected
    return true
end

function definition.update(state: any, action: any, context: any)
    if action.type == "tick" then
        state.snapshot = snapshot()
        return true
    elseif action.id == "objects" and action.type == "select" then
        local value: any = action.value
        local id = value and value.id or nil
        -- A second click on an already selected icon is the double click:
        -- the grid says the click came from the pointer, and the window
        -- decides what a repeat means — exactly as Explorer does.
        if id ~= nil and id == state.selected and action.pointer == true then
            return open_selected(state)
        end
        state.selected = id
        return true
    elseif action.id == "objects" and action.type == "activate" then
        local value: any = action.value
        state.selected = value and value.id or state.selected
        return open_selected(state)
    elseif action.type == "activate" and action.id == "open" then
        return open_selected(state)
    elseif action.type == "activate" and action.id == "refresh" then
        state.snapshot = snapshot()
        return true
    elseif action.type == "activate" and action.id == "about" then
        state.about = true
        return true
    elseif action.type == "activate" and action.id == "sheet_ok" then
        state.sheet, state.about = nil, false
        return true
    elseif action.type == "activate" and action.id == "close" then
        context.close()
    elseif action.type == "key" then
        if action.key_type == "esc" then
            if state.sheet or state.about then
                state.sheet, state.about = nil, false
                return true
            end
            context.close()
        elseif action.key_type == "f5" or action.key == "F5" then
            state.snapshot = snapshot()
            return true
        else
            return false
        end
    else
        return false
    end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
