-- The shell theme: the Windows 95 look under the theme contract (FR-002,
-- section 4).
--
-- There is not a single call here that goes out to the runtime: only strings
-- and arithmetic. That is why the file is a library, not a process, and it can
-- be called from any painting and measured in a test without a terminal.
--
-- Four rules everything else stands on:
--
--   * The window frame and the window content are put on the canvas
--     SEPARATELY. Merging them into one string means making clipping
--     decisions that can no longer be made: the content arrives as finished
--     lines of someone else's process.
--   * Width is counted in CELLS. `#string` counts bytes and does not see SGR:
--     on Cyrillic it lies twofold, on styled text threefold.
--   * Both painting and the mouse hit are computed from ONE table. A separate
--     formula for the click will one day drift from the painting, and "close"
--     will end up one character to the left of where it looks. Hence also the
--     rule for desktop icons: a painted icon MUST return its hit, otherwise it
--     is dead, and that is not visible on screen.
--   * How much room the window frame takes from the program is declared by
--     `window_insets()`, not computed on the spot by whoever needed it. The
--     compositor sets up the viewport and shifts the cursor by these same
--     numbers; two notions of the frame thickness drift apart by one row, and
--     the extra row of the program is painted over the bottom edge.
--
-- Volume is given by a one-cell edge: light on top and on the left, dark at
-- the bottom and on the right. Swap them and you get a sunken detail with the
-- same code; both the pressed button and the sunken field rest on this.

local tty = require("tty")

local glyphs = require("glyphs")
local icons = require("icons")
local palette = require("palette")
local widgets = require("widgets")
local menu_layout = require("menu_layout")

-- The color set. Exact RGB by default; `palette.basic` is the same palette as
-- indexes 0–15 for a terminal without truecolor, a one-line swap.
local color = palette.active

local chrome = {}

-- Short names for the primitives that know nothing about the screen. Declared
-- HERE, before the first use, and this is not a matter of taste: a local
-- variable is visible only below its declaration, and a reference above it is
-- silently read as a global — that is, as nil. While these lines sat in the
-- middle of the file, `chrome.title_button_at` failed on its very first call
-- with "attempt to call a non-function object", and did not fail earlier only
-- because nobody called it.
local whole = widgets.whole
local cells = widgets.cells
local clip = widgets.clip
local fit = widgets.fit
local bezel = widgets.bezel
local edge_top = widgets.edge_top
local edge_bottom = widgets.edge_bottom
local panel = widgets.panel
local wrap = icons.wrap

-- ─── Title buttons ───────────────────────────────────────────────────────
--
-- Exactly three cells per button: the compositor finds the button under a
-- point by dividing the offset by three. The width here and the step there are
-- one and the same number, and they must not drift apart.
-- The button step in cells. Exposed, because the set of buttons is no longer
-- one: a dialog has two, a window three, and "divide the offset by three" has
-- stopped being true. Computing the step on the spot means starting a second
-- notion of the button width, which will drift from this one on the first
-- edit of the set.
chrome.BUTTON_STEP = 3

chrome.BUTTONS = {
    {id = "minimize", glyph = glyphs.buttons.minimize},
    {id = "maximize", glyph = glyphs.buttons.maximize},
    {id = "close",    glyph = glyphs.buttons.close},
}

-- A dialog is neither minimized nor maximized: it has no button on the
-- taskbar, and a minimized dialog would have nothing to get it back with. On
-- the reference its title bar has "what's this?" and "close".
chrome.DIALOG_BUTTONS = {
    {id = "help",  glyph = glyphs.buttons.help},
    {id = "close", glyph = glyphs.buttons.close},
}

-- A tool window is opened from another one and closed when it is no longer
-- needed. There is nowhere to minimize it to — it is not on the taskbar
-- either — and there is no reason to maximize a tool palette to the whole
-- screen.
chrome.TOOL_BUTTONS = {
    {id = "close", glyph = glyphs.buttons.close},
}

-- Sets by window type. As a table, not a chain of ifs: a third type is added
-- as a line, not a branch, and "which set does tool have" is read in one
-- place.
--
-- The values are the same ones the base declares
-- (`butschster.tui_desktop.desktop:programs`). A type that is not here is
-- `app`: an unknown value is no reason not to draw the window, and that is
-- decided by the base, not the theme.
chrome.BUTTON_SETS = {
    app = chrome.BUTTONS,
    dialog = chrome.DIALOG_BUTTONS,
    tool = chrome.TOOL_BUTTONS,
}

chrome.BUTTONS_WIDTH = #chrome.BUTTONS * chrome.BUTTON_STEP

