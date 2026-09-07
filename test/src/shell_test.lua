-- Оболочка целиком, поднятая в тесте.
--
-- Экран у неё настоящий, только не терминал, а viewport, выданный тестом.
-- Полтора дня здесь считалось, что механику без настоящего терминала не
-- проверить, — неверно, и вот цена этого заблуждения: команда
-- `desktop.refresh`, которую ручки раскладки шлют ПОСЛЕ каждой правки, не
-- выполнялась в основе НИКОГДА. Она попадала в ветку «нет такого окна»,
-- потому что окна не называет, и молча ничего не делала. Снаружи это выглядит
-- как «значок появляется только после перезапуска» — то есть как дефект
-- раскладки, а не как несработавшая команда.
--
-- Поэтому здесь проверяется не форма реестра, а сама цепочка: строка
-- записана — оболочка толкнута — оболочка перечитала.
local test = require("test")
local channel = require("channel")
local control = require("control")
local process = require("process")
local repo = require("repo")
local time = require("time")
local tty = require("tty")

-- Поднять оболочку и дождаться, когда она зарегистрируется под своим именем.
-- Ждём ИМЕНИ, а не времени: имя появляется, когда оболочка готова принимать
-- команды, а сон наугад даёт то ложное падение, то тест, который «иногда
-- проходит».
local function boot_shell()
    local view = tty.viewport({width = 90, height = 26})
    test.not_nil(view, "viewport не создался")
    local grant = view:grant()
    test.not_nil(grant, "грант на viewport не выдался")

    -- Запись настоящая, а не копия оболочки для теста: копия разошлась бы с
    -- оригиналом на первой правке, и проверялась бы не та оболочка, которая
    -- поднимается на стенде. Имя службы она берёт себе сама — то же, которое
    -- ищет `control`.
    local pid, err = process.with_options({terminal = grant})
        :spawn_monitored("butschster.windows:shell", "app:processes", "test")
    test.is_nil(err)
    test.not_nil(pid, "оболочка не запустилась")

    local deadline = time.now():unix_nano() + 15000000000
    while time.now():unix_nano() < deadline do
        if process.registry.lookup(control.SERVICE_NAME) then
            return {pid = pid, view = view}
        end
        channel.select({time.after("100ms"):case_receive()})
    end
    test.is_true(false, "оболочка не зарегистрировалась под именем " .. control.SERVICE_NAME)
    return {pid = pid, view = view}
end

local function define_tests()
    test.describe("butschster.windows shell alive", function()
        test.it("перечитывает раскладку по команде ручки", function()
            local shell: any = boot_shell()

            -- Первый заход не измеряет, а заводит мебель: оболочка ставит
            -- «Мой компьютер» и папку «Программы» при первом чтении, и
            -- считать до него значило бы мерить два разных стола.
            local first, ferr = control.call("desktop.refresh", {})
            test.is_nil(ferr, "оболочка обязана отвечать на desktop.refresh")
            test.not_nil(first, "команда, которая не выполняется, отвечает молчанием")
            test.is_nil(first.failure, "раскладка обязана читаться")

            local before = first.items
            test.not_nil(before, "ответ обязан называть, сколько строк прочитано")

            -- Ровно то, что делает человек ручкой PATCH: строка записана в
            -- базу, и без толчка оболочка о ней не узнает до перезапуска.
            local item, cerr = repo.create({
                kind = repo.KIND_FOLDER, title = "Проба перечитывания",
            })
            test.is_nil(cerr)
            test.not_nil(item)

            local after, aerr = control.call("desktop.refresh", {})
            test.is_nil(aerr)
            test.eq(after.items, before + 1,
                "перечитанная раскладка обязана нести только что записанную строку")

            -- И то же самое глазами ручки: она обязана СКАЗАТЬ, что толчок
            -- дошёл. Пока команда молча не выполнялась, здесь стояло
            -- refreshed = false с причиной «нет окна nil» — то есть ручка
            -- отправляла человека искать опечатку в идентификаторе, которого
            -- он не посылал.
            local reported = control.refresh()
            test.is_true(reported.refreshed,
                "ручка обязана сообщить, что оболочка перечитала: " ..
                tostring(reported.reason))

            repo.delete(item.id)
            process.terminate(tostring(shell.pid))
        end)

        test.it("не выдаёт погашенную оболочку за отказ", function()
            -- Раскладку можно править и при погашенной оболочке, и называть
            -- это отказом нельзя: ручка вернула бы ошибку на успешную запись.
            --
            -- Оболочку гасит САМ этот случай, а не предыдущий. Проверка,
            -- опирающаяся на уборку соседа, краснеет вместе с ним и врёт про
            -- причину: упал бы предыдущий — здесь читалось бы «погашенная
            -- оболочка выдаётся за отказ», чего не происходило.
            local running = process.registry.lookup(control.SERVICE_NAME)
            if running then process.terminate(tostring(running)) end

            local deadline = time.now():unix_nano() + 10000000000
            while time.now():unix_nano() < deadline do
                if not process.registry.lookup(control.SERVICE_NAME) then break end
                channel.select({time.after("100ms"):case_receive()})
            end
            test.is_nil(process.registry.lookup(control.SERVICE_NAME),
                "оболочка обязана погаснуть")

            local reported = control.refresh()
            test.is_false(reported.refreshed)
            test.is_true(reported.reason:find("не запущена", 1, true) ~= nil,
                "причина обязана отличать погашенную оболочку от отказа")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
