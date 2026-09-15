# FR-005. Pixel chrome, cell content

Copied from the kickside application repository
(`docs/rfcs/005-pixel-chrome.md`, written 2026-09-08) so that the module's
references resolve inside a clone of this repository; translated to English on
2026-09-11. The application copy remains the original; if the two differ, the
original wins.

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** proposed, 2026-09-08. Supersedes the pixel part of FR-002
(`docs/rfcs/002-windows-shell.md` in the kickside application repository); the
window model of FR-004 (`docs/rfcs/004-window-model.md` in the kickside
application repository) is not affected.
**Decision made by a human on 2026-09-08** after the cost of the full screen
had been measured.

## 1. The idea in one sentence

> **Everything the shell draws is drawn in pixels. Everything a program draws
> inside a window stays text in cells.**

The frame, the title bar, the title bar buttons, the desktop icons, the
taskbar, the Start menu, dialogs — rasters. Bash, htop, a file list inside a
window — characters, as now.

## 2. Why not the whole screen

Measured on this stand; the terminal is Windows Terminal over ssh, the cell is
**10×20 pixels** (the terminal answered `CSI 16 t`).

- Whole screen 100×28 (1000×560 px) — encoding **47 ms**, 131 KB
- One window 500×280 — encoding 12 ms, 31 KB

sixel supports neither partial updates nor deletion by name. 47 ms and 131 KB
would be spent on **every keypress** in a window with bash, and over ssh that
is noticeable.

**The first thing worth knowing about the cost:** it comes from the number of
pixels, not from the complexity of the picture. A single-colour desktop
1000×540 encodes in 43 ms and weighs 2.6 KB — the encoder visits every pixel.
So what has to be optimised is the AREA of the redraw, not the content.

## 3. The trap everything else is built around

The surface compares rows and redraws the ones that changed. A placement that
covers a redrawn ROW is sent again — otherwise the text would wipe out part of
the picture, and nobody would notice: for the row itself nothing changed.

Hence a consequence that breaks a naive implementation:

> **If a window's chrome is one placement over the whole window rectangle,
> every keypress inside the window redraws the whole chrome.** Those are
> exactly the 47 ms we avoid by not drawing the whole screen.

So the chrome is cut into pieces by ROWS:

*(Below are the costs of the pieces if everything were drawn in pixels. Since
§3a the fill moves into cells and only the thin pieces remain.)*

- Top edge + title bar — rows: its own; touched by typing: no; cost 2.0 ms
- Left edge — rows: the content rows; touched by typing: **yes**; cost 0.36 ms
- Right edge — rows: the content rows; touched by typing: **yes**; cost
  0.36 ms
- Bottom edge — rows: its own; touched by typing: no; cost 1.0 ms
- Taskbar — rows: its own; touched by typing: no; cost 1.6 ms
- Desktop with icons — rows: its own; touched by typing: no (redrawn when a
  window moves); cost 43 ms

So a keypress costs **0.76 ms and 1.7 KB** — two thin strips.

**Rule:** a piece of chrome must not share rows with changing content more
than is unavoidable. The side edges — unavoidably; everything else — no.

### This is already pinned in the runtime

`present` returns **`placements_sent`** — how many rasters were actually sent,
as opposed to how many the frame declared. That is the measure of §3 and §4,
and it has to be looked at, not reasoned about: if the chrome is cut wrongly,
the screen stays CORRECT, it just becomes slow, and slowness has no stack
trace.

The scenario is pinned by the test `TestOnlyChromeSharingRowsWithTextIsResent`
(`service/terminal/graphics_test.go`): a window of four pieces plus a taskbar,
one content row changes — exactly two placements are sent, the side edges. A
frame without changes writes not a single byte. Mutations confirmed that the
test goes red.

## 3a. Pixels only where cells cannot cope

Found while trying to build a demo from this very specification, that is,
before the teammates ran into it.

The desktop raster covers the rows on which the window content lies. By the
rule of §3 this means every keypress resends **the whole desktop** — 43 ms.
Cutting the desktop into strips around the window is possible, but that is
arithmetic in every frame, and it will drift apart at the first window move.

The answer is simpler and changes the rule:

> **Fills stay cells. Only what a cell cannot provide is drawn in pixels.**

