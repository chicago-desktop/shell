# themeprobe — theme probe

Runs the REAL `src/shell/*.lua` outside the runtime and prints the canvas as
text: the frame, below it a grid of styles (which color is in which cell) and,
under every hit, the characters that actually lie beneath it. A full-screen
program cannot be checked otherwise, and the theme is pure strings and
arithmetic, so it can be measured without a terminal. This caught almost
everything that turned up in the theme before it reached the stand: frames
off by a cell, hits that did not match the drawing, degenerate screen sizes.

```bash
cd tools/themeprobe
go build ./...          # takes go-lua via the replace in go.mod — the path is ABSOLUTE, adjust it for your machine
python3 build.py        # glues the scenes together with the current theme files
./themeprobe combined.lua
```

The scenes live in `harness.lua` — along with a pure-Lua implementation of
`tty` (style, canvas, `text.width`, `text.truncate`). Added a scene — rerun
`build.py`: `combined.lua` is assembled anew and is not stored in the module.

## The caveat without which it becomes a false witness

**The probe checks the drawing geometry, not the width of characters.** Its
`tty.text.width` counts code points, so to it any character is one cell wide.
Should someone bring in an emoji or a CJK character, the probe will stay
silent, while on a real terminal the frame will come apart on every line where
the character occurs, and it will look like an arithmetic error rather than an
unfortunate character.

Character width is checked by a separate test in the suite — it measures
`glyphs.all()` with the real `tty.text.width` inside the runtime. The two
checks do not replace each other: this one says where the cells landed, that
one says how many cells a character takes.

`make check-probes` (from the module root) also builds and RUNS this probe once
and fails on a non-zero exit — see `tools/pixelprobe/README.md`. The glyph-width
check at the end now fails the run (`error`) instead of only printing a count.
