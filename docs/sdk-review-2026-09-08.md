# Window SDK review and component unification — 8 September 2026

What was checked: `src/sdk/*` against `docs/sdk.md` and the tests; every finished
window against the SDK and the base's libraries (`geometry`, `scroll`, `input`,
`window_api`); all application buttons against the Windows 95 reference. Separately —
what the [migration audit](sdk-audit-2026-09-08.md) called done and what of it
is not confirmed by the code. Here is the answer to one question: **what should become one
component, but currently exists in several variants.**

What was fixed in this review right away is marked "✔ fixed"; the rest is a
plan, point by point, in order of execution.

## 1. Verdict on the SDK

The mechanics are correct and the only ones in the project where a button behaves as in
Windows: it is armed by pressing, fires on release inside, is cancelled by
moving the mouse away; key release and the right button are ignored; Tab moves
focus. The tree is plain tables, one plan for drawing and hits. This is a
foundation worth keeping; windows written "after the Task Manager's example" are
worse than it on all these points.

What in the SDK does not hold up to its own contract:

- **A1** — Defect: `list_event` took the offset from the plan, not from the state: two wheel steps in a row without a redraw lost the first; Where: `ui.lua`; Status: ✔ fixed
- **A2** — Defect: A label with an `id` took focus on click, but it is not in `focusable` — Tab silently died until the window was restarted; Where: `ui.lua`; Status: ✔ fixed; 2026-09-11 — also for the other passive kinds with an `id` (`field`, `group`, `statusbar`, `image`, `graph`, `gauge`…): the click checks `passive`, not the name `label`
- **A3** — Defect: A click on the scrollbar column when there was nothing to scroll selected a row; Where: `ui.lua`; Status: ✔ fixed
- **A4** — Defect: The wheel scrolled the list while a button was armed or the thumb was being dragged; Where: `ui.lua`; Status: ✔ fixed
- **A5** — Defect: The button in cells was drawn as its own "[ … ]": no bevels, no black `default` outline, no pressed state — not Windows and not what Run and the explorer draw; Where: `cells.lua`; Status: ✔ fixed: `widgets.button` with `default/pressed/disabled/focused`
- **A6** — Defect: An error in `view`/`update` (for example, two identical `id`s) tears down the window bypassing `dispose`, `desktop.close`, `tty.stop`; in cells the terminal is left with the cursor hidden; Where: `app.lua:58-62`; Status: ✔ fixed: `pcall` around `init/view/update/plan`, a fallback tree with "Close"; 2026-09-11 — under the same guard: the cell frame (`cells.rows`/`surface:present`), event parsing and `ui.event`
- **A7** — Defect: `assert(desktop.publish_state(...))` and `assert(desktop.close(...))` turn a regular refusal by the compositor into the death of the window; Where: `app.lua:32,62`; Status: ✔ fixed: a compositor refusal is not the death of the window
- **A8** — Defect: The shared renderer checks only `state.sdk == 1`; a state without `interaction` brings down the frame of the whole shell (`chrome_pixels` calls `placement` without `pcall`); Where: `render.lua:12-13`; Status: ✔ 2026-09-11: `render.placement` checks the shape (`ui` is a tree, `interaction` is substituted as empty) and the tree itself via `ui.problem` — a bad tree gives text in the window, not an error. A `pcall` around the view in `chrome_pixels` is deliberately NOT placed: a caught error in go-lua tears upvalues in the frames below as well, that is, in the compositor's loop (a tripwire in `sdk_test`)
- **A9** — Defect: The renderer mutates `interaction` (offsets, focus) in the compositor's copy of the state; the plan is built before `store.take` and thrown away when `dirty == false`; Where: `render.lua:13`; Status: plan
- **A10** — Defect: The `app.run` loop is closed: only events and one timer. There is no channel for `desktop.replies()` (needed by Run and the explorer) or for the window's own data; `update` is synchronous. This is the main thing blocking the move of Run and Task Manager; Where: `app.lua:40-45`; Status: ✔ fixed: `context.watch/unwatch`, `close` and `key` as actions, `update` may return `false`
- **A11** — Defect: `interaction.offsets/editors` are not released when the tree changes; `capture`/`armed` are not cleared if the compositor removed the capture without a `release` (minimizing); Where: `ui.lua`; Status: ✔ fixed: `ui.plan` releases the records of vanished controls, clears capture and arming
- **A12** — Defect: `selected` accepts only a row number, although the document advises keeping the selection by ID; `selected == nil` + "down" gives the second row; Where: `ui.lua`, both renderers; Status: ✔ fixed: `selected` accepts an item ID; 2026-09-11 — with no selection the arrow selects the first row (list, table, tree, icons)
- **A13** — Defect: "Raw" keys do not reach the application: Esc, F5 cannot be handled; `close` does not reach `update`; Where: `ui.event`, `app.lua`; Status: ✔ fixed
- **A14** — Defect: Space on a button works only when `key_type == "runes"`; Shift+Tab depends on the terminal (`backtab` is not normalized); Where: `ui.lua`, `input.lua`; Status: plan