-- Which set of buttons this window has and how much room it takes. ONE table
-- for both painting and the hit — otherwise "close" will one day end up one
-- character to the left of where it looks, and a dialog will get three
-- buttons painted, of which two can be pressed.
--
-- What is read is `window_type` — the field the base's compositor puts in.
-- `dialog` as a boolean flag is no longer read: two names for one and the
-- same thing drift apart on the first edit, and a window that declared itself
-- a dialog both ways at once would look different depending on which read
-- happened first.
function chrome.buttons_for(window)
    local spec: any = type(window) == "table" and window or {}
    local kind: any = spec.window_type
    local set: any = type(kind) == "string" and chrome.BUTTON_SETS[kind] or nil
    if not set then set = chrome.BUTTONS end
    -- A fixed-size window (`meta.resizable: false`) is not maximized, and it
    -- has no "maximize" button — like the Windows 95 calculator. The flag is
    -- put in by the base's compositor from the entry; the filter is here, and
    -- not a third set in BUTTON_SETS: both ordinary windows and tool windows
    -- fix their size, and starting a set per combination would mean
    -- multiplying a table that must stay one.
    if spec.resizable == false then
        local kept = {}
        for _, button in ipairs(set) do
            if button.id ~= "maximize" then kept[#kept + 1] = button end
        end
        set = kept
    end
    return set, #set * chrome.BUTTON_STEP
end

-- The title button under a point, or nil.
--
-- It lives in the theme, not in the compositor, on purpose: after the title
-- moved inside the frame, its row is `y + 1`, not `y`, and the right edge of
-- the buttons stands off the window edge by the right inset. The theme knows
-- both numbers; repeated in the compositor, they drift apart silently, and a
-- miss on a button looks like "the click did not work".
function chrome.title_button_at(window, x: any, y: any)
    local spec: any = type(window) == "table" and window or {}
    local wx, wy = whole(spec.x), whole(spec.y)
    local ww = whole(spec.w)
    local inset = chrome.window_insets(spec)
    local set, width = chrome.buttons_for(spec)

    if whole(y) ~= wy + 1 then return nil end
    local span = ww - 2
    if span < width + 6 then return nil end

    local last = wx + ww - inset.right          -- the last cell before the right edge
    local from = last - width + 1
    local point = whole(x)
    if point < from or point > last then return nil end

    local slot = (point - from) // chrome.BUTTON_STEP + 1
    local button = set[slot]
    return button and button.id or nil
end

-- The window's client area is sunken, as on the reference: a dark edge on top
-- and on the left, a light one at the bottom and on the right. It costs the
-- program one row and two columns beyond the raised frame. It is switched off
-- here with one line — then the frame stays raised, and the content lies
-- straight on the window's face.
local SUNKEN_CLIENT = true

-- A taskbar button. Fewer than seven cells is two edges and three letters of
-- the name: a button by which the window cannot be recognised takes up room
-- for nothing.
local TASK_MAX = 20
local TASK_MIN = 7
-- Fewer than six cells for the status line and it is not drawn at all: three
-- letters and an ellipsis read as garbage, not as a message. One number for
-- both themes.
local STATUS_LEAST = 6

-- A desktop icon is drawn by the `icons` library — the same one the "My
-- Computer" window draws its icons with. Here there is only a redirect: two
-- identical icons drawn by different code will drift apart in look, not in a
-- failure.
local ICON_GRID: any = icons.grid()

function chrome.icon_grid()
    return icons.grid()
end

function chrome.caption_lines(title, room: any)
    return icons.caption_lines(title, room)
end

chrome.ICON_W = ICON_GRID.w
chrome.ICON_H = ICON_GRID.h
chrome.ICON_LEFT = ICON_GRID.left

-- The caption along the Start menu. This is NOT Windows: the shell draws the
-- wippy stand, and the banner names it. Ten characters, like the original —
-- exactly as many rows as the panel gives on a short screen.
--
-- One string for both themes: the pixel theme sets it in a font and lays it
-- down rotated as a whole, the cell theme writes it in capitals, one letter
-- per panel row. Both read it from here while painting: a copy of its own in
-- the pixel theme had already drifted from this one in letter case — the same
-- way the two style tables once drifted apart.
chrome.MENU_BANNER = "Wippy 2026"

-- Who is logged on — for the top row of Start. One table for both themes: the
-- pixel one computes the layout with the same `menu_layout` and reads from
-- here too, and the value is raised once, at logon (`use_user`), and lives as
-- long as the shell session itself — the identity is fixed at logon. Without
-- logon (the shell started under its own actor) there is no row at all: a
-- desktop under a service actor, signed with somebody's name, would look like
-- someone else's logon.
chrome.session = {user = nil}

-- use_user(user) — user = {id, name, entry?}, or nil to clear it. `entry` is
-- the profile window the application named (BUTSCHSTER_WINDOWS_PROFILE_ENTRY):
-- with it the user row at the top of Start opens that window; without it the
-- row is a caption.
function chrome.use_user(user: any)
    if type(user) == "table" and type(user.name) == "string" and user.name ~= "" then
        local entry = type(user.entry) == "string" and user.entry ~= "" and user.entry or nil
        chrome.session.user = {id = user.id, name = user.name, entry = entry}
    else
        chrome.session.user = nil
    end
end

-- rename_user(name) -> whether the name changed
--
-- The account was renamed while the shell runs (the profile window writes the
-- full name, the application answers it through BUTSCHSTER_WINDOWS_USER_FUNC
-- on `desktop.refresh`). The identity stays what it was at logon: the id and
-- the profile entry are kept, only the name moves — and with it the pixel
-- menu's memo key, so the row repaints. Nobody logged on, nobody to rename.
function chrome.rename_user(name: any): boolean
    local user: any = chrome.session.user
    if type(user) ~= "table" or type(name) ~= "string" or name == "" or name == user.name then return false end
    chrome.use_user({id = user.id, name = name, entry = user.entry})
    return true
end

-- profile_item(user) — the catalog item behind the user row, for the shell's
-- menu catalog; the rule is the layout's (`menu_layout.profile_item`).
function chrome.profile_item(user: any): any
    return menu_layout.profile_item(user)
end

local START_LABEL = " " .. glyphs.icons.start .. " Start "

-- The styles are shared with `widgets`, not our own. An own copy WAS here and
-- drifted: the teal desktop lived in it, which the neighbours did not have,
-- and the pixel theme crashed on it in the very first live run. Two tables of
-- one and the same thing drift apart exactly on the keys both of them rarely
-- need.
local styles = widgets.styles

-- ─── Shared measures and details ─────────────────────────────────────────
--
-- Everything that knows nothing about the screen lives in `widgets` and is
-- drawn by the same code in a window. Short names for them are declared at
-- the top of the file.

chrome.clip = clip
chrome.panel = panel
chrome.field = widgets.field
chrome.accel = widgets.accel
chrome.button = widgets.button
chrome.button_width = widgets.button_width
chrome.etched = widgets.etched
chrome.tabs = widgets.tabs

-- use_desktop(hex) — the desktop color from "Display Properties". One point
-- for all representations: the palette (the pixels read it on every icon
-- paint), the cell styles here, in the widgets and in the icons. The color's
-- form is checked by the caller; here only `#rrggbb` is accepted, anything
-- else is silently not accepted and returns false — a desktop with a broken
-- color is worse than the previous one.
function chrome.use_desktop(hex: any): boolean
    local value = tostring(hex or "")
    if not value:match("^#%x%x%x%x%x%x$") then return false end
    -- `widgets.use_desktop` rebuilds the desktop styles in the very table the
    -- theme paints with: the theme no longer keeps a copy of its own.
    widgets.use_desktop(value)
    icons.use_desktop()
    return true
end

-- use_pattern(rows) — the desktop pattern from "Display Properties": eight
-- bit rows (`butschster.windows.display:patterns`), or nil for none. The
-- pixel theme tiles it over the desktop color. Cells have no pattern: an 8×8
-- pixel tile has no place in a character cell, and a dither character on every
-- desktop cell would read as noise and cost every cell a styled character.
-- Anything but eight bytes is not accepted and returns false.
chrome.pattern = nil
function chrome.use_pattern(rows: any): boolean
    if rows == nil then
        chrome.pattern = nil
        return true
    end
    if type(rows) ~= "table" or #rows ~= 8 then return false end
    local copy: any = {}
    for index = 1, 8 do
        local byte = math.tointeger(rows[index])
        if byte == nil or byte < 0 or byte > 255 then return false end
        copy[index] = byte
    end
    chrome.pattern = copy
    return true
end

-- use_wallpaper(file, mode) — the desktop wallpaper from "Display
-- Properties": a picture of the wallpaper folder (`wallpaper_*`, read by
-- `images.wallpaper`) and "tile" or "center"; nil for none. Pixels only, like
-- the pattern, and for the same reason. Anything else is not accepted and
-- returns false.
chrome.wallpaper = nil
function chrome.use_wallpaper(file: any, mode: any): boolean
    if file == nil then
        chrome.wallpaper = nil
        return true
    end
    if type(file) ~= "string" or not file:match("^wallpaper_[%w_]+$") then return false end
    if mode ~= "tile" and mode ~= "center" then return false end
    chrome.wallpaper = {file = file, mode = mode}
    return true
