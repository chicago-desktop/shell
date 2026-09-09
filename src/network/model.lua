-- Network Neighborhood, the pure half: a snapshot of the mesh turned into
-- rows, captions and a status line. No `system` calls here — the window takes
-- the snapshot, this file only shapes it, and that is what the test checks
-- without a cluster to hand.
--
-- The vocabulary is the runtime's: a NODE is a member of the gossip mesh,
-- the LEADER is the node Raft currently elects, and `is_local` marks the node
-- the reader is sitting on. Windows called those computers, so the captions
-- do too — but a node that is this very runtime says so, otherwise the list
-- looks like a room full of strangers.

local model = {}

model.ENTIRE_NETWORK = "Entire Network"

-- A runtime with clustering switched off has no node NAME — it has a
-- generated uuid, and a workgroup of one machine called
-- `4a53358e-d8af-…` tells a reader nothing about which machine that is.
-- The host name is the honest caption there; with a cluster the node name
-- from the config wins, because that is what the peers call it.
local function looks_generated(id: any): boolean
    return tostring(id):match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-") ~= nil
end

function model.caption(id: any, snapshot: any, is_local: any): string
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local name = tostring(id or "")
    if is_local and looks_generated(name) then
        local host = tostring(snap.hostname or "")
        if host ~= "" then return host end
    end
    return name
end

-- rows(snapshot) -> rows for the table
--
-- One row per member, the local node first: in Network Neighborhood your own
-- machine is where the eye starts, and a list sorted purely by name would put
-- it wherever the alphabet happens to land.
function model.rows(snapshot: any): any
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local members: any = type(snap.members) == "table" and snap.members or {}
    local leader = tostring(snap.leader or "")

    local shaped = {}
    for _, entry in ipairs(members) do
        local member: any = entry
        local id = tostring(member.id or "")
        if id ~= "" then
            shaped[#shaped + 1] = {
                id = id,
                name = model.caption(id, snap, member.is_local == true),
                addr = tostring(member.addr or ""),
                is_local = member.is_local == true,
                is_leader = leader ~= "" and id == leader,
            }
        end
    end

    table.sort(shaped, function(a: any, b: any)
        if a.is_local ~= b.is_local then return a.is_local end
        return a.name < b.name
    end)
    return shaped
end

-- The role a person reads, not the one Raft prints. `voter` and `leader` are
-- the same word to gossip and different words to a reader deciding who
-- answers a consistent registry lookup.
function model.role_text(row: any, snapshot: any): string
    local line: any = type(row) == "table" and row or {}
    local snap: any = type(snapshot) == "table" and snapshot or {}
    if line.is_leader then return "Leader" end
    -- Capitalised by hand, not by `gsub` with a function replacement: in
    -- go-lua that form gives back the function itself, and the row then
    -- carries a gofunc where a word belongs — visible only when something
    -- tries to concatenate it.
    local role = tostring(snap.node_role or "")
    if line.is_local and role ~= "" then
        return role:sub(1, 1):upper() .. role:sub(2)
    end
    return "Member"
end

function model.status_text(row: any): string
    local line: any = type(row) == "table" and row or {}
    if line.is_local then return "This computer" end
    return "Online"
end

-- objects(snapshot) -> the icon grid, as Network Neighborhood shows it
--
-- "Entire Network" comes first and is not a node: in Windows it is the way
-- out of the workgroup into everything else. Here it stands for the mesh as
-- a whole — opening it says how many nodes there are and who leads them.
function model.objects(snapshot: any): any
    local out: any = {{
        id = model.ENTIRE_NETWORK, title = model.ENTIRE_NETWORK,
        image = "network", icon = "◍", kind = "item", entire = true,
    }}
    for _, row in ipairs(model.rows(snapshot)) do
        local line: any = row
        out[#out + 1] = {
            id = line.id, title = line.name,
            -- The single computer of shell32, the one Windows drew for a host
            -- in the workgroup. The globe belongs to Entire Network alone.
            image = "my_computer", icon = "▤", kind = "item",
            is_local = line.is_local, is_leader = line.is_leader,
            addr = line.addr,
        }
    end
    return out
end

-- The status bar of Explorer: how many objects, and — when one is picked —
-- that it is picked. Windows wrote both, and the second half is what tells a
-- reader that the dotted caption means "selected", not "broken".
function model.objects_status(snapshot: any, selected: any): string
    local objects = model.objects(snapshot)
    local count = #objects
    for _, entry in ipairs(objects) do
        local object: any = entry
        if object.id == selected then
            return "1 object(s) selected"
        end
    end
    return tostring(count) .. " object(s)"
end

model.COLUMNS = {
    {title = "Name", weight = 3},
    {title = "Address", weight = 3},
    {title = "Role", width = 8},
    {title = "Status", width = 14},
}

function model.table_rows(snapshot: any): any
    local out = {}
    for _, row in ipairs(model.rows(snapshot)) do
        local line: any = row
        out[#out + 1] = {id = line.id, cells = {
            line.name,
            line.addr ~= "" and line.addr or "—",
            model.role_text(line, snapshot),
            model.status_text(line),
        }}
    end
    return out
end

-- The status bar of Explorer, and the one sentence that has to distinguish
-- three states a reader would otherwise confuse: a mesh with peers, a runtime
-- with clustering switched off, and a cluster that refused to answer.
function model.summary(snapshot: any): string
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local rows = model.rows(snap)
    local count = #rows
    if snap.failure and count == 0 then
        return "0 object(s) · " .. tostring(snap.failure)
    end
    local text = tostring(count) .. " object(s)"
    if count == 1 and rows[1] and (rows[1] :: any).is_local then
        -- One member is not a defect and not an error: a single node IS the
        -- whole cluster. Saying so keeps a reader from hunting for the peer
        -- that was never configured.
        text = text .. " · standalone node, no peers"
    end
    return text
end

function model.detail(snapshot: any, selected: any): string
    local snap: any = type(snapshot) == "table" and snapshot or {}
    local rows = model.rows(snap)
    local chosen: any = nil
    for _, row in ipairs(rows) do
        local line: any = row
        if line.id == selected then chosen = line end
    end
    if not chosen then
        local leader = tostring(snap.leader or "")
        if leader == "" then return "No leader elected yet" end
        return "Leader: " .. leader
    end
    local parts = {chosen.name}
    if chosen.addr ~= "" then parts[#parts + 1] = chosen.addr end
    parts[#parts + 1] = model.role_text(chosen, snap)
    return table.concat(parts, " · ")
end

return model
