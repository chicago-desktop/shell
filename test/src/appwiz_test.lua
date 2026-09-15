-- "Add/Remove Programs": merging declarations with the cache and editing the
-- declarations file as text. The file is edited with the person's comments
-- inside, so the test checks that exactly its own item is removed along with
-- its comment, while the neighbours and their empty lines stay as they were.

local test = require("test")
local model = require("model")
local fs = require("fs")

local SAMPLE = table.concat({
    'version: "1.0"',
    "namespace: app.deps",
    "",
    "entries:",
    "  # app.deps:tui-desktop",
    "  #",
    "  # Windowed desktop in the terminal.",
    "  - version: '>=v0.0.0'",
    "    name: tui-desktop",
    "    kind: ns.dependency",
    "    meta: {}",
    "    component: windows/tui-desktop",
    "    parameters:",
    "      - name: windows.tui_desktop:api_router",
    "        value: app:api",
    "",
    "  # app.deps:blog",
    "  - version: '>=v0.0.0'",
    "    name: blog",
    "    kind: ns.dependency",
    "    meta: {}",
    "    component: butschster/blog",
    "",
    "  # app.deps:telegram-bot",
    "  - name: telegram-bot",
    "    kind: ns.dependency",
    "    version: '>=v0.4.0'",
    "    component: butschster/telegram",
    "",
}, "\n")