end

-- ─── Chrome geometry ─────────────────────────────────────────────────────

-- The taskbar takes the bottom row and only that. The chrome takes nothing on
-- top: Windows 95 has no window strip, its role is played by the buttons on
-- the taskbar.
function chrome.layout(width: any, height: any)
    return {top = 0, bottom = 1}
end

-- How many cells the window frame takes from the program on each side.
--
-- On top, two rows — the raised edge and the title bar under it: on the
-- reference the title lies INSIDE the frame rather than replacing its top, and
-- without this row the window reads as a panel with text. With the sunken
-- client area it is three on top and two at the bottom and on the sides.
--
-- The compositor must compute the viewport size and the cursor offset from
-- these numbers. Hence also the lower bound of the window size: a window with
-- not a single row of content left is a `tty.viewport` of zero height, that
-- is, a failure on opening.
function chrome.window_insets(window)
    -- The window's menu bar is NO LONGER counted here. The compositor gives
    -- the window the whole rectangle inside the frame, and what is drawn
    -- there is the window's business: every window has its own menu items,
    -- and "6 objects" is recounted on every folder opening. Were the theme to
    -- draw them, a channel "the window tells the theme its rows" would be
    -- needed, that is, the compositor would start knowing about the insides
    -- of someone else's window.
    if SUNKEN_CLIENT then
        return {top = 3, bottom = 2, left = 2, right = 2}
    end
    return {top = 2, bottom = 1, left = 1, right = 1}