Divergences between the two renderers of one component (what the "one plan
for both backends" contract does not guarantee by itself):

- **`default` on a button** — Cells: did not exist; Pixels: black outline; Decision: ✔ now `widgets.button{default}`
- **press (`armed`)** — Cells: did not exist; Pixels: sunken; Decision: ✔ now `widgets.button{pressed}`
- **focus** — Cells: inversion of the whole button; Pixels: dotted line; Decision: ✔ inversion of the caption only; there is nothing to draw a dotted line with in cells
- **list row indent** — Cells: 0; Pixels: 3 px; Decision: plan: 1 cell and `cell.w` px — one constant
- **right margin in a table** — Cells: 1 cell; Pixels: 4 px; Decision: plan: the same rule
- **text clipping** — Cells: cut off; Pixels: ellipsis; Decision: plan: ellipsis in both (`widgets.clip` can do it)
- **field/button height** — Cells: the whole rectangle; Pixels: ≤ 23 px, centered; Decision: plan: one height in cells, `cell.h`
- **scrollbar** — Cells: `░` track; Pixels: bevels only; the list and the table draw thumbs of different widths; Decision: cells ✔ 2026-09-11 — the list, table, tree and icons draw it with one `widgets.scrollbar`; pixels — plan: one scrollbar function in `pixels`
- **`disabled` on list/table/tree/icons** — Cells: ✔ `face_dim`, no highlight; Pixels: ✔ face and grey text, no highlight; Decision: ✔ 2026-09-11, like a disabled input field

## 2. The migration audit against the code

**Historical (2026-09-08).** The files this section cites as
`taskman/layout.lua:448`, `run/render.lua:67` and `controller.lua:67-74` no
longer exist: Run, the calculator, Task Manager and the registry viewer moved to
the SDK the same day, and their own layouts, controllers and renderers were
deleted — see §5. The findings stay as the record of why that was done.

The audit honestly calls the specialized windows specialized; but
several "uses the shared …" claims are not confirmed by the code:

- "Task Manager … normalization/reveal of the selected row use the shared
  `scroll`" — true, but **there is no input normalization in cells** (`taskman/window.lua:341`),
  `pgdn`/`page_down` are not normalized; the "Refresh" button exists and can be pressed **only in
  pixel mode**; there are three implementations of tabs (`widgets.tabs`, `taskman/render`,
  `datetime/render`); the `"track"` branch in `taskman/layout.lua:448` is not connected to
  `scroll.drag` — a dead path.
- "Run … uses the shared window API and normalization" — true, but **its line
  editor is entirely its own** (`run/model.lua:5-63`) although `sdk/editor.lua` exists,
  and **one dialog draws `default` by two rules**: in pixels it is always "OK"
  (`run/render.lua:67`), in cells — whichever button has focus (`run/window.lua:52`).
  Enter meanwhile does one thing, while something different is shown.
- "Date/Time … only a left click activates the buttons" — true, but `state.pressed`
  **is never published** (`render.lua:290` is dead), "OK" has no `default`, although
  Enter presses it; the ▾ and spinner buttons are mere props with no hits.
- "Registry viewer … shared event normalization and bounds" — true, but alongside
  its own `PAGE_UP/PAGE_DOWN` and its own `reveal` remain (`controller.lua:67-74,168-169`).
- "My Computer … the bounds are computed by the shared `scroll`" — true; but the
  toolbar, the address bar and the menu in pixels are drawn **anew** by their own
  code (`render_pixels.lua:74-160`), not by what draws them in cells; the menu accelerator is
  underlined in cells and not underlined in pixels, and works nowhere.

## 3. Buttons: ten painters of one part

- **`widgets.button` (cells)** — Drawn with: its own; Missing to match the reference: ✔ now `disabled`, `focused`; the accelerator was already there
- **`pixels.button` (pixels)** — Drawn with: **the reference**: default, pressed with a shift, etched, dotted focus; Missing to match the reference: no accelerator; the caption is centered on the original rectangle, not on the shrunken `default` one
- **SDK cells** — Drawn with: was "[ … ]"; Missing to match the reference: ✔ now `widgets.button`
- **SDK pixels** — Drawn with: `pixels.button`; Missing to match the reference: accelerator
- **window title bar, cells `chrome.lua:386`** — Drawn with: its own `bezel`; Missing to match the reference: no pressed state
- **window title bar, pixels `chrome_pixels.lua`** — Drawn with: `pixels.button` 16×14, glyphs `pixels.caption_mark`; Missing to match the reference: brought to the Windows 95 metrics (18 px bar, 4 px frame) — see README "Pixel geometry"
- **"Start", pixels `chrome_pixels.lua:463`** — Drawn with: `pixels.panel` + `bevel`; Missing to match the reference: not `pixels.button`
- **explorer toolbar, pixels `render_pixels.lua:102`** — Drawn with: `pixels.panel/bevel`; Missing to match the reference: not `pixels.button`; single bevel
- **address bar ▾ (both)** — Drawn with: `bezel`/`panel`; Missing to match the reference: is never pressed
- **test stand: `window_calc.lua`, `gfx_demo.lua`, `win95_demo.lua`** — Drawn with: three of their own; Missing to match the reference: flat tiles / local copies of `bevel`

Inconsistencies of behavior:

- **Moment of activation.** On release inside — only the SDK. On press — calc,
  datetime, run, taskman, explorer, regedit, the compositor. Rule: activation on
  release inside, as in Windows; for the keyboard — Enter and Space on the focused button.
- **Right button.** Ignored everywhere except the base's compositor
  (`library.lua:1271`): a right click on the title bar closes the window, on "Start"
  opens the menu. Fixed by one check `event.button == "left"`.
- **`default`.** Exists in Run and in the SDK; missing where Enter actually works —
  datetime "OK", ✔ appwiz ("Close", "Yes", "Write" are now marked).
- **`disabled`.** Etched only in `pixels.button`; `widgets.toolbar` and the explorer's pixel
  toolbar are just grey; the explorer answers a click on a disabled button
  with a message instead of silence.
- **Accelerators.** `widgets.accel` is not used by any button of the product;
  `pixels.button` cannot underline — in pixels there are physically no accelerators.
- **Focus.** The concept exists only in the SDK and Run. Tab traversal — only there as well.

## 4. Duplicates that must be reduced to one

- **`whole()`** — Copies: 30; Canonical: `geometry.whole` — import it, do not rewrite it
- **UTF-8 splitting** — Copies: 7; Canonical: `editor.runes` (or `text.runes` in the base)
- **clipping/ellipsis** — Copies: 5; Canonical: `widgets.clip/fit` (cells), `pixels.ellipsize` (pixels)
- **input visibility window + line editor** — Copies: 3 + 1; Canonical: `sdk/editor`
- **scrollbar** — Copies: 6 painters over one `scroll.bar` (2026-09-11: the four built-in copies in the SDK cells reduced to `widgets.scrollbar`); Canonical: `widgets.scrollbar` and one `pixels.scrollbar`
- **hit on the scrollbar** — Copies: 3 bypasses of `scroll.pointer`; Canonical: `scroll.pointer`
- **"reveal the selected row"** — Copies: 2; Canonical: `scroll.reveal`
- **status bar** — Copies: 4, none in the SDK; Canonical: a `statusbar` component with two renderers
- **tabs** — Copies: 3; Canonical: a `tabs` component
- **column widths** — Copies: 2; Canonical: `ui.columns`
- **double-click threshold** — Copies: 2 constants; Canonical: one in `input`
- **Page Up/Down aliases** — Copies: 3; Canonical: `input.normalize`
- **periodic tick** — Copies: 4; Canonical: `definition.interval`
- **unpacking the compositor's reply** — Copies: 2; Canonical: a helper in `window_api`

## 5. Unification plan, in order — and what of it was done on 2026-09-08

Done the same day (all suites green: base 58, shell 191):
one button per backend (`widgets.button` with all states, `pixels.button`
with an accelerator; "Start", the explorer toolbar and ▾, Task Manager's "Refresh",
the date dialog's "OK", both Run modes — on it; the compositor reacts only to the left button);
components `statusbar`, `tabs`, `menu`, `table` (also without a header), `tree`,
`group`, `graph`, `gauge`, `field`, `image`, `label.alert`; the `app.run` loop
rewritten (see A6–A13); **Run, Calculator, Task Manager and the registry
moved to the SDK entirely**, their own layouts, controllers and
renderers deleted, `chrome_pixels.VIEWS` shrank to the explorer, pictures and
"Date/Time"; `whole()` replaced with `geometry.whole` in 18 files, seven
UTF-8 parsers reduced to `desktop:text.runes`, the graph and the ceiling — into
`sdk:charts`. Along the way a VM trap was found: after an error under `pcall` a closure
and its owner stop sharing a local variable (the test stand's CLAUDE.md).

In a second pass: "Date/Time" on the SDK (components `calendar` and `clock`),
`selected` by ID, releasing `interaction`, one scrollbar and one
status bar in pixels (`pixels.scrollbar`, `pixels.statusbar`) for the SDK
and the explorer; the explorer toolbar fires on release inside the button,
a disabled one stays silent. Remaining: the explorer, Notepad and pictures — their own
renderers (by decision: an icon grid, text with horizontal scrolling and
a picture are not form components).

1. **The button — one in cells, one in pixels, both with the full set of states.**
   `widgets.button` (✔ default/pressed/disabled/focused/accel) and `pixels.button`
   (add an accelerator, center on the shrunken rectangle). Move onto
   them: the window title bar and "Start" in both chromes (with one geometry of the title bar
   buttons), the explorer toolbar and ▾ in pixels, Task Manager's "Refresh" in both
   modes, the datetime buttons (and publish `pressed`), the calculator (already
   `pixels.button`). The compositor — a left-button check. Activation everywhere on
   release inside — through a `ui`-like `armed`, moved out into `input`.
2. **Components that four windows lack at once:** `statusbar`, `tabs`,
   `menu` (the window's menu bar; item tables are already declared by the explorer,
   the registry, the calculator). Each — one layout, two renderers, a behavior
   test, a paragraph in `docs/sdk.md`.
3. **The `app.run` loop:** additional channels (`definition.channels` or
   `context.watch(ch)`), `pcall` around `view/update` with cleanup, a regular refusal of the
   compositor without `assert`, `close` and raw keys as actions in `update`.
   Without this, Run and Task Manager do not move to the SDK.
4. **Moving windows:** Run (after 3 — the whole interface is `label + input + 2 button`),
   the calculator (needs `menu` and a button caption colour), Task Manager's
   "Applications"/"Processes" tabs on `table` (needs `tabs`, the graphs stay its own),
   the registry's right pane on `table` + `split`. The explorer, Notepad, pictures
   remain their own renderers, but must give up the duplicates from §4.
5. **Duplicates from §4** — mechanically, file by file; checked by the copy
   being deleted, not by "it works anyway".

Each item is closed by a behavior test in `sdk_test.lua` and a screenshot; the rule
for checking a new test is to break it with a mutation.
