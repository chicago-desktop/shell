-- Network Neighborhood: membership turned into rows, the local node first,
-- the leader named, and a status line that tells three states apart —
-- a mesh with peers, a lone node, and membership that refused to answer.
--
-- The model takes a snapshot as plain data, so the whole thing is checked
-- without a cluster: a two-node mesh in a test harness would prove the
-- runtime works, not that this window shapes it correctly.
local test = require("test")
local model = require("model")
local ui = require("ui")
local network = require("network_window")
local cells = require("cells")
local facts = require("facts")

-- Подставной `system`: одно поле отказано видом PermissionDenied, одно — так,
-- как отказывает настоящий модуль (Invalid и «permission denied: …»), одно
-- недоступно (кластера нет), остальные отвечают.
local function refusing_system(): any
    return {
        node = {
            id = function() return "kickside", nil end,
            addr = function() return "127.0.0.1:7946", nil end,
            role = function() return nil, errors.new({message = "no node role for you", kind = errors.PERMISSION_DENIED}) end,
        },
        process = {hostname = function() return "wippy-host", nil end},
        cluster = {
            members = function()
                return nil, errors.new({message = "permission denied: system.read on cluster", kind = errors.INVALID})
            end,
            leader = function() return nil, errors.new({message = "raft not available", kind = errors.NOT_FOUND}) end,
        },
    }
end

local function screen_text(tree: any, width: integer, height: integer): string
    local interaction = ui.interaction()
    local rows = cells.rows(ui.plan(tree, width, height, interaction), interaction, width, height)
    return (table.concat(rows, "\n"):gsub("\27%[[%d;:]*m", ""))
end

local function mesh(): any
    return {
        node_id = "kickside", node_addr = "127.0.0.1:7946", node_role = "voter",
        leader = "mesh-node",
        members = {
            {id = "mesh-node", is_local = false, addr = "127.0.0.1:7947"},
            {id = "kickside", is_local = true, addr = "127.0.0.1:7946"},
        },
    }
end

local function alone(): any
    return {node_id = "kickside", node_addr = "", node_role = "",
        leader = "", members = {{id = "kickside", is_local = true, addr = ""}}}
end

