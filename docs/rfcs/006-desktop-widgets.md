# FR-006. Desktop widgets

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** proposed, 2026-09-13; revised the same day after the owner's
decision: **a widget is a registry entry**, found by `meta.type` like a
window, not a caption pushed by an arbitrary service. Decision of the owner:
"widgets on the desktop; first a UI kit for widgets, then weather, memory
usage, maybe the goroutine count".
**Depends on:** FR-005 (pixel chrome), the window SDK (`docs/sdk.md`), the
view-window model of the base (`butschster/tui-desktop`, README "state
provider": `pixel_state`, `desktop.state`, `spawn_monitored`).

## 1. The idea in one sentence

> **A widget is a view window without the window: a registry entry with
> `meta.type: windows.widget`, whose process the compositor spawns under the
> logged-on user and whose published component tree the theme draws in a
> panel on the desktop, under every window.**

Weather, heap in use, goroutine count: numbers a person wants to see without
opening a window. Windows cover widgets; minimising them reveals the widgets
again. A widget has no focus, no keyboard, no title buttons, no frame of its
own to drag — only a process that publishes state, exactly as the state
provider of an SDK window does.

## 2. Why a registry entry and not a push command

The first draft had a `desktop.widget` command that any service could send,
like `desktop.tray`. The owner chose the registry, and the reasons hold:

- **Discovery is the same as for windows.** The shell already finds windows
  by `meta.type: tui_desktop.window` and image packs by `meta.type:
  windows.images`; a widget found by `meta.type: windows.widget` needs no
  new mechanism and appears in every listing that reads the registry.
- **The process runs under the logged-on user**, spawned by the compositor
  like every window: the widget of the weather asks the forecaster the way
  the weather window does, with the user's rights, not the rights of some
  background service that happens to know the compositor's name.
- **The SDK runner is reused unchanged.** An SDK application publishes
  `{sdk = 1, revision, ui, interaction}` through `desktop.state`; a widget is
  the same loop with `interval` and without input. Nothing new to learn for
  the author of a widget: `init`, `view`, `interval`.
- **Declared size and title live where they are read**, in `meta`, not in
  every push.

## 3. The registry entry

```yaml
# app.monitor:memory — a widget
- name: memory
  kind: process.lua
  meta:
    type: windows.widget           # what makes it a widget
    title: Memory                  # drawn by the theme; optional
    width: 20                      # cells; default 20, limits 10..40
    height: 6                      # cells; default 5, limits 2..16
    order: 20                      # position in the column; lower first; default 100
    opens: butschster.windows.taskman:window   # optional: a click opens or raises it
    comment: Heap in use and its history, sampled every two seconds.
  source: file://memory.lua
  modules: [system, time]
  imports:
    app: butschster.windows.sdk:app
    ui: butschster.windows.sdk:ui
    gadget: butschster.windows.sdk:gadget
    facts: butschster.windows.config:system
  security:
    policies: [app.monitor:widget_scope]
```

The entry **is** the state provider: the compositor spawns it the way it
spawns `pixel_state` of a view window — `spawn_monitored(entry, WINDOW_HOST,
SERVICE_NAME, widget_id, nil, {width, height, cell_w, cell_h})`, with the
compositor's name in the context. The process is an SDK application:

```lua
local app = require("app")
local gadget = require("gadget")
return app.run({
    interval = "2s",
    init = function() return {history = {}} end,
    view = function(model)
        return gadget.stack{gadget.meter{caption = "Heap", value = model.used, ceiling = model.top, unit = " MB"},
                            gadget.history{values = model.history, ceiling = model.top}}
    end,
    tick = function(model) … end,   -- whatever the runner names its interval hook today
})
```

Rules, checked by the base and reported by name in the status line:

- `width`/`height` outside the limits → the widget is not spawned; the
  reason names the entry. Not clamped: a tree laid out for another size
  would be a different widget.
- Widgets are discovered at desktop start (after logon, so that the spawn
  carries the user's actor) and again on `desktop.refresh`: new entries are
  spawned, entries that vanished are stopped and forgotten. Order: `meta.order`,
  then entry id.
- **`desktop.state` for a widget id is accepted only from the pid the
  compositor spawned for it** — the rule view windows already have. Nobody
  else can draw into a widget.
- A widget whose process stops keeps its last tree and gets `stopped = true`;
  the theme says so over the panel; the status line names the entry (the
  compositor already notices a stopped provider for windows — same branch).
  `desktop.refresh` respawns stopped widgets.
- Widget ids are `g<n>` in order of spawning; they share the id space of
  windows only in form, never in value (windows are `w<n>`).

The list of widgets comes to the base from the shell as a provider, like
desktop items: `options.widgets()` returns `{{entry, title, w, h, order,
opens}, …}` already validated against the registry (`catalog.widgets()` in
`src/programs/catalog.lua`, the same `registry.find` by `meta.type`). The
base does not read the registry for widgets itself, for the same reason it
does not read it for desktop items.

`desktop.list` returns `widgets = {{id, entry, title, opens, w, h, revision,
waiting, stopped}, …}` (no tree). `GET /windows/status` passes it through.

## 4. What the theme receives

Cells mode: `chrome.fill(canvas, width, height, state)` gets
`state.widgets`. Pixel mode: `chrome.paint(state, …)` gets the same field. In
both, `widgets` is a list in display order, each item shaped like a view
window so that the SDK renderer can take it as it is:

```lua
{id = "g1", entry = "app.monitor:memory", title = "Memory", opens = "butschster.windows.taskman:window",
 w = 20, h = 6, waiting = false, stopped = false,
 content_state = {sdk = 1, revision = 17, ui = <tree>, interaction = {…}}, state_revision = 17}
```

`waiting = true` until the first state arrives (the theme draws the panel
with the title and an empty body — not yesterday's numbers, not a hang). A
theme that does not know the field draws nothing and breaks nothing: the
stock theme of the base may stay as it is (a short note in its README is
enough).

## 5. Hits

A widget produces one hit record per row of its rectangle in
`hits.desktop[]`, the same shape as an icon row plus `widget`:

```lua
{row = 4, from = 79, to = 98, widget = "g1", entry = "butschster.windows.taskman:window", title = "Memory"}
```

`entry` here is what a click opens (`meta.opens`), the field name kept as in
icon records so the base's open path does not branch. Dispatch in the base
(`desktop_spot` already finds the record):

- left press on a widget record: if `entry` — open the window or raise the
  one already open (the tray's behaviour); otherwise nothing. No selection,
  no icon drag, no double-click state.
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
  out at the drawn width — the one place where the shell, not the base,
  resizes: it knows the screen and the base checked only absolute limits).
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
`widget:<id>:row:<n>`, `layer = 0`. Each row's raster holds its slice of the
frame **and** of the body, painted together: a separate frame placement
under the body would overlap it, and overlapping parts already made Task
Manager vanish once (`docs/sdk.md`, custom renderers). A row is repainted
only when what it draws changed: the SDK renderer's per-row keys
(`render.rows` in `src/sdk/render.lua`) are the mechanism; export what the
theme needs (a full body raster plus row keys, or a row painter with a
decorator) rather than copying the key logic into the theme. The widget
table is already a "window" for the renderer (`content_state`,
`state_revision`, `id`). Rasters live in the theme's store between frames; a
widget that disappears is forgotten (`render.forget`).

**Cells.** `ui.plan` + `cells.rows` at the body rectangle, the panel from the
cells primitives (`src/shell/widgets.lua`). The drawn result is a set of
styled cells written into the canvas by `fill`.

A widget whose tree fails `ui.problem` shows the problem text (alert label)
in place of the body, the frame and title unchanged. `waiting` shows an empty
body; `stopped` draws "stopped" in the body's last row over the last tree.

## 8. The UI kit — `butschster.windows.sdk:gadget`

Builders of plain trees for the shapes every widget needs; a widget composes
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
`docs/sdk.md` under a new section "Desktop widgets", together with the entry
shape of §3 and the rule that a widget receives no input (a tree with
focusable components is laid out but never gets an event).

The SDK runner (`butschster.windows.sdk:app`) must run a widget without
change or with the smallest one: the widget id arrives where the window id
arrives, the interval hook fires, `view` publishes. If the runner insists on
something a widget cannot give (an input channel that must exist, an
`update` that must be a function), relax that in the runner, not in the
widget.

## 9. The application side (the stand)

Three entries, each a widget of §3:

- **`app.weather:widget`** — `stat` with the weather picture and the
  temperature, `lines` with the place and the condition. Data from the
  forecaster the way `app.weather:window` gets it (`weather.ask` /
  `weather.reply`); `interval` 60 s; `opens: app.weather:window`.
- **`app.monitor:memory`** — every 2 s reads `memory` through
  `butschster.windows.config:system` (`facts.read`), keeps 60 samples; heap in
  use as `meter` against a round ceiling (`charts.round_ceiling`) plus
  `history`. `opens: butschster.windows.taskman:window`.
- **`app.monitor:goroutines`** — same sampling for `goroutines`; `stat` +
  `history`.

Permissions of the monitor entries: `system.read`, `process.context`,
`process.registry`, `process.send`; nothing else. A permission denial is
shown as the widget's text, not as zero (the Task Manager rule:
`facts.denied`).

## 10. What is measured before this is called done

- `present.placements_sent` on a frame where one widget changed one number:
  only the rows holding that number are resent, not the widget, not the
  desktop.
- A frame with no widget change sends nothing for widgets.
- `test/shots/widgets.png` shows three widgets in the right column under a
  window that covers part of one of them.
- The stock cells theme of the base still passes its tests with `widgets` in
  the state.
- A widget process that dies shows "stopped" and comes back on
  `desktop.refresh` (a base wiring test with a fake provider).

## 11. Not in v1

Dragging widgets, per-user placement, hiding a widget (a settings key and a
context-menu item are the obvious next step), widgets in the taskbar,
interactive components inside widgets, a push command for services outside
the registry, and the stock theme drawing them.
