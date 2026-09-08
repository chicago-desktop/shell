-- «Установка и удаление программ»: слияние объявлений с кэшем и правка
-- файла объявлений текстом. Файл правится с комментариями человека внутри —
-- поэтому проверяется, что снимается ровно свой пункт с его комментарием, а
-- соседи и их пустые строки остаются как были.

local test = require("test")
local model = require("model")

local SAMPLE = table.concat({
    'version: "1.0"',
    "namespace: app.deps",
    "",
    "entries:",
    "  # app.deps:tui-desktop",
    "  #",
    "  # Оконный десктоп в терминале.",
    "  - version: '>=v0.0.0'",
    "    name: tui-desktop",
    "    kind: ns.dependency",
    "    meta: {}",
    "    component: butschster/tui-desktop",
    "    parameters:",
    "      - name: butschster.tui_desktop:api_router",
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
    test.describe("слияние объявлений с кэшем", function()
        test.it("объявление приложения главнее чужого, кэш даёт закреплённую версию и размер", function()
            local rows = model.merge({
                {id = "app.deps:bridge", component = "butschster/bridge", version = ">=v0.0.0"},
                {id = "butschster.windows:dep.wippy.migration", component = "wippy/migration", version = "*"},
                {id = "app.deps:windows", component = "butschster/windows", version = ">=v0.0.0"},
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
            test.eq(rows[1].version, "0.1.96", "берётся закреплённая локом, не первая в кэше")
            test.eq(rows[1].size, 3340000)
            test.eq(rows[2].component, "butschster/windows")
            test.is_nil(rows[2].version, "рабочей копии в кэше нет")
            test.eq(rows[3].component, "chestor/graph")
            test.eq(rows[3].owner, "cache")
            test.eq(rows[4].owner, "module")
            test.eq(rows[4].declared_by, "butschster.windows")
            test.is_true(model.owner_text(rows[4]):find("butschster.windows", 1, true) ~= nil)
        end)

        test.it("размер пишется по-русски с запятой", function()
            test.eq(model.human_size(3340000), "3,19 МБ")
            test.eq(model.human_size(4096), "4 КБ")
            test.eq(model.human_size(0), "—")
        end)
    end)

    test.describe("имя записи и вид имени модуля", function()
        test.it("имя записи — вторая половина, занятое уступает форме org-name", function()
            test.eq(model.dep_name("butschster/telegram", {}), "telegram")
            test.eq(model.dep_name("butschster/telegram", {telegram = true}), "butschster-telegram")
        end)
        test.it("модуль называется org/name строчными", function()
            test.is_true(model.valid_component("butschster/bridge-itp"))
            test.is_false(model.valid_component("Butschster/bridge"))
            test.is_false(model.valid_component("bridge"))
            test.is_false(model.valid_component("a/b/c"))
            test.is_false(model.valid_component(nil))
        end)
    end)

    test.describe("правка файла объявлений", function()
        test.it("читает пространство имён", function()
            test.eq(model.namespace_of(SAMPLE), "app.deps")
        end)

        test.it("снимает ровно свой пункт вместе с его комментарием", function()
            local edited, why = model.remove_declaration(SAMPLE, "blog")
            test.not_nil(edited, tostring(why))
            test.is_nil(edited:find("butschster/blog", 1, true), "пункт снят")
            test.is_nil(edited:find("# app.deps:blog", 1, true), "и его комментарий")
            test.not_nil(edited:find("# app.deps:tui-desktop", 1, true), "сосед выше цел")
            test.not_nil(edited:find("value: app:api", 1, true), "с параметрами")
            test.not_nil(edited:find("# app.deps:telegram-bot", 1, true), "сосед ниже цел")
            test.not_nil(edited:find("component: butschster/telegram", 1, true))
            -- Две пустые строки подряд там, где стоял пункт, не появляются.
            test.is_nil(edited:find("\n\n\n", 1, true), "лишних пустых строк нет")
        end)

        test.it("снимает последний пункт файла и пункт, где name стоит первым", function()
            local edited, why = model.remove_declaration(SAMPLE, "telegram-bot")
            test.not_nil(edited, tostring(why))
            test.is_nil(edited:find("telegram", 1, true))
            test.not_nil(edited:find("component: butschster/blog", 1, true))
            test.eq(edited:sub(-1), "\n")
        end)

        test.it("отказывает с причиной на неизвестное имя и на пункт другого вида", function()
            local edited, why = model.remove_declaration(SAMPLE, "nothing")
            test.is_nil(edited)
            test.is_true(tostring(why):find("nothing", 1, true) ~= nil)
            local other = SAMPLE .. "  - name: blog2\n    kind: registry.entry\n"
            edited = model.remove_declaration(other, "blog2")
            test.is_nil(edited, "не ns.dependency — не наше")
        end)

        test.it("дописывает объявление, которое читается обратно и снимается", function()
            local grown = model.append_declaration(SAMPLE, "butschster/npc", "npc", "app.deps", "2026-09-08")
            test.not_nil(grown:find("# app.deps:npc\n", 1, true))
            test.not_nil(grown:find("    component: butschster/npc\n", 1, true))
            test.not_nil(grown:find("kind: ns.dependency", grown:find("name: npc", 1, true), true))
            local back, why = model.remove_declaration(grown, "npc")
            test.not_nil(back, tostring(why))
            test.eq(back, SAMPLE, "снятие возвращает файл в точности")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
