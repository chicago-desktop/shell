# Frame cost: where the time goes

In cells the shell is cheap and is not where a slow screen comes from. In
pixels the cost is the encoder, and it is paid per pixel sent. Everything
below follows from those two facts.

## The frame path

1. **The compositor rebuilds the canvas** after every state change
   (`chicago.tui_desktop.desktop:library`, `draw`). In cells the theme
   paints `fill`, `window`, `bars` and `menu`; in pixels `chrome.paint` returns
   placements and `pixels.frame` blanks the cells under them.
2. **The runtime surface diffs and sends** (`service/terminal/surface.go`,
   `Present`): only changed text rows are written, and a placement is sent when
   it is new, changed (buffer identity, version, place) or covers a repainted
   row.
3. **A sent placement is encoded** — sixel with the exact palette of a picture
   of up to 256 colours (the general median-cut encoder beyond that), or kitty
   as RGBA with zlib.

A PTY window's updates are coalesced to the latest by the runtime's update
bridge, so a window produces at most one frame per compositor loop: a flood of
output is a few frames, not thousands.

## Measured

- **Cells** (probe, 120×36, 2026-09-11): 2.7 ms per frame on average, 4.6 ms
  at worst; 2.4 ms of it is the theme in Lua, 0.36 ms the surface.
  `yes | head -2000` arrives as three frames.
- **Pixels** — about 100 ns per pixel, whatever the picture: a 500×300 SDK
  window is ~19 ms per send, the whole screen 47–60 ms (1000×560: 47 ms and
  131 KB in [RFC-005](rfcs/005-pixel-chrome.md)). A flat 1000×540 raster still
  takes 43 ms — it only weighs 2.6 KB. A many-colour 500×300 gradient: 93.6 ms
  as sixel, 10.5 ms as kitty.
- **A keystroke in a pixel window** costs its two side edges: 0.76 ms and
  1.7 KB (RFC-005), because the chrome is cut by rows (below).

**Optimise the area resent, not the drawing.** A cheaper paint does not help a
frame that re-encodes the same pixels.

## Measured 2026-09-17 (chicago-desktop/app#2)

A driven SSH session at 190×50 cells, 10×20 px: logon, 15 s idle (widgets
ticking), a Bash window opened with alt+n, a line typed, the window dragged
along a 60-step path, the Start menu opened and closed. Frames from
`/api/v1/chicago/status?frame_samples=1`, split by phase; ms is `total_ms`
per frame, KB is bytes written per frame. "Old" is runtime
v0.3.40a-chicago.4 as released, "new" the same with the encoder, palette,
cache and stacking changes; the Lua is the same in both.

```text
wallpaper  phase   old sixel ms  new sixel ms  old KB  new KB  kitty ms     kitty KB
none       idle    11.6 / 32.3   5.9 / 9.6     10.9    8.6     7.6 / 11.2   3.1
none       typing  8.7 / 19.2    5.0 / 13.3    9.6     8.4     5.8 / 16.9   1.0
none       drag    13.8 / 26.5   5.6 / 10.5    57.3    51.8    5.4 / 10.7   0.8
none       menu    15.1 / 29.8   7.3 / 9.1     10.9    11.8    9.1 / 12.2   5.0
Rivets     idle    14.7 / 22.7   11.3 / 14.8   10.3    9.3     11.2 / 14.9  2.9
Rivets     typing  14.1 / 21.7   13.8 / 21.2   13.8    19.3    10.1 / 20.8  1.0
Rivets     drag    20.4 / 84.7   15.8 / 39.4   207     404     10.7 / 53.8  1.3
Rivets     menu    33.4 / 82.9   17.5 / 38.7   32.9    66.5    22.9 / 44.5  10.3
Sky        idle    11.0 / 19.2   7.5 / 12.9    9.1     10.5    14.2 / 24.5  3.1
Sky        typing  9.5 / 20.0    8.0 / 13.8    9.4     8.1     13.4 / 21.5  1.1
Sky        drag    15.0 / 89.2   8.8 / 18.2    69.3    72.6    13.6 / 47.5  1.2
Sky        menu    27.2 / 78.1   12.3 / 20.3   11.4    13.3    29.0 / 48.1  8.4
```

ms is avg / max per frame; "kitty" is the new runtime over kitty.

- **Time** is spent less everywhere, most at the worst frames: drag and menu
  under a wallpaper halve their maximum.
- **Bytes grow under Rivets.** Sixel has no layers, so the surface now resends
  whatever lies over a picture it sends (the widgets that vanished under the
  wallpaper). A repainted row resent its whole strip, and the strip brought
  everything on it along; cell-level damage (below) takes this back.
- **Kitty sends a picture once and puts it again by id**, so its bytes stay
  small whatever the wallpaper.
- `BenchmarkSixelEncode` (runtime, ns per pixel, before → after): title bar
  140 → 16, Rivets strip 114 → 19, full screen 88 → 5; a many-colour strip
  427 → 37 once the wallpaper is reduced to 256 colours at decode
  (`gfx.image(data, {colors = 256})`).

### After cell-level damage (app#8)

The same session once the surface repaints changed cells instead of whole
rows, re-sends only the pictures over those cells, and cuts a wallpaper row
in 32-column pieces over Sixel (whole rows over kitty). Sixel ms is avg / max,
KB per frame.

