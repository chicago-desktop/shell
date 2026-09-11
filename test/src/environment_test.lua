-- Чтение окружения: отказ по правам отличим от «не задано», и умолчание его
-- не прячет.
--
-- Настоящий отказ по правам в наборе не получить: тесты идут под широкими
-- правами. Поэтому env подставной — с теми же `get_all` и `get`, что у
-- модуля: `get_all` кладёт только разрешённые ключи, `get` отвечает
-- значением или ошибкой.
--
-- Ошибка же — НАСТОЯЩАЯ, из `errors.new`, как у рантайма. Таблица с полем
-- `kind` прошла бы и старую проверку `type(err) == "table" and err.kind`,
-- которую настоящая ошибка (userdata с методом `kind()`) не проходит
-- никогда: тест на таблице был бы зелёным ровно там, где код слеп.
local test = require("test")
local environment = require("environment")

local function fake(all: any, value: any, err: any): any
    return {
        get_all = function() return all end,
        get = function(_) return value, err end,
    }
end

local DENIED = errors.new({message = "permission denied", kind = errors.PERMISSION_DENIED})
local MISSING = errors.new({message = "environment variable not found", kind = errors.NOT_FOUND})

local function define_tests()
    test.describe("чтение окружения", function()
        test.it("отказ по правам называется отказом, а не «не задано»", function()
            local value, source, denied = environment.read("X", fake({}, nil, DENIED))
            test.is_nil(value)
            test.eq(source, environment.DENIED)
            test.is_true(denied == true)

            local fallback, why, refused = environment.read_or("X", "app:db", fake({}, nil, DENIED))
            test.eq(fallback, "app:db", "умолчание подставляется")
            test.eq(why, environment.DENIED, "но причина остаётся отказом")
            test.is_true(refused == true)
        end)

        test.it("переменной нет — это «not set», и отказом не называется", function()
            local value, source, denied = environment.read("X", fake({}, nil, MISSING))
            test.is_nil(value)
            test.eq(source, "not set")
            test.is_true(denied == false)

            local fallback, why, refused = environment.read_or("X", "app:db", fake({}, nil, MISSING))
            test.eq(fallback, "app:db")
            test.eq(why, "not set")
            test.is_true(refused == false)
        end)

        test.it("окружение процесса главнее хранилища, пустая строка — не значение", function()
            local value, source, denied = environment.read("X", fake({X = "app:other"}, nil, DENIED))
            test.eq(value, "app:other", "непустой get_all доказывает право")
            test.eq(source, "process environment")
            test.is_true(denied == false)

            value, source = environment.read("X", fake({}, "app:stored", nil))
            test.eq(value, "app:stored")
            test.eq(source, "file store")

            value, source = environment.read("X", fake({X = ""}, "", nil))
            test.is_nil(value)
            test.eq(source, "not set")

            local kept = environment.read_or("X", "app:db", fake({}, "app:stored", nil))
            test.eq(kept, "app:stored", "названное не заменяется умолчанием")
        end)

        test.it("читает вид ошибки, а не её текст", function()
            -- Текст меняется, вид объявлен константой: строка «permission
            -- denied» без вида — не доказательство отказа.
            local _, source, denied = environment.read("X", fake({}, nil, "permission denied"))
            test.eq(source, "not set")
            test.is_true(denied == false)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
