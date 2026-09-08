-- «Свойства: Экран»: цвета и их форма, подпись разрешения, раскладка двух
-- вкладок без пересечений, выбор цвета и «Применить» через подставленную
-- запись, «ОК» закрывает только после успешной записи; тема перекрашивает
-- стол одной точкой в обоих режимах.
local test = require("test")
local model = require("model")
local ui = require("ui")
local display = require("display_window")
local chrome = require("chrome")
local chrome_pixels = require("chrome_pixels")
local widgets = require("widgets")
local palette = require("palette")

local function fixture(): any
    local written = {}
    return {tab = 1, chosen = "#008080", saved = "#008080",
        info = {screen = {width = 100, height = 28}, cell = {w = 10, h = 20}, pixels = true},
        persist = function(hex: any) written[#written + 1] = hex; return true, nil end}, written
end

local function define_tests()
    test.describe("Display Properties model", function()
        test.it("проверяет форму цвета и подписывает разрешение", function()
            test.is_true(model.valid("#008080"))
            test.is_true(not model.valid("008080"))
            test.is_true(not model.valid("#00808"))
            test.is_true(not model.valid("#00zz80"))
            test.eq(model.resolution({width = 100, height = 28}, {w = 10, h = 20}), "100 × 28 ячеек, 1000 × 560 px")
            test.eq(model.cell_text({w = 10, h = 20}), "Ячейка терминала 10 × 20 px")
            test.eq(model.graphics(false), "Пиксельная графика: нет, только ячейки")
            test.eq(model.resolution({width = 80, height = 24}, nil), "80 × 24 ячеек")
            test.eq(model.resolution(nil, nil), "неизвестно")
            test.eq(#model.color_items("#008080"), #model.COLORS)
            local extra = model.color_items("#123456")
            test.eq(#extra, #model.COLORS + 1)
            test.eq(extra[#extra].id, "#123456")
        end)
    end)
    test.describe("Display Properties on the SDK", function()
        test.it("раскладывает обе вкладки без пересечений", function()
            for tab = 1, 2 do
                local state = fixture()
                state.tab = tab
                for _, dims in ipairs({{58, 22}, {48, 18}}) do
                    local plan = ui.plan(display.definition.view(state, {width = dims[1], height = dims[2]}), dims[1], dims[2], ui.interaction())
                    test.not_nil(plan.by_id.pages)
                    test.not_nil(plan.by_id.ok)
                    local monitors = 0
                    for index, item in ipairs(plan.items) do
                        if item.node.kind == "monitor" then monitors = monitors + 1 end
                        test.is_true(item.rect.x + item.rect.w <= dims[1] + 1)
                        test.is_true(item.rect.y + item.rect.h <= dims[2] + 1)
                        if item.node.kind ~= "group" then
                            for other = index + 1, #plan.items do
                                local b = plan.items[other]
                                if b.node.kind ~= "group" then
                                    local r = item.rect
                                    test.is_true(r.x + r.w <= b.rect.x or b.rect.x + b.rect.w <= r.x
                                        or r.y + r.h <= b.rect.y or b.rect.y + b.rect.h <= r.y,
                                        "пересечение " .. tostring(item.node.kind) .. "/" .. tostring(b.node.kind))
                                end
                            end
                        end
                    end
                    test.eq(monitors, 1, "монитор-предпросмотр на каждой вкладке")
                end
            end
        end)
        test.it("выбор цвета, «Применить» и «ОК» пишут через подставленную запись", function()
            local state, written = fixture()
            local closed = 0
            local context = {width = 58, height = 22, close = function() closed = closed + 1 end}
            local plan = ui.plan(display.definition.view(state, context), 58, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled == true, "нечего применять — кнопка недоступна")
            display.definition.update(state, {type = "select", id = "colors", index = 2, value = {id = "#000080", text = "Тёмно-синий"}}, context)
            test.eq(state.chosen, "#000080")
            test.eq(state.saved, "#008080")
            plan = ui.plan(display.definition.view(state, context), 58, 22, ui.interaction())
            test.is_true(plan.by_id.apply.node.disabled ~= true)
            display.definition.update(state, {type = "activate", id = "apply"}, context)
            test.eq(#written, 1)
            test.eq(written[1], "#000080")
            test.eq(state.saved, "#000080")
            test.eq(closed, 0, "«Применить» окно не закрывает")
            display.definition.update(state, {type = "select", id = "colors", index = 1, value = {id = "#zzzzzz"}}, context)
            test.eq(state.chosen, "#000080", "негодный цвет не принимается")
            display.definition.update(state, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1)
            test.eq(#written, 1, "ОК без изменений не пишет второй раз")
            -- Отказ записи держит окно открытым и называет причину.
            local failing, _ = fixture()
            failing.persist = function() return nil, "база занята" end
            failing.chosen = "#000000"
            display.definition.update(failing, {type = "activate", id = "ok"}, context)
            test.eq(closed, 1, "при отказе записи окно остаётся")
            test.eq(failing.failure, "база занята")
            test.eq(display.definition.update(failing, {type = "key", key_type = "runes", key = "x"}, context), false)
        end)
        test.it("тема перекрашивает стол одной точкой в обоих режимах", function()
            local before = widgets.styles.desktop
            test.is_true(chrome.use_desktop("#000080"))
            test.eq(palette.exact.desktop, "#000080")
            test.is_true(widgets.styles.desktop ~= before, "стиль ячеек переснят")
            test.is_true(not chrome.use_desktop("000080"), "цвет без решётки не принимается")
            test.eq(palette.exact.desktop, "#000080", "негодный цвет ничего не меняет")
            test.is_true(chrome.use_desktop("#008080"))
            test.eq(palette.exact.desktop, "#008080")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