```text
wallpaper  phase   sixel ms      sixel KB  kitty ms      kitty KB
none       idle    7.6 / 12.2    9.6       9.2 / 13.4    2.9
none       typing  7.9 / 14.6    1.7       6.1 / 17.7    0.6
none       drag    8.4 / 13.8    14.1      6.0 / 16.8    0.7
none       menu    11.2 / 12.8   11.2      12.6 / 19.5   5.9
Rivets     idle    21.6 / 30.2   8.9       10.8 / 17.6   3.0
Rivets     typing  19.8 / 29.1   1.7       9.5 / 20.7    0.6
Rivets     drag    19.6 / 25.9   128       10.8 / 59.1   1.2
Rivets     menu    19.7 / 23.5   21.8      21.8 / 39.8   10.3
Sky        idle    24.3 / 34.0   9.0       10.0 / 13.2   2.9
Sky        typing  22.2 / 31.8   1.7       9.6 / 20.7    0.6
Sky        drag    22.2 / 38.3   27.0      10.1 / 16.2   1.1
Sky        menu    28.2 / 35.3   11.8      21.6 / 42.3   6.7
```

- **Typing** writes 1.7 KB a frame instead of 8-19 KB: only the changed cells,
  and no picture beside them.
- **A drag under Rivets** is 128 KB a frame instead of 404 KB (207 KB on the
  old runtime); without a wallpaper 14 KB instead of 52 KB.
- **The price is Lua time.** A row in pieces is six placements instead of one,
  about 10 µs of theme work each (`placements.visible`, the raster store, the
  cell blanking): +6-10 ms a frame at 190x50 under a wallpaper. That is why
  kitty, whose re-sends are short puts by id, keeps whole rows.
- **A full-width row keeps its last column.** The whole-row repaint used to
  write the row and then erase to the end of the line, which from the
  pending-wrap position erased the last cell; it now erases first.

## The encoded-placement cache

The runtime surface keeps the bytes of each placement's last encoding, keyed
by buffer identity, version, size, cell size and protocol; a resend with the
same key copies them. For sixel the cache holds the payload, not the command:
the position is added when it is sent, and only the six-row band phase
(`y % 6`) is part of the key, so a moved picture is not encoded again. The
cache is capped at 32 MiB (least recently written go first) and forgets a
placement that leaves the frame. With kitty an image the terminal already
holds is put again by id (`a=p`) instead of being transmitted again.

Kitty placements carry no placement id, and every transmit or put is preceded
by `a=d,d=i` for the image. WezTerm re-attaches a cell's placements that have
an id each time another image is attached there, which doubled a cell holding
a wallpaper strip and a widget on every frame until the terminal ran out of
GPU buffer (app#13). Every placement carries `z` in frame order: kitty stacks
equal z by image id, and ids are hashes of names.

`BenchmarkRasterOnARepaintedRow` — 100 presents of a 500×300 raster on a row
repainted every frame: sixel 93.6 ms → 2.1 µs per present, kitty 10.5 ms →
0.85 µs.

The cache lives in the local runtime build (`dist/wippy-linux-amd64`); a
released runtime does not have it yet.

`WIPPY_TTY_TRACE_DIR`, set in the runtime's own environment, records what
every surface writes (one length-prefixed record per frame) for replaying a
session through a terminal model.

## Rules that keep a pixel frame cheap

- **Chrome is cut by rows.** A placement is resent when a text row it covers is
  repainted, so a window frame is strips by row band — title, side edges,
  bottom. Typing repaints content rows and resends only the two side edges.
- **Rasters survive frames.** Themes take rasters from the store
  (`store.take(id, cols, rows, cell, key)`) and draw only when dirty. A rebuilt
  raster restarts its version, so the surface tells pictures apart by buffer
  identity (`Placement.Serial`), not by version alone.
- **The menu is on top by subtraction, not by order.** Sixel has no z-order;
  the surface resends whatever lies over a picture it sends, but a cut is
  still cheaper than a resend. `chicago.shell.theme:placements`
  cuts every other picture by the menu panels and by higher windows; a crop is a
  placement of its own, keyed by its source's version.
- **Pattern and wallpaper are strips.** One placement per desktop row under the
  icons, cropped by the windows over it: a moving window re-crops only the rows
  it covers. The pattern's eight distinct pixel rows are drawn once per pattern,
  colour and width into a shared row raster; the rest is a blit.
- **Fills stay cells.** The desktop, window faces and the taskbar background are
  cell colours; only edges, icons and captions are pixels.

## Where to read the numbers

`desktop.list` answers with `frame`: `paint_ms`, `present_ms`, `total_ms`,
`trigger` (`start`, `tick`, `hover`, `pty:<window>`, `command:<topic>`,
`key`, `mouse`, `resize`), `bytes_written`, `placements_sent`, and `window` —
avg/p95/max of the last 200 frames with the trigger of the worst one. Over
HTTP it is `GET /chicago/status` (this module) and `GET /tui-desktop/windows`
(the base); `?frame_samples=1` adds the raw frames for splitting a run into
phases. The pixel probe prints what a keystroke resends
([tools/pixelprobe](../tools/pixelprobe/README.md)).

## Open

- **Done: the SDK client is cut into rows**, as the chrome is
  (`render.rows` in `sdk/render.lua`): one placement per client row, keyed by
  what that row draws, painted by blitting from one full client raster only
  when the row is dirty. Moving a list selection resends 2 rows — 20 000 px
  against the 150 000 px of the whole 500×300 client — and a revision that
  did not change repaints nothing (`test/shots/sdk-rows-cost.txt`).
- **A window record sized in pixels** — see
  [sdk.md, "Open: a window record sized in pixels"](sdk.md#open-a-window-record-sized-in-pixels).