end

-- ─── Desktop ─────────────────────────────────────────────────────────────

-- desktop_spot(item, top, bottom, width, drawn) -> x, y | nil
--
-- Where a desktop icon stands — one clipping rule for both themes. The layout
-- coordinate is clamped into the desk: an icon stored left of the edge or
-- above the top of the desk (the layout was written on another screen) moves
-- to the edge instead of vanishing. Not drawn is an icon right of the screen
-- and one without enough rows above the bottom of the desk: a row that
-- climbed onto the taskbar would stay there. The cell theme used to clamp
-- while the pixel theme silently skipped — the same icon was visible in one
-- mode and gone in the other.
function chrome.desktop_spot(item: any, top: any, bottom: any, width: any, drawn: any): (any, any)
    local x = math.max(1, whole(item.x))
    local y = math.max(math.max(1, whole(top)), whole(item.y))
    if x > whole(width) or y + whole(drawn) - 1 > whole(bottom) then return nil, nil end
    return x, y
end

-- desktop_hit(item, row, from, to) -> the hit of a desktop icon on one row
--
-- One table for both themes: the compositor decides from it what to open and
-- which items the context menu offers. A field one of two copies forgot
-- would vanish silently — without `properties` the Properties item goes.
function chrome.desktop_hit(item: any, row: any, from: any, to: any): any
    return {
        row = row, from = from, to = to,
        id = item.id, kind = item.kind,
        broken = item.broken and true or false,
        entry = item.entry, title = item.title,
        w = tonumber(item.w), h = tonumber(item.h), args = item.args,
        properties = item.properties,
    }
end

