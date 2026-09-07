-- Проверки формы реестра. Харнесс не ходит в свой роутер, поэтому ручки
-- проверяются как проводка: записи существуют и ссылаются друг на друга.
--
-- Здесь же закреплены инварианты, нарушение которых снаружи выглядит не как
-- ошибка, а как странность: терминальный хост обязан глушить лог, ручки
-- раскладки обязаны НЕ уметь порождать процессы, а ручки на создание
-- программы обязано не быть вовсе.
local test = require("test")
local registry = require("registry")

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
        test.it("глушит лог на своём терминальном хосте", function()
            -- Без этого строка лога рантайма разъезжает кадр насовсем: диффер
            -- поверхности считает себя единственным писателем.
            local terminal = data_of(get(TERMINAL_ID))
            test.eq(terminal.hide_logs, true)
        end)

        test.it("не заводит своего хоста окон", function()
            -- Окна хостит основа. Второй хост означал бы вторую копию
            -- механики окон, которая разошлась бы с оригиналом на первой
            -- правке — и обнаружилось бы это через неделю.
            -- registry.get на отсутствующую запись отвечает (nil, "entry not
            -- found"), а не (nil, nil): проверять надо запись, а не отсутствие
            -- ошибки — иначе тест падает ровно тогда, когда всё правильно.
            local workers = registry.get("butschster.windows:workers")
            test.is_nil(workers, "хост окон принадлежит основе")
        end)
    end)

    test.describe("butschster.windows shell", function()
        test.it("отдаёт оболочку командой windows с собственным актором", function()
            local entry = get(SHELL_ID)
            local command = meta_of(entry).command or {}
            test.eq(command.name, "windows")
            test.not_nil(command.security, "команда обязана нести свой контекст безопасности")

            local data = data_of(entry)
            test.eq(data.method, "main")
            test.is_true(has(data.modules or {}, "tty"), "оболочке нужен модуль tty")
        end)

        test.it("зовёт механику основы, а не копирует её", function()
            -- Ради этого оболочка и вынесена отдельным модулем: она приносит
            -- вид, каталог и раскладку. Появись здесь свой композитор — он
            -- разошёлся бы с оригиналом, и сегодняшние находки основы в копию
            -- не попали бы.
            local imports = data_of(get(SHELL_ID)).imports or {}
            test.eq(qualify(imports.library, "butschster.windows"),
                "butschster.tui_desktop.desktop:library", "оболочка зовёт композитор основы")
            test.eq(qualify(imports.catalog, "butschster.windows"), CATALOG_ID)
            test.eq(qualify(imports.seed, "butschster.windows"), SEED_ID)
            test.eq(qualify(imports.view, "butschster.windows"), VIEW_ID)
            test.eq(qualify(imports.repo, "butschster.windows"), REPO_ID)
        end)

        test.it("объявляет зависимость на основу", function()
            local dep = get("butschster.windows:dep.butschster.tui_desktop")
            test.eq(data_of(dep).component, "butschster/tui-desktop")
        end)

        test.it("несёт миграцию раскладки", function()
            local entry = get(MIGRATION_ID)
            test.eq(meta_of(entry).type, "migration")
            test.not_nil(meta_of(entry).target_db, "миграции нужен ресурс базы")
        end)
    end)

    test.describe("butschster.windows handles", function()
        test.it("сводит каждую ручку с её обработчиком на роутере приложения", function()
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

        test.it("не заводит ручки на создание программы", function()
            -- Программы объявляет реестр: установкой модуля или мастерской
            -- основы. Своя ручка создания означала бы второй источник истины,
            -- и разошлись бы они на первом удалении модуля.
            local found, err = registry.find({[".kind"] = "http.endpoint"})
            test.is_nil(err)
            for _, entry in ipairs(found or {}) do
                local data = data_of(entry)
                local path = tostring(data.path or "")
                local method = tostring(data.method or "")
                local creates_program = path == "/windows/programs" and method ~= "GET"
                test.is_false(creates_program,
                    "каталог программ доступен только на чтение: " .. method .. " " .. path)
            end
        end)

        test.it("толкает оболочку после изменения раскладки", function()
            -- Композитор перечитывает раскладку по команде, а не каждый кадр.
            -- Ручка, изменившая строку и промолчавшая, выглядит не
            -- сработавшей: значок появился бы только после перезапуска.
            for _, id in ipairs({"butschster.windows.api:create_desktop_item",
                "butschster.windows.api:update_desktop_item",
                "butschster.windows.api:delete_desktop_item"}) do
                local imports = data_of(get(id)).imports or {}
                test.eq(qualify(imports.control, "butschster.windows.api"), CONTROL_ID,
                    id .. " обязана уметь толкнуть оболочку")
            end
        end)
    end)

    test.describe("butschster.windows policies", function()
        test.it("не даёт ручкам раскладки порождать процессы", function()
            local actions = actions_of(get(STORAGE_POLICY_ID))
            test.is_true(has(actions, "db.get"), "ручке нужен доступ к базе как действие db.get")
            test.is_true(has(actions, "registry.find"), "и чтение каталога из реестра")
            test.is_true(has(actions, "process.send"), "и право толкнуть оболочку")
            test.is_false(has(actions, "process.spawn"), "порождать процессы ручка не может")
            test.is_false(has(actions, "exec.run"), "запускать программы ручка не может")
            test.is_false(has(actions, "registry.apply"), "менять реестр ручка не может")
        end)

        test.it("даёт оболочке вернуть окна мастерской в реестр", function()
            -- Оболочка часто поднимается одна. Без registry.apply её меню
            -- показало бы каталог без окон мастерской и не объяснило бы,
            -- почему их нет.
            local actions = actions_of(get(RUNTIME_POLICY_ID))
            test.is_true(has(actions, "registry.apply"),
                "без registry.apply окна мастерской не появятся во второй оболочке")
            for _, needed in ipairs({"process.spawn.monitored", "process.terminate",
                "process.registry.register", "exec.get", "exec.run", "db.get"}) do
                test.is_true(has(actions, needed), "оболочке нужно право " .. needed)
            end
        end)

        test.it("закрывает ручки политикой, которую внедряет приложение", function()
            local policy = data_of(get(ACCESS_POLICY_ID))
            local resources = policy.policy and policy.policy.resources
            test.not_nil(resources, "policy must list resources")
            if type(resources) == "string" then resources = {resources} end
            test.is_true(has(resources, "butschster.windows.api:*"),
                "policy must cover butschster.windows.api:*")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
