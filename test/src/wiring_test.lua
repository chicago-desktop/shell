-- Проверки формы реестра. Харнесс не ходит в свой роутер, поэтому ручки
-- проверяются как проводка: записи существуют и ссылаются друг на друга.
--
-- Здесь же закреплены инварианты, нарушение которых снаружи выглядит не как
-- ошибка, а как странность: терминальный хост обязан глушить лог, ручки
-- раскладки обязаны НЕ уметь порождать процессы, а ручки на создание
-- программы обязано не быть вовсе.
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
local RENDER_ID = "butschster.windows.explorer:render"

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

    test.describe("butschster.windows explorer", function()
        test.it("объявляет «Мой компьютер» обычной программой реестра", function()
            -- Оболочка находит его тем же registry.find, что и всё остальное.
            -- Особый путь для своего окна означал бы, что окно оболочки
            -- живёт по другим правилам, чем окно любого другого модуля.
            local entry = get(EXPLORER_ID)
            local meta = meta_of(entry)
            test.eq(meta.type, "tui_desktop.window",
                "без этого типа окно не попадёт ни в меню, ни в каталог")
            test.not_nil(meta.title)

            local data = data_of(entry)
            test.eq(data.kind or entry.kind, "process.lua")
            test.eq(data.method, "main")
            for _, needed in ipairs({"channel", "tty", "fs", "registry", "sql"}) do
                test.is_true(has(data.modules or {}, needed),
                    "окну нужен модуль " .. needed)
            end
        end)

        test.it("просит композитор библиотекой основы, а не своим протоколом", function()
            -- Имя композитора приезжает окну в контексте процесса. Своя
            -- константа работала бы только под нашей оболочкой и молча
            -- промахивалась бы под любой другой — а `open` ответа не ждёт,
            -- так что промах выглядел бы как успех.
            local imports = data_of(get(EXPLORER_ID)).imports or {}
            test.eq(qualify(imports.desktop, "butschster.windows.explorer"),
                "butschster.tui_desktop.desktop:window_api")

            -- С процессами окно само не разговаривает: за него это делает
            -- библиотека, и модуль объявлен у неё. Модуль `process` у окна
            -- означал бы второй, свой протокол рядом с общим.
            test.is_false(has(data_of(get(EXPLORER_ID)).modules or {}, "process"),
                "окно не разговаривает с процессами напрямую")
        end)

        test.it("рисует общими примитивами темы, а не своей копией", function()
            -- Своя, чуть другая кнопка означала бы, что внутри окна Windows 95
            -- живёт другая Windows. Разошлись бы они видом, а не отказом, — то
            -- есть заметили бы через неделю.
            local imports = data_of(get(EXPLORER_ID)).imports or {}
            test.eq(qualify(imports.render, "butschster.windows.explorer"), RENDER_ID)
            test.eq(qualify(imports.sources, "butschster.windows.explorer"),
                "butschster.windows.explorer:sources")

            local drawing = data_of(get(RENDER_ID)).imports or {}
            test.eq(qualify(drawing.widgets, "butschster.windows.explorer"),
                "butschster.windows.shell:widgets")
            test.eq(qualify(drawing.icons, "butschster.windows.explorer"),
                "butschster.windows.shell:icons")
        end)

        test.it("держит вид окна вне процесса окна", function()
            -- Полноэкранную программу не проверить кодом возврата, а кадр,
            -- собираемый внутри процесса, не посмотреть ничем, кроме стенда.
            -- Отсюда правило: содержимое рисует библиотека, которой нужен
            -- только tty, — её гоняет пробник без рантайма.
            local data = data_of(get(RENDER_ID))
            test.eq(data.kind or get(RENDER_ID).kind, "library.lua")
            for _, forbidden in ipairs({"process", "sql", "registry", "fs"}) do
                test.is_false(has(data.modules or {}, forbidden),
                    "виду нечего делать с модулем " .. forbidden)
            end
        end)

        test.it("не даёт окну порождать процессы и запускать программы", function()
            -- Окно с правом порождать процессы рано или поздно запустит не то,
            -- чем ему открыли файл. Открыть соседнее окно оно может только
            -- просьбой к композитору, который решает сам.
            local actions = actions_of(get(EXPLORER_POLICY_ID))
            test.is_false(has(actions, "process.spawn"), "порождать процессы окно не может")
            test.is_false(has(actions, "process.spawn.monitored"))
            test.is_false(has(actions, "exec.run"), "запускать программы окно не может")
            test.is_false(has(actions, "registry.apply"), "менять реестр окно не может")

            for _, needed in ipairs({"registry.find", "db.get", "fs.get",
                "process.send", "process.registry"}) do
                test.is_true(has(actions, needed), "окну нужно право " .. needed)
            end
        end)

        test.it("ставит на стол ярлыки только на существующие записи", function()
            -- Ярлык на исчезнувшую программу мебель пропускает МОЛЧА — это
            -- правильно при первом запуске и невыносимо здесь: переезд
            -- «Моего компьютера» в другую запись выглядел бы не как ошибка, а
            -- как пустой стол. Проверяется вся мебель, а не одна строка:
            -- список, из которого можно забыть добавить проверку, проверяет
            -- не то, что стоит на столе.
            for _, item in ipairs(defaults.ITEMS) do
                if item.kind == "shortcut" then
                    test.not_nil(registry.get(item.entry),
                        "мебель ведёт на " .. tostring(item.entry) ..
                        " — записи с таким идентификатором нет")
                end
            end
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
