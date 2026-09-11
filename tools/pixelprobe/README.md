# pixelprobe — the pixel probe

The first of two levels of checking the pixel theme ([FR-005](../../docs/rfcs/005-pixel-chrome.md) §8a). It runs
the REAL `src/shell/pixels.lua` and `src/shell/rasters.lua` outside the runtime,
substituting `gfx` with a pure-Lua stand-in, and prints three things:

- **a map in CELLS** — one letter per cell, the dominant color; text as a
  capital letter, so that a filled rectangle and a caption of the same color
  do not look the same;
- **the hit layout next to the map**, in the same units in which the mouse
  sends coordinates;
- **checks** that cannot be seen on a snapshot.

```bash
make probes             # from the module root: rebuilds combined.lua for both probes
cd tools/pixelprobe
go build ./...          # the path to go-lua in go.mod is ABSOLUTE, adjust it for yourself
./pixelprobe combined.lua
```

`combined.lua` is generated and not stored in git, so it goes stale silently:
a probe run on an old one checks yesterday's theme and prints a clean map.
`make check-probes` builds both probes in memory and fails when a file on disk
differs from `harness.lua` plus the current sources (`build.py --check`).
Neither target is part of `make lint` or `make verify`: the probes are a tool
you run, not a gate.

## What it asserts, not only shows

**Two hits may not share a cell.** This is not nitpicking, and it does not
show on a snapshot at all. Three title buttons 16 px wide at an 18 px step
look flawless, but at a 10 px cell their areas overlap: a click on the shared
column belongs to two buttons at once, and whichever is found first wins.
Silently. The probe caught this on its very first run — the scene had been
written in pixels. Hence `pixels.box`: the place and size of an interactive
detail are named in cells before painting, the hit is the same cells from the
layout, and only the drawing inside is free. Primitives return no hits.

**A frame without changes moves no version at all** — the main measure of [FR-005](../../docs/rfcs/005-pixel-chrome.md) §4.
If rasters are recreated every frame, the screen stays CORRECT, everything is
simply sent again; slowness has no call stack.

What is compared is **the raster's identity, not only its version**, and this
came out through mutation: a store that recreates the raster every frame hands
out a fresh buffer, the drawing code repeats the same calls — and the version
comes out THE VERY SAME. The numbers match, while everything is sent to the
screen. Only identity tells them apart: the surface can tell that the picture
has not changed only as long as it is the same raster.

## The caveat without which the probe becomes a false witness

**The stand-in does not know the real font metrics.** `font:measure` computes
the width by approximation, not from glyphs, so the probe checks THE LAYOUT
GIVEN THE MEASUREMENTS, not the measurements themselves. A caption that will
not fit into a button on the running system will fit here.

Measured how big the lie is: the "My Computer" caption (measured while it was
still in Russian) in a 13 px font — 94 px on live `gfx` against 91 for the
stand-in. Small, but not zero, and on a long line it will diverge more.

Only the second level can do the real metrics.

## What it covers now

`tty` is stubbed here together with `gfx`, so this probe runs not only the
primitives but **the explorer's whole pixel backend** — `render.layout` and
`render_pixels.paint` — without the runtime or a local build. The two probes
are not merged: the cell theme keeps its own probe, `tools/themeprobe`, because
it needs a text canvas, and the `tty` stub here deliberately has none.

The `tty` stub can do EXACTLY as much as is needed for the libraries to load:
only `tty.style()`, because `widgets` and `icons` build style tables at load
time. **It has no canvas at all**, and that is a condition, not an economy: a
stub that starts pretending to be the real `tty` will diverge from it, and the
checks will start lying in the other direction. The layout draws nothing, the
pixel backend draws into a raster — the probe has no need to draw into cells,
and an attempt fails loudly instead of quietly drawing into nowhere.

What is checked is the slicing and the keys, that is, exactly what cannot be
seen on a snapshot:

- placements do not share rows — otherwise redrawing one touches the other;
- an icon's hit lies inside its own placement — otherwise a click leads to a
  picture that is not there;
- the same frame once more moves nothing;
- a change of selection redraws the field and the status line — and **by
  enumeration, not by count**: "two were redrawn" would also pass on the pair
  "field and menu", that is, on a real error.

## The second level: a real PNG

```bash
cd test && wippy run --host wippy.terminal:host paint-png 10x20
```

It writes `test/shots/*.png` and `test/shots/report.txt`. The snapshot is
opened and looked at with your own eyes — this is the only way to see a glyph,
an edge and a color. It is drawn by THE SAME primitive code as the first level.

Two things worth knowing about this command:

- **`print` from it does not reach the outside.** Measured: the snapshots were
  written, and not a single line appeared. That is why the report is written
  to a file — a report told only to the log is told to no one.
- **It cannot ask the terminal for the cell size**, because it has no
  terminal: it writes files, it does not draw on a screen. The number is given
  as an argument, and the report writes where it came from. Without an
  argument a fallback value is taken, and this is said in capital letters: the
  guess "8×16" is right often enough to look correct.
