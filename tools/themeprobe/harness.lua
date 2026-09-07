-- Пробник темы: подменяет `tty` чистой реализацией на Lua и печатает холст
-- текстом. Проверяет ровно то, что нельзя увидеть в коде, — куда легли
-- ячейки и совпали ли попадания с рисунком.
--
-- Написан вместе с темой butschster/windows, чтобы проверять её, не поднимая
-- стенд: стенд один на всех, а разъехавшаяся на ячейку рамка видна только на
-- кадре. Оговорка про ширину символов — в README рядом, и она обязана ехать
-- вместе с инструментом.

-- Метки для build.py: строки ниже он заменяет телом самих файлов темы.
local BASE = "src/shell/"

local M1, M2, M3 = "\1", "\2", "\3"

local function chars(s)
    local out = {}
    for ch in tostring(s):gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out+1] = ch end
    return out
end

local function visible(s)
    local out, i, list = {}, 1, chars(s)
    while i <= #list do
        local ch = list[i]
        if ch == M1 then
            repeat i = i + 1 until i > #list or list[i] == M2
        elseif ch == M3 then
            -- конец стиля
        else
            out[#out+1] = ch
        end
        i = i + 1
    end
    return out
end

-- ─── стиль ───────────────────────────────────────────────────────────────
local function new_style(spec)
    local self = {}
    local function copy(extra)
        local n = {}
        for k, v in pairs(spec) do n[k] = v end
        for k, v in pairs(extra) do n[k] = v end
        return new_style(n)
    end
    self.foreground = function(_, c) return copy({fg = c}) end
    self.background = function(_, c) return copy({bg = c}) end
    self.bold = function(_) return copy({bold = true}) end
    self.faint = function(_) return copy({faint = true}) end
    self.underline = function(_) return copy({under = true}) end
    self.width = function(_, n) return copy({w = n}) end
    self.key = function()
        return (spec.fg or "-") .. ":" .. (spec.bg or "-")
            .. (spec.bold and "!" or "") .. (spec.under and "_" or "")
    end
    self.render = function(_, text)
        return M1 .. self.key() .. M2 .. tostring(text) .. M3
    end
    return self
end

-- ─── холст ───────────────────────────────────────────────────────────────
local function new_canvas(w, h)
    local cell, style = {}, {}
    for y = 1, h do
        cell[y], style[y] = {}, {}
        for x = 1, w do cell[y][x], style[y][x] = " ", "-:-" end
    end

    local canvas = {}

    local function place(x, y, text, limit)
        if y < 1 or y > h then return end
        local span = math.min(limit or w, w - x + 1)
        local col, stack, i, list = x, {"-:-"}, 1, chars(text)
        while i <= #list do
            local ch = list[i]
            if ch == M1 then
                local key = {}
                i = i + 1
                while i <= #list and list[i] ~= M2 do key[#key+1] = list[i]; i = i + 1 end
                stack[#stack+1] = table.concat(key)
            elseif ch == M3 then
                if #stack > 1 then stack[#stack] = nil end
            else
                if col >= x and col <= x + span - 1 and col >= 1 and col <= w then
                    cell[y][col] = ch
                    style[y][col] = stack[#stack]
                end
                col = col + 1
                if col > x + span - 1 then break end
            end
            i = i + 1
        end
    end

    canvas.put = function(_, x, y, text, limit) place(x, y, text, limit) end
    canvas.put_rows = function(_, x, y, rows, limit)
        for index, row in ipairs(rows) do place(x, y + index - 1, row, limit) end
    end
    canvas.clear = function(_, fill)
        local list = visible(fill or " ")
        local key = "-:-"
        do
            local c = chars(fill or " ")
            for i = 1, #c do
                if c[i] == M1 then
                    local k = {}
                    i = i + 1
                    while i <= #c and c[i] ~= M2 do k[#k+1] = c[i]; i = i + 1 end
                    key = table.concat(k)
                    break
                end
            end
        end
        for y = 1, h do
            for x = 1, w do
                cell[y][x] = #list > 0 and list[((x - 1) % #list) + 1] or " "
                style[y][x] = key
            end
        end
    end
    canvas.rows = function()
        local out = {}
        for y = 1, h do out[y] = table.concat(cell[y]) end
        return out
    end
    canvas.styles = function() return style end
    return canvas
end

-- ─── tty ─────────────────────────────────────────────────────────────────
local tty = {}
tty.style = function() return new_style({}) end
tty.text = {
    width = function(s) return #visible(s) end,
    truncate = function(s, n)
        local out, count, i, list, stack = {}, 0, 1, chars(s), 0
        while i <= #list do
            local ch = list[i]
            if ch == M1 then
                out[#out+1] = ch
                i = i + 1
                while i <= #list and list[i] ~= M2 do out[#out+1] = list[i]; i = i + 1 end
                out[#out+1] = M2
                stack = stack + 1
            elseif ch == M3 then
                out[#out+1] = ch
                if stack > 0 then stack = stack - 1 end
            else
                if count >= n then break end
                out[#out+1] = ch
                count = count + 1
            end
            i = i + 1
        end
        for _ = 1, stack do out[#out+1] = M3 end
        return table.concat(out)
    end,
}
tty.canvas = function(w, h) return new_canvas(w, h) end

-- ─── загрузка темы ───────────────────────────────────────────────────────
local modules = {tty = tty}
local saved_require = require
require = function(name)
    if modules[name] then return modules[name] end
    if saved_require then return saved_require(name) end
    error("нет модуля " .. tostring(name))
end

modules.palette = dofile(BASE .. "shell/palette.lua")
modules.glyphs = dofile(BASE .. "shell/glyphs.lua")
modules.widgets = dofile(BASE .. "shell/widgets.lua")
modules.icons = dofile(BASE .. "shell/icons.lua")
local chrome = dofile(BASE .. "shell/chrome.lua")
local glyphs = modules.glyphs

-- Каталог программ — заглушка, и только он. `model` зовёт его в одном месте,
-- чтобы отличить битый ярлык от исправного; сценам ниже это не нужно, а
-- тащить сюда реестр значило бы завести в пробнике половину рантайма.
modules.catalog = {find = function() return nil end}
modules.model = dofile(BASE .. "explorer/model.lua")
modules.render = dofile(BASE .. "explorer/render.lua")
local model = modules.model
local render = modules.render

-- ─── печать ──────────────────────────────────────────────────────────────
local function show(title, canvas, w, h, hits)
    print("")
    print("┌── " .. title .. " (" .. w .. "×" .. h .. ")")
    local rows = canvas:rows()
    local styles = canvas:styles()
    local legend, letters, next_letter = {}, {}, 0
    local alphabet = "abcdefghijklmnopqrstuvwxyz"
    for y = 1, h do
        local marks = {}
        for x = 1, w do
            local key = styles[y][x]
            if not letters[key] then
                next_letter = next_letter + 1
                letters[key] = alphabet:sub(next_letter, next_letter)
                legend[#legend+1] = letters[key] .. " = " .. key
            end
            marks[x] = letters[key]
        end
        local wide = #visible(rows[y]) ~= w and "  ◄ ШИРИНА " .. #visible(rows[y]) or ""
        print(string.format("%3d|%s|%s%s", y, rows[y], table.concat(marks), wide))
    end
    print("    легенда фг:фон — " .. table.concat(legend, ", "))
    if hits then
        for _, hit in ipairs(hits) do
            local what = hit.action or hit.id or (hit.open and ("раскрыть " .. table.concat(hit.open, "/")) or ("открыть " .. tostring(hit.index)))
            local under = {}
            local row = canvas:rows()[hit.row] or ""
            local list = visible(row)
            for x = hit.from, hit.to do under[#under+1] = list[x] or "?" end
            print(string.format("    попадание строка %d, %d..%d → %s   под ним: [%s]",
                hit.row, hit.from, hit.to, what, table.concat(under)))
        end
    end
end

-- ─── сцены ───────────────────────────────────────────────────────────────
local function scene(w, h, opts)
    local canvas = tty.canvas(w, h)
    local layout = chrome.layout(w, h)
    chrome.fill(canvas, w, h)
    if opts.empty then
        chrome.empty_desktop(canvas, w, h, opts.empty)
    end
    for _, win in ipairs(opts.windows or {}) do
        chrome.window(canvas, win, win.focused)
    end
    local hits = chrome.bars(canvas, w, h, opts.state or {})
    if opts.menu then
        local mhits = chrome.menu(canvas, w, h, opts.menu.items, opts.menu.failure, opts.menu.open)
        for _, hit in ipairs(mhits) do hits[#hits+1] = hit end
    end
    print("layout: top=" .. layout.top .. " bottom=" .. layout.bottom)
    show(opts.title, canvas, w, h, hits)
end

local content = {}
for i = 1, 10 do content[i] = "строка содержимого " .. i end

scene(96, 24, {
    title = "рабочий стол: два окна, панель задач",
    windows = {
        {x = 4, y = 2, w = 40, h = 10, title = "Свёрнутый сосед", rows = content},
        {x = 20, y = 6, w = 52, h = 12, title = "Командная строка — bash", rows = content, focused = true},
    },
    state = {
        windows = {
            {id = "w1", title = "Свёрнутый сосед"},
            {id = "w2", title = "Командная строка"},
            {id = "w3", title = "Часы", minimized = true},
        },
        focused_id = "w2",
        clock = "21:47",
        status = "Командная строка · 50×10 · окон: 3",
    },
})

scene(96, 24, {
    title = "меню «Пуск» с папками",
    state = {
        windows = {{id = "w2", title = "Командная строка"}},
        focused_id = "w2", clock = "21:47", menu_open = true,
    },
    menu = {items = {
        {entry = "app:calc", title = "Калькулятор", icon = "▣"},
        {entry = "app:ping", title = "Пинг", group = "Служебные/Сеть", order = 2},
        {entry = "app:trace", title = "Трассировка", group = "Служебные/Сеть", order = 1},
        {entry = "app:sysinfo", title = "Сведения о системе", group = "Служебные"},
        {entry = "app:notepad", title = "Блокнот"},
        {entry = "app:deep", title = "Глубоко", group = "А/Б/В/Г"},
    }},
})

scene(96, 14, {
    title = "отказ реестра назван причиной",
    state = {clock = "21:47", menu_open = true},
    menu = {items = {}, failure = "registry.find: permission denied for actor butschster.windows.shell:shell"},
})

scene(96, 12, {
    title = "пустой каталог",
    state = {clock = "21:47", menu_open = true},
    menu = {items = {}},
})

scene(28, 10, {
    title = "экран уже панели: кнопки окон исчезли",
    empty = "alt+n — окно с bash · ctrl+q — выход",
    state = {
        windows = {{id = "w1", title = "Одно"}, {id = "w2", title = "Два"}},
        focused_id = "w1", clock = "21:47", status = "нет окон",
    },
})

scene(14, 8, {
    title = "совсем узко",
    state = {windows = {{id = "w1", title = "Одно"}}, focused_id = "w1", clock = "21:47"},
})


scene(60, 14, {
    title = "значки рабочего стола, среди них битый",
    desk = {top = 1, bottom = 13, items = {
        {id = "s1", kind = "shortcut", entry = "app:calc", title = "Калькулятор", icon = "▣", x = 3, y = 2, w = 28, h = 15},
        {id = "s2", kind = "shortcut", entry = "app:notepad", title = "Блокнот", x = 3, y = 5},
        {id = "f1", kind = "folder", title = "Мои документы", x = 3, y = 8},
        {id = "s3", kind = "shortcut", entry = "app:gone", title = "Старая программа", x = 18, y = 2, broken = true},
    }},
    state = {clock = "21:47", windows = {}},
})

scene(60, 12, {
    title = "раскладка стола не прочитана",
    desk = {top = 1, bottom = 11, failure = "db: no such table: butschster_windows_desktop_items"},
    state = {clock = "21:47"},
})

scene(50, 12, {
    title = "каталог длиннее экрана",
    state = {clock = "21:47", menu_open = true},
    menu = {items = (function()
        local list = {}
        for i = 1, 20 do list[i] = {entry = "app:p" .. i, title = "Программа " .. i} end
        return list
    end)()},
})


scene(70, 20, {
    title = "эталон: колонка значков слева и окно с полной рамкой",
    desk = {top = 1, bottom = 19, selected = "s2", items = {
        {id = "s1", kind = "shortcut", entry = "app:computer", title = "Мой компьютер", icon = "▣", x = 2, y = 1},
        {id = "s2", kind = "shortcut", entry = "app:network", title = "Сетевое окружение", x = 2, y = 5},
        {id = "f1", kind = "folder", title = "Мои документы", x = 2, y = 9},
        {id = "s3", kind = "shortcut", entry = "app:bin", title = "Корзина", x = 2, y = 13},
        {id = "s4", kind = "shortcut", entry = "app:gone", title = "Старая программа", x = 2, y = 17, broken = true},
    }},
    windows = {
        {x = 18, y = 3, w = 44, h = 12, title = "Welcome", focused = true, rows = {
            "Добро пожаловать в Windows 95",
            "",
            "Совет дня: чтобы открыть меню, нажмите",
            "кнопку «Пуск» в левом нижнем углу.",
        }},
    },
    state = {
        windows = {{id = "w1", title = "Welcome"}},
        focused_id = "w1", clock = "21:47",
    },
})

-- Примитивы диалога печатаются отдельно: у них нет своего места в контракте,
-- их зовут те, кто рисует внутренность окна.
do
    local canvas = tty.canvas(44, 7)
    canvas:clear(M1 .. "0:#c0c0c0" .. M2 .. " " .. M3)
    canvas:put(2, 1, chrome.etched(40), 40)
    canvas:put(2, 3, chrome.button("ОК", {default = true, accel = 1}), 40)
    canvas:put(12, 3, chrome.button("Отмена", {accel = 1}), 40)
    canvas:put(24, 3, chrome.button("Далее", {pressed = true}), 40)
    chrome.field(canvas, 2, 5, 40, 3)
    canvas:put(3, 6, M1 .. "0:#c0c0c0" .. M2 .. " утопленное поле списка" .. M3, 38)
    show("примитивы диалога: этчед, кнопки, поле", canvas, 44, 7, nil)
    print("    ширина кнопки ОК по chrome.button_width: " .. chrome.button_width("ОК", {default = true})
        .. ", нарисовано: " .. #visible(chrome.button("ОК", {default = true, accel = 1})))
end

print("")
print("insets окна: " .. (function()
    local i = chrome.window_insets()
    return "top=" .. i.top .. " bottom=" .. i.bottom .. " left=" .. i.left .. " right=" .. i.right
end)())
local grid = chrome.icon_grid()
print("chrome.icon_grid(): w=" .. grid.w .. " h=" .. grid.h .. " left=" .. grid.left .. " drawn=" .. grid.drawn)
print("сетка значков: ICON_W=" .. chrome.ICON_W .. " ICON_H=" .. chrome.ICON_H .. " ICON_LEFT=" .. chrome.ICON_LEFT)


-- Подпись значка: что отдаёт chrome.caption_lines на настоящих именах.
print("")
print("caption_lines (колонка " .. chrome.icon_grid().w .. "):")
for _, title in ipairs({"Мой компьютер", "Программы", "Сетевое окружение", "Корзина",
                        "Сверхдлинноеимябезпробелов", "Мой компьютер и всё остальное"}) do
    local lines, overflow = chrome.caption_lines(title)
    print(string.format("  %-32s → [%s]%s", title,
        table.concat(lines, "] ["), overflow and "  НЕ ПОМЕСТИЛОСЬ" or ""))
end


scene(96, 20, {
    title = "каскад «Пуска»: раскрыты Программы → Стандартные",
    state = {clock = "21:47", menu_open = true, windows = {}},
    menu = {open = {"Программы", "Стандартные"}, items = {
        {entry = "app:calc", title = "Калькулятор", icon = "▣", group = "Программы/Стандартные"},
        {entry = "app:notepad", title = "Блокнот", group = "Программы/Стандартные"},
        {entry = "app:paint", title = "Графический редактор", group = "Программы/Стандартные"},
        {entry = "app:ping", title = "Пинг", group = "Программы/Связь"},
        {entry = "app:bash", title = "Сеанс MS-DOS", group = "Программы"},
        {entry = "app:explorer", title = "Проводник", group = "Программы"},
        {entry = "app:docs", title = "Документы"},
        {entry = "app:settings", title = "Настройка"},
        {entry = "app:shutdown", title = "Завершение работы"},
    }},
})

-- Три типа окна: состав кнопок заголовка выбирает тема по `window_type`,
-- который кладёт композитор. Под каждым набором печатается попадание — оно и
-- есть доказательство, что нажимается ровно то, что нарисовано.
scene(72, 18, {
    title = "три типа окна: app, dialog, tool",
    windows = {
        {x = 2, y = 1, w = 34, h = 6, title = "Обычное окно", window_type = "app",
         focused = true, rows = {"свернуть, развернуть, закрыть"}},
        {x = 2, y = 8, w = 34, h = 6, title = "Свойства системы", window_type = "dialog",
         rows = {"справка и закрыть"}},
        {x = 38, y = 1, w = 32, h = 6, title = "Палитра", window_type = "tool",
         rows = {"только закрыть"}},
        {x = 38, y = 8, w = 32, h = 6, title = "Тип с опечаткой", window_type = "popup",
         rows = {"неизвестный тип — это app"}},
    },
    state = {clock = "21:47", windows = {}},
})

do
    local samples = {
        {window_type = "app"}, {window_type = "dialog"},
        {window_type = "tool"}, {window_type = "popup"}, {},
    }
    print("")
    print("состав кнопок заголовка по типу окна:")
    for _, spec in ipairs(samples) do
        local set, width = chrome.buttons_for(spec)
        local ids = {}
        for _, button in ipairs(set) do ids[#ids+1] = button.id end
        print(string.format("  %-10s → %-28s ширина %d",
            tostring(spec.window_type or "не назван"), table.concat(ids, ", "), width))
    end

    -- Попадание считается по тем же числам, что и рисование. Здесь это видно
    -- глазом: под каждой нарисованной кнопкой печатается то, что вернёт
    -- title_button_at.
    for _, window_type in ipairs({"app", "dialog", "tool"}) do
        local window = {x = 1, y = 1, w = 34, h = 6, title = "Окно",
                        window_type = window_type, rows = {}}
        local canvas = tty.canvas(34, 6)
        chrome.window(canvas, window, true)
        local row = visible(canvas:rows()[2] or "")
        local marks = {}
        for x = 1, 34 do
            local id = chrome.title_button_at(window, x, 2)
            marks[x] = id and id:sub(1, 1) or "·"
        end
        print("")
        print("  " .. window_type .. ": |" .. table.concat(row) .. "|")
        print("  " .. string.rep(" ", #window_type) .. "  |" .. table.concat(marks) .. "|")
    end
end

-- ─── «Мой компьютер»: содержимое рисует само окно ────────────────────────
--
-- Рамки вокруг него здесь нет нарочно: композитор отдаёт окну прямоугольник
-- ВНУТРИ рамки, и то, что рисует окно, начинается с первой строки этого
-- прямоугольника. Нарисуй пробник рамку — он проверял бы не то, что окно
-- отдаёт композитору.
local function window_scene(w, h, title, view)
    local canvas = tty.canvas(w, h)
    local hits = render.window(canvas, view, w, h)
    local flat = {}
    for _, hit in ipairs(hits.tools) do
        flat[#flat+1] = {row = hit.row, from = hit.from, to = hit.to, id = hit.id}
    end
    for _, cell in ipairs(hits.cells) do
        local object = view.objects[cell.index] or {}
        flat[#flat+1] = {row = cell.top, from = cell.from, to = cell.to,
                         id = "значок " .. tostring(object.title)}
    end
    show(title, canvas, w, h, flat)
end

window_scene(64, 20, "«Мой компьютер»: диски из реестра и папки оболочки", {
    title = "Мой компьютер",
    selected = 2,
    objects = model.root({programs = 12, desktop = 3, windows = 2}, model.drives({
        {id = "app:app_fs", kind = "fs.directory"},
        {id = "wippy.facade:public_files", kind = "fs.directory"},
        {id = "keeper:ui_static_fs", kind = "fs.embed"},
        {id = "vlad.doom:ui_static_fs", kind = "fs.directory"},
        {id = "butschster.windows:previews_fs", kind = "fs.directory"},
    })),
})

window_scene(64, 16, "внутри диска: папки раньше файлов, у файла нечего открыть", {
    title = "app:app_fs",
    selected = 4,
    objects = model.files({
        {name = "index.html", type = "file"},
        {name = "assets", type = "directory"},
        {name = "app.js", type = "file"},
        {name = "chunks", type = "directory"},
        {name = "style.css", type = "file"},
    }, "drive/app:app_fs"),
})

window_scene(64, 12, "диск объявлен, но не открылся — причина, а не пустота", {
    title = "Мой компьютер",
    failure = "диск не открылся: filesystem not found: app:gone_fs",
    objects = {},
})

window_scene(64, 12, "прочитали не всё, и об этом сказано", {
    title = "app:huge_fs",
    notice = "показаны первые 500",
    objects = model.files({
        {name = "0001.log", type = "file"},
        {name = "0002.log", type = "file"},
    }, "drive/app:huge_fs"),
})

-- Столько дисков на стенде и есть. Без прокрутки окно показало бы первые
-- десять и промолчало про остальные — то есть соврало бы счётчиком внизу.
local many = {}
for i = 1, 68 do
    many[i] = {id = "модуль" .. i .. ":fs", kind = "fs.directory"}
end

window_scene(64, 20, "дисков больше, чем помещается: полоса и ползунок", {
    title = "Мой компьютер",
    selected = 1,
    objects = model.root({}, model.drives(many)),
})

window_scene(64, 20, "та же сетка, прокрученная к концу", {
    title = "Мой компьютер",
    offset = 99,
    objects = model.root({}, model.drives(many)),
})

window_scene(30, 10, "окно уже одной колонки значков", {
    title = "Мой компьютер",
    objects = model.root({}, model.drives({{id = "app:app_fs", kind = "fs.directory"}})),
})

-- ─── проверка набора символов ────────────────────────────────────────────
local bad = {}
for _, ch in ipairs(glyphs.all()) do
    if tty.text.width(ch) ~= 1 then bad[#bad+1] = ch end
end
print("")
print("символов в наборе: " .. #glyphs.all() .. ", шире одной ячейки: " .. #bad)
