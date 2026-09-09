-- Экран входа: маска пароля, порядок Enter, отказ и повтор, отмена, снимок.
--
-- Диалог гоняется на ПОДДЕЛЬНОМ экране: события — свой канал, заполненный
-- заранее, кадр — холст в памяти. Проверка пароля — заглушка, которая
-- записывает, что ей дали: так видно, что после отказа поле пароля пустое,
-- а имя осталось.
local test = require("test")
local channel = require("channel")
local tty = require("tty")
local fs = require("fs")
local gfx = require("gfx")
local screen_lib = require("screen")
local chrome_pixels = require("chrome_pixels")
local ui = require("ui")
local cells = require("cells")

local function runes(word: any): any
    local out = {}
    for rune in tostring(word):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = {type = "key", key_type = "runes", key = rune}
    end
    return out
end

local function fake_screen(events: any, pixels: boolean): any
    local screen: any = {
        events = events, pixels = pixels, width = 100, height = 30,
        canvas = tty.canvas(100, 30), frames = 0, painted = nil,
    }
    function screen.cell() return 10, 20 end
    function screen.resize() return screen.width, screen.height end
    function screen.present(painted: any)
        screen.frames = screen.frames + 1
        screen.painted = painted
        return true
    end
    return screen
end

local function feed(events: any, list: any)
    for _, event in ipairs(list) do assert(events:send(event)) end
end

-- Принимает и холст, и готовый список строк (`cells.rows` отдаёт второе).
local function joined(canvas: any): string
    local rows: any = type(canvas) == "table" and canvas or canvas:rows()
    local out = {}
    for _, row in ipairs(rows) do out[#out + 1] = tostring(row) end
    return table.concat(out, "\n")
end

local function define_tests()
    test.describe("Welcome to Windows", function()
        test.it("маскирует пароль звёздочками, оставляя настоящее значение в дереве", function()
            local tree = screen_lib.tree({user = "pb", password = "secret", busy = false})
            local interaction = ui.interaction()
            local plan = ui.plan(tree, 52, 7, interaction)
            local shown = joined(cells.rows(plan, interaction, 52, 7))
            test.is_true(shown:find("******", 1, true) ~= nil, "звёздочек нет")
            test.is_nil(shown:find("secret", 1, true))
            test.is_true(shown:find("pb", 1, true) ~= nil, "имя пользователя не показано")
            test.eq(plan.by_id["password"].node.text, "secret")
        end)

        test.it("Enter в имени ведёт в пароль; отказ очищает пароль, второй заход входит", function()
            local events = channel.new(64)
            feed(events, runes("pb"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("wrong"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("right"))
            feed(events, {{type = "key", key = "enter"}})
            local screen = fake_screen(events, false)
            local attempts = {}
            local identity, why = screen_lib.run(screen, function(login, password)
                attempts[#attempts + 1] = {login = login, password = password}
                if password == "right" then return {actor = "A", scope = "S", context = {user_id = "u1"}}, nil end
                return nil, "Неверный пароль"
            end)
            test.is_nil(why)
            test.not_nil(identity)
            test.eq(identity.context.user_id, "u1")
            test.eq(#attempts, 2)
            test.eq(attempts[1].login, "pb")
            test.eq(attempts[1].password, "wrong")
            test.eq(attempts[2].login, "pb")
            -- Пароль после отказа пуст: «wrongright» означал бы, что поле не очищено.
            test.eq(attempts[2].password, "right")
            test.is_true(screen.frames >= 6, "кадров меньше, чем нажатий")
        end)

        test.it("не зовёт проверку с пустым именем и показывает подсказку", function()
            local events = channel.new(8)
            feed(events, {{type = "key", key = "enter"}, {type = "key", key = "esc"}})
            local screen = fake_screen(events, false)
            local called = false
            local identity, why = screen_lib.run(screen, function() called = true; return nil, "x" end)
            test.is_nil(identity)
            test.eq(why, "logon cancelled")
            test.is_true(not called, "проверка вызвана с пустым именем")
            test.is_true(joined(screen.canvas):find("Type a user name.", 1, true) ~= nil)
        end)

        test.it("Esc и «Отмена» отказывают без проверки; закрытый терминал называет причину", function()
            local events = channel.new(8)
            feed(events, {{type = "key", key = "esc"}})
            local _, why = screen_lib.run(fake_screen(events, false), function() error("не должна зваться") end)
            test.eq(why, "logon cancelled")

            events = channel.new(8)
            -- Tab: имя → пароль → OK → Отмена, затем Enter.
            feed(events, {{type = "key", key = "tab"}, {type = "key", key = "tab"}, {type = "key", key = "tab"},
                {type = "key", key = "enter"}})
            _, why = screen_lib.run(fake_screen(events, false), function() error("не должна зваться") end)
            test.eq(why, "logon cancelled")

            events = channel.new(8)
            events:close()
            _, why = screen_lib.run(fake_screen(events, false), function() error("не должна зваться") end)
            test.eq(why, "the terminal closed before logon")
        end)

        test.it("рисует диалог в ячейках как окно темы: заголовок, поля, кнопки", function()
            local events = channel.new(8)
            events:close()
            local screen = fake_screen(events, false)
            screen_lib.run(screen, function() return nil, "x" end)
            local shown = joined(screen.canvas)
            for _, expected in ipairs({screen_lib.TITLE, "User name:", "Password:", "OK", "Cancel"}) do
                test.is_true(shown:find(expected, 1, true) ~= nil, "нет: " .. expected)
            end
        end)

        test.it("рисует диалог пикселями через paint темы и отдаёт снимок", function()
            local font_files = assert(fs.get("app:system_fonts"))
            local face = assert(gfx.font(assert(font_files:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true}))
            local bold = assert(gfx.font(assert(font_files:readfile("LiberationSans-Bold.ttf")), {size = 13, smooth = true}))
            chrome_pixels.use_fonts(face, bold, bold)
            chrome_pixels.use_cell_size(10, 20)

            local events = channel.new(16)
            feed(events, runes("pb"))
            feed(events, {{type = "key", key = "enter"}})
            feed(events, runes("secret"))
            events:close()
            local screen = fake_screen(events, true)
            local _, why = screen_lib.run(screen, function() return nil, "x" end)
            test.eq(why, "the terminal closed before logon")
            local painted: any = screen.painted
            test.not_nil(painted)
            test.is_true(#painted.placements > 0, "размещений нет")

            local ids = {}
            local shot = assert(gfx.raster(100 * 10, 30 * 20))
            shot:fill("#008080")
            for _, item in ipairs(painted.placements) do
                ids[item.id] = true
                shot:blit(item.raster, (item.x - 1) * 10 + 1, (item.y - 1) * 20 + 1)
            end
            test.is_true(ids["win:logon:head"] == true, "нет заголовка окна")
            test.is_true(ids["win:logon:sdk"] == true, "нет клиента SDK")
            test.is_nil(ids["bars"], "панель задач нарисована на экране входа")
            assert(assert(fs.get("app:shots")):writefile("logon.png", assert(shot:encode("png"))))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