local function define_tests()
    test.describe("Network Neighborhood model", function()
        test.it("puts this computer first and names the elected leader", function()
            local rows = model.rows(mesh())
            test.eq(#rows, 2)
            test.eq(rows[1].id, "kickside", "the local node opens the list")
            test.is_true(rows[1].is_local)
            test.eq(rows[2].id, "mesh-node")
            test.is_true(rows[2].is_leader, "the leader is marked on the row, not guessed by the view")
            test.eq(model.role_text(rows[2], mesh()), "Leader")
            test.eq(model.role_text(rows[1], mesh()), "Voter", "the local node falls back to its own runtime role")
            test.eq(model.status_text(rows[1]), "This computer")
            test.eq(model.status_text(rows[2]), "Online")
        end)

        test.it("fills the table with the address, and writes a dash where there is none", function()
            local rows = model.table_rows(mesh())
            test.eq(#rows, 2)
            test.eq(rows[1].cells[1], "kickside")
            test.eq(rows[1].cells[2], "127.0.0.1:7946")
            test.eq(rows[2].cells[3], "Leader")
            test.eq(#model.COLUMNS, 4)
            local lonely = model.table_rows(alone())
            test.eq(lonely[1].cells[2], "—", "no address is a dash, not an empty column")
        end)

        test.it("tells a lone node from a refusal in the status line", function()
            test.eq(model.summary(mesh()), "2 object(s)")
            test.is_true(model.summary(alone()):find("standalone node", 1, true) ~= nil,
                "one member is the whole cluster, not a missing peer")
            local refused = {members = {}, failure = "cluster membership not available"}
            local said = model.summary(refused)
            test.is_true(said:find("0 object(s)", 1, true) ~= nil)
            test.is_true(said:find("not available", 1, true) ~= nil,
                "a refusal is named, not shown as an empty workgroup")
        end)

        test.it("names the selected node, and the leader when nothing is selected", function()
            local snap = mesh()
            test.is_true(model.detail(snap, "mesh-node"):find("127.0.0.1:7947", 1, true) ~= nil)
            test.is_true(model.detail(snap, nil):find("Leader: mesh-node", 1, true) ~= nil)
            test.eq(model.detail(alone(), nil), "No leader elected yet")
        end)
    end)

    test.describe("Network Neighborhood objects", function()
        test.it("opens with Entire Network and gives every node the host icon", function()
            local objects = model.objects(mesh())
            test.eq(#objects, 3, "the globe plus two computers")
            test.eq(objects[1].id, model.ENTIRE_NETWORK)
            test.eq(objects[1].image, "network", "the globe belongs to Entire Network alone")
            test.eq(objects[2].id, "kickside", "this computer comes first among the nodes")
            test.eq(objects[2].image, "my_computer")
            test.eq(objects[3].image, "my_computer")
            test.not_nil(objects[2].title, "the caption is the node name")
        end)

        test.it("counts objects, and says when one is picked", function()
            test.eq(model.objects_status(mesh(), nil), "3 object(s)")
            test.eq(model.objects_status(mesh(), "mesh-node"), "1 object(s) selected")
            test.eq(model.objects_status(alone(), nil), "2 object(s)")
        end)
    end)

    test.describe("Network Neighborhood window", function()
        -- The window itself is checked through the same plan the renderers and
        -- the hit tests use: a table that does not fit its window is a defect
        -- no screenshot of the model would show.
        test.it("lays out the menu, the icon grid and the status bar without overlaps", function()
            local state: any = {snapshot = mesh(), selected = "kickside", sheet = nil, about = false}
            local tree = network.definition.view(state, {width = 60, height = 14})
            local plan = ui.plan(tree, 60, 14, ui.interaction())
            test.not_nil(plan.by_id.objects, "the icon grid is planned")
            test.not_nil(plan.by_id.bar, "the window has a menu bar")
            local grid = plan.by_id.objects
            test.eq(#grid.cells, 3, "every object gets a cell in the grid")
            test.is_true(grid.cells[2].selected, "the selected node is marked on its cell")
            for _, item in ipairs(plan.items) do
                local rect = item.rect
                test.is_true(rect.x >= 1 and rect.y >= 1, "nothing is planned outside the client")
                test.is_true(rect.x + rect.w - 1 <= 60 and rect.y + rect.h - 1 <= 14,
                    "nothing is planned past the client edge")
            end
        end)

        test.it("opens a node on the second click and closes the sheet with Escape", function()
            local state: any = {snapshot = mesh(), selected = nil, sheet = nil, about = false}
            local node: any = model.objects(mesh())[3]
            network.definition.update(state, {type = "select", id = "objects", index = 3,
                value = node, pointer = true}, {})
            test.eq(state.selected, node.id, "the first click selects")
            test.is_nil(state.sheet, "and opens nothing")
            network.definition.update(state, {type = "select", id = "objects", index = 3,
                value = node, pointer = true}, {})
            test.eq(state.sheet, node.id, "the second click on the same icon opens it")
            local tree = network.definition.view(state, {width = 60, height = 14})
            local plan = ui.plan(tree, 60, 14, ui.interaction())
            test.not_nil(plan.by_id.sheet_ok, "the sheet has a way out")
            network.definition.update(state, {type = "key", key_type = "esc"}, {})
            test.is_nil(state.sheet, "Escape leaves the sheet instead of closing the window")
        end)

        test.it("keeps only working menu items, and each of them does something", function()
            local state: any = {snapshot = mesh(), selected = nil, sheet = nil, about = false}
            local closed = false
            local context: any = {width = 60, height = 14, close = function() closed = true end}
            local tree = network.definition.view(state, context)
            local titles, ids = {}, {}
            for _, entry in ipairs(tree.children[1].entries) do
                titles[#titles + 1] = entry.title
                for _, item in ipairs(entry.items) do
                    if not item.separator then ids[#ids + 1] = item.id end
                end
            end
            test.eq(table.concat(titles, " "), "File View Help", "no Edit: there is nothing to select all")
            test.eq(table.concat(ids, " "), "open close refresh about", "no Large Icons: there is one view")

            state.selected = "kickside"
            network.definition.update(state, {type = "activate", id = "open", menu = "bar"}, context)
            test.eq(state.sheet, "kickside", "Open opens the selected node")
            local plan = ui.plan(network.definition.view(state, context), 60, 14, ui.interaction())
            local title_w = 0
            for _, item in ipairs(plan.items) do
                if item.node.kind == "label" and item.node.text == "kickside" then title_w = item.rect.w end
            end
            test.is_true(title_w >= #"kickside", "the sheet title is shown whole, not cut to one cell")
            network.definition.update(state, {type = "activate", id = "sheet_ok"}, context)

            local before = state.snapshot
            network.definition.update(state, {type = "activate", id = "refresh", menu = "bar"}, context)
            test.is_true(state.snapshot ~= before, "Refresh reads a new snapshot")
            network.definition.update(state, {type = "activate", id = "close", menu = "bar"}, context)
            test.is_true(closed, "Close closes")
        end)

        test.it("switches to About and back, and Escape closes the window", function()
            local state: any = network.definition.init(nil, {})
            state.snapshot = mesh()
            state.sheet = nil
            network.definition.update(state, {type = "activate", id = "about"}, {})
            test.is_true(state.about)
            local tree = network.definition.view(state, {width = 60, height = 14})
            local plan = ui.plan(tree, 60, 14, ui.interaction())
            test.not_nil(plan.by_id.sheet_ok, "About has a way out")
            network.definition.update(state, {type = "key", key_type = "esc"}, {})
            test.is_false(state.about, "Escape leaves About instead of closing the window")
            local closed = false
            network.definition.update(state, {type = "key", key_type = "esc"},
                {close = function() closed = true end})
            test.is_true(closed, "the second Escape closes")
        end)
    end)

    -- Reading the runtime: a refusal by policy is named as one, a missing
    -- cluster as unavailable, and neither turns into "unnamed" or
    -- "no leader elected yet".
    test.describe("Network Neighborhood reading the runtime", function()
        test.it("tells a policy refusal from an absent cluster, whatever kind the runtime used", function()
            test.is_true(facts.denied(errors.new({message = "x", kind = errors.PERMISSION_DENIED})))
            test.is_true(facts.denied(errors.new({message = "permission denied: system.read on hosts", kind = errors.INVALID})),
                "the runtime's system module marks a refusal as Invalid")
            test.is_false(facts.denied(errors.new({message = "host ID required", kind = errors.INVALID})),
                "Invalid alone is not a refusal")
            test.is_false(facts.denied(errors.new({message = "cluster membership not available", kind = errors.INTERNAL})))
            test.is_false(facts.denied("permission denied"), "text without a runtime error is not evidence")
        end)

        test.it("keeps each field's value or its reason, and the screen shows the refusal", function()
            local snap: any = network.definition.snapshot(refusing_system())
            test.eq(snap.node_id, "kickside", "an answered field keeps its value")
            test.eq(snap.problems.members, "cluster members: permission denied: system.read on cluster")
            test.eq(snap.problems.node_role, "node role: permission denied (no node role for you)")
            test.eq(snap.problems.leader, "leader: unavailable (raft not available)")
            test.eq(snap.failure, snap.problems.members, "membership refusal goes to the status line")

            local state: any = {snapshot = snap, selected = nil, sheet = nil, about = false}
            local shown = screen_text(network.definition.view(state, {width = 140, height = 14}), 140, 14)
            test.is_true(shown:find("permission denied: system.read on cluster", 1, true) ~= nil,
                "the refusal is on screen: " .. shown)
            test.is_true(shown:find("raft not available", 1, true) ~= nil, "so is the missing cluster")
            test.is_nil(shown:find("standalone node", 1, true), "a refused membership is not a lone node")
            test.is_nil(shown:find("No leader elected yet", 1, true), "an unread leader is not an unelected one")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
