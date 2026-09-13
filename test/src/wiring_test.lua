-- Registry shape checks. The harness does not go through its own router, so
-- the handles are checked as wiring: the entries exist and reference each other.
--
-- Pinned here too are invariants whose violation looks from outside not like
-- an error but like an oddity: the terminal host must silence the log, the
-- layout handles must NOT be able to spawn processes, and a handle for
-- creating a program must not exist at all.
local test = require("test")
local registry = require("registry")
local defaults = require("defaults")

local TERMINAL_ID = "butschster.windows:terminal"
local SHELL_ID = "butschster.windows:shell"
local CATALOG_ID = "butschster.windows.programs:catalog"
local SEED_ID = "butschster.windows.programs:seed"
local VIEW_ID = "butschster.windows.programs:desktop_view"
local REPO_ID = "butschster.windows.persist:repo"
local CONTROL_ID = "butschster.windows.api:control"
local MIGRATION_ID = "butschster.windows.migrations:01_create_desktop_items"
local RUNTIME_POLICY_ID = "butschster.windows.security:shell_runtime"
local STORAGE_POLICY_ID = "butschster.windows.security:shell_storage"
local ACCESS_POLICY_ID = "butschster.windows.security:shell_endpoint_access"
local EXPLORER_ID = "butschster.windows.explorer:window"
local EXPLORER_POLICY_ID = "butschster.windows.security:explorer_window"
local SDK_RENDER_ID = "butschster.windows.sdk:render"

local ENDPOINTS = {
    {id = "butschster.windows.api:list_programs", method = "GET", path = "/windows/programs"},
    {id = "butschster.windows.api:list_desktop", method = "GET", path = "/windows/desktop"},
    {id = "butschster.windows.api:create_desktop_item", method = "POST", path = "/windows/desktop"},
    {id = "butschster.windows.api:update_desktop_item", method = "PATCH", path = "/windows/desktop/{id}"},
    {id = "butschster.windows.api:delete_desktop_item", method = "DELETE", path = "/windows/desktop/{id}"},
    {id = "butschster.windows.api:shell_status", method = "GET", path = "/windows/status"},
}

local function get(id)
    local entry, err = registry.get(id)
    test.is_nil(err)
    test.not_nil(entry, id .. " is missing")
    return entry
end

local function meta_of(entry)
    if type(entry.meta) == "table" then return entry.meta end
    if type(entry.data) == "table" and type(entry.data.meta) == "table" then return entry.data.meta end
    return {}
end

local function data_of(entry)
    if type(entry.data) == "table" then return entry.data end
    return entry
end

local function qualify(ref, ns)
    if type(ref) ~= "string" then return ref end
    if ref:find(":", 1, true) then return ref end
    return ns .. ":" .. ref
end

local function actions_of(policy_entry)
    local policy = data_of(policy_entry).policy or {}
    local actions = policy.actions
    if type(actions) == "string" then return {actions} end
    return type(actions) == "table" and actions or {}
end

local function has(list, needle)
    for _, item in ipairs(list) do
        if item == needle then return true end
    end
    return false
end

