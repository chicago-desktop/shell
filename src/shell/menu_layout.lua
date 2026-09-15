-- The Start menu's layout: WHAT and WHERE, without a single paint.
--
-- Moved out of `chrome.lua` (review, 2026-09-11): the cascade — the folder
-- tree built from `meta.group`, the panels, their rows and the hit map — is
-- one pure function for both themes. The cell theme paints it with
-- characters, the pixel theme with rasters; two backends each computing the
-- cascade their own way would drift apart silently, and a click would land on
-- the neighbouring item in one of the two modes.
--
-- Nothing here knows about the screen or reads the theme: the banner text
-- arrives as `metrics.banner` (the theme owns its branding, and `chrome`,
-- which imports this library, could not be imported back).
local glyphs = require("glyphs")
local icons = require("icons")
local widgets = require("widgets")

local whole = widgets.whole
local cells = widgets.cells
local wrap = icons.wrap

local menu_layout = {}

-- The Start menu.
local MENU_WIDTH = 38
local MENU_MIN = 22
-- From this width on the vertical caption fits in the menu.
--
-- It was 26, and that turned out to be more than our panels ever are: the
-- caption was practically never shown, while on the classic reference frame
-- it is always there. The threshold is kept, but lowered to the width at
-- which the panel does not yet look squeezed.
local MENU_BANNER_AT = 18

-- ─── Start menu ──────────────────────────────────────────────────────────

local function title_of(item)
    local title = item.title
    if type(title) == "string" and title ~= "" then return title end
    return tostring(item.entry or "?")
end

local function order_of(item)
    return tonumber(item.order) or math.huge
end

local function new_node()
    return {names = {}, groups = {}, programs = {}, order = math.huge}
end