local function define_tests()
    test.describe("merging declarations with the cache", function()
        test.it("the application declaration outranks another, the cache gives the pinned version and size", function()
            local rows = model.merge({
                {id = "app.deps:bridge", component = "butschster/bridge", version = ">=v0.0.0"},
                {id = "windows.shell:dep.wippy.migration", component = "wippy/migration", version = "*"},
                {id = "app.deps:windows", component = "windows/shell", version = ">=v0.0.0"},
            }, {
                {module = "butschster/bridge", version = "0.1.95", size = 100, pinned = false},
                {module = "butschster/bridge", version = "0.1.96", size = 3340000, pinned = true},
                {module = "wippy/migration", version = "0.2.0", size = 5000, pinned = true},
                {module = "chestor/graph", version = "0.1.26", size = 777, pinned = true},
            }, "app.deps")
            test.eq(#rows, 4)
            test.eq(rows[1].component, "butschster/bridge")
            test.eq(rows[1].owner, "app")
            test.eq(rows[1].name, "bridge")
            test.eq(rows[1].version, "0.1.96", "the one pinned by the lock is taken, not the first in the cache")
            test.eq(rows[1].size, 3340000)
            test.eq(rows[2].component, "chestor/graph")
            test.eq(rows[2].owner, "cache")
            test.eq(rows[3].component, "windows/shell")
            test.is_nil(rows[3].version, "a working copy is not in the cache")
            test.eq(rows[4].owner, "module")
            test.eq(rows[4].declared_by, "windows.shell")
            test.is_true(model.owner_text(rows[4]):find("windows.shell", 1, true) ~= nil)
        end)

        test.it("size is formatted with a dot and MB", function()
            test.eq(model.human_size(3340000), "3.19 MB")
            test.eq(model.human_size(4096), "4 KB")
            test.eq(model.human_size(0), "—")
        end)
    end)

    test.describe("entry name and the form of the module name", function()
        test.it("the entry name is the second half, a taken one gives way to the form org-name", function()
            test.eq(model.dep_name("butschster/telegram", {}), "telegram")
            test.eq(model.dep_name("butschster/telegram", {telegram = true}), "butschster-telegram")
        end)
        test.it("a module is named org/name in lowercase", function()
            test.is_true(model.valid_component("butschster/bridge-itp"))
            test.is_false(model.valid_component("Butschster/bridge"))
            test.is_false(model.valid_component("bridge"))
            test.is_false(model.valid_component("a/b/c"))
            test.is_false(model.valid_component(nil))
        end)
    end)

    test.describe("editing the declarations file", function()
        test.it("reads the namespace", function()
            test.eq(model.namespace_of(SAMPLE), "app.deps")
        end)

        test.it("removes exactly its own item along with its comment", function()
            local edited, why = model.remove_declaration(SAMPLE, "blog")
            test.not_nil(edited, tostring(why))
            test.is_nil(edited:find("butschster/blog", 1, true), "the item is removed")
            test.is_nil(edited:find("# app.deps:blog", 1, true), "and its comment")
            test.not_nil(edited:find("# app.deps:tui-desktop", 1, true), "the neighbour above is intact")
            test.not_nil(edited:find("value: app:api", 1, true), "with parameters")
            test.not_nil(edited:find("# app.deps:telegram-bot", 1, true), "the neighbour below is intact")
            test.not_nil(edited:find("component: butschster/telegram", 1, true))
            -- Two empty lines in a row do not appear where the item stood.
            test.is_nil(edited:find("\n\n\n", 1, true), "no extra empty lines")
        end)

        test.it("removes the last item of the file and an item where name comes first", function()
            local edited, why = model.remove_declaration(SAMPLE, "telegram-bot")
            test.not_nil(edited, tostring(why))
            test.is_nil(edited:find("telegram", 1, true))
            test.not_nil(edited:find("component: butschster/blog", 1, true))
            test.eq(edited:sub(-1), "\n")
        end)

        test.it("refuses with a reason for an unknown name and for an item of another kind", function()
            local edited, why = model.remove_declaration(SAMPLE, "nothing")
            test.is_nil(edited)
            test.is_true(tostring(why):find("nothing", 1, true) ~= nil)
            local other = SAMPLE .. "  - name: blog2\n    kind: registry.entry\n"
            edited = model.remove_declaration(other, "blog2")
            test.is_nil(edited, "not ns.dependency, not ours")
        end)

        test.it("appends a declaration that reads back and can be removed", function()
            local grown = model.append_declaration(SAMPLE, "butschster/npc", "npc", "app.deps", "2026-09-08")
            test.not_nil(grown:find("# app.deps:npc\n", 1, true))
            test.not_nil(grown:find("    component: butschster/npc\n", 1, true))
            test.not_nil(grown:find("kind: ns.dependency", grown:find("name: npc", 1, true), true))
            local back, why = model.remove_declaration(grown, "npc")
            test.not_nil(back, tostring(why))
            test.eq(back, SAMPLE, "removal returns the file exactly")
        end)
    end)

    -- The stand does not come up without the declarations file, and the
    -- window used to write it with a single `writefile` and under a foreign
    -- namespace if its own was not found.
    test.describe("checking and writing the declarations file", function()
        local FILE = "_index.yaml"

        test.it("a file without namespace is rejected with a reason, not appended under app.deps", function()
            local bare = (SAMPLE:gsub("namespace: app.deps\n", ""))
            test.is_nil(model.namespace_of(bare))
            local grown, why = model.append_declaration(bare, "butschster/npc", "npc",
                model.namespace_of(bare), "2026-09-11", FILE)
            test.is_nil(grown)
            test.eq(why, "namespace not declared in _index.yaml")
            -- And text assembled bypassing the append will not pass the check.
            local forced = model.append_declaration(bare, "butschster/npc", "npc", "app.deps", "2026-09-11", FILE)
            local ok, reason = model.check_edit(bare, forced, "npc", 1, FILE)
            test.is_nil(ok)
            test.eq(reason, "namespace not declared in _index.yaml")
        end)

        test.it("an appended item takes the neighbours' indent, not always two spaces", function()
            local wide = (SAMPLE:gsub("\n  ", "\n    "))
            local grown = model.append_declaration(wide, "butschster/npc", "npc", "app.deps", "2026-09-11", FILE)
            test.not_nil(grown:find("\n    # app.deps:npc\n", 1, true))
            test.not_nil(grown:find("\n    - version: '>=v0.0.0'\n      name: npc\n      kind: ns.dependency\n", 1, true),
                "the item and its fields at the neighbours' indent")
            local ok, why = model.check_edit(wide, grown, "npc", 1, FILE)
            test.is_true(ok == true, tostring(why))
            local back = model.remove_declaration(grown, "npc")
            test.eq(back, wide, "removal returns the file exactly")
        end)

        test.it("an edit that changed other than one declaration is rejected before writing", function()
            local ok, why = model.check_edit(SAMPLE, SAMPLE, "npc", 1, FILE)
            test.is_nil(ok)
            test.is_true(tostring(why):find("instead of 1", 1, true) ~= nil, tostring(why))
            local two = SAMPLE .. "  - name: x\n    kind: ns.dependency\n  - name: y\n    kind: ns.dependency\n"
            test.is_nil(model.check_edit(SAMPLE, two, "x", 1, FILE))
            -- An item with parameters: it has three `- name:` lines, but one
            -- declaration.
            local removed = model.remove_declaration(SAMPLE, "tui-desktop")
            ok, why = model.check_edit(SAMPLE, removed, "tui-desktop", -1, FILE)
            test.is_true(ok == true, tostring(why))
        end)

        local function put(handle: any, name: string, text: string)
            local _, err = handle:writefile(name, text)
            if err then error(tostring(err)) end
        end

        test.it("writes with a backup next to it, and the disk holds exactly what was written", function()
            local handle = assert(fs.get("app:appwiz_scratch"))
            put(handle, FILE, SAMPLE)
            put(handle, FILE .. ".bak", "")
            local grown = model.append_declaration(SAMPLE, "butschster/npc", "npc", "app.deps", "2026-09-11", FILE)
            local ok, why = model.write_file(handle, FILE, SAMPLE, grown)
            test.is_true(ok == true, tostring(why))
            test.eq(handle:readfile(FILE), grown)
            test.eq(handle:readfile(FILE .. ".bak"), SAMPLE, "the previous text lies next to it")

            -- The file was changed by hand while the window was open: the edit
            -- does not overwrite it.
            put(handle, FILE, SAMPLE .. "# hand edit\n")
            ok, why = model.write_file(handle, FILE, SAMPLE, grown)
            test.is_false(ok)
            test.is_true(tostring(why):find("changed on disk", 1, true) ~= nil, tostring(why))
            test.eq(handle:readfile(FILE), SAMPLE .. "# hand edit\n", "the other edit is intact")
        end)

        test.it("a mismatch after writing is named together with where the previous text is", function()
            local files: any = {[FILE] = SAMPLE}
            -- A store that loses the tail of a write: this is how a full disk
            -- or a cut-off write looks, not a failure.
            local lossy = {
                readfile = function(_, name) return files[name], nil end,
                writefile = function(_, name, data)
                    files[name] = name == FILE and data:sub(1, 40) or data
                    return true, nil
                end,
            }
            local grown = model.append_declaration(SAMPLE, "butschster/npc", "npc", "app.deps", "2026-09-11", FILE)
            local ok, why = model.write_file(lossy, FILE, SAMPLE, grown)
            test.is_false(ok)
            test.is_true(tostring(why):find("reads back different", 1, true) ~= nil, tostring(why))
            test.is_true(tostring(why):find("_index.yaml.bak", 1, true) ~= nil, "it names where the previous text is")
            test.eq(files[FILE .. ".bak"], SAMPLE)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
