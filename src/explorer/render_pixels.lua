local scroll = require("scroll")
-- Пиксельный бэкенд «Моего компьютера».
--
-- Раскладку не считает НИ ОДНОЙ строки: план приходит готовым из
-- `butschster.windows.explorer:render`, оттуда же попадания. Здесь только
-- краски. Посчитай этот файл раскладку сам — два бэкенда разъехались бы
-- молча, и щелчок попадал бы на соседа в одном из двух режимов.
--
-- ─── ПОЧЕМУ ОТДЕЛЬНАЯ ЗАПИСЬ, А НЕ ВЕТКА В `render` ─────────────────────
--
-- `render` обязан грузиться там, где модуля `gfx` нет вовсе: оболочка должна
-- работать в обычном xterm (FR-005 §8б), и путь в ячейках не имеет права
-- умирать вместе с графикой. Запись, объявившая `gfx`, на таком рантайме не
-- грузится — не «без пикселей», а целиком. Значит `gfx` объявляет только тот,
-- кто без него не существует, и это вот этот файл.
--
-- ─── ЧТО ЗДЕСЬ ГЛАВНОЕ ──────────────────────────────────────────────────
--
-- Растры берутся из хранилища по имени и ключу и НЕ создаются заново
-- (FR-005 §4). Растр, пересозданный каждый кадр, — это не медленный экран, а
-- НЕВЕРНЫЙ: поверхность сравнивает буфер по его номеру, и картинка, которая
-- поменялась, но лежит в новом буфере с тем же номером версии, не уезжает
-- вовсе. На экране остаются вчерашние часы, и ни одного признака поломки.
--
-- Кадр нарезан по СТРОКАМ (FR-005 §3): меню, панель инструментов, поле,
-- статусная строка — четыре размещения. Одно на всё окно значило бы, что
-- выделение значка перерисовывает и меню, и статусную строку.

local pixels = require("pixels")
local palette = require("palette")

local color = palette.exact

local backend = {}

local geometry = require("geometry")
local whole = geometry.whole


-- Отпечаток состояния поля. Ключ, забывший поле, даёт картинку, которая не
-- обновляется; ключ, взявший лишнее, перерисовывает зря. Здесь названо ровно
-- то, от чего картинка зависит.
local function field_key(plan: any)
    local parts = {tostring(plan.width), tostring(plan.height),
                   tostring(plan.failure or ""), tostring(plan.scroll and plan.scroll.first or 0),
                   tostring(plan.icon_size), tostring(plan.scroll and plan.scroll.total),
                   tostring(plan.scroll and plan.scroll.visible)}
    for _, cell in ipairs(plan.cells or {}) do
        local object: any = cell.object or {}
        parts[#parts + 1] = table.concat({
            tostring(cell.index), tostring(object.kind or ""), tostring(object.title or ""),
            tostring(object.icon or ""), tostring(object.image or ""), tostring(object.entry or ""),
            object.broken and "!" or "", cell.selected and "1" or "0",
        }, "\30")
    end
    return table.concat(parts, "\31")
end

