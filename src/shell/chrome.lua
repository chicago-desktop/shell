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

-- The Start menu.
local MENU_WIDTH = 38
local MENU_MIN = 22
-- From this width on the vertical caption fits in the menu.
--
-- It was 26, and that turned out to be more than our panels ever are: the
-- caption was practically never shown, while on the Windows 95 reference frame
-- it is always there. The threshold is kept, but lowered to the width at
-- which the panel does not yet look squeezed.
local MENU_BANNER_AT = 18
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

-- use_user(user) — user = {id, name}, or nil to clear it.
function chrome.use_user(user: any)
    if type(user) == "table" and type(user.name) == "string" and user.name ~= "" then
        chrome.session.user = {id = user.id, name = user.name}
    else
        chrome.session.user = nil
    end
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
-- (`butschster.windows.programs:catalog`) had already done that, with
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
-- "My Computer" could not be put above "Programs", as in Windows. Between
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
        -- Windows 95 did not have them, and a person opening programs with
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
function chrome.menu_layout(width: any, height: any, items, failure, open, cursor: any, metrics: any): any
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

    local root = new_node()
    for index, item in ipairs(catalog) do place(root, index, item) end

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
        -- a separator under it. The row is NOT selectable: it has neither a
        -- hit nor a `slot` number, the cursor steps over it, and Enter on
        -- "the first row" still opens the first program. Hints and clipping
        -- on a short screen are counted by the same `#lines`, so it takes up
        -- room honestly; on clipping it stays — the tail is cut.
        local user: any = sizing.user
        if level == 1 and type(user) == "table" and type(user.name) == "string" and user.name ~= "" then
            table.insert(lines, 1, {kind = "user", text = user.name, image = "user"})
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
            local selectable = line.kind == "item" or line.kind == "group"
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
                local banner = tostring(chrome.MENU_BANNER or ""):upper()
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
                -- Folder labels have the same weight as applications in Win95;
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
            if line.kind == "item" then
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
