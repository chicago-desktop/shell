-- Ширина набора символов темы.
--
-- Ловит самую дорогую здесь ошибку: символ шириной в две ячейки сдвигает всё
-- правее себя на строке, и рамка разъезжается на каждой строке, где он
-- встретился. Снаружи это выглядит как ошибка арифметики в отрисовке, а не
-- как неудачный символ, — и искать будут не там.
--
-- Проверка живёт здесь, а не в самой теме: ветка «а ну-ка померим себя» внутри
-- библиотеки отрисовки — это не тест, а лишний код в кадре. Набор темы отдаёт
-- сам, функцией `all()`, ровно ради этой проверки.
local test = require("test")
local tty = require("tty")
local glyphs = require("glyphs")
local palette = require("palette")

local function define_tests()
    test.describe("butschster.windows glyphs", function()
        test.it("держит каждый символ набора в одной ячейке", function()
            local set = glyphs.all()
            test.is_true(#set > 0, "набор не должен быть пустым: мерить было бы нечего")
            for _, ch in ipairs(set) do
                test.eq(tty.text.width(ch), 1, "символ шире ячейки: " .. tostring(ch))
            end
        end)
    end)

    test.describe("butschster.windows palette", function()
        test.it("держит в обоих наборах одни и те же имена", function()
            -- Ключ, забытый в запасном наборе, обнаружится не отказом, а nil в
            -- стиле — то есть цветом «как получится» у одной детали из
            -- двадцати. На 16-цветном терминале это увидят, а связать с
            -- пропущенным ключом не смогут.
            local names = palette.names()
            test.is_true(#names > 0, "палитра не должна быть пустой")
            for _, name in ipairs(names) do
                test.not_nil(palette.exact[name], name .. ": нет в точном наборе")
                test.not_nil(palette.basic[name], name .. ": нет в запасном наборе")
            end

            -- И наоборот: лишнее имя в запасном наборе означает, что точный
            -- набор от него отстал, и одна деталь красится не тем.
            local known = {}
            for _, name in ipairs(names) do known[name] = true end
            for name in pairs(palette.basic) do
                test.is_true(known[name] == true,
                    tostring(name) .. ": есть в запасном наборе, но не в точном")
            end
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return { run = function(options) return run_cases(options) end }