A cell can do exactly one background colour — and does it PERFECTLY. The teal
desktop `#008080`, the grey window face `#c0c0c0`, the blue title bar
`#000080` — all of these are fills, and in cells they are exactly as precise
as in pixels.

Pixels are needed where there is a BOUNDARY inside a cell:

- Desktop background, window face, taskbar background — with: cells; why: a
  fill, the cell is exact
- 3D edge, frame, sunken area — with: pixels; why: the boundary runs inside a
  cell
- Icons — with: pixels; why: a 32×32 raster
- Labels and titles — with: pixels; why: a glyph is needed, not a character
- Content of a foreign window — with: cells; why: it is text

Hence the cost of a keypress: on the content rows there are only two side
edges one cell wide. Everything else on those rows is fill. **0.76 ms.**

This also settles the question "what if two windows are on the same row": the
fill between them is cells, not a picture.

**A trap that was hiding here and has already been defused — but it hangs on a
single line.** The fill colour in cells and the colour in the raster must match
EXACTLY, otherwise the seam between them is visible. The cell is coloured by
lipgloss, and it converts the colour to the terminal's profile: with the
ANSI256 profile `#c0c0c0` would become the nearest of the 256, while the raster
would give the exact one.

Verified: the runtime **forces TrueColor**
(`runtime/lua/modules/tty/module.go:27`). Also verified why this matters:
`COLORTERM` over ssh is empty, `TERM` is `xterm-256color`, so without that line
the profile would be detected as 256-colour and there would be seams
everywhere.

So the rule: **do not rely on profile detection and do not remove the forced
TrueColor.** If it ever goes away, the symptom will not be an error but "the
frame is a slightly different grey from the window" — and it will be looked
for in the drawing code.

## 4. Second rule: rasters outlive the frame

A placement is sent again when its `version` changes. `version` advances on
every write into the raster.

> **A theme that creates rasters anew every frame resends everything every
> frame** — and gets the same 47 ms, only in parts.

**And the version is not enough for this — identity is needed too.** A
recreated raster starts counting again; drawn with the same number of calls,
it arrives with THE SAME version. A clock showing 01:59 and the same clock at
02:00 would arrive indistinguishable, and the surface would leave 01:59 on the
screen. Not a slow screen but a **wrong** one, and without a single sign of
malfunction.

Fixed in the runtime: `Placement` carries a `Serial` — the number of the buffer
itself, not of its content — and the surface compares that first. A recreated
raster is always sent again. Pinned by the test
`TestARebuiltRasterIsNotTheSamePicture`, with a control check that an
unchanged buffer still costs nothing.

So the theme MUST keep rasters between frames and redraw only those whose
state has changed. The title bar raster is redrawn when the text, the width or
the focus changed; the desktop raster when an icon was moved. No more often.

This is not checked by eye — but not by the version alone either: the check
"no version moved" stays GREEN when rasters are recreated, because the numbers
match. What has to be compared is **object identity** and the version. On the
runtime side that is `placements_sent`; on the theme side, that the raster is
the very same one.

## 4a. The mouse stays in cells, and this is a rule, not a limitation

The terminal sends click coordinates **in cells** — SGR 1006 knows no others.
So the hit layout must stay in cells, even when the paint is in pixels.

> **The position and size of an interactive detail are stated in CELLS; only
> the decoration inside it is free.**

The first wording was weaker — "the button is drawn as a real 16×14, and its
hit area is a whole number of cells" — and **broke on the very first probe
run**. Three title bar buttons 16×14 with an 18 px step: with a 10 px cell a
button takes two columns, the step of 18 is not a multiple of the cell, and
the zones overlapped:

```
✗ cell 26,1 belongs to two at once: minimize and maximize
✗ cell 28,1 belongs to two at once: maximize and close
```

A click on the shared column goes to whichever button was found first, and
**it is not visible in the screenshot at all**. The rule of a whole number of
cells per button was obeyed — and it did not forbid making those cells shared.

So quantisation is held **structurally, not by discipline**: drawing functions
take position and size in cells, and the inner padding (`inset`) is the only
thing given in pixels.

### Amendment: hits are computed by the layout, not by the drawing

The rule "drawing and hit-testing are computed from ONE table" was written
when there was one drawer. With two backends "one table" no longer means "the
function that draws" but the **layout** — a shared layer that computes the
geometry before any drawing and hands it to both.