-- The desktop: the fill, the layout's icons and the hits on them.
--
-- The whole canvas is filled: the taskbar and windows will lie on top, and an
-- unfilled strip under the taskbar would differ in color for one frame on a
-- resize.
--
-- The theme neither stores nor invents the layout — it arrives in
-- `state.items`. Every painted icon returns a hit; a double click opens it, a
-- single click selects it, and that is decided by the compositor, not the
-- theme.
function chrome.fill(canvas, width: any, height: any, state)
    canvas:clear(styles.desktop:render(" "))

    local hits = {}
    local w, h = whole(width), whole(height)
    local desk = type(state) == "table" and state or {}
    if w < 4 or h < 2 then return hits end

    local top = whole(desk.top)
    if top < 1 then top = 1 end
    local bottom = whole(desk.bottom)
    if bottom < 1 or bottom > h then bottom = h end

    -- "The layout was not read" and "the desktop is empty" are different
    -- statements. An empty desktop is silent; a failure names the reason,
    -- otherwise the person will go looking for missing shortcuts they never
    -- lost.
    if desk.failure then
        local box_w = math.min(48, w - 4)
        if box_w >= 12 then
            local body = {fit(styles.alert, " layout not read:", box_w - 2)}
            local reason = wrap(tostring(desk.failure), box_w - 4, 3)
            for _, piece in ipairs(reason) do
                body[#body + 1] = fit(styles.face, " " .. piece, box_w - 2)
            end
            panel(canvas, 3, top + 1, box_w, body, false)
        end
        return hits
    end

    local selected = desk.selected

    for _, item in ipairs(type(desk.items) == "table" and desk.items or {}) do
        local x, y = chrome.desktop_spot(item, top, bottom, w, ICON_GRID.drawn)
        local drawn = nil
        if x then
            drawn = icons.cell(canvas, x, y, item, {
                surface = "desktop",
                selected = selected ~= nil and item.id == selected,
                room = math.min(whole(ICON_GRID.w), w - x + 1),
            })
        end

        if drawn then
            -- A hit on every row of the item: people click both the picture
            -- and the caption, including its second line. The rectangle is
            -- taken from whoever drew it — a formula of our own would drift
            -- from the drawing.
            for row = drawn.top, drawn.bottom do
                hits[#hits + 1] = chrome.desktop_hit(item, row, drawn.from, drawn.to)
            end
        end
    end

    return hits
end

-- ─── Window ──────────────────────────────────────────────────────────────

-- The title bar: runs across the width of the INNER area, not touching the
-- edges. Returns a string of exactly `span` cells.
local function title_bar(title, span: any, focused, window)
    local width = whole(span)
    if width <= 0 then return "" end

    local bar = focused and styles.title or styles.title_idle

    -- The set is taken from the same `buttons_for` as the hit. Always drawing
    -- three while pressing by the type's set means drawing a "minimize" on a
    -- dialog that silently does not work; that is exactly why the window
    -- came here, and not just its name.
    local set, set_width = chrome.buttons_for(window)

    -- The buttons give way to the name: a title without a name does not say
    -- which window this is, and it can also be closed from the taskbar.
    local buttons = width >= set_width + 6 and set_width or 0
    local room = width - buttons - 2
    local name = room > 0 and clip(title or "", room) or ""

    local parts = {bar:render(" " .. name)}
    local used = 1 + cells(name)

    local tail = width - used - buttons
    if tail > 0 then parts[#parts + 1] = bar:render(string.rep(" ", tail)) end

    if buttons > 0 then
        for _, button in ipairs(set) do
            -- A button is the same raised detail as everything else: a light
            -- edge on the left, a dark one on the right. Three cells each.
            parts[#parts + 1] = bezel(styles.face:render(button.glyph), false)
        end
    end

    return table.concat(parts)
end

chrome.title_bar = title_bar

-- The whole window: the raised frame, the title inside it, the sunken client
-- area and the content.
--
-- `rows` is an array of lines as viewport:snapshot() returns it. It is shared
-- and immutable, so it is put as is: put_rows clips to the width itself.
-- PTY windows need stable defaults through SGR 0/39/49, independent of the
-- outer terminal theme. Explicit application colors remain authoritative.
local console_colors = {foreground = color.console_text, background = color.console_bg}
function chrome.content_colors(window)
    if window.entry == "butschster.tui_desktop.desktop:window_pty" then return console_colors end
    return nil
end

function chrome.window(canvas, window, focused)
    local hits = {}
    local x, y = whole(window.x), whole(window.y)
    local w, h = whole(window.w), whole(window.h)
    local inset = chrome.window_insets(window)
    if w < inset.left + inset.right + 1 or h < inset.top + inset.bottom + 1 then return hits end

    -- The raised window frame.
    canvas:put(x, y, edge_top(w, false), w)
    canvas:put(x, y + 1, bezel(title_bar(window.title, w - 2, focused, window), false), w)
    local blank = bezel(styles.face:render(string.rep(" ", w - 2)), false)
    for row = 2, h - 2 do
        canvas:put(x, y + row, blank, w)
    end
    canvas:put(x, y + h - 1, edge_bottom(w, false), w)

    -- The sunken client area inside it.
    if SUNKEN_CLIENT then
        widgets.field(canvas, x + 1, y + 2, w - 2, h - 3)
    end

    -- The content is put separately and clipped to the frame height. Usually
    -- the window's viewport is made exactly to fit it, but at the moment of a
    -- resize the frame arrives from the previous geometry: `put_rows` keeps
    -- the bound of the CANVAS, not of the frame, so an extra row would be
    -- painted over the bottom edge and outside the window. That reads as a
    -- broken frame, not as a lagging frame.
    local defaults = chrome.content_colors(window)
    if defaults then
        local width = w - inset.left - inset.right
        local blank = styles.console:render(string.rep(" ", width))
        for row = inset.top, h - inset.bottom - 1 do
            canvas:put(x + inset.left, y + row, blank, width)
        end
    end
    if window.rows then
        local room = h - inset.top - inset.bottom
        local body = window.rows
        if #body > room then
            body = {}
            for row = 1, room do body[row] = window.rows[row] end
        end
        canvas:put_rows(x + inset.left, y + inset.top, body, w - inset.left - inset.right, defaults)
    end

    return hits
end

-- ─── Taskbar ─────────────────────────────────────────────────────────────

-- The taskbar: Start on the left, the buttons of open windows, the clock on
-- the right.
--
-- Returns the hit map — by it the compositor finds what a click landed on:
-- {row, from, to, action = "menu"} for Start and {row, from, to, id} for a
-- window button. What to do with a hit is decided by the compositor: raising
-- a window and restoring a minimized one is its job, not the theme's.
-- taskbar_layout(width, windows, metrics) -> {start, tasks, status?, clock?}
--
-- The taskbar layout in cells — ONE for both themes. The measures differ per
-- theme and come as a parameter, as with `menu_layout`; the rules are shared:
--
--   * Start on the left, the clock at the right edge, window buttons between;
--   * when it is tight, window buttons go FIRST: Start and the clock stay as
--     the only sign that the shell is alive, and the list of windows is also
--     reachable with alt+tab;
--   * the room is shared evenly between buttons within `task_min..task_max`;
--     a button narrower than `task_min` is not placed — it names no window;
--   * the status line takes what is left, if that is at least `STATUS_LEAST`
--     cells and a window is open.
--
-- `metrics`: `start` — the width of Start; `gap` — the gap after it;
-- `task_min`, `task_max`; `clock` — the clock width (0 — no clock) and
-- `clock_narrow` — the fallback when the first does not fit; `clock_gap` —
-- the gap before the notification area; `tray` — the widths of the tray
-- items, in their order.
--
-- The notification area is the tray items plus the clock, one block at the
-- right edge, as in Windows 95. Tray items are reserved before the window
-- buttons and the status, so those give way first. An item that does not
-- fit beside Start and the clock is dropped; the others keep their order.
-- `plan.tray` is `{{from, to, index}}`, `index` pointing into `metrics.tray`.
--
-- Computed in two places, the layout drifted apart: in cells a button shared
-- the room, in pixels it was 16 wide and stopped at `w - 10`, and the clock
-- started at `w - 8` — three rules written as three numbers in one theme.
function chrome.taskbar_layout(width: any, windows: any, metrics: any): any
    local w = whole(width)
    local m: any = type(metrics) == "table" and metrics or {}
    local task_min = math.max(1, whole(m.task_min or TASK_MIN))
    local task_max = math.max(task_min, whole(m.task_max or TASK_MAX))
    local gap, clock_gap = whole(m.gap), whole(m.clock_gap)
    local plan: any = {tasks = {}}
    local used = math.min(w, math.max(1, whole(m.start)))
    plan.start = {from = 1, to = used}

    local clock = 0
    for _, want in ipairs({whole(m.clock), whole(m.clock_narrow)}) do
        if clock == 0 and want > 0 and used + clock_gap + want <= w then clock = want end
    end
    local tray_slots: any = {}
    local tray_total = 0
    local budget = w - used - clock_gap - clock
    for index, want in ipairs(type(m.tray) == "table" and m.tray or {}) do
        local span = whole(want)
        if span > 0 and tray_total + span <= budget then
            tray_slots[#tray_slots + 1] = {index = index, span = span}
            tray_total = tray_total + span
        end
    end
    local area = clock + tray_total
    local reserve = area > 0 and area + clock_gap or 0

    local list: any = type(windows) == "table" and windows or {}
    local room = w - used - reserve
    if #list > 0 and room >= task_min + gap then
        used, room = used + gap, room - gap
        local share = math.max(task_min, math.min(task_max, room // #list))
        for _, window in ipairs(list) do
            local span = math.min(share, room)
            if span < task_min then break end
            plan.tasks[#plan.tasks + 1] = {from = used + 1, to = used + span, id = window.id, window = window}
            used, room = used + span, room - span
        end
    end

    -- What is left is the notice room: "could not open: …" is shown there,
    -- and it happens exactly when no window is open yet, so an empty taskbar
    -- keeps the room too. The compositor's key hint never goes there (owner's
    -- rule, 2026-09-11): both themes draw `notice` and ignore `status`.
    local rest = w - used - reserve
    if rest >= STATUS_LEAST then plan.status = {from = used + 1, to = used + rest} end
    if clock > 0 then plan.clock = {from = w - clock + 1, to = w} end
    plan.tray = {}
    local at = w - clock - tray_total
    for _, slot in ipairs(tray_slots) do
        plan.tray[#plan.tray + 1] = {from = at + 1, to = at + slot.span, index = slot.index}
        at = at + slot.span
    end
    return plan
end

function chrome.bars(canvas, width: any, height: any, state)
    local hits = {}
    local w, h = whole(width), whole(height)
    if w < 1 or h < 1 then return hits end

    local bar = type(state) == "table" and state or {}
    local row = h

    -- Start. An open menu keeps the button pressed: otherwise the screen
    -- cannot tell whether this is the menu or a window that popped up above
    -- the taskbar.
    local pressed = bar.menu_open and true or false
    local face = pressed and styles.face_bold or styles.face
    local label = START_LABEL
    if w < cells(START_LABEL) + 2 + TASK_MIN then label = glyphs.icons.start end
    local boxed = cells(label) + 2 <= w

    -- The sunken clock field opens the window the host declared. When it
    -- does not fit with its bevels, the clock goes without them.
    local clock = type(bar.clock) == "string" and bar.clock or ""
    local padded = " " .. clock .. " "
    -- Tray items are captions with a space on each side, left of the clock;
    -- the compositor sends them as `{key, text, entry, icon, image}`. In
    -- cells the picture is `icon` — one character before the caption.
    local tray: any = type(bar.tray) == "table" and bar.tray or {}
    local tray_captions = {}
    local tray_widths = {}
    for index, item in ipairs(tray) do
        local icon = type(item.icon) == "string" and item.icon ~= "" and (item.icon .. " ") or ""
        tray_captions[index] = " " .. icon .. tostring(item.text or "")
        tray_widths[index] = cells(tray_captions[index]) + 1
    end
    local plan = chrome.taskbar_layout(w, bar.windows, {
        start = boxed and cells(label) + 2 or 1, gap = 1,
        task_min = TASK_MIN, task_max = TASK_MAX,
        clock = clock ~= "" and cells(padded) + 2 or 0,
        clock_narrow = clock ~= "" and cells(clock) or 0,
        tray = tray_widths,
    })

    local parts: any = {boxed and bezel(face:render(label), pressed) or face:render(glyphs.icons.start)}
    hits[#hits + 1] = {row = row, from = plan.start.from, to = plan.start.to, action = "menu"}
    local used = plan.start.to
    local function pad(upto: any)
        if whole(upto) > used then
            parts[#parts + 1] = styles.face:render(string.rep(" ", whole(upto) - used))
            used = whole(upto)
        end
    end

    for _, entry in ipairs(plan.tasks) do
        local task: any = entry
        local window: any = task.window
        local span = task.to - task.from + 1
        pad(task.from - 1)
        local active = bar.focused_id ~= nil and window.id == bar.focused_id
        -- A minimized window gets a dimmed caption. Nothing formally asks
        -- for it, but otherwise "raise" and "restore" look the same on
        -- screen, and they are different expectations of one click.
        local face_style = styles.face
        if active then face_style = styles.face_bold
        elseif window.minimized then face_style = styles.face_dim end

        -- A narrow button has no icon: it is the same for every window and
        -- takes two cells from the name the window is recognised by.
        local body = " " .. tostring(window.title or "?")
        if span >= TASK_MIN + 5 then
            local icon = type(window.icon) == "string" and window.icon or glyphs.icons.program
            body = " " .. icon .. " " .. tostring(window.title or "?")
        end
        parts[#parts + 1] = bezel(fit(face_style, body, span - 2), active)
        hits[#hits + 1] = {row = row, from = task.from, to = task.to, id = window.id}
        used = task.to
    end

    -- The notice takes what is left. It no longer has a row of its own —
    -- the taskbar took the only bottom one — and throwing it away would mean
    -- losing messages like "could not open: …", which are shown nowhere
    -- else. Only `notice`: `status` used to carry the key hint, and Windows
    -- 95 has no such text on the taskbar.
    local notice = type(bar.notice) == "string" and bar.notice or ""
    if notice ~= "" and plan.status then
        pad(plan.status.from - 1)
        parts[#parts + 1] = fit(styles.face_dim, " " .. notice, plan.status.to - plan.status.from + 1)
        used = plan.status.to
    end

    -- A click on a tray item opens (or raises) the window it names, the same
    -- way as the clock; an item without `entry` is only a caption.
    for _, entry in ipairs(plan.tray) do
        local slot: any = entry
        local item: any = tray[slot.index]
        pad(slot.from - 1)
        parts[#parts + 1] = fit(styles.face, tray_captions[slot.index], slot.to - slot.from + 1)
        if type(item.entry) == "string" and item.entry ~= "" then
            hits[#hits + 1] = {row = row, from = slot.from, to = slot.to, entry = item.entry}
        end
        used = slot.to
    end

    pad(plan.clock and plan.clock.from - 1 or w)
    if plan.clock then
        local span = plan.clock.to - plan.clock.from + 1
        parts[#parts + 1] = span == cells(padded) + 2 and bezel(styles.face:render(padded), true)
            or styles.face:render(clock)
        if chrome.clock_entry then
            hits[#hits + 1] = {row = row, from = plan.clock.from, to = plan.clock.to,
                -- There is no title here on purpose: the window's entry names
                -- it, and "Clock" over "Date and Time" would read as a
                -- different window.
                entry = chrome.clock_entry}
        end
    end

    canvas:put(1, row, table.concat(parts), w)
    return hits
end

-- ─── Start menu ──────────────────────────────────────────────────────────
--
-- The cascade layout lives in `butschster.windows.shell:menu_layout`: one pure
-- function for both themes, no painting. `chrome.menu_layout` stays as a thin
-- alias — the callers and the tests use it — and it is also where the banner
-- enters the layout: the text is branding and lives here with the theme, and
-- it is read at CALL time, so a change to `chrome.MENU_BANNER` reaches both
-- themes (the layout cannot read `chrome` itself: `chrome` imports it).
function chrome.menu_layout(width: any, height: any, items, failure, open, cursor: any, metrics: any): any
    local sizing: any = {}
    for key, value in pairs(type(metrics) == "table" and metrics or {}) do sizing[key] = value end
    if sizing.banner == nil then sizing.banner = chrome.MENU_BANNER end
    return menu_layout.layout(width, height, items, failure, open, cursor, sizing)
end

function chrome.menu(canvas, width: any, height: any, items, failure, open, cursor: any, anchor: any)
    local shown = chrome.menu_layout(width, height, items, failure, open, cursor,
        {anchor = type(anchor) == "table" and anchor or nil, user = chrome.session.user})

    if shown.notice then
        local body = {}
        for _, line in ipairs(shown.notice.lines) do
            local style = line.alert and styles.alert or styles.face_dim
            body[#body + 1] = fit(style, line.text, shown.notice.list_w)
        end
        panel(canvas, shown.notice.x, shown.notice.y, shown.notice.w, body, false)
        return shown.hits
    end

    for _, entry in ipairs(shown.panels) do
        local box: any = entry
        local body = {}
        for _, item in ipairs(box.lines) do
            local line: any = item
            local parts = {}
            if box.banner > 0 then
                parts[#parts + 1] = styles.banner:render(line.banner_letter .. " ")
            end

            local style = styles.face
            if line.bold then style = styles.face_bold end
            if line.dim then style = styles.face_dim end
            if line.selected then style = styles.select end

            local head = clip(line.text, math.max(0, box.list_w - cells(line.tail)))
            parts[#parts + 1] = style:render(head
                .. string.rep(" ", box.list_w - cells(head) - cells(line.tail)) .. line.tail)
            body[#body + 1] = table.concat(parts)
        end
        panel(canvas, box.x, box.y, box.w, body, false)
    end

    return shown.hits
end

-- ─── Empty desktop ───────────────────────────────────────────────────────

-- The hint on an empty desktop is a grey plate in the middle of the teal:
-- white text straight on the desktop reads as wallpaper, not as a message.
-- The farewell screen after "Shut Down": a black screen and the caption
-- Windows 95 showed when the power could already be turned off. The
-- compositor holds it for FAREWELL_HOLD seconds and only then shuts the
-- application down — this way a shutdown looks like a shutdown, not like a
-- cut-off.
chrome.FAREWELL_HOLD = 5
chrome.FAREWELL_TEXT = "It's now safe to turn off your computer."

function chrome.farewell(canvas, width: any, height: any)
    canvas:clear(styles.farewell:render(" "))
    local w, h = whole(width), whole(height)
    if w < 4 or h < 1 then return nil end
    local message = clip(chrome.FAREWELL_TEXT, w - 2)
    local span = cells(message)
    local left = (w - span) // 2 + 1
    if left < 1 then left = 1 end
    local row = h // 2
    if row < 1 then row = 1 end
    canvas:put(left, row, styles.farewell:render(message), span)
    return nil
end

function chrome.empty_desktop(canvas, width: any, height: any, text)
    local w, h = whole(width), whole(height)
    if w < 6 or h < 3 then return end

    local message = clip(text or "", w - 4)
    local box_w = cells(message) + 4
    if box_w > w then box_w = w end
    local left = (w - box_w) // 2 + 1
    if left < 1 then left = 1 end
    local top = h // 2 - 1
    if top < 1 then top = 1 end

    panel(canvas, left, top, box_w, {fit(styles.face, " " .. message, box_w - 2)}, false)
end

return chrome
