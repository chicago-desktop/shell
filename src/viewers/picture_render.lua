-- Просмотр картинок: чистая отрисовка.
--
-- Это `render` окна-вида (FR-005 §4б): библиотека без рантайма и без прав,
-- которую зовёт ТЕМА в процессе композитора. Данные приносит поставщик
-- `picture_state` — в состоянии окна лежит сама картинка (base64), имя файла
-- и как её показывать: вписать в окно или в масштабе со сдвигом.
--
-- Почему картинка едет в состоянии, а не читается здесь: у композитора нет
-- права на диски и не должно быть — «рисование в композиторе, права
-- снаружи». Почему base64: тело сообщения проходит через транскодер, и
-- строка с произвольными байтами — то, на чём он однажды сломается молча.
--
-- Растры живут между кадрами (FR-005 §4): на окно держится ОДИН растр
-- кадра, и он перерисовывается на месте только когда изменилась картинка,
-- размер окна или способ показа. Иначе поверхность переотправляла бы всё
-- окно на каждое нажатие клавиши в соседнем.

local base64 = require("base64")
local gfx = require("gfx")

local picture_render = {}

-- Идентификатор записи, по которому тема узнаёт, что окно рисуется здесь.
picture_render.ID = "butschster.windows.viewers:picture_render"

-- Фон вокруг картинки — серое лицо, как у диалогов; картинка меньше окна
-- лежит по центру, как в Imaging.
picture_render.BACKGROUND = "#c0c0c0"

local function whole(value: any): integer
    return math.tointeger(math.floor(tonumber(value) or 0)) or 0
end

-- Декодированные исходники, по ключу файла. Ключ — диск, путь и размер в
-- байтах: тот же файл, перезаписанный другим содержимым, меняет размер
-- почти всегда, а перечитывать base64 на каждый кадр — нет.
local sources = {}
local SOURCE_LIMIT = 8

local function source_key(state: any): string
    return tostring(state.drive) .. "|" .. tostring(state.path) .. "|" .. tostring(state.size)
end

local function remember(key, entry)
    local count = 0
    for _ in pairs(sources) do count = count + 1 end
    if count >= SOURCE_LIMIT then
        -- Самый старый — по счётчику обращений; хранить время незачем.
        local oldest, oldest_at = nil, math.huge
        for other, kept in pairs(sources) do
            if kept.at < oldest_at then oldest, oldest_at = other, kept.at end
        end
        if oldest then sources[oldest] = nil end
    end
    sources[key] = entry
end

local tick = 0

-- source(state) -> растр исходника | nil, причина
function picture_render.source(state: any): (any, any)
    if type(state) ~= "table" then return nil, "состояния ещё нет" end
    if state.failure then return nil, tostring(state.failure) end
    local key = source_key(state)
    local kept = sources[key]
    tick = tick + 1
    if kept then
        kept.at = tick
        return kept.raster, nil
    end
    if type(state.data) ~= "string" or state.data == "" then
        return nil, "картинка ещё не доехала"
    end
    local bytes, err = base64.decode(state.data)
    if err or type(bytes) ~= "string" then
        return nil, "картинка не раскодирована: " .. tostring(err)
    end
    local raster, why = gfx.image(bytes :: string)
    if not raster then
        return nil, "картинка не открылась: " .. tostring(why)
    end
    local w, h = raster:size()
    remember(key, {raster = raster, w = w, h = h, at = tick})
    return raster, nil
end

-- Кадры по окну: один растр на окно, живёт между кадрами.
local frames = {}

local function frame_for(window_id: any, px_w: integer, px_h: integer): (any, boolean)
    local kept = frames[window_id]
    if kept and kept.w == px_w and kept.h == px_h then return kept, false end
    local raster = gfx.raster(px_w, px_h)
    kept = {raster = raster, w = px_w, h = px_h, signature = ""}
    frames[window_id] = kept
    return kept, true
end