Two backends that each compute hits their own way will drift apart silently: a
click will start landing on a neighbour in ONE of the two modes, while the
screenshot looks right. So the rule is not revoked but raised one level up.

In practice this means moving the geometry — the icon rectangle, the panel
coordinates — out of the drawing code, and comparing in a test what the layout
predicted with what the drawing returned: if they diverge by a cell, the test
goes red.

### Where an exact copy runs into the terminal

A dialog button in Windows 95 is 75×23 px. That does not fit the 10×20 grid,
and §4a outranks the reference proportions: a button with a non-whole number
of cells catches its neighbour's clicks. The button comes out 80×20.

There will be several more such places. **List them in one place** — otherwise
each one will be found anew and taken for unfinished work.

If the theme starts returning rectangles in pixels and the compositor divides
them by `cell_size`, then at the border between two neighbouring buttons the
rounding will decide who gets the click — and will decide wrongly, silently.
So hits remain as they were: `{row, from, to, id}`.

As a side effect, this is exactly why the transition is cheap: hit-testing,
layout and geometry do not change at all.

## 4b. How the content is drawn is declared by the entry

Here the specification almost left a hole exactly the size of the thing the
human had pointed at.

The window content stays cells — but **the shell's own windows are also
processes that write cells.** So inside the perfect pixel frame of "My
Computer" there would be terminal innards with `▢` icons. The showcase would
have stayed exactly as it was.

The first wording divided windows by who wrote the program inside. That is an
inference, and the next person will infer differently. **So the choice is
declared, and the entry declares it** — by the same rule the whole window
model rests on (FR-004, `docs/rfcs/004-window-model.md` in the kickside
application repository): the registry states, the shell executes.

```yaml
meta:
  type: tui_desktop.window
  window_content: pixels                        # cells (default) | pixels
  render: windows.shell.explorer:render    # pure drawing library
  state:  windows.shell.explorer:state     # provider process, its own actor
```

- `cells` (default) — what is inside: the process writes into its viewport;
  who draws: the process itself, as now
- `pixels` — what is inside: there is no process; who draws: the compositor
  calls `render` with a raster

**The default is `cells`, and this is not a matter of taste.** A foreign
program (bash, htop, Claude Code) can only produce cells and changes on every
keypress; a window whose entry says nothing about this field must behave as
before. Erring towards `cells` loses beauty; erring towards `pixels` loses
bash.

**A window with `pixels` must also be able to do `cells`.** A plain xterm has
no graphics at all (§8b), and a shell that can only do pixels dies there
silently. So `render` is one library with two backends: layout, geometry and
hits are shared, only the paint differs. The explorer is already built that
way.

**The price that has to be said out loud:** the explorer window now has ITS
OWN actor — `fs.get`, `db.get`, `registry.find`, without `spawn` and `exec`.
Once it became a view inside the compositor, these reads would move to a
process that can spawn processes and launch programs. A boundary drawn on
purpose would be erased.

So the declaration has two different names, not one: **drawing in the
compositor, rights outside.** `render` is a pure function with no runtime and
no rights. `state` is a process with its own narrow actor that obtains the
data and hands over ready state. The view does not obtain data.

## 5. The pixel theme contract

A theme with the field `chrome.pixel = true` works differently from the
current one.

What stays exactly the same:
- `chrome.layout(cols, rows)` — geometry in CELLS;
- `chrome.window_insets()`, `chrome.icon_grid()`, `chrome.BUTTONS` and the
  rest;
- **the hit layout**. Hit-testing is computed in cells and knows nothing about
  paint. That is exactly why the transition is cheap.

What appears:

```lua
-- Returns a list of placements and the hit layout.
-- Placement coordinates are in CELLS, 1-based, as everywhere here.
chrome.paint(state, cell_w, cell_h) -> {
    placements = {
        {id = "win:w1:title", raster = <gfx.Raster>, x = 10, y = 3, cols = 60, rows = 2},
        {id = "win:w1:left",  raster = <gfx.Raster>, x = 10, y = 5, cols = 1,  rows = 20},
        ...
    },
    hits = { ... as now ... },
}
```

