# Wippy window SDK

This is the primary contract for new windows and for fixes to existing ones. The
window mechanics are provided by `butschster/tui-desktop`, the look and the
declarative components by `butschster/windows`. Do not copy the loop, layout and
scrolling from a random application: specialized windows use the lower level.

## Quick start: entry → menu → window

A new application declares an ordinary `process.lua`, already known to the compositor.
No new kind, HTTP handler or entry in the theme's table is required.

```yaml
version: "1.0"
namespace: my.documents
entries:
  - name: window
    kind: process.lua
    meta:
      type: tui_desktop.window
      title: Documents
      image: program
      group: [Work, Documents]
      order: 100
      width: 62
      height: 23
      window_type: app
      resizable: true
      pixel_render: butschster.windows.sdk:render
      pixel_state: my.documents:window
    source: file://window.lua
    method: main
    imports:
      app: butschster.windows.sdk:app
    security:
      policies: [butschster.windows.security:view_state]
```

The catalog looks for a `process.lua` with the exact `meta.type: tui_desktop.window`
when the menu is opened. After the entry is applied to the live registry, the next
menu opening will see the program. Changing the YAML on disk does not by itself apply the registry.
`group` sets the folder path: a string with `/` or an array of segments, up to three levels.
Without the field "Programs" is used; an empty string means the menu root.
`in_menu: false` hides the item while keeping the ability to open the window by ID.
`image` is a name from the [icon catalog](icons.md), the same for the menu and the window.
`width/height` are the initial outer sizes in cells, including the frame.
With `resizable: false` the size from the entry applies, but a small terminal still
limits the window to the available space.

The entry adds the program to the menu automatically, **it does not create a desktop
shortcut**: shortcuts are separate user data. `opens` declares file extensions
for the explorer; the view argument is assembled by the `viewers:files` library.

```lua
local app = require("app")
local definition = {}
function definition.init(args, context)
    return {selected = 1, items = {"First document", "Second document"}}
end
function definition.view(model, context)
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Documents"},
        {kind = "list", id = "documents", items = model.items, selected = model.selected},
        {kind = "button", id = "close", size = 2, text = "Close"},
    }}
end
function definition.update(model, action, context)
    if action.id == "documents" and action.type == "select" then model.selected = action.index
    elseif action.id == "close" then context.close()
    else return false end
end
definition.close_on_escape = true
return {main = app.main(definition), definition = definition}
```

A ready runnable example with two panes and input:
[`test/src/sdk_demo.lua`](../test/src/sdk_demo.lua). It is registered only in the
test stand. The generator from the skill creates the same pair of files in your module.

## Declarative components, version 1

The tree consists of plain tables: no functions, userdata, rasters, channels or PIDs.
Handlers stay in the application process. `view` returns the tree for the
current data; `update` changes the model on a component's action.

- `column`: vertical placement of `children`.
- `row`: horizontal placement of `children`. `align = "right"` puts children of a
  fixed `size` against the far end (with a flexible child there is nothing to align).
- `split`: horizontal panes, shares via `weight`. The divider is fixed for now.
- Containers' `padding` and `gap` are non-negative integer **cells**.
  `padding_top` / `padding_right` / `padding_bottom` / `padding_left`
  override one side. A dialog with buttons at the bottom sets
  `padding_bottom = 0`: below the pixel theme's bottom frame there is already a whole
  row of cells, and the extra padding pushed the buttons twice as far away as in Windows 95.
- A child's `size` is its size along the parent's axis. Without `size` the remaining
  space is divided by `weight` (1 by default). When space runs short, components are
  clipped; the container's size does not grow beyond the viewport.
- Pixel measures: `size_px` on a child, `padding_px` and `gap_px` on a container
  name Windows 95 pixels. When the plan draws in pixels (`ui.plan(…, {cell = {w,
  h}})`, which `app.run` and the renderer both pass), they are rounded to the
  nearest whole cells per axis — the mouse speaks cells, so a layout is always
  whole cells, and the pixel number picks the closest one (7 px of padding is a
  column at an 8–10 px cell and no row at a 16–20 px one). In cells mode `size`,
  `padding` and `gap` stand, so a tree gives both. A button's `width_px` is its
  drawn width: in a row with `align = "right"` such buttons are packed from the
  row's right edge `pack_px` (6) apart, each drawing kept inside its own cells.
  A dialog row gives each button `size_px = 81, width_px = 75` and gets the
  Windows 95 75×23 buttons 6 px apart; "Display Properties" is the example.
