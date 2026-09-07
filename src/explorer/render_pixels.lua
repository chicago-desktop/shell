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

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Значки рисуются примитивами: `gfx.image` пока нет, а растровых картинок
-- Windows 95 взять неоткуда. Формы намеренно простые — папка с язычком, диск
-- со щелью, лист с отогнутым углом: в шестнадцать пикселей больше и не
-- ложится, а узнаваемость даёт силуэт, а не детали.
local ICON = 16

local function icon_folder(raster, x, y)
    raster:rect(x, y + 3, ICON, ICON - 5, "#c8a848")
    raster:rect(x, y + 1, 7, 3, "#c8a848")
    pixels.bevel(raster, x, y + 3, ICON, ICON - 5, true)
end

local function icon_drive(raster, x, y)
    raster:rect(x, y + 2, ICON, ICON - 4, color.face)
    pixels.bevel(raster, x, y + 2, ICON, ICON - 4, true)
    -- Щель дисковода: вдавленная полоска, по ней диск и узнаётся.
    raster:rect(x + 3, y + ICON - 6, ICON - 6, 3, "#404040")
    raster:rect(x + 2, y + 4, 4, 2, "#008000")
end

local function icon_file(raster, x, y)
    raster:rect(x + 2, y, ICON - 4, ICON, color.field)
    pixels.bevel(raster, x + 2, y, ICON - 4, ICON, false)
    -- Отогнутый угол — ступенькой, а не диагональю: диагоналей у нас нет.
    raster:rect(x + ICON - 7, y + 1, 4, 1, color.shadow)
    raster:rect(x + ICON - 6, y + 2, 3, 1, color.shadow)
end

local function icon_broken(raster, x, y)
    raster:rect(x + 2, y, ICON - 4, ICON, color.field)
    pixels.bevel(raster, x + 2, y, ICON - 4, ICON, false)
    raster:rect(x + 4, y + 4, ICON - 8, 2, color.alert)
    raster:rect(x + 4, y + 9, ICON - 8, 2, color.alert)
end

local function draw_icon(raster, x, y, object: any)
    local kind = type(object) == "table" and object.kind or nil
    if kind == "folder" then icon_folder(raster, x, y)
    elseif kind == "drive" or kind == "directory" then
        if kind == "directory" then icon_folder(raster, x, y) else icon_drive(raster, x, y) end
    elseif kind == "shortcut" and object.icon == "▨" then icon_broken(raster, x, y)
    else icon_file(raster, x, y) end
end

-- Отпечаток состояния поля. Ключ, забывший поле, даёт картинку, которая не
-- обновляется; ключ, взявший лишнее, перерисовывает зря. Здесь названо ровно
-- то, от чего картинка зависит.
local function field_key(plan: any)
    local parts = {tostring(plan.width), tostring(plan.height),
                   tostring(plan.failure or ""), tostring(plan.scroll and plan.scroll.first or 0)}
    for _, cell in ipairs(plan.cells or {}) do
        local object: any = cell.object or {}
        parts[#parts + 1] = table.concat({
            tostring(cell.index), tostring(object.kind or ""), tostring(object.title or ""),
            tostring(object.icon or ""), cell.selected and "1" or "0",
        }, "\30")
    end
    return table.concat(parts, "\31")
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

    store.begin()

    -- ─── строка меню ─────────────────────────────────────────────────────
    local menu_id = name .. ":menu"
    local menu, menu_dirty = store.take(menu_id, w, 1, cell, tostring(w))
    if menu_dirty then
        local box = pixels.box(1, 1, w, 1, cell)
        menu:rect(1, 1, box.w, box.h, color.face)
        local at = 6
        for _, item in ipairs(plan.menu or {}) do
            local text = tostring((item :: any).text or "")
            local advance = menu:text(at, (box.h - 15) // 2, text,
                {font = face, color = color.face_text})
            at = at + advance + 12
        end
    end
    store.place(menu_id, 1, plan.rows.menu)

    -- ─── панель инструментов ─────────────────────────────────────────────
    local tool_id = name .. ":tools"
    local tool_key = tostring(w)
    for _, button in ipairs(plan.tools or {}) do
        tool_key = tool_key .. "|" .. tostring((button :: any).id)
            .. ((button :: any).pressed and "!" or "")
    end
    local tools, tools_dirty = store.take(tool_id, w, 1, cell, tool_key)
    if tools_dirty then
        local box = pixels.box(1, 1, w, 1, cell)
        tools:rect(1, 1, box.w, box.h, color.face)
        for _, entry in ipairs(plan.tools or {}) do
            local button: any = entry
            -- Кнопка ставится по ЯЧЕЙКАМ плана, а не по своим пикселям:
            -- иначе её зона попадания разъедется с планом, из которого окно
            -- считает щелчок.
            local span = button.to - button.from + 1
            local area = pixels.box(button.from, 1, span, 1, cell)
            pixels.panel(tools, area.x + 1, area.y + 2, area.w - 2, area.h - 4)
            pixels.label(tools, area.x + 1, area.y + 2, area.w - 2, area.h - 4,
                button.label, face, color.face_text)
        end
    end
    store.place(tool_id, 1, plan.rows.tool)

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
                    item.to - item.from + 1, 3, cell)

                draw_icon(field, at.x + (at.w - ICON) // 2, at.y + 2, item.object)

                local caption = tostring((item.object :: any).title or "")
                local lines = pixels.wrap(face, caption, at.w - 4, 2)
                local top = at.y + 2 + ICON + 2
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
                    plan.scroll.y - plan.field.y + 1, 1, plan.scroll.h, cell)
                pixels.panel(field, at.x, at.y, at.w, at.h)
                local track = at.h - at.w * 2
                local total = math.max(1, whole(plan.scroll.total))
                local visible = whole(plan.scroll.visible)
                local thumb = (track * visible) // total
                if thumb < 8 then thumb = 8 end
                if thumb > track then thumb = track end
                local room = track - thumb
                local last = math.max(1, total - visible)
                local offset = room > 0 and (room * whole(plan.scroll.first)) // last or 0
                pixels.panel(field, at.x, at.y + at.w + offset, at.w, thumb)
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
        status:rect(1, 1, box.w, box.h, color.face)
        local left = pixels.box(1, 1, 16, 1, cell)
        pixels.field(status, 2, 2, left.w - 2, box.h - 4)
        status:text(6, (box.h - 15) // 2, plan.status.count,
            {font = face, color = color.face_text})

        pixels.field(status, left.w + 2, 2, box.w - left.w - 4, box.h - 4)
        status:text(left.w + 6, (box.h - 15) // 2, plan.status.detail,
            {font = face, color = color.face_text})
    end
    store.place(status_id, 1, plan.rows.status)

    return store.frame(cell)
end

return backend