- **`id` must be stable between frames.** By it the surface recognises the
  same picture; a changed id is a deletion plus an insertion, that is,
  flicker.
- **The list is complete.** A placement missing from the list is removed from
  the screen. This is how a menu is removed: by not drawing it.
- `cell_w`, `cell_h` come from `gfx.cell_size()`. The theme does not ask for
  them itself — otherwise on a terminal that does not answer it will draw the
  wrong size.

## 6. What the compositor does

1. Gets the cell size. **It is asked by the SHELL, not by the mechanics** — an
   entry that declares `modules: [gfx]` brings down the whole boot where the
   module is absent (`node with ID {gfx :gfx} not found`), and the base would
   become unusable for everyone who does not need pixels. Hence
   `run({cell_size = gfx.cell_size})`, while the decision stays in the
   mechanics. **No answer — pixel mode is not enabled**, and that is a
   refusal with a reason, not a silent fallback: a picture of the wrong size
   looks like a drawing bug, not like an unasked question.
2. Assembles the canvas as now, but **puts spaces under every placement**. A
   character under a picture is what will show from under it at the very
   first redraw of the row.
3. Takes the window content from the viewports, as now. It is NOT rasterised.
4. Hands over the frame: `surface:present(rows, {images = placements})`.

**The mode is enabled explicitly, not by the presence of graphics.** A
terminal that can do sixel is no reason to draw the interface differently from
what the human asked for.

## 7. Edge cases

- The terminal did not report the cell size — behaviour: pixel mode is not
  enabled, the reason is named. Why: the guess "8×16" is right often enough to
  look correct.
- The window went past the screen edge — behaviour: the raster is drawn whole,
  the placement is clipped to the screen. Why: clipping in the theme is
  arithmetic in every call.
- Two windows on the same row — behaviour: both pictures are resent when the
  row changes. Why: the row is redrawn whole, including `\x1b[K`.
- The terminal understands kitty — behaviour: the same code; kitty scales the
  raster into the cell rectangle. Why: it does not need the cell size, but it
  does not hurt either.
- The entry says nothing about `window_content` — behaviour: `cells` is
  assumed. Why: an error towards `cells` loses beauty, towards `pixels` loses
  bash.
- `window_content: pixels`, but there are no graphics — behaviour: drawn by
  the `cells` backend of the same library. Why: otherwise the window
  disappears in a plain xterm.
- `window_content: pixels` without `render` — behaviour: the window does not
  open, the reason is named. Why: silently opening an empty window is the
  worst of the outcomes.
- The raster has not changed — behaviour: it is not sent. Why: all the
  savings rest on this, see §4.

## 8. Acceptance criteria

1. **An edge one pixel thick.** The window frame on screen has an edge one
   pixel thick, not one cell (measure: a screenshot, visible by eye).
2. **Typing does not lag.** A keypress in a window with bash resends no more
   than two placements (measure: `placements_sent` in the `present` reply).
   **Verified on the live stand 2026-09-08: two rasters, 3.1 KB per
   keypress**; opening a window — 9 rasters, opening the menu — 1.
3. **A frame without changes sends nothing** (measure: `placements_sent == 0`
   and `bytes_written == 0`).
4. **The menu disappears.** A closed menu vanishes from the screen instead of
   staying behind as a picture (measure: its id is absent from the list, the
   screen is clean).
5. **Without a cell size — a refusal with a reason**, not a picture of the
   wrong size.
6. **One and the same library draws the window in both worlds** (measure:
   `render` is called with a raster and with a canvas, the layout matches, the
   hits are identical).

## 8a. The probe moves before the theme

**This is the first task, before any drawing.**

Today `themeprobe` prints the frame as text, and it has caught almost
everything that was found before the stand. If the pixel theme gets no such
probe, it will be checkable only on the stand and only by a human's eye — that
is, we will go back to exactly the loop we are leaving.

Two levels, and both are needed:

- **Pure Lua, no runtime.** A stand-in that implements the same methods as
  `gfx.Raster` (`fill`, `rect`, `set`, `text`) and records the calls. It
  catches layout, overlaps, hits — that is, almost all defects — and runs in
  milliseconds while the stand is busy.
- **A real PNG.** `raster:encode("png")` in `gfx`, a command that draws a
  frame and writes a file. It is opened and looked at by eye — the only way to
  see a glyph, an edge and a colour.

