# FR-006. Desktop widgets

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** proposed, 2026-09-13. Decision of the owner: "widgets on the
desktop; first a UI kit for widgets, then weather, memory usage, maybe the
goroutine count".
**Depends on:** FR-005 (pixel chrome), the window SDK (`docs/sdk.md`), the
tray command of the base (`butschster/tui-desktop`, README "desktop.tray").

## 1. The idea in one sentence

> **A widget is a small panel that lives on the desktop, under every window,
> and shows a component tree that a background service pushes to the
> compositor — the way the tray shows a caption.**

Weather, heap in use, goroutine count: numbers that a person wants to see
without opening a window. Windows cover widgets; minimising them reveals the
widgets again. A widget is not a window: it has no focus, no keyboard, no
title buttons and no process of its own behind the drawing.

## 2. Split of responsibilities

The split is the one already used for the tray and for desktop icons.

- **The base (`butschster/tui-desktop`, mechanics)** stores the widgets,
  validates the command, prunes by TTL, passes the list to the theme every
  frame, dispatches mouse hits on them, and reports them in `desktop.list`.
  It draws nothing.
- **The shell (`butschster/windows`, theme)** decides where widgets stand,
  draws the frame in both themes, lays out the component tree with the SDK
  inside the frame, and returns placements and hits. The UI kit — ready-made
  trees for the usual widget shapes — lives in the SDK.
- **The application (the stand)** runs services that sample data and push a
  widget: the weather forecaster, a runtime monitor.

## 3. The command: `desktop.widget`

Same channel and same discipline as `desktop.tray`: `process.send` to the
compositor's registered name, `reply_to` optional, refusals arrive as
`unsolicited` replies and go to the status line. Client helper in the base:
`window_api.widget(spec, service?)`.

```lua
desktop.widget({
    key      = "app.weather",          -- required, ≤ 64 bytes; the same key updates
    title    = "Weather",              -- optional, ≤ 32 runes; drawn by the theme
    entry    = "app.weather:window",   -- optional: a click opens or raises it
    w        = 20, h = 6,              -- cells; defaults 20×5; limits w 10..40, h 2..16
    ui       = { kind = "column", children = { … } },   -- plain data, SDK tree
    revision = 17,                     -- optional; a changed revision repaints
    ttl      = 180,                    -- optional seconds; expired widgets vanish
}, "butschster.windows.shell")

desktop.widget({key = "app.weather", remove = true})
```

Rules, all checked in the base and refused by name:

- `key` non-empty, ≤ 64 bytes. `remove = true` deletes; a missing key is a
  successful no-op.
- `ui` must be a table. The base does **not** know the SDK and does not
  validate the tree; the theme does (`ui.problem`) and draws the reason inside
  the widget instead of the tree. A widget with a broken tree is still a
  widget: it occupies its place and says why it is empty.
- `w`, `h` are whole cells within the limits above; outside — refused, not
  clamped (a clamped widget would draw a tree laid out for another size).
- At most `WIDGET_MAX = 8` widgets; the ninth is refused.
- `ttl` > 0 seconds → `expires = now + ttl`. Pruning happens where the tray
  prunes, and a pruned widget triggers a redraw. **Services should always set
  a TTL** (three ticks of their own period): a widget of a dead service must
  not outlive it, exactly like the tray caption.
- `revision`: number or string. The stored item keeps it; a set with the same
  revision and the same `w/h/title/entry` costs no frame. A set without a
  revision always repaints.
- `owner = tostring(from)`; only reported, not enforced (any sender may update
  any key, as with the tray).

Order of widgets is the order of first appearance; removing and re-adding a
key puts it last. No persistence in v1.

`desktop.list` returns `widgets = {{key, title, entry, w, h, revision, owner,
expires_in}, …}` (without `ui`; the tree is not a status). `GET /windows/status`
in the shell passes the list through.

## 4. What the theme receives

Cells mode: `chrome.fill(canvas, width, height, state)` gets
`state.widgets`. Pixel mode: `chrome.paint(state, …)` gets the same field. In
both, `widgets` is a list in display order:

```lua
{key = "app.weather", title = "Weather", entry = "app.weather:window",
 w = 20, h = 6, ui = <tree>, revision = 17}
```

A theme that does not know the field draws nothing and breaks nothing: the
stock theme of the base may stay as it is (a short note in its README is
enough).

## 5. Hits

A widget produces one hit record per row of its rectangle in
`hits.desktop[]`, the same shape as an icon row plus `widget`:

```lua
{row = 4, from = 79, to = 98, widget = "app.weather", entry = "app.weather:window", title = "Weather"}
```

Dispatch in the base (`desktop_spot` already finds the record):