-- A menu folder is given by a path in `meta.group`, not by a separate entry:
-- a folder without programs is meaningless, and one declared separately
-- drifts away from its content when a module is removed. Deeper than three
-- levels the path collapses: in a terminal the fourth indent no longer reads.
-- The folder path arrives ALREADY PARSED — as a list of segments, not a
-- string.
--
-- This function used to parse it, and parsed it a SECOND time: the catalog
-- (`chicago.shell.programs:catalog`) had already done that, with
-- clipping by depth and by spaces, and put a table here. It was never a
-- string, so `type(item.group) == "string"` never fired once — the path came
-- out empty, the folder was not created, the program lay on the top level.
--
-- No failure, no trace: the program IS VISIBLE, just not where it was asked
-- to be. The same class as `id` instead of `action` in a hit, and as the two
-- style tables: two representations of one and the same thing, and the
-- divergence is silent.
--
-- There is no depth clipping of our own here any more either. It was a second
-- number next to `catalog.MAX_DEPTH`, and two numbers with one meaning will
-- one day be changed one at a time. Depth is limited by whoever parses the
-- path; the cascade is stopped by the screen width, and that limit is real.
local function place(root, index, item)
    local node = root
    local path: any = type(item.group) == "table" and item.group or {}
    local order = order_of(item)
    for _, part in ipairs(path) do
        local name = tostring(part)
        if name ~= "" then
            local child = node.groups[name]
            if not child then
                child = new_node()
                node.groups[name] = child
                node.names[#node.names + 1] = name
            end
            -- A folder takes the place of its earliest program: "Programs"
            -- is above "Settings" because that is how their items are
            -- placed, not by alphabet — the alphabet would put them the
            -- other way round. The same rule as in `catalog.tree`: two
            -- orders of one menu would drift apart silently.
            if order < child.order then child.order = order end
            node = child
        end
    end
    node.programs[#node.programs + 1] = {index = index, item = item}
end

-- The rows of one panel: folders and programs TOGETHER, by `order`; a folder
-- stands where its earliest program is. Folders used to always go first, and
-- "My Computer" could not be put above "Programs", as in the original. Between
-- equals — a folder before a program, then the alphabet. There are no indents
-- ON PURPOSE: nesting is shown by a separate panel, not by a shift to the
-- right. With indents the tree reads as a list, and that was no trifle — a
-- list does not show that a folder opens.
local function panel_lines(node)
    local lines = {}
    for _, name in ipairs(node.names) do
        lines[#lines + 1] = {kind = "group", text = name, order = node.groups[name].order}
    end
    for _, program in ipairs(node.programs) do
        lines[#lines + 1] = {
            kind = "item", index = program.index, item = program.item,
            text = title_of(program.item), order = order_of(program.item),
        }
    end
    table.sort(lines, function(left, right)
        if left.order ~= right.order then return left.order < right.order end
        if left.kind ~= right.kind then return left.kind == "group" end
        return left.text < right.text
    end)
    -- A separator is a property of the ROW, not of the program: it is asked
    -- for either by the program itself (`separator_before`, as with "Shut
    -- Down"), or by the previous one (`separator_after` — this is how "My
    -- Computer" is separated from the folders under it). A folder has
    -- nothing to ask with, so it is computed here.
    for index, line in ipairs(lines) do
        local own = line.item and line.item.separator_before
        local prev = lines[index - 1]
        local after = prev and prev.item and prev.item.separator_after
        line.separator_before = (own or after) and true or nil
    end
    return lines
end

-- The row's caption without style: needed twice — to measure the panel and to
-- draw it. Computing it in two places means one day measuring one thing and
-- drawing another.
local function line_text(line)
    if line.kind == "item" then
        local item = line.item
        -- Digits before the item WERE here and were removed on purpose.
        -- The original did not have them, and a person opening programs with
        -- the mouse reads a column of digits as the question "what are they
        -- for". They appeared not by design but because of a tool: the probe
        -- could not do the mouse, and there was no other way to open a window
        -- in a check. The tool's limitation leaked into the interface — the
        -- tool is fixed, the digits are gone.
        local icon = type(item.icon) == "string" and item.icon ~= "" and item.icon or glyphs.icons.unknown
        return " " .. icon .. " " .. line.text, ""
    end
    if line.kind == "group" then
        return " " .. glyphs.icons.folder .. " " .. line.text, glyphs.icons.submenu .. " "
    end
    if line.kind == "user" then
        return " " .. glyphs.icons.user .. " " .. tostring(line.text or ""), ""
    end
    return " " .. tostring(line.text or ""), ""
end

-- The Start menu: a cascade of panels, filled from the registry catalog.
--
-- `open` is the path of open folders from the root outwards, for example
-- {"Programs", "Accessories"}. The theme remembers nothing about what is open:
-- that is held by the compositor, and it also gets the ready path in the hit —
-- it only has to store it, without parsing the tree.
--
-- The hit map tells two actions apart, not one:
--   program — {row, from, to, index = <number in the passed array>}
--   folder  — {row, from, to, open = {…full path…}, level = k}
-- The program's number is in the PASSED array, not in display order: the same
-- number stands in the row as the accelerator, and they have nothing to drift
-- apart with.
-- `cursor` is the number of the highlighted row in the DEEPEST open panel,
-- from one. The menu does not store it: the theme draws a frame and remembers
-- nothing between frames; the compositor remembers — it also moves the cursor
-- with the arrows.
--
-- The highlighted row is marked in the hit map with the `cursor` field, and
-- this matters: the compositor does not recompute what is selected now, but
-- reads what is DRAWN. A second count would drift from the first, and Enter
-- would open a row other than the highlighted one.
--
-- Every hit has `level` and `slot` — the panel level and the row number in it.
-- By them the compositor clamps the cursor without knowing how the panels are
-- built.
-- profile_item(user) -> the catalog item behind the user row, or nil
--
-- `user` is the session's `{id, name, entry}`. With an `entry` (the window the
-- application named as the profile) the shell appends this item to the menu
-- catalog, and the layout puts it behind the user row instead of placing it
-- as a program: a click and Enter go through the compositor's ordinary
-- `items[hit.index]` path, which opens `entry` with `args`. No entry, no item:
-- the row stays a caption.
function menu_layout.profile_item(user: any): any
    if type(user) ~= "table" or type(user.name) ~= "string" or user.name == "" then return nil end
    if type(user.entry) ~= "string" or user.entry == "" then return nil end
    return {entry = user.entry, title = user.name, image = "user", group = {}, profile = true,
        args = {user_id = user.id}}
end
-- menu_layout(width, height, items, failure, open, cursor) -> layout
--
-- WHAT and WHERE, without a single paint. Taken out of painting for the same
-- reason as the explorer layout: there are now two painters — characters and
-- pixels — and "one table" now means the layout. Two backends each computing
-- the cascade their own way will drift apart silently, and a click will land
-- on the neighbouring item in one of the two modes.
--
-- Returns `{panels, hits, notice}`:
--
--   panels  the list of panels from the root outwards: x, y, w, h, the column
--           width, the width of the vertical caption, and the rows with their
--           look
--   hits    the hit map, as before
--   notice  the failure or empty-catalog panel, when there is no cascade at
--           all
function menu_layout.layout(width: any, height: any, items, failure, open, cursor: any, metrics: any): any
    local out: any = {panels = {}, hits = {}, notice = nil}
    local sizing: any = type(metrics) == "table" and metrics or {}
    local compact = sizing.compact == true
    local minimum = compact and 12 or MENU_MIN
    local padding = compact and 0 or 2
    local w, h = whole(width), whole(height)
    if w < 8 or h < 4 then return out end

    local catalog = type(items) == "table" and items or {}
    local bottom = h - math.max(1, whole(sizing.bottom or 1))
    local room = bottom - 2
    if room < 1 then return out end

    -- An icon's context menu: one panel at the anchor, a flat list without a
    -- banner, folders or hints. The items are the same tables as the
    -- catalog's; the caption is `label` (for "Open", `title` is the window
    -- title). The panel does not go off the screen: at the right and bottom
    -- edges it shifts inwards.
    local anchor: any = sizing.anchor
    if type(anchor) == "table" then
        local lines: any = {}
        for index, item in ipairs(catalog) do
            lines[#lines + 1] = {index = index, item = item,
                text = tostring(item.label or item.title or ""),
                separator_before = item.separator_before and true or nil,
                bold = item.bold and true or nil}
        end
        if #lines == 0 then return out end
        local widest = 0
        for _, line in ipairs(lines) do
            local size = cells(line.text) + 3
            if type(sizing.measure) == "function" then
                -- Level 0 is the context menu: no icon, the caption closer.
                size = whole(sizing.measure(line.text, 0, "context"))
            end
            if size > widest then widest = size end
        end
        local box_w = math.min(w, math.max(minimum, widest + 2))
        local span = math.max(1, whole(sizing.context_rows or 1))
        local box_h = #lines * span + padding
        local left = math.max(1, math.min(whole(anchor.x), w - box_w + 1))
        local top = whole(anchor.y)
        if top + box_h - 1 > bottom then top = math.max(1, bottom - box_h + 1) end
        local painted: any = {x = left, y = top, w = box_w, h = box_h, list_w = box_w - 2,
            banner = 0, level = 1, context = true, lines = {}}
        local at = whole(cursor)
        for index, line in ipairs(lines) do
            local row = top + (index - 1) * span + (compact and 0 or 1)
            local under_cursor = at > 0 and index == at
            painted.lines[#painted.lines + 1] = {
                kind = "item", text = " " .. line.text, tail = "", row = row, rows = span,
                label = line.text, entry = line.item.entry, image = line.item.image,
                separator_before = line.separator_before, bold = line.bold,
                selected = under_cursor, dim = false, banner_letter = " ",
            }
            out.hits[#out.hits + 1] = {
                row = row, bottom_row = span > 1 and row + span - 1 or nil,
                -- In pixels (`compact`) the frame is three pixels, not a
                -- cell, and the outermost cells are almost entirely content:
                -- the hit spans the whole panel width. In cells the outermost
                -- cells are the frame.
                from = compact and left or left + 1,
                to = compact and left + box_w - 1 or left + box_w - 2, index = index,
                level = 1, slot = index, cursor = under_cursor or nil,
            }
        end
        out.panels[1] = painted
        return out
    end

    -- A registry failure and an empty catalog must differ on screen: the same
    -- look sends the person looking for an error in their own application,
    -- where there is none. One panel is enough for both — there is nowhere
    -- for a cascade to come from here.
    if failure or #catalog == 0 then
        local box_w = math.min(MENU_WIDTH, math.max(MENU_MIN, w - 2))
        if box_w > w then box_w = w end
        local list_w = box_w - 2
        if list_w < 4 then return out end

        local body = {}
        if failure then
            body[#body + 1] = {text = " catalog not read:", alert = true}
            for _, piece in ipairs(wrap(tostring(failure), list_w - 2, 3)) do
                body[#body + 1] = {text = " " .. piece, alert = true}
            end
        else
            body[#body + 1] = {text = " no applications registered", dim = true}
        end
        if #body > room then for index = #body, room + 1, -1 do body[index] = nil end end

        out.notice = {x = 1, y = bottom - (#body + 2) + 1, w = box_w, h = #body + 2,
                      list_w = list_w, lines = body}
        return out
    end

    -- The profile item (`menu_layout.profile_item`) is not a program row:
    -- it stands behind the user row at the top of the root, so it is not
    -- placed in the tree, only remembered by its index in the catalog.
    local root = new_node()
    local profile_index: any = nil
    for index, item in ipairs(catalog) do
        if type(item) == "table" and item.profile == true then profile_index = index
        else place(root, index, item) end
    end

    -- The open levels. A path that no longer resolves (the folder was
    -- removed together with its module) is cut off silently: three panels
    -- cannot be shown instead of two, and there is nothing to complain about
    -- in a vanished folder.
    local path = type(open) == "table" and open or {}
    local levels: any = {root}
    local names = {}
    for _, name in ipairs(path) do
        local node = levels[#levels].groups[name]
        if not node then break end
        levels[#levels + 1] = node
        names[#names + 1] = name
    end

    local left, parent_row = 1, 0
    local deepest = #levels
    local at = whole(cursor)

    for level, node in ipairs(levels) do
        -- The row number inside the panel. Counted HERE, not by the index in
        -- the list of rows: hints and the "…N more" clipping also take up
        -- room as rows, and they cannot be selected.
        local slot = 0
        local lines: any = panel_lines(node)

        -- The logged-on user is the first row of the root, with an icon and
        -- a separator under it. Without a profile item in the catalog the
        -- row is NOT selectable: it has neither a hit nor a `slot` number,
        -- the cursor steps over it, and Enter on "the first row" still opens
        -- the first program. With one (the shell was told which window is
        -- the profile) it is a row like a program's: it carries the item's
        -- catalog index, takes slot 1 and a hit, and the compositor opens it
        -- the way it opens any program — `items[hit.index]`. Hints and
        -- clipping on a short screen are counted by the same `#lines`, so it
        -- takes up room honestly; on clipping it stays — the tail is cut.
        local user: any = sizing.user
        if level == 1 and type(user) == "table" and type(user.name) == "string" and user.name ~= "" then
            table.insert(lines, 1, {kind = "user", text = user.name, image = "user",
                index = profile_index, item = profile_index and catalog[profile_index] or nil})
            if lines[2] then lines[2].separator_before = true end
        end

        -- The panel width is by the longest caption, not by a constant: a
        -- cascade of three panels of equal width eats the screen, and a
        -- narrow panel clips the names, which are all there is in it.
        local widest = 0
        for _, line in ipairs(lines) do
            local text, tail = line_text(line)
            local size = cells(text) + cells(tail) + 1
            if type(sizing.measure) == "function" then
                -- The measure needs the level and the kind of the row: on
                -- the root the icon is 32 px, in a submenu 16, and a folder
                -- also has an arrow on the right. Without them the panel was
                -- computed for the worst case and an empty margin was left on
                -- the right.
                size = whole(sizing.measure(tostring(line.text or ""), level, line.kind))
            end
            if size > widest then widest = size end
        end

        local banner_w = 0
        if level == 1 and widest + 2 + 2 <= w and widest + 2 >= MENU_BANNER_AT then banner_w = 2 end
        local box_w = widest + banner_w + 2
        if box_w < minimum then box_w = minimum end
        if box_w > w - left + 1 then box_w = w - left + 1 end
        if box_w > w then box_w = w end
        local list_w = box_w - 2 - banner_w
        if list_w < 4 then break end

        local span = math.max(1, whole(level == 1 and sizing.root_rows or sizing.item_rows or 1))
        local capacity = math.max(1, room // span)
        if #lines > capacity then
            local last: any = lines[#lines]
            local footer = level == 1 and last.item and last.item.action == "quit" and last or nil
            local keep = math.max(0, capacity - (footer and 2 or 1))
            local hidden = #lines - keep - (footer and 1 or 0)
            for index = #lines, keep + 1, -1 do lines[index] = nil end
            if capacity > 1 or not footer then
                lines[#lines + 1] = {kind = "hint", text = "…" .. hidden .. " more"}
            end
            if footer then lines[#lines + 1] = footer end
        end

        local box_h = #lines * span + padding
        -- The root panel stands above Start; a submenu aligns its first row
        -- with the row of the folder that opened it.
        local top
        if level == 1 then
            top = bottom - box_h + 1
        else
            top = parent_row - (compact and 0 or 1)
            if top + box_h - 1 > bottom then top = bottom - box_h + 1 end
        end
        if top < 1 then top = 1 end

        local painted: any = {x = left, y = top, w = box_w, h = box_h,
                              list_w = list_w, banner = banner_w, level = level, lines = {}}

        for index, line in ipairs(lines) do
            local row = top + (index - 1) * span + (compact and 0 or 1)
            local text, tail = line_text(line)
            local opens = line.kind == "item" or (line.kind == "user" and line.index ~= nil)
            local selectable = opens or line.kind == "group"
            if selectable then slot = slot + 1 end
            local under_cursor = selectable and level == deepest and at > 0 and slot == at
            local expanded = line.kind == "group" and names[level] ~= nil
                and line.text == names[level]

            local letter = " "
            if banner_w > 0 then
                -- The caption reads bottom to top, as if rotated by 90°.
                -- The variable is NOT named `slot` on purpose: `slot` in this
                -- same function is the number of the selectable row, and one
                -- name for two different numbers will sooner or later be read
                -- as the wrong one.
                local banner = tostring(sizing.banner or ""):upper()
                local letter_at = #lines - index + 1
                if letter_at <= #banner then
                    letter = banner:sub(letter_at, letter_at)
                end
            end

            -- `label` and `text` are DIFFERENT things, and the difference is
            -- not cosmetic. `text` carries the icon as a character (`▢`, `▤`)
            -- and is good only for cells. The font has no geometric symbols:
            -- "a missing rune advances as a space", that is, in pixels there
            -- is emptiness in their place — exactly what came out on the very
            -- first screenshot of the menu. The pixel backend draws the icon
            -- with a primitive and takes `label`.
            painted.lines[#painted.lines + 1] = {
                kind = line.kind, text = text, tail = tail, row = row, rows = span,
                label = tostring(line.text or ""),
                entry = line.item and line.item.entry,
                image = line.item and line.item.image or line.image,
                separator_before = line.separator_before,
                arrow = line.kind == "group",
                -- Folder labels have the same weight as applications in the original;
                -- the user name at the top is bold, like a caption.
                bold = line.kind == "user" or nil,
                selected = under_cursor or expanded,
                dim = line.kind == "hint", banner_letter = letter,
            }

            -- In pixels the frame is three pixels, not a cell: the hit spans
            -- the whole list width, including the outermost cells (see the
            -- context menu).
            local hit_from = compact and left + banner_w or left + 1 + banner_w
            local hit_to = compact and left + box_w - 1 or left + box_w - 2
            if opens then
                out.hits[#out.hits + 1] = {
                    row = row, bottom_row = span > 1 and row + span - 1 or nil, from = hit_from,
                    to = hit_to, index = line.index,
                    level = level, slot = slot, cursor = under_cursor or nil,
                }
            elseif line.kind == "group" then
                local target = {}
                for step = 1, level - 1 do target[step] = names[step] end
                target[level] = line.text
                out.hits[#out.hits + 1] = {
                    row = row, bottom_row = span > 1 and row + span - 1 or nil, from = hit_from,
                    to = hit_to, open = target,
                    level = level, slot = slot, cursor = under_cursor or nil,
                }
                if expanded then parent_row = row end
            end
        end

        out.panels[#out.panels + 1] = painted

        -- The next panel stands to the right of this one.
        left = left + box_w
        if left > w then break end
    end

    return out
end

return menu_layout