- `label`: `text`, does not take focus; `alert = true` — refusal text (red).
  `\n` in the text makes a multi-line label: lines go at the font's step (15 px in
  pixels, one row per line in cells), the block centered in the rectangle; this way
  the two hint lines of a dialog do not drift a cell apart like two paragraphs.
  `wrap = true` flows the text by words into the label's rectangle from the top:
  lines of its width, as many as its height holds (one per row in cells, 15 px
  apart in pixels), and only the last line is cut with "…". A wrapped label is
  one paragraph: `\n` is not a hard break there. `align = "center"` centers a
  single-line label in its width (by cells in cells, by the font in pixels).
- `monitor`: `color` — a monitor screen in the desktop color, like the preview in
  "Display Properties"; in pixels a case with a bevel and a stand, in cells
  a face frame and a colored screen. Does not take focus, no `id` needed.
  `pattern` — eight bit rows of a Windows 95 desktop pattern
  (`butschster.windows.display:patterns`), set bits black over the screen color;
  pixels only.
- `image`: `image` (a name from the icon catalog), `icon` (a character for cells),
  `size_px` (32 by default). A dialog icon: a raster in pixels, a single character
  in cells. Does not take focus, no `id` needed.
- `ui.message(spec)` is an in-window sheet — "Help → About", an object's
  "Properties": `title`, `lines`, `image`/`icon`, and `buttons = {{id, text,
  default}, …}` in that order at the right edge (by default one "OK" with the id
  `spec.ok` or `"message_ok"`). A button is at least 10 cells; the default is the
  declared one, else the only button. `ui.confirm(spec)` is the question: "Yes"
  (`spec.yes`, id `"yes"` by default) and "No" (`spec.no`, `"no"`), "No" the
  default unless `spec.default = "yes"`; `yes_text`/`no_text` rename them. The
  window returns the sheet from `view` while it is open and closes it on the
  button's `activate`.
- Buttons in a row stand at the RIGHT edge (shell rule, 2026-09-09): the row says
  `align = "right"`, the buttons have a fixed `size` and follow each other through
  `gap`. That is how "Run…" does it.
- `button`: `id`, `text`, `disabled`, `default`; the `activate` action on releasing the left button inside,
  or on Enter or Space. Releasing outside the button cancels the press.
  A right press on an enabled button is `context` with the button's `id`, at
  the PRESS, as Windows does it (Minesweeper flags a cell on the right button
  going down). It arms nothing and takes no focus, so its release activates
  nothing; the window decides what the right button means. The middle button
  and passive views get nothing. The compositor sends right and middle presses
  inside the client to the window (the chrome listens only to the left one).
  `image` puts a picture on the button instead of its caption, in pixels: a
  name from the [icon catalog](icons.md) or from an image pack of another
  module (`<pack entry>/<file>`, see "Image packs" there), 16 px unless
  `image_px`. The caption stays what cells show, and what pixels show when
  the picture is missing or does not fit — the Minesweeper face is `:)` in
  cells and a smiley in pixels.
  `default` is a black outline in both modes: what Enter will do, and a dialog has
  exactly one. In cells the button is drawn by `widgets.button` — the same one as in Run
  and the explorer; in pixels by `pixels.button`. Tab/Shift+Tab moves
  focus.
- `checkbox`: `id`, `text`, `checked`, `disabled`; `change.value` is the new boolean
  value on a click or Space. Store it in the model in `update`.
- `radio`: `id`, `text`, `checked`, `disabled` — one option of a group. A click,
  Space or Enter on an unchosen one gives `change` with `value = true`; on the
  chosen one nothing — a radio button is never unchosen by itself, the
  application clears its neighbours (their `checked` follows the model). In
  pixels the Windows 95 12×12 ring with a dot, in cells `( )` and `(•)`.
- `input`: `id`, `text`, an optional `password` (shows asterisks, one per
  character; the model and `change.value` keep the real text);
  `change.value` returns the new text, `activate.value`
  is the Enter confirmation. Supports UTF-8, arrows, Home/End, Backspace/Delete,
  Ctrl+A and paste. This is single-line input, not a text editor.
  An optional `placeholder` is grey text shown while the value is empty and the
  field is not focused (cells: grey on the field's white; pixels: the shadow
  color). It is only drawn: never edited, never sent — `change.value` is what was
  typed.
- `select`: `id`, `value`, `options = {{value, label}, …}`, `disabled`. A drop-down
  list: a field with the chosen option's label and a ▾ button. A click on it,
  Enter or Space opens the list straight under the field (over it when more fits
  there), with the cursor on the chosen option; ↑/↓ and Home/End move the cursor,
  Enter, Space or a click on a row chooses, Esc, Tab or a click elsewhere closes.
  Closed, ↑/↓ and Home/End change the value directly, as in Windows 95. A choice
  is `change` with the option's `value`, only when it differs. The list is an
  overlay, like a menu's; its rectangle is `ui.dropdown`, one for both renderers
  and the hit test.