### The probe checks the parts, the screenshot checks the whole

These are different checks, and the second is irreplaceable. Found at a high
price: the pixel theme passed both the stand-in and the PNG of each piece
separately — and **a screenshot of the whole screen found three defects at
once**:

- the desktop icons had no labels at all — eight nameless squares;
- the windows had no title bar buttons;
- the window body was not filled, the desktop showed through it.

Each piece was correct. No test looked at the whole, and the defect lived
exactly there: not in a piece, but in pieces being missing.

So the screenshot is assembled **with `blit` at the same coordinates at which
the surface will place it** — then it lies exactly as much as the coordinates
lie, and no more.

### The check "a hit was found" checks nothing

The check I proposed — click the cell of the Start button and require that a
hit is found — **would have missed both real errors**, because the hit was
there. It simply was not readable:

- Start returned `id = "menu"` instead of `action = "menu"`. The compositor
  checks `spot.id` first, looks for a window named "menu", does not find one —
  and silently does nothing. The menu branch is unreachable altogether.
- The desktop icons returned ONE hit for three rows with a `bottom_row` field
  the compositor does not know: it matches `event.y == spot.row`. An icon
  would be clickable on its picture and not on its label.

The rule derived from this:

> **There is one compositor for both modes, so it is the compositor, not the
> theme, that dictates the shape of hits. A hit it cannot read is
> indistinguishable from a missing one.**

So the probe does not count hits; it **compares them with the character mode
on the same state** — by count and by the set of fields:

```
desktop: 9 hits, shapes broken,entry,from,id,kind,row,title,to | broken,from,id,kind,row,title,to
taskbar: 2 hits, shapes action,from,row,to | from,id,row,to
```

This is the only one of the night's errors that **could not have been found
without running it**: the contract lives in someone else's file, not in one's
own.

### The cost of a keypress is measured, not exempted from the check

The check "a placement has no right to cover content rows" looks right and
breaks on the desktop icons: they do cover them, and this cannot be removed.
The temptation is to exempt them with an exception, and that is a lie: they
really do cover and really do cost.

The right thing is to **sum the area and name the culprits**:

```
a keypress resends 16800 px (3.0% of the screen):
desk:f1 6600, desk:s2 6600, win:w1:left 1800, win:w1:right 1800
```

The threshold is derived, not assigned as a round number: a tenth of the
screen is 4–5 ms, and over ssh that is noticeable. A derived threshold can be
rechecked when the numbers change; a round one stays forever and one day turns
out wrong, silently.

## 8b. The fallback path in cells is not thrown away

Windows Terminal understands sixel and does not understand kitty at all; a
plain xterm has neither. A shell that can only do pixels dies there silently.

Two backends in a theme are fine precisely because the layout, geometry and
hits are shared. The cost of the fallback path has already been paid:
`widgets`/`icons` compute the numbers, `chrome`/`render` lay down the paint.

## 9. What carries over from the work in cells

Everything except the last layer. Carried over: the layout, the palette with
exact values, the menu cascade, the registry model, "My Computer" with `fs.*`
drives, scrolling, hit-testing, the three window types, dialogs and their
kinship, menu filtering.

Not carried over: `widgets`, `glyphs` and everything that puts characters into
cells. The icon grid numbers will have to be recomputed in pixels — but the
rule because of which they once drifted apart stays: **the step and the size
of the picture are different numbers.**

## 10. What is still missing

- **Bold weight** as an option — that is a separate font file and a separate
  `Font` object. The window title in Windows 95 is set in bold, so it will be
  needed.
- **Scaling when blitting.** An icon is placed at its own size.
- ~~PNG loading~~ — **exists**: `gfx.image(bytes)` decodes PNG/GIF/JPEG into a
  raster, `raster:blit(source, x, y)` places it with transparency. So the real
  Windows 95 icons (32×32 raster) can be taken from a file rather than drawn
  with primitives. There is no scaling: with a 10×20 cell a 32×32 icon takes a
  little more than three cells in width and less than two in height.
- **Clipping of a picture by a foreign window.** The compositor knows about
  placements but does not compute intersections: a window that slides over the
  menu will cover it with text, and the surface will resend the menu on top.
  Visible as flicker, not as breakage.