-- geometry(state, source_w, source_h, px_w, px_h) -> {scale, x, y, w, h}
--
-- Вписывание не увеличивает: значок 32×32 в окне 600×400 остаётся значком,
-- а не размытым квадратом. Увеличить — это масштаб, и его просят явно.
function picture_render.geometry(state: any, source_w: any, source_h: any, px_w: any, px_h: any): any
    local sw, sh = whole(source_w), whole(source_h)
    local fw, fh = whole(px_w), whole(px_h)
    if sw < 1 or sh < 1 or fw < 1 or fh < 1 then return nil end

    local scale = 1.0
    if state.mode == "zoom" then
        scale = tonumber(state.zoom) or 1
        if scale <= 0 then scale = 1 end
    else
        scale = math.min(fw / sw, fh / sh, 1)
    end

    local w = math.max(1, whole(math.floor(sw * scale + 0.5)))
    local h = math.max(1, whole(math.floor(sh * scale + 0.5)))

    -- Меньше окна — по центру. Больше окна — сдвиг из состояния, зажатый
    -- так, чтобы за краем картинки не оставалось пустоты.
    local x = (fw - w) // 2 + 1
    local y = (fh - h) // 2 + 1
    if w > fw then
        local max_shift = w - fw
        local shift = math.max(0, math.min(max_shift, whole(state.x)))
        x = 1 - shift
    end
    if h > fh then
        local max_shift = h - fh
        local shift = math.max(0, math.min(max_shift, whole(state.y)))
        y = 1 - shift
    end
    return {scale = scale, x = x, y = y, w = w, h = h}
end

-- frame(window_id, state, px_w, px_h) -> растр кадра | nil, причина
--
-- Возвращает ОДИН И ТОТ ЖЕ растр, пока ничего не менялось: у него не
-- сдвигается версия, и поверхность его не переотправляет.
function picture_render.frame(window_id: any, state: any, px_w: any, px_h: any): (any, any)
    local fw, fh = whole(px_w), whole(px_h)
    if fw < 1 or fh < 1 then return nil, "окну не хватает места под картинку" end

    local source, why = picture_render.source(state)
    if not source then return nil, why end
    local kept: any = sources[source_key(state)]
    if not kept then return nil, "исходник не удержался в кэше" end

    local box = picture_render.geometry(state, kept.w, kept.h, fw, fh)
    if not box then return nil, "картинка без размера" end

    local signature = table.concat({source_key(state), tostring(box.scale),
        tostring(box.x), tostring(box.y), tostring(box.w), tostring(box.h)}, "|")

    local frame, fresh = frame_for(window_id, fw, fh)
    if not fresh and frame.signature == signature then
        return frame.raster, nil
    end

    frame.raster:fill(picture_render.BACKGROUND)
    local shown = source
    if box.w ~= kept.w or box.h ~= kept.h then
        -- Уменьшение сглаженное — фотография пикселями превращается в кашу
        -- муара; увеличение ступенчатое — иначе пиксельная графика
        -- размывается, а увеличивают как раз её.
        shown = source:scaled(box.w, box.h, {smooth = box.scale < 1})
    end
    frame.raster:blit(shown, box.x, box.y)
    frame.signature = signature
    return frame.raster, nil
end

-- placement(window, inner, cell) -> размещение | nil, причина
--
-- Вход темы. `inner` — прямоугольник внутри рамки в ЯЧЕЙКАХ ({x, y, cols,
-- rows}), `cell` — размер ячейки в пикселях. Размещение накрывает ровно
-- inner, и композитор стирает под ним символы сам.
function picture_render.placement(window: any, inner: any, cell: any): (any, any)
    if type(window) ~= "table" or type(inner) ~= "table" or type(cell) ~= "table" then
        return nil, "placement ждёт окно, прямоугольник и размер ячейки"
    end
    local cols, rows = whole(inner.cols), whole(inner.rows)
    local cw, ch = whole(cell.w), whole(cell.h)
    if cols < 1 or rows < 1 or cw < 1 or ch < 1 then
        return nil, "окну не хватает места под картинку"
    end
    if window.waiting then return nil, "картинка ещё не доехала" end
    local raster, why = picture_render.frame(window.id, window.content_state, cols * cw, rows * ch)
    if not raster then return nil, why end
    return {
        id = "win:" .. tostring(window.id) .. ":content",
        raster = raster,
        x = whole(inner.x), y = whole(inner.y), cols = cols, rows = rows,
    }, nil
end

-- forget(window_id) — окно закрыто, кадр больше не нужен.
function picture_render.forget(window_id: any)
    frames[window_id] = nil
end

return picture_render