-- Выпадающий список поверх окна: строки — попадания плана, по строке на
-- пункт. `lead` — сколько строк рамки над первым пунктом лежит в растре: у
-- меню верхняя рамка — своя строка под заголовками, у адреса её нет.
-- `raised` — меню: лицо и выпуклая грань; иначе белое вдавленное поле.
local function paint_list(store: any, id: string, hits: any, titles: any, chosen: integer,
        lead: integer, raised: boolean, face: any, cell: any)
    local first: any = hits[1]
    local cols_n = first.to - first.from + 1
    local rows_n = #hits + lead
    local key = tostring(cols_n) .. "|" .. tostring(rows_n) .. "|" .. tostring(chosen)
        .. "|" .. table.concat(titles, "\30")
    local list, dirty = store.take(id, cols_n, rows_n, cell, key)
    if dirty then
        local box = pixels.box(1, 1, cols_n, rows_n, cell)
        if raised then
            list:rect(1, 1, box.w, box.h, color.face)
            pixels.edge(list, 1, 1, box.w, box.h, true)
        else
            pixels.field(list, 1, 1, box.w, box.h)
        end
        local ink = raised and color.face_text or color.field_text
        local line_h = whole(cell.h)
        for index, title in ipairs(titles) do
            local top = (index - 1 + lead) * line_h + 1
            if index == chosen then
                list:rect(2, top + 1, box.w - 2, line_h - 1, color.select_bg)
            end
            list:text(6, top + math.max(1, (line_h - 15) // 2),
                pixels.ellipsize(face, title, box.w - 12),
                {font = face, color = index == chosen and color.select_fg or ink})
        end
    end
    store.place(id, first.from, first.row - lead)
end

-- paint(store, plan, cell, fonts, prefix) -> размещения
--
-- `fonts`: {face = обычный, bold = полужирный}. Полужирный обязателен для
-- заголовков — в Windows 95 они набраны им, и «синтезировать» его размазыванием
-- пикселей значит перестать быть похожим.
function backend.paint(store: any, plan: any, cell: any, fonts: any, prefix)
    local face: any = type(fonts) == "table" and fonts.face or nil
    local name = tostring(prefix or "explorer")
    local w = plan.width
    local icon_size = plan.icon_size or 16

    store.begin()

    -- ─── строка меню ─────────────────────────────────────────────────────
    local menu_id = name .. ":menu"
    local open_index = plan.menu_popup and plan.menu_popup.index or 0
    local menu, menu_dirty = store.take(menu_id, w, 1, cell, tostring(w) .. "|" .. tostring(open_index))
    if menu_dirty then
        local box = pixels.box(1, 1, w, 1, cell)
        menu:rect(1, 1, box.w, box.h, color.face)
        -- Заголовок стоит в СВОИХ ячейках плана, по центру: по ним окно
        -- считает щелчок, и слово, нарисованное левее своего попадания,
        -- нажималось бы соседом.
        for _, entry in ipairs(plan.menu_hits or {}) do
            local hit: any = entry
            local area = pixels.box(hit.from, 1, hit.to - hit.from + 1, 1, cell)
            local text = tostring(hit.menu)
            local width = face and whole(face:measure(text)) or 0
            local open = hit.index == open_index
            if open then menu:rect(whole(area.x), 1, whole(area.w), whole(box.h), color.select_bg) end
            menu:text(whole(area.x) + (whole(area.w) - width) // 2, math.max(1, (box.h - 15) // 2), text,
                {font = face, color = open and color.select_fg or color.face_text})
        end
    end
    store.place(menu_id, 1, plan.rows.menu)

    -- ─── панель инструментов ─────────────────────────────────────────────
    if (plan.tool_rows or 1) > 0 then
        local tool_id = name .. ":tools"
        local tool_key = tostring(w)
        for _, button in ipairs(plan.tools or {}) do
            tool_key = tool_key .. "|" .. tostring((button :: any).id)
                .. ((button :: any).pressed and "!" or "") .. ((button :: any).disabled and "-" or "")
        end
        local tool_rows = plan.tool_rows or 1
        local tools, tools_dirty = store.take(tool_id, w, tool_rows, cell, tool_key)
        if tools_dirty then
            local box = pixels.box(1, 1, w, tool_rows, cell)
            tools:rect(1, 1, box.w, box.h, color.face)
            for _, entry in ipairs(plan.tools or {}) do
                local button: any = entry
                -- Кнопка ставится по ЯЧЕЙКАМ плана, а не по своим пикселям:
                -- иначе её зона попадания разъедется с планом, из которого окно
                -- считает щелчок.
                local span = button.to - button.from + 1
                local area = pixels.box(button.from, 1, span, tool_rows, cell)
                -- Кнопка 23×22 px по центру своих ячеек, как на панели
                -- окна папки Windows 95; лишнее место остаётся лицом.
                local bw, bh = math.min(23, whole(area.w) - 2), math.min(22, whole(area.h) - 2)
                local bx, by = whole(area.x) + (whole(area.w) - bw) // 2, whole(area.y) + (whole(area.h) - bh) // 2
                -- Та же кнопка, что у диалогов и хрома: двойная грань, нажатая
                -- вдавлена. Знак рисуется сверху и сдвигается вместе с ней.
                pixels.button(tools, bx, by, bw, bh,
                    {label = "", pressed = button.pressed, disabled = button.disabled}, cell)
                local mark = pixels.MARKS[button.id]
                if type(mark) == "function" then
                    local size = 16
                    local mx = bx + (bw - size) // 2 + (button.pressed and 1 or 0)
                    local my = by + (bh - size) // 2 + (button.pressed and 1 or 0)
                    if button.disabled then
                        pixels.mark_disabled(tools, mark, mx, my, size)
                    else
                        mark(tools, mx, my, size, color.face_text)
                    end
                else
                    pixels.label(tools, bx, by, bw, bh, button.label ~= "" and button.label or button.icon,
                        face, button.disabled and color.shadow or color.face_text)
                end
            end
        end
        store.place(tool_id, 1, plan.rows.tool)
    end

    -- ─── адресная строка ─────────────────────────────────────────────────
    -- Геометрия — из плана (widgets.address_hits), в ячейках; здесь только
    -- перевод в пиксели и краска.
    local address: any = plan.address
    if address and address.hits and address.hits.field then
        local address_id = name .. ":address"
        local address_key = tostring(w) .. "|" .. tostring(address.text) .. "|" .. tostring(address.open)
        local strip, strip_dirty = store.take(address_id, w, address.rows, cell, address_key)
        if strip_dirty then
            local box = pixels.box(1, 1, w, address.rows, cell)
            strip:rect(1, 1, box.w, box.h, color.face)
            local field_h = 24
            local field_y = 1 + (box.h - field_h) // 2
            local text_y = field_y + (field_h - whole(face:height())) // 2
            strip:text(6, text_y, "Address", {font = face, color = color.face_text})
            local fhit: any = address.hits.field
            local fbox = pixels.box(fhit.from, 1, fhit.to - fhit.from + 1, 1, cell)
            pixels.field(strip, fbox.x, field_y, fbox.w, field_h)
            pixels.mark_folder(strip, fbox.x + 3, field_y + (field_h - 16) // 2, 16, color.face_text)
            strip:text(fbox.x + 22, text_y, pixels.ellipsize(face, address.text, fbox.w - 26),
                {font = face, color = color.field_text})
            local dhit: any = address.hits.drop
            local dbox = pixels.box(dhit.from, 1, dhit.to - dhit.from + 1, 1, cell)
            local open = address.open == true
            pixels.button(strip, dbox.x + 1, field_y, dbox.w - 2, field_h,
                {label = "", pressed = open}, cell)
            local drop_shift = open and 1 or 0
            pixels.mark_drop(strip, dbox.x + (dbox.w - 16) // 2 + drop_shift,
                field_y + (field_h - 16) // 2 + drop_shift, 16, color.face_text)
        end
        store.place(address_id, 1, address.row)
    end

    -- ─── поле со значками ────────────────────────────────────────────────
    local field_id = name .. ":field"
    local field, field_dirty = store.take(field_id, plan.field.w, plan.field.h, cell,
        field_key(plan))
    if field_dirty then
        local box = pixels.box(1, 1, plan.field.w, plan.field.h, cell)
        pixels.field(field, 1, 1, box.w, box.h)

        if plan.failure then
            field:text(6, 6, tostring(plan.failure), {font = face, color = color.field_text})
        else
            for _, entry in ipairs(plan.cells or {}) do
                local item: any = entry
                -- Место значка приходит планом, в ячейках поля; в пиксели оно
                -- переводится здесь, один раз.
                local at = pixels.box(item.from - plan.field.x + 1,
                    item.top - plan.field.y + 1,
                    item.to - item.from + 1, item.bottom - item.top + 1, cell)

                pixels.icon(field, at.x + (at.w - icon_size) // 2, at.y + 5, item.object, icon_size)

                local caption = tostring((item.object :: any).title or "")
                local lines = pixels.wrap(face, caption, at.w - 4, 2)
                local top = at.y + 5 + icon_size + 4
                for index, line in ipairs(lines) do
                    local width = face and face:measure(line) or 0
                    local left = at.x + (at.w - width) // 2
                    if item.selected then
                        field:rect(left - 1, top - 1, width + 2, 16, color.select_bg)
                    end
                    field:text(left, top, line, {font = face,
                        color = item.selected and color.select_fg or color.field_text})
                    top = top + 15
                    if index >= 2 then break end
                end
            end

            if plan.scroll then
                local at = pixels.box(plan.scroll.x - plan.field.x + 1,
                    plan.scroll.y - plan.field.y + 1, plan.scroll.w or 1, plan.scroll.h, cell)
                local thumb = scroll.bar(plan.scroll.first, plan.scroll.total, plan.scroll.visible,
                    plan.scroll.h, plan.scroll.arrow_rows)
                -- Та же полоса, что у списков SDK: одна рисовалка на всех.
                pixels.scrollbar(field, at.x, at.y, at.w, at.h, thumb, cell.h,
                    whole(plan.scroll.arrow_rows or 1) * whole(cell.h))
            end
        end
    end
    store.place(field_id, plan.field.x, plan.field.y)

    -- ─── статусная строка ────────────────────────────────────────────────
    local status_id = name .. ":status"
    local status, status_dirty = store.take(status_id, w, 1, cell,
        plan.status.count .. "\31" .. plan.status.detail)
    if status_dirty then
        local box = pixels.box(1, 1, w, 1, cell)
        -- Та же статусная строка, что у окон SDK.
        pixels.statusbar(status, 1, 1, box.w, box.h, {
            {text = plan.status.count, width = math.min(128, (whole(box.w) - 8) // 2)},
            {text = plan.status.detail},
        }, face)
    end
    store.place(status_id, 1, plan.rows.status)

    -- ─── раскрытые списки — поверх поля, поэтому последними ──────────────
    -- Текущая папка в списке адреса выделена: она последняя среди предков.
    if address and address.dropdown and #address.dropdown > 0 then
        local titles: any = {}
        for index, item in ipairs(address.items or {}) do titles[index] = tostring((item :: any).title or "") end
        paint_list(store, name .. ":dropdown", address.dropdown, titles, #titles, 0, false, face, cell)
    end
    local popup: any = plan.menu_popup
    if popup and #popup.hits > 0 then
        local titles: any = {}
        for index, item in ipairs(popup.items) do titles[index] = tostring((item :: any).title or "") end
        paint_list(store, name .. ":menu_popup", popup.hits, titles, 0, 1, true, face, cell)
    end

    return store.frame(cell)
end

return backend