- left press on a widget record: if `entry` — open the window or raise the one
  already open (the tray's behaviour); otherwise nothing. No selection, no
  icon drag, no double-click state.
- right press: a context menu at the pointer with `Open` (only when `entry`
  is set); no `Properties`. Without an entry the click does nothing.
- keyboard navigation of desktop icons skips widget records.

## 6. Layout in the shell

- Widgets stand in a **column at the right edge** of the desktop: `x = width
  - w`, first widget at `top + 1`, one empty row between widgets. A widget that
  does not fit below the previous one starts a **second column** to the left
  (`x` minus the widest width of the first column minus one). A widget that
  fits nowhere is not drawn and `hits` say nothing about it.
- `w` wider than a third of the screen is drawn at a third (the tree is laid
  out at the drawn width — this is the one place where the shell, not the
  base, resizes: it knows the screen and the base refused only absolute
  limits).
- Icons keep their grid on the left; a dragged icon may be dropped over a
  widget — icons are drawn after widgets and therefore on top. Nothing
  forbids it in v1.
- Windows cover widgets: pixel placements carry `layer = 0` and go through
  `placements.visible` like icons; in cells the windows are drawn after
  `fill`.

## 7. Drawing

The frame is Windows 95 vocabulary, not Vista glass: a **raised panel** in
button face `#c0c0c0` with the 2-px 3D edge of the taskbar, the title (when
given) as a `group` caption — the SDK already draws a titled group in both
themes. The body is the SDK tree laid out inside the panel with 1 cell of
padding, in pixel measures when the theme is pixel (`ui.plan(…, {cell})`).

**Pixels — cut by rows.** One placement per widget row, ids
`widget:<key>:row:<n>`, `layer = 0`. Each row's raster holds its slice of the
frame **and** of the body, painted together: a separate frame placement
under the body would overlap it, and overlapping parts already made Task
Manager vanish once (`docs/sdk.md`, custom renderers). A row is repainted
only when what it draws changed: the SDK renderer's per-row keys
(`render.rows` in `src/sdk/render.lua`) are the mechanism; export what the
theme needs (a full body raster plus row keys, or a row painter with a
decorator) rather than copying the key logic into the theme. Rasters live in
the theme's store between frames; `revision` is part of the key; a widget
that disappears is forgotten (`render.forget`).

**Cells.** `ui.plan` + `cells.rows` at the body rectangle, the panel from the
cells primitives (`src/shell/widgets.lua`). The drawn result is a set of
styled cells written into the canvas by `fill`.

A widget whose tree fails `ui.problem` shows the problem text (alert label)
in place of the body, the frame and title unchanged.

## 8. The UI kit — `butschster.windows.sdk:gadget`

Builders of plain trees for the shapes every widget needs; a service composes
them and never touches geometry:

- `gadget.stat{caption, value, unit?, image?}` — a big value with a caption
  underneath ("Heap", "38 MB"); `image` (a pack picture name, 32 px) to the
  left when given.
- `gadget.meter{caption, value, ceiling, unit?}` — the caption, a `gauge` and
  the value text on one line.
- `gadget.history{caption, values, ceiling?, unit?}` — the caption above a
  `graph`; the ceiling from `charts.ceiling_of` when omitted.
- `gadget.lines{lines}` — up to four short lines of text (place, condition,
  wind).
- `gadget.stack{…}` — vertical composition of the above with the kit's gap.

Every builder returns a tree that passes `ui.problem`; a test asserts it for
each builder and for the composed weather and monitor widgets at the default
size. Sizes the kit assumes: `stat` 3 rows, `meter` 2 rows, `history` ≥ 4
rows, `lines` one row per line; `w` 20 for all. The kit is documented in
`docs/sdk.md` under a new section "Desktop widgets".

The kit lives in the shell because the trees are the shell's dialect; a
service in the application imports it by id, the way Task Manager imports
`butschster.windows.config:system`.

## 9. The application side (the stand)

- **Weather.** `app.weather:forecaster` pushes, next to the tray caption,
  a widget `app.weather`: `stat` with the weather picture and the temperature,
  `lines` with the place and the condition. Same TTL as the tray, same tick.
- **Runtime monitor.** New `app.monitor:service` (process + `process.service`
  with `auto_start`, like the forecaster): every 2 s reads `memory` and
  `goroutines` through `butschster.windows.config:system` (`facts.read`),
  keeps 60 samples, pushes two widgets — `app.monitor.memory` (heap in use:
  `meter` against a round ceiling, `history`) and `app.monitor.goroutines`
  (`stat` + `history`). Permissions: `system.read`, `process.registry`,
  `process.registry.register`, `process.send`; nothing else. A permission
  denial is shown as the widget's text, not as zero (the Task Manager rule).
  TTL 10 s. Revision is the sample counter, so an unchanged sample still
  repaints only the rows whose text changed.

## 10. What is measured before this is called done

- `present.placements_sent` on a frame where one widget changed one number:
  only the rows holding that number are resent, not the widget, not the
  desktop.
- A frame with no widget change sends nothing for widgets.
- `test/shots/widgets.png` shows three widgets in the right column under a
  window that covers part of one of them.
- The stock cells theme of the base still passes its tests with `widgets` in
  the state.

## 11. Not in v1

Dragging widgets, per-user placement, hiding a widget from its context menu,
widgets in the taskbar, interactive components inside widgets (buttons,
inputs — a widget has no focus; a tree with focusable components is laid out
but never receives input), and the stock theme drawing them.
