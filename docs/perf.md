# Frame cost: where the time goes

In cells the shell is cheap and is not where a slow screen comes from. In
pixels the cost is the encoder, and it is paid per pixel sent. Everything
below follows from those two facts.

## The frame path

1. **The compositor rebuilds the canvas** after every state change
   (`butschster.tui_desktop.desktop:library`, `draw`). In cells the theme
   paints `fill`, `window`, `bars` and `menu`; in pixels `chrome.paint` returns
   placements and `pixels.frame` blanks the cells under them.
2. **The runtime surface diffs and sends** (`service/terminal/surface.go`,
   `Present`): only changed text rows are written, and a placement is sent when
   it is new, changed (buffer identity, version, place) or covers a repainted
   row.
3. **A sent placement is encoded** — sixel with a median-cut palette per call,
   or kitty as RGBA with zlib.

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

## The encoded-placement cache

The runtime surface keeps the bytes of each placement's last encoding, keyed
by buffer identity, version, place, cell size and protocol; a resend with the
same key copies them. The cache is capped at 32 MiB (least recently written go
first) and forgets a placement that leaves the frame. With kitty an image the
terminal already holds is put again by id (`a=p` with placement id 1) instead
of being transmitted again.

`BenchmarkRasterOnARepaintedRow` — 100 presents of a 500×300 raster on a row
repainted every frame: sixel 93.6 ms → 2.1 µs per present, kitty 10.5 ms →
0.85 µs.

The cache lives in the local runtime build (`dist/wippy-linux-amd64`); a
released runtime does not have it yet.

## Rules that keep a pixel frame cheap

- **Chrome is cut by rows.** A placement is resent when a text row it covers is
  repainted, so a window frame is strips by row band — title, side edges,
  bottom. Typing repaints content rows and resends only the two side edges.
- **Rasters survive frames.** Themes take rasters from the store
  (`store.take(id, cols, rows, cell, key)`) and draw only when dirty. A rebuilt
  raster restarts its version, so the surface tells pictures apart by buffer
  identity (`Placement.Serial`), not by version alone.
- **The menu is on top by subtraction, not by order.** Sixel has no z-order and
  the surface resends only damaged placements, so a window under an open menu,
  resent on its tick, would paint over the menu. `butschster.windows.shell:placements`
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
HTTP it is `GET /windows/status` (this module) and `GET /tui-desktop/windows`
(the base); `?frame_samples=1` adds the raw frames for splitting a run into
phases. The pixel probe prints what a keystroke resends
([tools/pixelprobe](../tools/pixelprobe/README.md)).

## Open

- **The SDK client is one raster per window**, keyed by the state revision
  (`sdk/render.lua`): any change re-encodes the whole client, however small.
  The cache removes only resends of an unchanged revision. Cutting the client
  into row strips, as the chrome is, is the next step.
- **A window record sized in pixels** — see
  [sdk.md, "Open: a window record sized in pixels"](sdk.md#open-a-window-record-sized-in-pixels).
