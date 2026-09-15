-- Notepad as in Windows 95 (FR-007 §1, §6): the model's `update` for every
-- menu item against a stand-in of the window's five functions, the "save
-- changes?" gate with each answer, the Find sequence, the 64 KB refusal over
-- a stand-in `fs.get`, the title after Save As, and test/shots/notepad.png.
local test = require("test")
local gfx = require("gfx")
local fs = require("fs")
local ui = require("ui")
local cells = require("cells")
local render = require("render")
local rasters = require("rasters")
local editor = require("editor")
local app = require("app")
local notepad = require("notepad")
local filedialog = require("filedialog")
local files = require("files")

local DRIVE = "app:docs"
local IDS = filedialog.IDS
local CELL = {w = 10, h = 20}

-- The window's five functions over a table of files, `drive .. path` → text.
local function stand_in(stored: any): any
    local sys: any = {stored = stored or {}, writes = {}}
    function sys.read(drive: any, path: any): (any, any, any)
        local text: any = sys.stored[tostring(drive) .. tostring(path)]
        if text == nil then return nil, "no such file", "missing" end
        -- Its own reason: the words the window shows are the model's.
        if #text > notepad.LIMIT then return nil, "over the limit", "large" end
        return text, nil, nil
    end
    function sys.write(drive: any, path: any, text: any): (any, any)
        if drive == "app:readonly" then return nil, "the drive is read-only" end
        sys.stored[tostring(drive) .. tostring(path)] = text
        sys.writes[#sys.writes + 1] = tostring(drive) .. tostring(path)
        return true, nil
    end
    function sys.exists(drive: any, path: any): boolean
        return sys.stored[tostring(drive) .. tostring(path)] ~= nil
    end
    function sys.drives(): (any, any)
        return {{id = DRIVE, title = "(Docs)"}}, nil
    end
    function sys.list(place: any): (any, any)
        local out: any = {{id = "sub", title = "sub", kind = "directory"}}
        local prefix = DRIVE .. "/"
        for stored_key in pairs(sys.stored) do
            local name = tostring(stored_key)
            if name:sub(1, #prefix) == prefix and not name:sub(#prefix + 1):find("/", 1, true) then
                out[#out + 1] = {id = name:sub(#prefix + 1), title = name:sub(#prefix + 1), kind = "file"}
            end
        end
        return out, nil
    end
    function sys.now(): string
        return "9:45 PM 9/13/2026"
    end
    return sys
end
local function opened(stored: any, args: any?): (any, any, any)
    local sys = stand_in(stored)
    local context = app.context({width = 64, height = 20})
    local state = notepad.init(sys, args, context)
    return state, context, sys
end
local function doc(context: any): any
    return context.editor(notepad.DOC)
end
local function act(state: any, context: any, action: any): any
    return notepad.update(state, action, context)
end
local function menu(id: string): any
    return {type = "activate", id = id, menu = "bar"}
end
local function press(id: string): any
    return {type = "activate", id = id}
end
local function change(id: string, value: any): any
    return {type = "change", id = id, value = value}
end
local function key(name: string, char: string?, ctrl: boolean?): any
    return {type = "key", key_type = char and "runes" or name, key = char or name, ctrl = ctrl}
end
-- The items of one menu as text: "Cut\tCtrl+X(off)", "Word Wrap(v)", "-".
local function listed(state: any, context: any, title: string): string
    local tree = notepad.view(state, context)
    local out = {}
    for _, entry in ipairs(tree.children[1].entries) do
        if entry.title == title then
            for _, item in ipairs(entry.items) do
                if item.separator then out[#out + 1] = "-"
                else
                    out[#out + 1] = item.text .. (item.shortcut and ("\t" .. item.shortcut) or "")
                        .. (item.disabled and "(off)" or "") .. (item.checked and "(v)" or "")
                end
            end
        end
    end
    return table.concat(out, "|")
end
local function plain(row: any): string
    return (tostring(row or ""):gsub("\27%[[%d;:]*m", ""))
end
-- One cells frame as a picture, cell by cell from its own SGR (as editor_test does).
local DIGITS = "0123456789abcdef"
local function hex(value: any): string
    local n = math.tointeger(math.max(0, math.min(255, tonumber(value) or 0))) or 0
    return DIGITS:sub(n // 16 + 1, n // 16 + 1) .. DIGITS:sub(n % 16 + 1, n % 16 + 1)
end
local function pictured_cells(rows: any, cols: integer, count: integer, font: any): any
    local shot = gfx.raster(cols * CELL.w, count * CELL.h)
    shot:fill("#c0c0c0")
    for row = 1, count do
        local line = tostring(rows[row] or "")
        local fg, bg = "#000000", "#c0c0c0"
        local column, at_byte = 0, 1
        while at_byte <= #line and column < cols do
            local sgr = line:match("^\27%[([%d;:]*)m", at_byte)
            if sgr then
                local params = {}
                for number in sgr:gmatch("%d+") do params[#params + 1] = tonumber(number) end
                local index = 1
                while index <= #params do
                    local code = params[index]
                    if code == 0 then fg, bg = "#000000", "#c0c0c0"
                    elseif code == 39 then fg = "#000000"
                    elseif code == 49 then bg = "#c0c0c0"
                    elseif (code == 38 or code == 48) and params[index + 1] == 2 then
                        local colour = "#" .. hex(params[index + 2]) .. hex(params[index + 3]) .. hex(params[index + 4])
                        if code == 38 then fg = colour else bg = colour end
                        index = index + 4
                    end
                    index = index + 1
                end
                at_byte = at_byte + #sgr + 3
            else
                local char = line:match("^[%z\1-\127\194-\244][\128-\191]*", at_byte) or " "
                shot:rect(column * CELL.w + 1, (row - 1) * CELL.h + 1, CELL.w, CELL.h, bg)
                if char ~= " " then shot:text(column * CELL.w + 1, (row - 1) * CELL.h + 3, char, {font = font, color = fg}) end
                column = column + 1
                at_byte = at_byte + #char
            end
        end
    end
    return shot
end

local function define_tests()
    test.describe("chicago.shell.viewers Notepad", function()
        test.it("starts untitled, opens the explorer's file, and titles the window with a plain hyphen", function()
            local state, context = opened({})
            test.eq(notepad.title(state), "Untitled - Notepad")
            test.eq(editor.text(doc(context)), "")
            local tree = notepad.view(state, context)
            test.eq(tree.children[1].kind .. "," .. tree.children[2].kind, "menu,editor", "a menu bar over one editor, nothing else")
            test.eq(tree.children[2].font, "mono")
            local named, named_context = opened({[DRIVE .. "/a.txt"] = "alpha\nbeta"}, files.encode(DRIVE, "/a.txt"))
            test.eq(editor.text(doc(named_context)), "alpha\nbeta")
            test.eq(notepad.title(named), "a.txt - Notepad")
            test.is_false(editor.dirty(doc(named_context)))
        end)

        test.it("refuses a file over 64 KB with the original's words before it is read into the editor", function()
            local big = string.rep("x", notepad.LIMIT + 1)
            local state, context = opened({[DRIVE .. "/big.txt"] = big}, files.encode(DRIVE, "/big.txt"))
            test.eq(state.sheet and state.sheet.lines[1], "This file is too large for Notepad to open.")
            test.eq(editor.text(doc(context)), "", "nothing went into the editor")
            test.is_nil(state.file)
            test.eq(notepad.title(state), "Notepad")
            act(state, context, press("msg_ok"))
            test.eq(notepad.title(state), "Untitled - Notepad")
            local fits = opened({[DRIVE .. "/fit.txt"] = string.rep("y", notepad.LIMIT)}, files.encode(DRIVE, "/fit.txt"))
            test.eq(fits.file and fits.file.name, "fit.txt", "64 KB itself opens")
        end)

        test.it("reads through the drive's own handle: stat first, then the 64 KB rule, a missing file apart", function()
            local stored: any = {["/big.txt"] = string.rep("x", notepad.LIMIT + 1), ["/a.txt"] = "alpha",
                ["/fit.txt"] = string.rep("y", notepad.LIMIT)}
            local reads = 0
            local function get(drive: any): (any, any)
                if drive ~= DRIVE then return nil, "no such entry" end
                return {
                    stat = function(_: any, path: any): (any, any)
                        if stored[path] == nil then return nil, "not found" end
                        return {size = #stored[path]}, nil
                    end,
                    readfile = function(_: any, path: any): (any, any)
                        reads = reads + 1
                        return stored[path], nil
                    end,
                    writefile = function(_: any, path: any, text: any): (any, any)
                        stored[path] = text
                        return true, nil
                    end,
                }, nil
            end
            local text, _, kind = notepad.read_file(get, DRIVE, "/big.txt")
            test.is_nil(text)
            test.eq(kind, "large")
            test.eq(reads, 0, "known too large from stat, before a byte is read")
            test.eq(notepad.read_file(get, DRIVE, "/a.txt"), "alpha")
            test.eq(#tostring(notepad.read_file(get, DRIVE, "/fit.txt")), notepad.LIMIT, "64 KB itself is read")
            local _, _, missing = notepad.read_file(get, DRIVE, "/none.txt")
            test.eq(missing, "missing")
            local _, why, failed = notepad.read_file(get, "app:gone", "/a.txt")
            test.eq(failed, "failed")
            test.is_true(tostring(why):find("app:gone", 1, true) ~= nil, "the reason names the drive")
            test.is_true(notepad.exists_file(get, DRIVE, "/a.txt"))
            test.is_false(notepad.exists_file(get, DRIVE, "/none.txt"))
            test.is_false(notepad.exists_file(get, "app:gone", "/a.txt"), "a drive that does not open has no file")
            test.is_true(notepad.write_file(get, DRIVE, "/w.txt", "text"))
            test.eq(stored["/w.txt"], "text")
            test.is_nil(notepad.write_file(get, "app:gone", "/w.txt", "text"))
        end)

        test.it("has the menus of Windows 95: the shortcut column, Word Wrap checked, what cannot be done greyed", function()
            local state, context = opened({})
            test.eq(listed(state, context, "File"), "New|Open...|Save|Save As...|-|Page Setup...(off)|Print(off)|-|Exit")
            test.eq(listed(state, context, "Edit"), "Undo\tCtrl+Z(off)|-|Cut\tCtrl+X(off)|Copy\tCtrl+C(off)"
                .. "|Paste\tCtrl+V(off)|Delete\tDel(off)|-|Select All|Time/Date\tF5|-|Word Wrap")
            test.eq(listed(state, context, "Search"), "Find...|Find Next\tF3")
            test.eq(listed(state, context, "Help"), "Help Topics|-|About Notepad")
            editor.insert(doc(context), "abc")
            act(state, context, menu("select_all"))
            act(state, context, menu("copy"))
            test.eq(listed(state, context, "Edit"), "Undo\tCtrl+Z|-|Cut\tCtrl+X|Copy\tCtrl+C"
                .. "|Paste\tCtrl+V|Delete\tDel|-|Select All|Time/Date\tF5|-|Word Wrap", "an undo point, a selection, a clipboard")
            act(state, context, menu("wrap"))
            test.is_true(listed(state, context, "Edit"):find("Word Wrap(v)", 1, true) ~= nil)
            test.is_true(notepad.view(state, context).children[2].wrap, "the editor wraps")
            act(state, context, menu("wrap"))
            test.is_false(notepad.view(state, context).children[2].wrap)
        end)

        test.it("asks before New, Open and Exit drop a changed document: Yes saves and goes on, No goes on, Cancel stays", function()
            local state, context, sys = opened({[DRIVE .. "/a.txt"] = "alpha"}, files.encode(DRIVE, "/a.txt"))
            editor.insert(doc(context), "X")
            act(state, context, menu("new"))
            test.eq(state.sheet and state.sheet.kind, "ask")
            test.eq(state.sheet.lines[1], "The text in the a.txt file has changed.")
            test.eq(state.sheet.lines[3], "Do you want to save the changes?")
            act(state, context, press("ask_cancel"))
            test.is_nil(state.sheet)
            test.eq(editor.text(doc(context)), "Xalpha", "Cancel keeps the document")
            -- Cancel forgets the New it held back: a later Save only saves.
            act(state, context, menu("save"))
            test.eq(editor.text(doc(context)), "Xalpha", "the New held back is gone with Cancel")
            editor.insert(doc(context), "Y")
            act(state, context, menu("exit"))
            act(state, context, press("ask_yes"))
            test.eq(sys.stored[DRIVE .. "/a.txt"], "XYalpha", "Yes saves first")
            test.is_true(context.closing, "and then closes")
            local fresh, fresh_context = opened({})
            editor.insert(doc(fresh_context), "draft")
            act(fresh, fresh_context, menu("new"))
            test.eq(fresh.sheet.lines[1], "The text in the Untitled file has changed.")
            act(fresh, fresh_context, press("ask_no"))
            test.eq(editor.text(doc(fresh_context)), "", "No drops it")
            test.is_nil(fresh.sheet)
            test.is_false(editor.dirty(doc(fresh_context)))
            act(fresh, fresh_context, menu("new"))
            test.is_nil(fresh.sheet, "a clean document asks nothing")
            local draft, draft_context, draft_sys = opened({})
            editor.insert(doc(draft_context), "notes")
            act(draft, draft_context, menu("open"))
            act(draft, draft_context, press("ask_yes"))
            test.eq(draft.sheet and draft.sheet.mode, "save", "an untitled Yes goes through Save As")
            act(draft, draft_context, change(IDS.name, "notes"))
            act(draft, draft_context, press(IDS.accept))
            test.eq(draft_sys.writes[1], DRIVE .. "/notes.txt")
            test.eq(draft.sheet and draft.sheet.mode, "open", "and then does the Open it held back")
        end)

        test.it("saves an untitled document through Save As, adds .txt under Text Documents, and titles it", function()
            local state, context, sys = opened({})
            editor.insert(doc(context), "hello")
            act(state, context, menu("save"))
            test.eq(notepad.title(state), "Save As", "Save of an untitled document is Save As")
            act(state, context, change(IDS.name, "plan"))
            act(state, context, press(IDS.accept))
            test.eq(sys.writes[1], DRIVE .. "/plan.txt")
            test.eq(sys.stored[DRIVE .. "/plan.txt"], "hello")
            test.eq(notepad.title(state), "plan.txt - Notepad", "the title follows Save As")
            test.is_false(editor.dirty(doc(context)))
            editor.insert(doc(context), "!")
            act(state, context, menu("save"))
            test.is_nil(state.sheet, "a named file saves without asking")
            test.eq(sys.stored[DRIVE .. "/plan.txt"], "hello!")
            act(state, context, menu("save_as"))
            act(state, context, change(IDS.type, "all"))
            act(state, context, change(IDS.name, "raw"))
            act(state, context, press(IDS.accept))
            test.eq(sys.writes[#sys.writes], DRIVE .. "/raw", "All Files keeps the name as typed")
            -- Over a file that is there: the question, No back to the dialog, Yes writes.
            local written = #sys.writes
            act(state, context, menu("save_as"))
            act(state, context, change(IDS.name, "plan"))
            act(state, context, press(IDS.accept))
            test.eq(state.sheet and state.sheet.kind, "replace")
            test.eq(state.sheet.lines[1], "plan.txt already exists.")
            test.eq(state.sheet.lines[2], "Do you want to replace it?")
            test.eq(notepad.title(state), "Save As")
            test.eq(#sys.writes, written, "nothing written before the answer")
            act(state, context, press("replace_no"))
            test.eq(state.sheet and state.sheet.kind .. ":" .. state.sheet.mode, "dialog:save", "No goes back to the dialog")
            act(state, context, press(IDS.accept))
            act(state, context, press("replace_yes"))
            test.eq(sys.writes[#sys.writes], DRIVE .. "/plan.txt", "Yes replaces it")
            test.eq(#sys.writes, written + 1)
            test.eq(notepad.title(state), "plan.txt - Notepad")
            state.file = {drive = "app:readonly", path = "/x.txt", name = "x.txt"}
            act(state, context, menu("save"))
            test.eq(state.sheet and state.sheet.lines[1], "the drive is read-only", "a failed write says why")
        end)

        test.it("opens the chosen file, and a name that is not there asks to create it", function()
            local state, context, sys = opened({[DRIVE .. "/a.txt"] = "alpha"})
            act(state, context, menu("open"))
            test.eq(notepad.title(state), "Open")
            act(state, context, {type = "select", id = IDS.list, index = 2, value = {id = "a.txt"}, pointer = true})
            act(state, context, press(IDS.accept))
            test.eq(editor.text(doc(context)), "alpha")
            test.eq(notepad.title(state), "a.txt - Notepad")
            act(state, context, menu("open"))
            act(state, context, change(IDS.name, "new.txt"))
            act(state, context, press(IDS.accept))
            test.eq(state.sheet and state.sheet.lines[1], "Cannot find the new.txt file.")
            test.eq(state.sheet.lines[3], "Do you want to create a new file?")
            act(state, context, press("create_no"))
            test.eq(state.sheet and state.sheet.kind, "dialog", "No goes back to the dialog")
            act(state, context, press(IDS.accept))
            act(state, context, press("create_yes"))
            test.eq(sys.writes[1], DRIVE .. "/new.txt")
            test.eq(notepad.title(state), "new.txt - Notepad")
            act(state, context, menu("open"))
            act(state, context, change(IDS.name, "other.txt"))
            act(state, context, press(IDS.accept))
            act(state, context, press("create_cancel"))
            test.is_nil(state.sheet)
            test.eq(notepad.title(state), "new.txt - Notepad", "Cancel changes nothing")
        end)

        test.it("finds with the Find sheet, F3 finds the next, a text that is not there says Cannot find", function()
            local state, context = opened({[DRIVE .. "/a.txt"] = "alpha beta alpha"}, files.encode(DRIVE, "/a.txt"))
            act(state, context, key("f3"))
            test.eq(state.sheet and state.sheet.kind, "find", "F3 with nothing searched opens Find")
            test.eq(notepad.title(state), "Find")
            act(state, context, change("find_what", "alpha"))
            act(state, context, press("find_next"))
            test.is_nil(state.sheet, "the sheet goes to show the match")
            test.eq(editor.selection(doc(context)), "alpha")
            test.eq(doc(context).caret.col, 5)
            act(state, context, key("f3"))
            test.eq(doc(context).caret.col, 16, "the next one")
            act(state, context, key("f3"))
            test.eq(state.sheet and state.sheet.lines[1], "Cannot find \"alpha\"")
            act(state, context, key("esc"))
            act(state, context, menu("find"))
            test.eq(state.sheet.needle, "alpha", "Find remembers the last search")
            act(state, context, change("find_case", true))
            act(state, context, change("find_up", true))
            act(state, context, change("find_what", "Alpha"))
            act(state, context, press("find_next"))
            test.eq(state.sheet and state.sheet.lines[1], "Cannot find \"Alpha\"", "Match case up from the end finds none")
            act(state, context, press("msg_ok"))
            act(state, context, menu("find"))
            act(state, context, change("find_case", false))
            act(state, context, press("find_next"))
            test.eq(doc(context).anchor.col, 0, "up without case from the second alpha: the first one")
        end)

        test.it("keeps the clipboard in the window: Ctrl+X, C and V, Ctrl+Z toggles, F5 inserts the time, Help and About", function()
            local state, context = opened({[DRIVE .. "/a.txt"] = "abc"}, files.encode(DRIVE, "/a.txt"))
            act(state, context, menu("select_all"))
            act(state, context, key("runes", "c", true))
            test.eq(state.clipboard, "abc")
            test.eq(editor.text(doc(context)), "abc", "Copy leaves the text")
            act(state, context, key("runes", "x", true))
            test.eq(editor.text(doc(context)), "")
            act(state, context, key("runes", "v", true))
            test.eq(editor.text(doc(context)), "abc")
            act(state, context, key("runes", "z", true))
            test.eq(editor.text(doc(context)), "", "Undo takes the paste back")
            act(state, context, key("runes", "z", true))
            test.eq(editor.text(doc(context)), "abc", "and a second Undo redoes it")
            act(state, context, key("f5"))
            test.is_true(editor.text(doc(context)):find("9:45 PM 9/13/2026", 1, true) ~= nil, editor.text(doc(context)))
            act(state, context, menu("select_all"))
            act(state, context, menu("delete"))
            test.eq(editor.text(doc(context)), "")
            act(state, context, menu("paste"))
            act(state, context, menu("select_all"))
            act(state, context, menu("cut"))
            test.eq(editor.text(doc(context)), "")
            test.eq(state.clipboard, "abc")
            editor.set(doc(context), "xyz")
            act(state, context, menu("select_all"))
            act(state, context, menu("cut"))
            test.eq(state.clipboard, "xyz", "Cut puts the selection on the clipboard")
            act(state, context, menu("help"))
            test.eq(state.sheet and state.sheet.lines[1], "Help is not available.")
            act(state, context, key("esc"))
            test.is_nil(state.sheet)
            act(state, context, menu("about"))
            test.eq(notepad.title(state), "About Notepad")
            test.eq(state.sheet.lines[1], "Notepad")
        end)

        test.it("the title bar's close asks for a changed document: Yes saves and closes, No closes, Cancel stays", function()
            -- A refusal is `context.stay()` called while answering `close`;
            -- what `update` returns does not matter (C1). The close goes
            -- through the SDK's own rule, and the window must have stayed
            -- exactly when that rule refused.
            local function refuses(state: any, context: any): boolean
                local calls: any = {stay = 0}
                local stay = context.stay
                test.eq(type(stay), "function", "the context can stay")
                context.stay = function()
                    calls.stay = calls.stay + 1
                    stay()
                end
                local refused = app.refuses_close({update = function(model: any, action: any, ctx: any): any
                    return notepad.update(model, action, ctx)
                end}, state, context)
                context.stay = stay
                test.eq(refused, calls.stay > 0, "refused exactly when the window stayed")
                return refused
            end
            local clean, clean_context = opened({[DRIVE .. "/a.txt"] = "alpha"}, files.encode(DRIVE, "/a.txt"))
            test.is_false(refuses(clean, clean_context), "an unchanged document closes at once")
            test.is_nil(clean.sheet)

            local state, context, sys = opened({[DRIVE .. "/a.txt"] = "alpha"}, files.encode(DRIVE, "/a.txt"))
            editor.insert(doc(context), "X")
            test.is_true(refuses(state, context), "a changed one refuses the close")
            test.eq(state.sheet and state.sheet.lines[1], "The text in the a.txt file has changed.")
            test.is_false(context.closing)
            act(state, context, press("ask_yes"))
            test.eq(sys.stored[DRIVE .. "/a.txt"], "Xalpha", "Yes saves")
            test.is_true(context.closing, "and then closes")

            local kept, kept_context, kept_sys = opened({[DRIVE .. "/a.txt"] = "alpha"}, files.encode(DRIVE, "/a.txt"))
            editor.insert(doc(kept_context), "X")
            test.is_true(refuses(kept, kept_context))
            act(kept, kept_context, press("ask_cancel"))
            test.is_false(kept_context.closing, "Cancel keeps the window")
            test.is_nil(kept.sheet)
            test.eq(editor.text(doc(kept_context)), "Xalpha")
            test.is_true(refuses(kept, kept_context), "and asks again at the next close")
            act(kept, kept_context, press("ask_no"))
            test.is_true(kept_context.closing, "No closes")
            test.eq(#kept_sys.writes, 0, "without saving")

            local draft, draft_context, draft_sys = opened({})
            editor.insert(doc(draft_context), "draft")
            test.is_true(refuses(draft, draft_context))
            act(draft, draft_context, press("ask_yes"))
            test.eq(draft.sheet and draft.sheet.mode, "save", "an untitled Yes goes through Save As")
            test.is_false(draft_context.closing, "not closed while the dialog is up")
            act(draft, draft_context, change(IDS.name, "draft"))
            act(draft, draft_context, press(IDS.accept))
            test.eq(draft_sys.writes[1], DRIVE .. "/draft.txt")
            test.is_true(draft_context.closing, "saved, then closed")
        end)

        test.it("paints a few lines with a selection and the Edit menu open, in pixels and in cells", function()
            local text = "Windows 95 Notepad keeps a plain text file.\nThe second line.\n\tA tab, then the third."
            local state, context = opened({[DRIVE .. "/readme.txt"] = text}, files.encode(DRIVE, "/readme.txt"))
            local document = doc(context)
            -- "file" at the end of the first line: right of the open menu in both modes.
            document.anchor, document.caret = {line = 1, col = 38}, {line = 1, col = 42}
            local interaction = context.interaction
            interaction.menus.bar = {index = 2, cursor = 0}
            interaction.focus = notepad.DOC
            local tree = notepad.view(state, context)
            test.is_nil(ui.problem(tree), tostring(ui.problem(tree)))
            local files_dir = assert(fs.get("app:system_fonts"))
            local fonts = {face = assert(gfx.font(assert(files_dir:readfile("LiberationSans-Regular.ttf")), {size = 13, smooth = true})),
                mono = assert(gfx.font(assert(files_dir:readfile("LiberationMono-Regular.ttf")), {size = 13, smooth = true}))}
            local store = rasters.store()
            store.begin()
            local placed = assert(render.placement({id = "notepad-shot", state_revision = 1, content_state = {sdk = 1, revision = 1,
                ui = tree, interaction = interaction}}, {x = 1, y = 1, cols = 64, rows = 20}, CELL, fonts, store))
            local rows: any = cells.rows(ui.plan(tree, 64, 20, interaction), interaction, 64, 20)
            local bar = plain(rows[1])
            test.is_true(bar:find("File", 1, true) ~= nil and bar:find("Search", 1, true) ~= nil and bar:find("Help", 1, true) ~= nil, bar)
            test.is_true(plain(rows[3]):find("Ctrl+Z", 1, true) ~= nil, "the Edit menu open: " .. plain(rows[3]))
            local shot = gfx.raster(64 * CELL.w, 20 * CELL.h * 2 + 10)
            shot:fill("#808080")
            shot:blit(placed.raster, 1, 1)
            shot:blit(pictured_cells(rows, 64, 20, fonts.mono), 1, 20 * CELL.h + 11)
            assert(assert(fs.get("app:shots")):writefile("notepad.png", assert(shot:encode("png"))))
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
