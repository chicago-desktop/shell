-- Theme probe: substitutes `tty` with a pure-Lua implementation and prints
-- the canvas as text. It checks exactly what cannot be seen in the code —
-- where the cells landed and whether the hits matched the drawing.
--
-- Written together with the butschster/windows theme to check it without
-- bringing up the stand: there is one stand for everyone, and a frame that is
-- off by a cell is visible only in a rendered frame. The caveat about
-- character width is in the README next to it, and it must travel together
-- with the tool.

-- Markers for build.py: it replaces the lines below with the bodies of the
-- theme files themselves.
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
            -- end of style
        else
            out[#out+1] = ch
        end
        i = i + 1
    end
    return out
end

-- ─── style ───────────────────────────────────────────────────────────────
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

-- ─── canvas ──────────────────────────────────────────────────────────────
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

-- ─── theme loading ───────────────────────────────────────────────────────
local modules = {tty = tty}
local saved_require = require
require = function(name)
    if modules[name] then return modules[name] end
    if saved_require then return saved_require(name) end
    error("no module " .. tostring(name))
end

-- The rules for `meta.in_menu` and `meta.window_type` live in the BASE
-- library, in the neighboring repository. The probe will not pull it in here:
-- a path into someone else's tree is what makes a tool work on only one
-- machine.
--
-- The stub answers with DEFAULTS and nothing more, and the probe looks at
-- neither `in_menu` nor `window_type`: those are checked by the test suite on
-- the real library. A stub that starts deciding for it will diverge from it —
-- and will show a menu that will not exist on the stand.
modules.programs_meta = {
    DEFAULT_TYPE = "app",
    window_type = function() return "app", nil end,
    in_menu = function() return true end,
}

-- The probe does not need the registry: it calls only `catalog.build`, a pure
-- assembly. The stub answers with a REFUSAL, not with emptiness — if someone
-- calls `list`, that must be visible, not look like "there are no programs".
modules.registry = {
    find = function() return nil, "the probe does not go to the registry" end,
    get = function() return nil, "the probe does not go to the registry" end,
}

-- The viewers' file helpers need `fs` at load time; the probe opens no
-- drives, so the stub refuses with a reason rather than answering empty.
modules.fs = {
    get = function() return nil, "the probe does not open drives" end,
}
-- And `json`, for the file argument format. Plain go-lua has no json module;
-- no scene here encodes a file argument, and if one ever does, the probe
-- must stop with the reason, not draw a picture built on a fake value.
modules.json = {
    encode = function() error("the probe does not encode json") end,
    decode = function() error("the probe does not decode json") end,
}

-- The base's pure libraries that `widgets` needs: text measuring, and the
-- scroll arithmetic, which itself needs geometry. build.py takes "core/" from
-- ../kickside-module/src/desktop.
modules.geometry = dofile(BASE .. "core/geometry.lua")
modules.text = dofile(BASE .. "core/text.lua")
modules.scroll = dofile(BASE .. "core/scroll.lua")
modules.palette = dofile(BASE .. "shell/palette.lua")
modules.glyphs = dofile(BASE .. "shell/glyphs.lua")
modules.widgets = dofile(BASE .. "shell/widgets.lua")
modules.icons = dofile(BASE .. "shell/icons.lua")
modules.menu_layout = dofile(BASE .. "shell/menu_layout.lua")
local chrome = dofile(BASE .. "shell/chrome.lua")
modules.catalog = dofile(BASE .. "programs/catalog.lua")
local catalog = modules.catalog

-- Menu items are assembled by the REAL catalog, not written by hand.
--
-- They used to be written by hand, and the probe repeated the contract from
-- memory: it sent `group` as a STRING, while the catalog has long put a parsed
-- list there. Because of this divergence, menu folders were not created on the
-- stand but were created in the probe — that is, the tool showed something
-- other than what the shell would show.
--
-- Now the path is the same as the shell's: registry entry → `catalog.build` →
-- items. The probe has nothing left to diverge from it by.
local function menu_items(records)
    local built = catalog.build(records)
    local items = {}
    for _, program in ipairs(catalog.listed(built.programs)) do
        items[#items + 1] = {
            entry = program.entry, title = program.title,
            group = program.group, order = program.order, icon = program.icon,
        }
    end
    return items
end

local function program(id, title, group, icon)
    return {id = id, meta = {type = "tui_desktop.window", title = title,
                             group = group, icon = icon}}
end
local glyphs = modules.glyphs

-- The program catalog is a stub, and only it. `model` calls it in one place,
-- to tell a broken shortcut from a working one; the scenes below do not need
-- that, and dragging the registry in here would mean bringing half the runtime
-- into the probe.
modules.catalog = {find = function() return nil end}
-- The explorer model opens files through the viewers' associations, and
-- those read the file argument format.
modules.files = dofile(BASE .. "viewers/files.lua")
modules.associations = dofile(BASE .. "viewers/associations.lua")
modules.model = dofile(BASE .. "explorer/model.lua")
modules.render = dofile(BASE .. "explorer/render.lua")
local model = modules.model
local render = modules.render

-- ─── printing ────────────────────────────────────────────────────────────
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
        local wide = #visible(rows[y]) ~= w and "  ◄ WIDTH " .. #visible(rows[y]) or ""
        print(string.format("%3d|%s|%s%s", y, rows[y], table.concat(marks), wide))
    end
    print("    legend fg:bg — " .. table.concat(legend, ", "))
    if hits then
        for _, hit in ipairs(hits) do
            local what = hit.action or hit.id or (hit.open and ("expand " .. table.concat(hit.open, "/")) or ("open " .. tostring(hit.index)))
            local under = {}
            local row = canvas:rows()[hit.row] or ""
            local list = visible(row)
            for x = hit.from, hit.to do under[#under+1] = list[x] or "?" end
            print(string.format("    hit row %d, %d..%d → %s   beneath it: [%s]",
                hit.row, hit.from, hit.to, what, table.concat(under)))
        end
    end
end

-- ─── scenes ──────────────────────────────────────────────────────────────
local function scene(w, h, opts)
    local canvas = tty.canvas(w, h)
    local layout = chrome.layout(w, h)
    -- The desk state is passed ALWAYS, even when there is none.
    --
    -- This used to read `chrome.fill(canvas, w, h)` without the fourth
    -- argument, and three scenes named "desktop icons" drew emptiness: the
    -- icons did not appear even once, while the scene title promised them.
    -- A probe that lies by default is worse than a missing one — people cite
    -- it.
    local desk_hits = chrome.fill(canvas, w, h, opts.desk or {})
    if opts.empty then
        chrome.empty_desktop(canvas, w, h, opts.empty)
    end
    for _, win in ipairs(opts.windows or {}) do
        chrome.window(canvas, win, win.focused)
    end
    local hits = {}
    for _, hit in ipairs(type(desk_hits) == "table" and desk_hits or {}) do
        hits[#hits+1] = hit
    end
    for _, hit in ipairs(chrome.bars(canvas, w, h, opts.state or {})) do
        hits[#hits+1] = hit
    end
    if opts.menu then
        local mhits = chrome.menu(canvas, w, h, opts.menu.items, opts.menu.failure,
            opts.menu.open, opts.menu.cursor)
        for _, hit in ipairs(mhits) do hits[#hits+1] = hit end
    end
    print("layout: top=" .. layout.top .. " bottom=" .. layout.bottom)
    show(opts.title, canvas, w, h, hits)
end

local content = {}
for i = 1, 10 do content[i] = "content line " .. i end

scene(96, 24, {
    title = "desktop: two windows, taskbar",
    windows = {
        {x = 4, y = 2, w = 40, h = 10, title = "Minimized neighbor", rows = content},
        {x = 20, y = 6, w = 52, h = 12, title = "Command Prompt — bash", rows = content, focused = true},
    },
    state = {
        windows = {
            {id = "w1", title = "Minimized neighbor"},
            {id = "w2", title = "Command Prompt"},
            {id = "w3", title = "Clock", minimized = true},
        },
        focused_id = "w2",
        clock = "21:47",
        status = "Command Prompt · 50×10 · windows: 3",
    },
})

scene(96, 24, {
    title = "Start menu with folders",
    state = {
        windows = {{id = "w2", title = "Command Prompt"}},
        focused_id = "w2", clock = "21:47", menu_open = true,
    },
    menu = {items = menu_items({
        program("app:calc", "Calculator", nil, "▣"),
        program("app:ping", "Ping", "System Tools/Network"),
        program("app:trace", "Traceroute", "System Tools/Network"),
        program("app:sysinfo", "System Information", "System Tools"),
        program("app:notepad", "Notepad"),
        program("app:deep", "Deep", "A/B/C/D"),
    })},
})

scene(96, 14, {
    title = "registry refusal is named by its reason",
    state = {clock = "21:47", menu_open = true},
    menu = {items = {}, failure = "registry.find: permission denied for actor butschster.windows.shell:shell"},
})

scene(96, 12, {
    title = "empty catalog",
    state = {clock = "21:47", menu_open = true},
    menu = {items = {}},
})

scene(28, 10, {
    title = "screen narrower than the taskbar: window buttons disappeared",
    empty = "alt+n — window with bash · ctrl+q — exit",
    state = {
        windows = {{id = "w1", title = "One"}, {id = "w2", title = "Two"}},
        focused_id = "w1", clock = "21:47", status = "no windows",
    },
})

scene(14, 8, {
    title = "very narrow",
    state = {windows = {{id = "w1", title = "One"}}, focused_id = "w1", clock = "21:47"},
})


scene(60, 14, {
    title = "desktop icons, one of them broken",
    desk = {top = 1, bottom = 13, items = {
        {id = "s1", kind = "shortcut", entry = "app:calc", title = "Calculator", icon = "▣", x = 3, y = 2, w = 28, h = 15},
        {id = "s2", kind = "shortcut", entry = "app:notepad", title = "Notepad", x = 3, y = 5},
        {id = "f1", kind = "folder", title = "My Documents", x = 3, y = 8},
        {id = "s3", kind = "shortcut", entry = "app:gone", title = "Old program", x = 18, y = 2, broken = true},
    }},
    state = {clock = "21:47", windows = {}},
})

scene(60, 12, {
    title = "desktop layout could not be read",
    desk = {top = 1, bottom = 11, failure = "db: no such table: butschster_windows_desktop_items"},
    state = {clock = "21:47"},
})

scene(50, 12, {
    title = "catalog longer than the screen",
    state = {clock = "21:47", menu_open = true},
    menu = {items = menu_items((function()
        local list = {}
        for i = 1, 20 do list[i] = program("app:p" .. i, "Program " .. i) end
        return list
    end)())},
})


scene(70, 20, {
    title = "reference: icon column on the left and a window with a full frame",
    desk = {top = 1, bottom = 19, selected = "s2", items = {
        {id = "s1", kind = "shortcut", entry = "app:computer", title = "My Computer", icon = "▣", x = 2, y = 1},
        {id = "s2", kind = "shortcut", entry = "app:network", title = "Network Neighborhood", x = 2, y = 5},
        {id = "f1", kind = "folder", title = "My Documents", x = 2, y = 9},
        {id = "s3", kind = "shortcut", entry = "app:bin", title = "Recycle Bin", x = 2, y = 13},
        {id = "s4", kind = "shortcut", entry = "app:gone", title = "Old program", x = 2, y = 17, broken = true},
    }},
    windows = {
        {x = 18, y = 3, w = 44, h = 12, title = "Welcome", focused = true, rows = {
            "Welcome to Windows 95",
            "",
            "Tip of the day: to open the menu, click",
            "the Start button in the lower-left corner.",
        }},
    },
    state = {
        windows = {{id = "w1", title = "Welcome"}},
        focused_id = "w1", clock = "21:47",
    },
})

-- The dialog primitives are printed separately: they have no place of their
-- own in the contract, they are called by whoever draws the inside of a
-- window.
do
    local canvas = tty.canvas(44, 7)
    canvas:clear(M1 .. "0:#c0c0c0" .. M2 .. " " .. M3)
    canvas:put(2, 1, chrome.etched(40), 40)
    canvas:put(2, 3, chrome.button("OK", {default = true, accel = 1}), 40)
    canvas:put(12, 3, chrome.button("Cancel", {accel = 1}), 40)
    canvas:put(24, 3, chrome.button("Next", {pressed = true}), 40)
    chrome.field(canvas, 2, 5, 40, 3)
    canvas:put(3, 6, M1 .. "0:#c0c0c0" .. M2 .. " sunken list field" .. M3, 38)
    show("dialog primitives: etched, buttons, field", canvas, 44, 7, nil)
    print("    OK button width per chrome.button_width: " .. chrome.button_width("OK", {default = true})
        .. ", drawn: " .. #visible(chrome.button("OK", {default = true, accel = 1})))
end

print("")
print("window insets: " .. (function()
    local i = chrome.window_insets()
    return "top=" .. i.top .. " bottom=" .. i.bottom .. " left=" .. i.left .. " right=" .. i.right
end)())
local grid = chrome.icon_grid()
print("chrome.icon_grid(): w=" .. grid.w .. " h=" .. grid.h .. " left=" .. grid.left .. " drawn=" .. grid.drawn)
print("icon grid: ICON_W=" .. chrome.ICON_W .. " ICON_H=" .. chrome.ICON_H .. " ICON_LEFT=" .. chrome.ICON_LEFT)


-- Icon caption: what chrome.caption_lines returns for real names.
print("")
print("caption_lines (column " .. chrome.icon_grid().w .. "):")
for _, title in ipairs({"My Computer", "Programs", "Network Neighborhood", "Recycle Bin",
                        "Superlongnamewithoutspaces", "My Computer and everything else"}) do
    local lines, overflow = chrome.caption_lines(title)
    print(string.format("  %-32s → [%s]%s", title,
        table.concat(lines, "] ["), overflow and "  DID NOT FIT" or ""))
end


scene(96, 20, {
    title = "Start cascade: Programs → Accessories expanded, cursor on the second row",
    state = {clock = "21:47", menu_open = true, windows = {}},
    menu = {open = {"Programs", "Accessories"}, cursor = 2, items = menu_items({
        program("app:calc", "Calculator", "Programs/Accessories", "▣"),
        program("app:notepad", "Notepad", "Programs/Accessories"),
        program("app:paint", "Paint", "Programs/Accessories"),
        program("app:ping", "Ping", "Programs/Communications"),
        program("app:bash", "MS-DOS Prompt", "Programs"),
        program("app:explorer", "Windows Explorer", "Programs"),
        program("app:docs", "Documents"),
        program("app:settings", "Settings"),
        program("app:shutdown", "Shut Down"),
    })},
})

-- Three window types: the theme picks the set of title buttons by
-- `window_type`, which the compositor puts in. Under each set the hit is
-- printed — it is the proof that exactly what is drawn is what gets pressed.
scene(72, 18, {
    title = "three window types: app, dialog, tool",
    windows = {
        {x = 2, y = 1, w = 34, h = 6, title = "Ordinary window", window_type = "app",
         focused = true, rows = {"minimize, maximize, close"}},
        {x = 2, y = 8, w = 34, h = 6, title = "System Properties", window_type = "dialog",
         rows = {"help and close"}},
        {x = 38, y = 1, w = 32, h = 6, title = "Palette", window_type = "tool",
         rows = {"close only"}},
        {x = 38, y = 8, w = 32, h = 6, title = "Type with a typo", window_type = "popup",
         rows = {"an unknown type is app"}},
    },
    state = {clock = "21:47", windows = {}},
})

do
    local samples = {
        {window_type = "app"}, {window_type = "dialog"},
        {window_type = "tool"}, {window_type = "popup"}, {},
    }
    print("")
    print("title button set by window type:")
    for _, spec in ipairs(samples) do
        local set, width = chrome.buttons_for(spec)
        local ids = {}
        for _, button in ipairs(set) do ids[#ids+1] = button.id end
        print(string.format("  %-10s → %-28s width %d",
            tostring(spec.window_type or "not named"), table.concat(ids, ", "), width))
    end

    -- The hit is computed from the same numbers as the drawing. Here it can be
    -- seen by eye: under each drawn button, what title_button_at returns is
    -- printed.
    for _, window_type in ipairs({"app", "dialog", "tool"}) do
        local window = {x = 1, y = 1, w = 34, h = 6, title = "Window",
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

-- ─── "My Computer": the window draws its own content ─────────────────────
--
-- There is no frame around it here on purpose: the compositor gives the window
-- the rectangle INSIDE the frame, and what the window draws starts on the
-- first row of that rectangle. Were the probe to draw a frame, it would be
-- checking something other than what the window gives the compositor.
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
                         id = "icon " .. tostring(object.title)}
    end
    show(title, canvas, w, h, flat)
end

window_scene(64, 20, "My Computer: drives from the registry and shell folders", {
    title = "My Computer",
    selected = 2,
    objects = model.root({programs = 12, desktop = 3, windows = 2}, model.drives({
        {id = "app:app_fs", kind = "fs.directory"},
        {id = "wippy.facade:public_files", kind = "fs.directory"},
        {id = "keeper:ui_static_fs", kind = "fs.embed"},
        {id = "vlad.doom:ui_static_fs", kind = "fs.directory"},
        {id = "butschster.windows:previews_fs", kind = "fs.directory"},
    })),
})

window_scene(64, 16, "inside a drive: folders before files, a file has nothing to open", {
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

window_scene(64, 12, "drive declared but did not open — a reason, not emptiness", {
    title = "My Computer",
    failure = "drive did not open: filesystem not found: app:gone_fs",
    objects = {},
})

window_scene(64, 12, "not everything was read, and that is said", {
    title = "app:huge_fs",
    notice = "showing the first 500",
    objects = model.files({
        {name = "0001.log", type = "file"},
        {name = "0002.log", type = "file"},
    }, "drive/app:huge_fs"),
})

-- That is how many drives the stand actually has. Without scrolling the
-- window would show the first ten and keep quiet about the rest — that is, it
-- would lie with the counter at the bottom.
local many = {}
for i = 1, 68 do
    many[i] = {id = "module" .. i .. ":fs", kind = "fs.directory"}
end

window_scene(64, 20, "more drives than fit: scrollbar and thumb", {
    title = "My Computer",
    selected = 1,
    objects = model.root({}, model.drives(many)),
})

window_scene(64, 20, "the same grid scrolled to the end", {
    title = "My Computer",
    offset = 99,
    objects = model.root({}, model.drives(many)),
})

window_scene(30, 10, "window narrower than one icon column", {
    title = "My Computer",
    objects = model.root({}, model.drives({{id = "app:app_fs", kind = "fs.directory"}})),
})

-- ─── glyph set check ─────────────────────────────────────────────────────
local bad = {}
for _, ch in ipairs(glyphs.all()) do
    if tty.text.width(ch) ~= 1 then bad[#bad+1] = ch end
end
print("")
print("glyphs in the set: " .. #glyphs.all() .. ", wider than one cell: " .. #bad)
-- The one check here that is not for the eye, so it fails like the pixel
-- probe's: a printed count nobody reads is a check that cannot fail, and
-- `make check-probes` judges a probe by its exit code.
if #bad > 0 then
    error("themeprobe failed: glyphs wider than one cell: " .. table.concat(bad, " "))
end
