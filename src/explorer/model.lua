-- Что показывает «Мой компьютер».
--
-- Дисков здесь нет, и это не упущение: их нет и на стенде. Окно показывает
-- сам стенд — то, из чего он состоит с точки зрения оболочки, — потому что
-- нарисовать диск C: значило бы показать предмет, которого не существует, и
-- первым же вопросом было бы, почему он не открывается.
--
-- Три источника, и все три оболочка УЖЕ читает по другим поводам:
--
--   Программы      — каталог реестра, тот же, что наполняет меню «Пуск»
--   Рабочий стол   — своя раскладка, ярлыки и папки стола
--   Открытые окна  — то, что сейчас на экране, у композитора основы
--
-- Чего здесь намеренно НЕТ: прогонов, работ бриджа, битов контент-машины.
-- Читать чужие таблицы напрямую значило бы завести зависимость от схем
-- модулей, от которых оболочка не зависит, — и сломаться на их первой
-- миграции, молча и не у себя. Модуль, желающий показать своё, объявляет окно
-- записью с `meta.type: tui_desktop.window`, и оно появляется в «Программах»
-- само. Это тот же принцип, на котором стоит весь модуль: объявляет реестр.
--
-- Разбиение на чистую сборку и чтение источников — то же, что в каталоге:
-- правило, проверяемое только через живую базу, проверяется один раз, а потом
-- никогда.

local catalog = require("catalog")

local model = {}

model.ROOT = ""

-- Папки верхнего уровня. Порядок задан здесь и не сортируется: «Программы»
-- первыми, потому что за ними чаще всего и приходят.
model.FOLDERS = {
    {id = "programs", title = "Программы", icon = "▤"},
    {id = "desktop", title = "Рабочий стол", icon = "▣"},
    {id = "windows", title = "Открытые окна", icon = "◫"},
}

model.DEFAULT_ICON = "▢"
model.BROKEN_ICON = "▨"

-- Объект: что видно (title, icon, detail) и что происходит по двойному щелчку
-- (open). Двойной, а не одиночный: программа, стартующая с одного клика, —
-- ловушка, и в настоящей Windows её тоже нет.
--
-- `open` описывает НАМЕРЕНИЕ, а не выполняет его: окно не порождает процессов
-- и не открывает соседей само, оно просит об этом композитор. Разбор намерения
-- живёт в одном месте, и окно не решает по дороге, что значит «открыть».
local function object(fields: any)
    return {
        id = fields.id,
        kind = fields.kind,
        title = fields.title,
        icon = fields.icon,
        detail = fields.detail,
        open = fields.open,
    }
end

-- Корень: три папки со счётчиком объектов внутри. Счётчик — не украшение:
-- пустая папка и папка, которую не удалось прочитать, обязаны отличаться, и
-- `nil` здесь означает второе.
function model.root(counts: any)
    local out = {}
    for _, folder in ipairs(model.FOLDERS) do
        local count = type(counts) == "table" and counts[folder.id] or nil
        out[#out + 1] = object({
            id = folder.id,
            kind = "folder",
            title = folder.title,
            icon = folder.icon,
            detail = count and (tostring(count) .. " объектов") or "не прочитано",
            open = {action = "folder", path = folder.id},
        })
    end
    return out
end

-- Программы каталога. Плоско, без папок меню: в окне проводника папки меню
-- были бы вторым деревом рядом с деревом «Мой компьютер», и человек не понял
-- бы, в каком из них он находится.
function model.programs(programs: any)
    local out = {}
    for _, program in ipairs(type(programs) == "table" and programs or {}) do
        out[#out + 1] = object({
            id = program.entry,
            kind = "program",
            title = program.title,
            icon = program.icon or model.DEFAULT_ICON,
            detail = program.entry,
            open = {
                action = "open_window",
                entry = program.entry,
                title = program.title,
                w = program.width,
                h = program.height,
                args = program.args,
            },
        })
    end
    return out
end

-- Ярлыки и папки стола. Битый ярлык виден и здесь, и по той же причине:
-- пропавшая строка читается как «я его случайно удалил», битая — как
-- «программы больше нет».
function model.desktop(items: any, programs: any)
    local out = {}
    for _, item in ipairs(type(items) == "table" and items or {}) do
        if item.kind == "folder" then
            out[#out + 1] = object({
                id = item.id,
                kind = "folder",
                title = item.title,
                icon = "▤",
                detail = "папка стола",
                -- Папка стола открывается своим окном, а не этим: у неё своё
                -- содержимое и своя раскладка.
                open = {action = "folder", path = "desktop/" .. tostring(item.id)},
            })
        else
            local program = catalog.find(programs, item.entry)
            out[#out + 1] = object({
                id = item.id,
                kind = "shortcut",
                title = item.title,
                icon = program and (program.icon or model.DEFAULT_ICON) or model.BROKEN_ICON,
                detail = program and item.entry or ("нет программы: " .. tostring(item.entry)),
                open = program and {
                    action = "open_window",
                    entry = item.entry,
                    title = item.title,
                    w = program.width,
                    h = program.height,
                    args = program.args,
                } or nil,
            })
        end
    end
    return out
end

-- Открытые окна. Двойной щелчок поднимает окно, а не открывает второе такое
-- же: список показывает то, что уже на экране, и «открыть» здесь значит
-- «показать».
function model.windows(windows: any)
    local out = {}
    for _, window in ipairs(type(windows) == "table" and windows or {}) do
        out[#out + 1] = object({
            id = window.id,
            kind = "window",
            title = window.title or window.id,
            icon = "◫",
            detail = window.minimized and "свёрнуто" or "на экране",
            open = {action = "raise", id = window.id},
        })
    end
    return out
end

return model