local function define_tests()
    test.describe("butschster.windows hosts", function()
        test.it("silences the log on its own terminal host", function()
            -- Without this a runtime log line throws the frame out of alignment
            -- for good: the surface differ considers itself the only writer.
            local terminal = data_of(get(TERMINAL_ID))
            test.eq(terminal.hide_logs, true)
        end)

        test.it("does not set up a window host of its own", function()
            -- Windows are hosted by the base. A second host would mean a second
            -- copy of the window mechanics, which would drift from the original
            -- at the first edit — and that would come to light a week later.
            -- registry.get on a missing entry answers (nil, "entry not
            -- found"), not (nil, nil): check the entry, not the absence of an
            -- error — otherwise the test fails exactly when everything is right.
            local workers = registry.get("butschster.windows:workers")
            test.is_nil(workers, "the window host belongs to the base")
        end)
    end)

    test.describe("butschster.windows explorer", function()
        test.it("declares \"My Computer\" as an ordinary registry program", function()
            -- The shell finds it by the same registry.find as everything else.
            -- A special path for its own window would mean that the shell's
            -- window lives by different rules than a window of any other module.
            local entry = get(EXPLORER_ID)
            local meta = meta_of(entry)
            test.eq(meta.type, "tui_desktop.window",
                "without this type the window gets into neither the menu nor the catalog")
            test.not_nil(meta.title)

            local data = data_of(entry)
            test.eq(data.kind or entry.kind, "process.lua")
            test.eq(data.method, "main")
            for _, needed in ipairs({"channel", "tty", "fs", "registry", "sql"}) do
                test.is_true(has(data.modules or {}, needed),
                    "the window needs the module " .. needed)
            end
        end)

        test.it("asks the compositor through the base's library, not a protocol of its own", function()
            -- The compositor's name reaches the window in the process context.
            -- A constant of our own would work only under our shell and would
            -- silently miss under any other — and `open` does not wait for an
            -- answer, so a miss would look like success.
            local imports = data_of(get(EXPLORER_ID)).imports or {}
            test.eq(qualify(imports.desktop, "butschster.windows.explorer"),
                "butschster.tui_desktop.desktop:window_api")

            -- The window does not talk to processes itself: the library does it
            -- for the window, and the module is declared on the library. A
            -- `process` module on the window would mean a second protocol of its
            -- own next to the shared one.
            test.is_false(has(data_of(get(EXPLORER_ID)).modules or {}, "process"),
                "the window does not talk to processes directly")
        end)

        test.it("is an SDK application: the shared components and renderer, not a copy of its own", function()
            -- A button of its own, slightly different, would mean that inside a
            -- Windows 95 window lives a different Windows. They would diverge in
            -- look, not in a failure — that is, it would be noticed a week later.
            -- FR-008 moved the folder window onto the SDK: the tree is drawn by
            -- the one renderer every SDK window uses.
            local imports = data_of(get(EXPLORER_ID)).imports or {}
            test.eq(qualify(imports.app, "butschster.windows.explorer"), "butschster.windows.sdk:app")
            test.eq(qualify(imports.sources, "butschster.windows.explorer"),
                "butschster.windows.explorer:sources")
            test.is_nil(imports.render, "no renderer of its own")
            local meta = meta_of(get(EXPLORER_ID))
            test.eq(meta.pixel_render, SDK_RENDER_ID)
            test.eq(meta.pixel_state, EXPLORER_ID, "the window is its own state provider")
        end)

        test.it("keeps no custom renderer entries behind", function()
            -- A renderer that nothing uses still loads, still imports the
            -- theme's internals, and is the first thing someone edits by
            -- mistake. registry.get answers (nil, "entry not found").
            test.is_nil(registry.get("butschster.windows.explorer:render"))
            test.is_nil(registry.get("butschster.windows.explorer:render_pixels"))
            test.is_nil(registry.get("butschster.windows.explorer:state"))
        end)

        test.it("does not let the window spawn processes or run programs", function()
            -- A window with the right to spawn processes will sooner or later
            -- launch something other than what the file was opened with. It can
            -- open a neighbouring window only by asking the compositor, which
            -- decides for itself.
            local actions = actions_of(get(EXPLORER_POLICY_ID))
            test.is_false(has(actions, "process.spawn"), "the window cannot spawn processes")
            test.is_false(has(actions, "process.spawn.monitored"))
            test.is_false(has(actions, "exec.run"), "the window cannot run programs")
            test.is_false(has(actions, "registry.apply"), "the window cannot change the registry")

            for _, needed in ipairs({"registry.find", "db.get", "fs.get",
                "process.send", "process.registry"}) do
                test.is_true(has(actions, needed), "the window needs the right " .. needed)
            end
        end)

        test.it("puts shortcuts on the desktop only to existing entries", function()
            -- The furniture skips a shortcut to a vanished program SILENTLY —
            -- that is right on the first launch and unbearable here: moving "My
            -- Computer" to another entry would look not like an error but like
            -- an empty desktop. All the furniture is checked, not one line: a
            -- list you can forget to add a check to checks something other than
            -- what stands on the desktop.
            for _, item in ipairs(defaults.ITEMS) do
                if item.kind == "shortcut" then
                    test.not_nil(registry.get(item.entry),
                        "the furniture points to " .. tostring(item.entry) ..
                        " — there is no entry with that id")
                end
            end
        end)
    end)

    test.describe("butschster.windows shell", function()
        test.it("serves the shell as the windows command with its own actor", function()
            local entry = get(SHELL_ID)
            local command = meta_of(entry).command or {}
            test.eq(command.name, "windows")
            test.not_nil(command.security, "the command must carry its own security context")

            local data = data_of(entry)
            test.eq(data.method, "main")
            test.is_true(has(data.modules or {}, "tty"), "the shell needs the tty module")
        end)

        test.it("calls the base's mechanics rather than copying them", function()
            -- This is why the shell is split out into a separate module: it
            -- brings the look, the catalog and the layout. Were a compositor of
            -- its own to appear here, it would drift from the original, and
            -- today's findings in the base would not make it into the copy.
            local imports = data_of(get(SHELL_ID)).imports or {}
            test.eq(qualify(imports.library, "butschster.windows"),
                "butschster.tui_desktop.desktop:library", "the shell calls the base's compositor")
            test.eq(qualify(imports.catalog, "butschster.windows"), CATALOG_ID)
            test.eq(qualify(imports.seed, "butschster.windows"), SEED_ID)
            test.eq(qualify(imports.view, "butschster.windows"), VIEW_ID)
            test.eq(qualify(imports.repo, "butschster.windows"), REPO_ID)
        end)

        test.it("declares a dependency on the base", function()
            local dep = get("butschster.windows:dep.butschster.tui_desktop")
            test.eq(data_of(dep).component, "butschster/tui-desktop")
        end)

        test.it("carries the layout migration", function()
            local entry = get(MIGRATION_ID)
            test.eq(meta_of(entry).type, "migration")
            test.not_nil(meta_of(entry).target_db, "the migration needs a database resource")
        end)
    end)

    test.describe("butschster.windows handles", function()
        test.it("wires each handle to its handler on the application router", function()
            for _, expected in ipairs(ENDPOINTS) do
                get(expected.id)
                local endpoint = get(expected.id .. ".endpoint")
                local data = data_of(endpoint)
                test.eq(qualify(data.func, "butschster.windows.api"), expected.id)
                test.eq(data.method, expected.method)
                test.eq(data.path, expected.path)
                test.eq(meta_of(endpoint).router, "app:api")
            end
            get(CONTROL_ID)
        end)

        test.it("does not set up handles for creating a program", function()
            -- Programs are declared by the registry: by installing a module or
            -- through the base's workshop. A creation handle of its own would
            -- mean a second source of truth, and the two would diverge on the
            -- first removal of a module.
            local found, err = registry.find({[".kind"] = "http.endpoint"})
            test.is_nil(err)
            for _, entry in ipairs(found or {}) do
                local data = data_of(entry)
                local path = tostring(data.path or "")
                local method = tostring(data.method or "")
                local creates_program = path == "/windows/programs" and method ~= "GET"
                test.is_false(creates_program,
                    "the program catalog is read-only: " .. method .. " " .. path)
            end
        end)

        test.it("nudges the shell after a layout change", function()
            -- The compositor re-reads the layout on command, not every frame.
            -- A handle that changed a row and kept quiet looks as if it did not
            -- work: the icon would appear only after a restart.
            for _, id in ipairs({"butschster.windows.api:create_desktop_item",
                "butschster.windows.api:update_desktop_item",
                "butschster.windows.api:delete_desktop_item"}) do
                local imports = data_of(get(id)).imports or {}
                test.eq(qualify(imports.control, "butschster.windows.api"), CONTROL_ID,
                    id .. " must be able to nudge the shell")
            end
        end)
    end)

    test.describe("butschster.windows policies", function()
        test.it("does not let the layout handles spawn processes", function()
            local actions = actions_of(get(STORAGE_POLICY_ID))
            test.is_true(has(actions, "db.get"), "the handle needs database access as the db.get action")
            test.is_true(has(actions, "registry.find"), "and reading the catalog from the registry")
            -- The runtime checks registry.get on every entry registry.find
            -- returns, and nothing else: without it the catalog is empty, not
            -- refused.
            test.is_true(has(actions, "registry.get"),
                "registry.find returns only the entries registry.get allows")
            test.is_true(has(actions, "process.send"), "and the right to nudge the shell")
            test.is_false(has(actions, "process.spawn"), "the handle cannot spawn processes")
            test.is_false(has(actions, "exec.run"), "the handle cannot run programs")
            test.is_false(has(actions, "registry.apply"), "the handle cannot change the registry")
        end)

        test.it("grants the environment by variable name, never over \"*\"", function()
            -- Under neighbouring names lie tokens. `env.get` is checked per
            -- name, so a policy that grants it names every variable it opens.
            -- Checked by a rule over every policy of the module, not a list.
            local found, err = registry.find({[".kind"] = "security.policy"})
            test.is_nil(err)
            local checked = 0
            for _, entry in ipairs(found or {}) do
                local id = tostring(entry.id)
                if id:sub(1, #"butschster.windows") == "butschster.windows" and has(actions_of(entry), "env.get") then
                    checked = checked + 1
                    local policy = data_of(entry).policy or {}
                    local resources = policy.resources
                    test.eq(type(resources), "table", id .. " grants env.get without a list of names")
                    for _, name in ipairs(type(resources) == "table" and resources or {}) do
                        test.is_nil(tostring(name):find("*", 1, true), id .. " grants env.get over " .. tostring(name))
                    end
                end
            end
            test.is_true(checked >= 2, "the shell's and the install panel's env policies were not found")
        end)

        test.it("grants no registry.entry anywhere: it is not an action", function()
            -- The runtime checks registry.get and nothing else on the
            -- registry; `registry.entry` is the kind of a registry entry. A
            -- policy that lists it reads as a right it does not grant, and the
            -- next policy copies it. A rule over every policy of the module.
            local found, err = registry.find({[".kind"] = "security.policy"})
            test.is_nil(err)
            local checked = 0
            for _, entry in ipairs(found or {}) do
                local id = tostring(entry.id)
                if id:sub(1, #"butschster.windows") == "butschster.windows" then
                    checked = checked + 1
                    test.is_false(has(actions_of(entry), "registry.entry"),
                        id .. " grants registry.entry, which is not an action")
                end
            end
            test.is_true(checked > 0, "no policies of the module were found")
        end)

        test.it("names one database for every migration and for the repository", function()
            -- The requirement writes meta.target_db into each migration it
            -- aims at; a migration it misses creates its table in app:db while
            -- the rest go where the application said. The repository reads
            -- the name back from a migration entry, so it has no second opinion.
            local requirement = data_of(get("butschster.windows:target_db"))
            local aimed = {}
            for _, target in ipairs(requirement.targets or {}) do
                if target.path == ".meta.target_db" then aimed[tostring(target.entry)] = true end
            end
            local db, why = repo.database()
            test.not_nil(db, "the repository names no database: " .. tostring(why))
            local found, err = registry.find({["meta.type"] = "migration"})
            test.is_nil(err)
            local checked = 0
            for _, entry in ipairs(found or {}) do
                local id = tostring(entry.id)
                if id:sub(1, #"butschster.windows.migrations:") == "butschster.windows.migrations:" then
                    checked = checked + 1
                    test.is_true(aimed[id] == true, "the target_db requirement does not aim at " .. id)
                    test.eq(meta_of(entry).target_db, db, id .. " and the repository name different databases")
                end
            end
            test.is_true(checked >= 3, "the three migrations were not found")
        end)

        test.it("lets the shell return workshop windows to the registry", function()
            -- The shell often comes up alone. Without registry.apply its menu
            -- would show the catalog without the workshop windows and would not
            -- explain why they are missing.
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            test.is_true(has(actions, "registry.apply"),
                "without registry.apply workshop windows will not appear in the second shell")
            for _, needed in ipairs({"process.spawn.monitored", "process.terminate",
                "process.registry.register", "exec.get", "exec.run", "db.get"}) do
                test.is_true(has(actions, needed), "the shell needs the right " .. needed)
            end
        end)

        test.it("closes the handles with a policy the application injects", function()
            local policy = data_of(get(ACCESS_POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = {resources} end
            test.is_true(has(resources, "butschster.windows.api:*"),
                "policy must cover butschster.windows.api:*")
        end)
    end)

    test.describe("butschster.windows declared modules have rights", function()
        test.it("declares no module whose right has not been granted", function()
            -- A DECLARED MODULE WITHOUT A GRANTED RIGHT LOOKS LIKE A MODULE
            -- THAT HAS NOTHING TO SAY.
            --
            -- That is how a whole request from a person got lost: the shell had
            -- `modules: [env]`, the policy had no `env.get` action, and
            -- `env.get_all` returned an EMPTY table — it puts only the permitted
            -- keys into it and does not complain about a refusal at all. From
            -- outside this looked like "the person did not ask for pixel mode".
            --
            -- Checked by a rule, not a list: a list would have to be extended
            -- with every new entry, and it would be forgotten exactly on the one
            -- where it matters.
            local gated = {
                env = {"env.get"},
                fs = {"fs.get"},
                sql = {"db.get"},
                gfx = {},          -- drawing is not gated by rights
                -- registry.find returns only what registry.get allows, and
                -- the runtime checks nothing else: registry.get is the right.
                registry = {"registry.get"},
            }

            local checked = 0
            for _, id in ipairs({
                "butschster.windows:shell",
                "butschster.windows.explorer:window",
            }) do
                local entry = get(id)
                local data = data_of(entry)
                local granted = {}
                for _, policy in ipairs(data.security and data.security.policies
                        or (meta_of(entry).command and meta_of(entry).command.security
                            and meta_of(entry).command.security.policies) or {}) do
                    for _, action in ipairs(actions_of(get(qualify(policy, "butschster.windows")))) do
                        granted[action] = true
                    end
                end

                for _, module in ipairs(data.modules or {}) do
                    local wanted = gated[module]
                    if wanted and #wanted > 0 then
                        local ok = false
                        for _, action in ipairs(wanted) do
                            if granted[action] then ok = true end
                        end
                        checked = checked + 1
                        test.is_true(ok, id .. " declares the module " .. module
                            .. ", but no right to it was granted — it will stay silent rather than refuse")
                    end
                end
            end

            test.is_true(checked > 0, "the check must check at least something")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
