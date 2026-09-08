-- Настоящие значки Windows 95 — растры из файлов, а не примитивы.
--
-- Значок 32×32 — это тысяча пикселей, и примитивами он не рисуется: силуэт
-- узнаётся, деталей нет. Здесь значки приезжают PNG-файлами из каталога
-- `butschster.windows.shell:icon_files` (assets/icons, см. SOURCE.md там же),
-- декодируются через `gfx.image` и накладываются на растр темы через `blit`.
--
-- Три правила, по которым это устроено:
--
--   * **Файл приезжает БАЙТАМИ через `fs`, а не путём внутри `gfx`.** То же
--     решение, что у шрифта: чтение файла управляется правами процесса, и
--     модуль, открывающий пути сам, был бы дорогой мимо них.
--   * **Имя значка — одно, и оно же имя файла.** Таблица `images.NAMES` —
--     единственный список того, что есть в пакете; тест проверяет, что каждое
--     имя декодируется в обоих размерах. Имя, которого нет в списке, — это
--     отказ с причиной, а не тихий пропуск: значок, который «почему-то не
--     нарисовался», ищут в рисовании, а не в опечатке.
--   * **Декодированный растр живёт, пока жив процесс.** Растры переживают
--     кадр (FR-005 §4): значок, декодированный заново на каждый кадр, был бы
--     новым растром с той же версией — и поверхность его бы НЕ переотправила.
--     Поэтому кэш здесь, а не у вызывающего.
--
-- Отказ открыть каталог или файл называется по имени и запоминается: тема
-- зовёт это на каждый кадр, и повторять `fs.get` шестьдесят раз в секунду
-- ради одного и того же «нет права» незачем. Вызывающий при отказе рисует
-- примитивами — как и до появления этого файла.

local fs = require("fs")
local gfx = require("gfx")

local images = {}

-- Запись реестра с файловой системой значков. Каталог объявлен в модуле
-- (`base: module`), поэтому приложению заводить ничего не нужно.
images.STORE = "butschster.windows.shell:icon_files"

-- Размеры, в которых пакет собран. Других файлов в каталоге нет, и просить
-- другой размер — ошибка вызывающего, а не повод масштабировать: у `gfx`
-- масштабирования нет нарочно, а 16-цветный значок, растянутый в полтора
-- раза, перестаёт быть тем значком.
images.SIZES = {32, 16}

-- Всё, что есть в пакете. Порядок — как в SOURCE.md.
images.NAMES = {
    "my_computer", "folder", "folder_open", "recycle_bin", "recycle_bin_full",
    "programs", "settings", "documents", "find", "help", "run", "shutdown",
    "program", "document", "text_document",
    "drive", "floppy", "cdrom", "network_drive", "printer",
    "control_panel", "fonts", "desktop", "windows", "shortcut_overlay",
    "network", "network_neighborhood", "documents_stack", "program_settings", "system",
}

local known = {}
for _, name in ipairs(images.NAMES) do known[name] = true end

-- Ярлык на окно проводника — это «Мой компьютер», а не программа со
-- стрелкой. Та же особая запись, что и в `pixels.icon`.
local EXPLORER = "butschster.windows.explorer:window"

-- Вид элемента → имя значка. Одна таблица на все места, где значок нужен
-- (стол, меню «Пуск», список проводника): у каждого свой рисовальщик, но имя
-- решается здесь, иначе папка на столе и папка в проводнике однажды окажутся
-- разными папками.
local BY_KIND = {
    folder = "folder",
    directory = "folder",
    group = "folder",
    drive = "drive",
    program = "program",
    window = "program",
    item = "document",
}