- `slider`: `id`, `value`, `min`, `max`, `disabled` — a Windows 95 trackbar. In
  pixels a sunken 4 px track and an 11 px raised thumb; in cells a `─` track
  with a `█` thumb. The thumb's column is `ui.slider_position(node, width)`, the
  hit test's rule too. A click sets the value at the clicked column; ←/↓ and
  →/↑ step by one, Page Up/Down by a quarter of the range, Home/End go to the
  ends. The action is `change` with the whole number `value`, only when it
  changes. Disabled: no focus, no clicks.
- `spectrum`: a color spectrum bar ("Display Properties → Settings"), passive,
  no `id`: the hue sweeps from magenta through blue, cyan, green and yellow to
  red, one rule for both renderers (`ui.spectrum_color(t)`). In pixels a
  sunken box up to 15 px tall, in cells one colored cell per step.
- Form rules — `required`, `required_if`, validation messages — are out of scope:
  the SDK draws the controls and reports what the person did, the window decides
  what a valid form is (the Connections window checks its credential schema
  itself and names the field in the status line).
- `list`: `id`, `items`, `selected`, an optional `wheel_step` (3).
  An item is a string or `{id = ..., text = ...}`. `select` carries `index` (1-based)
  and `value`; Enter gives `activate`. Store the selection in the model in `update`.
  `selected` is a 1-based row number **or an item ID** (`{id = …}` on the element):
  that way the selection holds on to the item when new data shifts the rows.
  The scrollbar is part of the list's rectangle, flush right: one column in
  cells, in pixels 16 px rounded up to whole cells (`widgets.scroll_cols` — two
  columns at an 8 or 10 px cell, the same bar as Explorer's). The layout reserves
  the columns (`ui.plan(…, {scroll_cols = n})`, `item.bar_cols`), text and table
  columns end before them, and a press on any of them scrolls; `app.run` passes
  the number from the window's context. A `select` from a mouse click
  carries `pointer = true`: the application may treat a repeated click on the
  already selected item as a double click. An optional `reveal` is the row number
  that must be shown; it is applied once per value (the chat log sets
  `reveal = #items` and brings the new message into view without knocking the human's scrolling off).
  Row text starts one cell in, in both renderers.
  When the wheel pushes down with the last row on screen, or ↓, Page Down or
  End arrive with the last row already selected, the list says
  `{type = "end", id, offset, total}` — the moment to load the next page, with no
  polling of the offset. Reaching the last row by keys is still a `select`; only
  pushing past it is `end`. Tables and trees say it the same way. `end` is drawn
  even when `update` returns false: the view has already moved.
- `table`: `id`, `columns`, `rows`, `selected`, `wheel_step`. A column is
  `{title, width | weight, align = "left" | "right"}`: `width` in cells
  fixes it, otherwise the remainder is divided by `weight`; one cell between columns.
  A row is `{id = ..., cells = {...}}`; cells are strings, the excess is clipped,
  `right` aligns to the column's edge (numbers, sizes). The first row of the
  rectangle is the header: raised column buttons, as in Explorer;
  a click on it selects nothing. Selection, keys, wheel and scrollbar are the same
  as for `list`, the `select`/`activate` actions carry `index` and the row.
  There is no sorting or cell editing: this is a table for reading. Text in a cell
  starts one cell in, and a right-aligned value ends one cell before its column's
  end — the same in cells and pixels. `static = true` is a table nobody selects
  (the "name — value" pairs of a properties sheet): it needs no `id`, takes no
  focus and no clicks, and keeps no scroll offset.
- `text`: `id?`, `text`, `wrap` (on by default), `wheel_step` (3). Read-only text
  with its own vertical scroll — an event's payload, a log. The plan wraps it
  ONCE by the rectangle's width in characters, minus the scrollbar and the cell
  of air on the left, breaking after the last space that fits and keeping the
  text's own lines and indents (`ui.wrap_text`); both renderers draw those lines,
  so a window never pre-wraps by `context.width`. With an `id` it takes the
  focus, the wheel, a press on its bar and ↑/↓/Page Up/Page Down/Home/End; every
  move is `{type = "scroll", id, offset, total}`, drawn whatever `update` answers.
  Without an `id` it is inert, like a `static` table, and stays at the top.
  `wrap = false` keeps each line whole and the renderer cuts it.
- `tree`: `id`, `rows`, `selected`, `wheel_step`. A row is a visible row of the
  flattened tree: `{id, label, depth, has_children, expanded, trail,
  kind = "folder" | "entry", image?}`; `trail` says, per ancestor level, whether that
  ancestor has more siblings below (the lines are drawn from it). Indent is two cells
  per level: the expander box, the icon, the caption (`ui.tree_columns`). A click on
  the expander box, Enter and → on a collapsed node give `toggle`; → on an expanded
  one gives `select` of the child; ← on an expanded one gives `toggle`, on a collapsed
  one `select` of the parent; the rest is as for `list`. The application expands and
  flattens: the SDK does not store the tree.
- `icons`: `id`, `items`, `selected`, an optional `wheel_step` (1).
  A grid of icons with captions — Explorer's "Large Icons" view and "Network
  Neighborhood". An item is `{id, title, image?, icon?, kind?, broken?}`: `image`
  comes from the [icon catalog](icons.md) for pixels, `icon` is a character for
  cells, the rest is as for desktop objects. The grid step is 12×4 cells, the picture
  takes three rows, the caption two (`ui.icon_grid`, `ui.icon_shape`); `shell:icons`
  has the same numbers, and a test checks that they match.
  **The scroll unit is a ROW of icons**, not an item: the wheel, the scrollbar,
  Page Up/Down and `scroll.reveal` count rows. The grid keeps the scrollbar's
  columns free of icons, and a press on the bar scrolls, as in a list. A click on a cell gives
  `select` with `index`, the item in `value` and `pointer = true`; the application
  may treat a repeated click on the already selected item as a double click. A click
  on an empty spot of the grid clears the selection (`index = 0`, `value = nil`) — like
  empty space in Explorer. Arrows move over the grid in two dimensions (←/→ across
  items, ↑/↓ by a row), Enter gives `activate`.
- `calendar`: `year`, `month`, `day`, `first_weekday` (0 = Monday),
  `days` — a month grid with weekdays, today highlighted; read-only.
  The grid is computed by `ui.month_grid(first, days)`, leap years by the `time` module.
- `clock`: `hour`, `minute`, `second` — an analog clock in pixels,
  digital time in cells; read-only.
- `group`: `title`, `children`, `padding`, `gap` — a frame with a title, the children
  inside, one cell from the edge; takes no input.
- `graph`: `values`, `unit`, `ceiling?` — the history of a number, green on black;
  the ceiling is round (`sdk:charts`), the latest measurement on the right.
- `gauge`: `value`, `ceiling`, `caption`, `orient` — a gauge toward the ceiling.
  The default (`orient = "vertical"`) is Task Manager's LED meter with the caption
  under it. `orient = "horizontal"` is a Windows 95 progress bar and draws no
  caption: in pixels a sunken field up to 18 px tall with navy blocks 8 px wide
  2 px apart, in cells `█` over the face in a sunken field on the middle row. Both
  fill `ui.gauge_filled(node, units)` of their units — value over ceiling,
  clamped to 0..1, to the nearest block or cell. Any other `orient` is refused by
  `ui.problem`.
- `field`: `text`, `align` — a sunken read-only field (a display).
- `table.header = false` — a table without the header row ("name — value" pairs).
- `button.ink` is the caption color in pixels; `button.pressed` — pressed by force
  (the calculator's key highlight); `bold` — a bold caption; `fill = true` with
  `inset` (px) — a button over its whole rectangle minus the inset, so neighboring
  keys stand four pixels apart. `field.face = true` — the face background instead of
  white (the empty memory box). Give an `input` field two rows of cells: in
  one the text runs into the bevels.
- `statusbar`: `fields = {{text, width?}, …}` — sunken fields in one row
  at the bottom of its rectangle; the last one stretches. Does not take focus,
  no `id` needed. This is the fourth most frequent element of the shell — until now
  every window had its own.
- `tabs`: `id`, `labels`, `active`, `children`. A container with a one-row tab strip
  and a page frame under it; the children are laid out inside the frame as a
  column (`padding`, `gap` — as for `column`). A click on a tab and the ←/→ arrows
  while focused give `select` with `index`; the application itself switches the page
  content by `active`. A tab that did not fit in the strip is neither drawn nor
  clickable — half a tab would be clicked "into nowhere". `pad` is the air on each
  side of a caption in cells (2 by default; 1 fits more tabs). In pixels a tab is
  measured by its caption — 7 px a character, the Liberation Sans 13 average, plus
  10 px — and rounded up to whole cells, so the four tabs of a Windows 95 dialog fit.
- `menu`: `id`, `entries = {{title, accel?, items = {{id, text, accel?,
  disabled?} | {separator = true}, …}}, …}` — the window's menu bar. A click on a
  title or Alt+letter opens the list; it lies on top of everything
  (`plan.overlays`, drawn last, its hits checked first). A row of
  the list gives `activate` with the item's `id` and `menu`, the menu bar's identifier.
  While the list is open, ←/→ move across the titles, ↑/↓ across the rows (separators
  and disabled items are skipped), Enter chooses, Esc and a click outside collapse it,
  and such a click goes no further. The menu is not part of the Tab ring, as in Windows.

The `id` of an interactive component is mandatory, unique within the window and stable
between frames. The SDK keeps focus, the input position and the list offset by this ID.
Trees (`tree`), tabs (`tabs`), window menus (`menu`) and graphs (`graph`, `gauge`) are
SDK components described above. What still belongs to custom renderers is a table
with sorting and cell editing: `table` is read, not edited.

`disabled` on `list`, `table`, `tree` and `icons` works as on an input field: input is
not accepted, and in both renderers the look is muted — face instead of field, gray
text, no selection. With no selection an arrow selects the first row (for icons, the
first icon) rather than stepping from it.

A tree that does not lay out (an unknown `kind`, an interactive view without an
`id` or with a repeated one, `children` that is not a list) is shown by `app.run` as
a fallback tree. The shared renderer in the compositor asks `ui.problem` and shows the
reason as text in the window rather than throwing: an error caught by `pcall` in go-lua
breaks the upvalues of the whole stack beneath it, and beneath the renderer lies the compositor's loop.

## Styling of standard elements

The pixel SDK uses the shared `shell:pixels` primitives: `button`, `field`,
`checkbox`, `edge` and `focus_rect`. A button has the two Windows 95 bevels: a light
one at top/left and a gray one with black outside at bottom/right. A pressed button is
sunken, its caption shifts by a pixel. `default` adds an outer black outline;
focus is a separate dotted line inside, not yet another sunken frame.
A disabled caption is gray and drawn once. We do not add a white shifted copy:
at a small font size it makes the letters unreadable. This rule is shared by
buttons and checkbox captions; frames and icons keep their relief.

Fonts are provided by the shell: Liberation Sans 13 px, regular and bold,
with antialiasing in `gfx.font(..., {smooth = true})`. Draw with the font you are given:
its setting applies with a plain `raster:text` too. Do not add a white
backing and do not turn antialiasing off locally for the application's text.

A button, an input field and a field occupy the middle cell row of their rectangle:
in cells that row, in pixels the control grows around it to the Windows 95 size — a
button up to 23 px, an input up to 24 px, a field up to 26 px (a `fill` button takes
the whole rectangle). The hit rectangle stays an integer number of cells. Text that
does not fit is cut with "…" in both renderers; each measures in its own unit — cells
by cell width, pixels by the font — so pixels keep what the proportional font fits.
In cells a button wider than its caption fills its room, the caption centred, as in
pixels. A list and a field have a double sunken bevel; a checkbox is a 13×13 px square.
Panel buttons can be given an equal `size` instead of stretching across the whole
width of the window. For custom styling use these primitives,
do not copy combinations of `panel` and `bevel` into the application.

## Lifecycle

`butschster.windows.sdk:app.run(definition, first, id, args, viewport)` hides the
difference between the two ways of launching:

- Cells: the compositor creates a `tty.viewport` and calls `main(args)` with a terminal
  grant. The SDK starts `tty`, reads the size and events, draws through the surface.
- Pixels: the compositor calls the provider
  `main(service, window_id, args, {width,height,cell_w,cell_h})`.
  The SDK listens to `window.input` and publishes the tree for the shared renderer.

`resize` can change `cell_w`/`cell_h` without changing the `width`/`height` grid:
for example, after the terminal font changes. The cell size, the frame insets and the
client area size are updated by the compositor. A custom pixel client takes the
event's new metrics; it does not need to scale the old raster or keep a separate
initial copy of the cell size.

`init(args, context)` is called once. `view(model, context)` does not read
files and does not send messages. `update(model, action, context)` handles
actions, including `resize`, `tick`, `close` (the window is being closed from outside;
it cannot be cancelled, you can finish cleaning up) and `key` — a key that no component
took (`key`, `key_type`, `alt`, `ctrl`, `shift`): that is how windows close on Esc and
refresh on F5. Returning `false` from `update` means "nothing changed, do not
redraw" — except for `end` and `scroll`, which report a move the SDK has already
made and are drawn regardless. For periodic data set `definition.interval = "1s"`; a one-shot timer is
`context.after(duration, tag)`, and the action `{type = "timer", tag = tag}` arrives
once. `definition.close_on_escape = true` closes the window on an Esc that `update`
did not take (returned `false`): a window with an open sheet closes the sheet in
`update` first. A window file ends with
`return {main = app.main(definition), definition = definition}`.
`definition.title` is the window title, as a string or a function of the model, when it
does not match the menu item's name (for "Run…" the item has an ellipsis, the window
is "Run"); empty means the title from the registry entry.
`dispose(model, context)` releases resources on a normal close. `context`
contains `args`, `width`, `height`, `native`, `window_id`, `close()`, `after(duration, tag)`,
and also `watch(ch)` and `unwatch(ch)` — always, in a test too:
`app.context({width = …, height = …})` builds the same context without a loop, and
`app.dispatch(definition, model, context, action)` runs one action the way the loop
does. The application's own channel (a compositor reply from
`desktop.replies()`, a subscription, a request timer) arrives as the action
`{type = "channel", channel = ch, value = ..., ok = ...}`; a closed channel
unsubscribes itself. So a long request does not block the window: send —
subscribe — receive it as an action. Sizes here are always **client** sizes, without
the title bar and the frame.

An error in `init`, `view` or `update` does not tear the window down: it becomes visible
state — the error text and a "Close" button — and `dispose` and closing the
transport are performed anyway. A compositor refusal to publish a frame or to
close is not the death of the window either. The loop's mutable state lives in a table,
not in locals: in go-lua, after an error under `pcall`, a closure and its owner stop
sharing a local variable (see the test stand's CLAUDE.md).

The compositor owns moving, sizing, window focus, minimizing,
maximizing and stacking order. The application does not draw the outer frame,
does not enter the alternate screen and does not write escape sequences to stdout.
The compositor tells a window when it loses and regains the keyboard, with the
runtime's terminal event `{type = "focus", focused = …}` — another window took
focus, or this one was minimized. The SDK handles it itself: on `focused = false`
it drops an armed button and a captured drag (`app.focus`), because the release
they wait for now goes to another window, and redraws only when something was
held. `update` does not receive it. A custom window reads the same event from
`window_api.inputs()` or `tty.events()`.

Both kinds of window receive `close`; after a common deadline the compositor terminates
a process that has not finished. So `dispose` is not guaranteed on a crash or a
forced stop. Long requests should be done outside the input handler: a synchronous
`update` stops this window for the duration of the request.

## Low-level geometry, input and scrolling

The base's libraries: `butschster.tui_desktop.desktop:geometry`, `:input`, `:scroll`.

`geometry.rect(x,y,w,h)` is a rectangle in cells, 1-based coordinates; the right and
bottom bounds are exclusive. `contains(rect,x,y)` checks a hit;
`inset(rect,padding)` shrinks the area without creating negative sizes.
The pixel details of buttons stay inside these same rectangles. Do not compute the
coordinates of the drawing and of the click separately. The declarative `ui.plan` is one
for both renderers and input. A custom window must also have one pure `layout`.

`input.normalize(event)` maps Page Down (`pgdn/page_down/pagedown`) to
`pgdown`, Page Up to `pgup`, Escape to `esc`, keeping the modifiers and `action`.
`input.key(event)` ignores key release. `input.pressed(event)` means
only the left button and `action: press`. Normalization does not turn a key release
into a press: the consumer must check `action`.

Mouse coordinates are already translated by the compositor into the client area. The
wheel goes to the window under the cursor. After a press in the client area, motion and
release go to the same window, even if the cursor has left its bounds: this is the
capture for dragging a scrollbar thumb. After release the capture is dropped. The
application does not subscribe to the outer frame and the taskbar.

`scroll` works in **logical rows**: a list row, a row of icons or a pixel of
an image — the unit is chosen once for a given view.
The offset is the number of hidden rows, from 0; the selected element is a 1-based index or an item ID.

```lua
offset = scroll.clamp(offset, total, page)
offset = scroll.reveal(offset, selected_index, total, page)
offset = scroll.key(offset, "pgdown", total, page)
offset = scroll.wheel(offset, "wheel_down", total, page, 3)
local bar = scroll.bar(offset, total, page, height)
offset = scroll.drag(pointer_row, grab_inside_thumb, bar)
offset, capture, handled = scroll.pointer(offset, total, page, rect, capture, event)
```

After a change of size, filter, data set, tab or zoom the offset must be
clamped again. An empty list has offset 0. The wheel outside a pane does not
scroll it. The scrollbar and the handler use one thumb geometry;
the arrows move by one unit, the track by a page, dragging by the length of the track.
For a tree with the historical 1-based `first` the conversion is explicit: `offset = first - 1`.

## Custom windows and renderers

A custom window is chosen for a PTY, an editor, a tree or graphs that are not
in the component set. It uses the same input, geometry and scroll-bounds
libraries. There is no need to create your own message protocol:

- `window_api.inputs()` returns a channel of `window.input` only.
- `window_api.input_event(message)` unpacks and normalizes an event.
- `window_api.normalize_event(event)` does the same for `tty` events.
- `window_api.publish_state(id, state)` publishes ordinary data.
- `open{entry=..., args=...}` sends a command; `open_wait` returns the window
  or the reason for refusal. `request` + `replies` suits a custom loop
  that must keep handling input while the window is opening.
- `dialog(spec)` opens a dialog owned by the calling window. It closes
  with the parent, but **is not modal**. `tool` also supports an owner.
- `close(id)`, `focus(id)`, `list()` reach the compositor from the context,
  without a hard-coded shell name. Check errors; do not call sending a
  command a confirmed window opening.

A custom pixel renderer has the signature
`placement(window, inner, cell, fonts, store) -> placement | placements | nil, reason`.
`inner` holds `{x,y,cols,rows}` in cells, `cell` holds `{w,h}` in pixels,
the interface font is `fonts.face`. Resources are read in the provider under
its permissions through `fs`, and the renderer receives data/bytes. Images and fonts
are not opened by system paths from `gfx`.

A placement contains `{id,raster,x,y,cols,rows}`. Rasters live between frames:
`store.take(id, cols, rows, cell, key)` returns a raster and `dirty`; drawing into
the raster when `dirty == false` is not allowed. Every frame returns the **full** list of
placements, including the unchanged ones. Parts within one window do not overlap:
a background panel under other images has already made Task Manager disappear
after the first tick. The SDK's shared renderer uses a single client raster, so
it does not have this ambiguity. With frequent large updates a custom
renderer can split the client into non-overlapping strips.

A new specialized library requires an explicit import and registration in
`chrome_pixels.VIEWS`: `require` does not load an arbitrary ID from metadata.
This is an extension of the theme, not an ordinary addition of an application. A new
declarative application only needs the already registered `butschster.windows.sdk:render`.

`pixel_render` + `pixel_state` is an enhancement of an ordinary window in graphics mode;
on a terminal without graphics the main process in cells remains.
`window_content: pixels` + `render/state` means graphics are required. In text mode the base can show only such a window's `state.caption`;
that does not give a full interface. Do not claim
GNOME Terminal support for an application that has only a pixel view.

## Desktop widgets

A widget is a view window without the window
([FR-006](rfcs/006-desktop-widgets.md)): a registry entry with
`meta.type: windows.widget` whose process the compositor spawns under the
logged-on user, and whose published tree the theme draws in a raised panel at
the right edge of the desktop, under every window. It has no focus, no
keyboard, no title buttons and no frame of its own to drag.

### The entry

```yaml
- name: memory
  kind: process.lua
  meta:
    type: windows.widget                        # what makes it a widget
    title: Memory                               # drawn in the panel's top edge; optional
    width: 20                                   # cells; default 20, limits 10..40
    height: 8                                   # cells; default 5, limits 2..16
    order: 20                                   # place in the column, lower first; default 100
    opens: butschster.windows.taskman:window    # optional: a click opens or raises it
  source: file://memory.lua
  method: main
  modules: [system, time]
  imports:
    app: butschster.windows.sdk:app
    gadget: butschster.windows.sdk:gadget
  security:
    policies: [app.monitor:widget_scope]
```

The shell reads these entries (`catalog.widgets()`, `meta.order` then the
entry id) at desktop start and on `desktop.refresh`, and hands the list to the
base as `options.widgets`. The base checks the limits and refuses a size
outside them by name — it does not clamp: a tree laid out for another size
would be another widget — and spawns each entry as a state provider, with the
widget's id (`g<n>`) where a window gets its window id.

### The process

A widget is an ordinary SDK application run by `app.main`, with an
`interval` and no input:

```lua
local app = require("app")
local gadget = require("gadget")
local definition = {interval = "2s"}
function definition.init(args, context) return {used = 0, top = 1, history = {}} end
function definition.view(model, context)
    return gadget.stack{
        gadget.meter{caption = "Heap", value = model.used, ceiling = model.top, unit = " MB"},
        gadget.history{values = model.history, ceiling = model.top, unit = " MB"},
    }
end
function definition.update(model, action, context)
    if action.type ~= "tick" then return false end
    -- sample here: `view` reads no files and sends no messages
end
return {main = app.main(definition), definition = definition}
```

The interval arrives as `update(model, {type = "tick"})`; a widget without
`update` is still redrawn on every tick. `view` publishes through
`desktop.state` exactly as a window's does, and the runner closes the widget's
id when the process ends. No input ever arrives: a tree with focusable
components is laid out and drawn, nothing in it is drawn focused, and it never
gets an event. Until the first state the panel shows its title over an empty
body; a widget whose process stopped keeps its last tree with "stopped" in the
body's last row; a tree `ui.problem` refuses shows the reason in place of the
body. A refusal of the widget's own — a permission denial — is its text
(`{kind = "label", alert = true, wrap = true, text = …}`), never a zero.

### The kit — `butschster.windows.sdk:gadget`

Plain, passive trees for the usual shapes; none needs an `id`:

- `gadget.stat{caption, value, unit?, image?, icon?}` — three rows: the value
  in two, the caption dimmed under it; `image` (a catalog or pack picture)
  32 px on the left, `icon` its character in cells.
- `gadget.meter{caption, value, ceiling, unit?}` — two rows: the caption at the
  left and the value at the right, over a horizontal `gauge` (a progress bar)
  toward the ceiling across the whole width.
- `gadget.history{caption?, values, ceiling?, unit?}` — the rows a stack
  leaves, four or more: the caption over a `graph`; the ceiling is
  `charts.ceiling_of(values)` when omitted.
- `gadget.lines{lines}` — a row per line, up to four.
- `gadget.stack{…}` — the shapes one under another, `gadget.GAP` (0) rows
  apart.

`unit` is appended as it is, with its own leading space (`" MB"`), the way a
graph takes it; `gadget.amount(value, unit)` is the text the kit shows — a
whole number without a fraction, any other with one decimal. The sizes assume a
widget 20 cells wide. The panel takes one cell on each side, so the body of a
`width × height` widget is `(width − 2) × (height − 2)`: the weather (a stat
and two lines) is 20×7, the heap monitor (a meter and a four-row history) 20×8.
The SDK has one interface font, so a stat's "big" value is room, not size.

### How the shell draws it

Widgets stand in a column at the right edge, `x = width − w` (one column in
from the edge, as the icon grid is one in from the left), the first one row
under the top of the desktop, one empty row between. The first that does not
fit under the previous one opens a second column, one empty column left of the
first column's widest; a widget that fits in neither is not drawn and has no
hits. A widget wider than a third of the screen is drawn, and laid out, at a
third. Icons are drawn over widgets and windows cover them. The layout and the
hits are `butschster.windows.shell:gadgets`, one table for both themes: one
record per widget row in `hits.desktop`, after the icons' — `{row, from, to,
widget = id, entry = meta.opens, title}`.

In cells the panel is `widgets.panel` with the title in its top edge, the body
`ui.plan` + `cells.rows` at the inner rectangle. In pixels every widget row is
one placement `widget:<id>:row:<n>` holding its slice of the frame and of the
body, and only rows whose content changed are repainted: `render.tree_rows`
is `render.rows` for a tree that is not a window's client — the same row keys
and the same one rasterisation, plus a `key` and a `decorate` function for the
frame painted into the same rows. `render.forget(id)` drops a gone widget's
keys.

## Open: a window record sized in pixels

A window entry names its size in cells (`meta.width`, `meta.height`), and one
number of cells is a different dialog at every cell size: "Display Properties"
is 46×24 cells — 460×480 px at a 10×20 cell, 368×384 px at 8×16 — while the
Windows 95 original is 404×448 px. The layout inside already speaks pixels
(`size_px`, `padding_px`, `width_px`); the record cannot. The fix belongs to the
base: `meta.width_px` / `meta.height_px`, converted to whole cells by the
compositor, which is the one that knows the cell. Not started — it is a change
to `butschster/tui-desktop`, not to this module.

## Checks and adding capabilities

Before a new application, read the [skill](../skills/wippy-window-app/SKILL.md).
The main checks: discovery through the registry; opening in both modes; shrinking the
client; scrolling a long and an empty list; data changes; key release;
dragging the scrollbar past the window edge; closing and releasing resources.

`make lint` and `make test` run with the local build that has `gfx` (see the Makefile).
The runnable example and the SDK tests are in `test/src/sdk_*`; the test writes
`test/shots/sdk-controls.png`. The screenshot is needed in addition to the geometry check.
The test stand of the whole application is checked separately from the module harness.

A new shared component is first added to the SDK with one layout, input handling
and two renderers; then windows use it. Add a behavior test
and a description of the contract to this file. The [migration audit](sdk-audit-2026-09-08.md)
shows which existing windows use the specialized level.