-- name_for(item) -> имя значка, имя накладки или nil
--
-- Явное `item.image` побеждает вид: запись реестра, объявившая
-- `meta.image: printer`, получает принтер. Неизвестное имя не подменяется
-- «чем-нибудь похожим» — отдаётся как есть, и `get` откажет с причиной.
function images.name_for(item: any): (any, any)
    if type(item) ~= "table" then return nil, nil end
    local explicit: any = item.image
    if type(explicit) == "string" and explicit ~= "" then
        return explicit, nil
    end
    local kind: any = item.kind
    if kind == "shortcut" then
        if item.entry == EXPLORER then return "my_computer", nil end
        return "program", "shortcut_overlay"
    end
    if item.broken then return nil, nil end
    return BY_KIND[kind], nil
end

local store: any = nil
local store_failure: any = nil
local cache = {}

local function open_store(): (any, any)
    if store then return store, nil end
    if store_failure then return nil, store_failure end
    local opened, err = fs.get(images.STORE)
    if err or not opened then
        store_failure = "каталог значков не открылся (" .. images.STORE .. "): " .. tostring(err)
        return nil, store_failure
    end
    store = opened
    return store, nil
end

-- get(name, size) -> растр или nil, причина
--
-- Растр общий для всех вызывающих и не должен меняться: `blit` из него
-- читает, и этого достаточно. Кто нарисует в него — испортит значок всем.
function images.get(name: any, size: any): (any, any)
    if type(name) ~= "string" or not known[name] then
        return nil, "нет такого значка: " .. tostring(name)
    end
    local px = math.tointeger(tonumber(size) or 0) or 0
    local sized = false
    for _, allowed in ipairs(images.SIZES) do
        if allowed == px then sized = true end
    end
    if not sized then
        return nil, "значков размера " .. tostring(size) .. " в пакете нет"
    end

    local key = name .. "@" .. tostring(px)
    local cached: any = cache[key]
    if cached ~= nil then
        if cached == false then return nil, "значок " .. key .. " не прочитан (см. первый отказ)" end
        return cached, nil
    end

    local opened, why = open_store()
    if not opened then return nil, why end

    local path = tostring(px) .. "/" .. name .. ".png"
    local data, read_err = opened:readfile(path)
    if read_err or not data then
        cache[key] = false
        return nil, "значок " .. path .. " не прочитан: " .. tostring(read_err)
    end
    -- `opened` типизирован как any, и readfile отдаёт any; линтер прав, что
    -- строку надо назвать строкой, а не догадываться.
    local raster, decode_err = gfx.image(data :: string)
    if not raster then
        cache[key] = false
        return nil, "значок " .. path .. " не декодирован: " .. tostring(decode_err)
    end
    local w, h = raster:size()
    if w ~= px or h ~= px then
        cache[key] = false
        return nil, string.format("значок %s размером %dx%d, ожидался %dx%d", path, w, h, px, px)
    end
    cache[key] = raster
    return raster, nil
end

-- icon(raster, x, y, item, size) -> true или nil, причина
--
-- Кладёт значок элемента (и накладку ярлыка, если положена) в растр темы.
-- Координата — верхний левый угол, как у всего в `gfx`. Отказ — повод
-- нарисовать примитивами, а не пустоту; причину стоит показать хотя бы раз.
function images.icon(raster: any, x: any, y: any, item: any, size: any): (any, any)
    local name, overlay = images.name_for(item)
    if not name then return nil, "у элемента нет значка в пакете" end
    local px = math.tointeger(tonumber(size) or 32) or 32
    local picture, why = images.get(name, px)
    if not picture then return nil, why end
    raster:blit(picture, x, y)
    if overlay then
        -- Стрелка ярлыка в Windows 95 стоит в левом нижнем углу значка.
        local arrow = images.get(overlay, 16)
        if arrow then
            local ax = math.tointeger(tonumber(x) or 1) or 1
            local ay = (math.tointeger(tonumber(y) or 1) or 1) + px - 16
            raster:blit(arrow, ax, ay)
        end
    end
    return true, nil
end

-- forget() — сбросить кэш; нужен тестам и смене каталога, больше никому.
function images.forget()
    store, store_failure, cache = nil, nil, {}
end

return images
