#!/usr/bin/env python3
"""Build combined.lua — the pixel probe plus the real primitive files.

The modules are glued into one file on purpose: go-lua in this build provides
neither `dofile`, nor `loadfile`, nor `load`, so from inside Lua there is
nothing to load a library from disk with. Each file is wrapped in a function
call — it ends in `return` anyway — and put where its marker stood.

Paths are computed from the location of this file, not from the current
directory: the probe is run both from the module root and from its own folder.

`--check` builds in memory and fails when combined.lua on disk differs, that
is, when it is older than harness.lua or any file it embeds (`make
check-probes`). combined.lua is not stored in git, and a stale one checks
yesterday's theme without saying so.
"""

import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
SRC = HERE.parent.parent / "src"
# Order matters: each file is wrapped in place of its marker, and the markers
# in harness.lua go in dependency order.
MODULES = (
    ("core", "geometry"),
    ("core", "text"),
    ("core", "scroll"),
    ("shell", "palette"),
    ("shell", "glyphs"),
    ("shell", "widgets"),
    ("shell", "icons"),
    ("shell", "images"),
    ("shell", "pixels"),
    ("shell", "rasters"),
    ("shell", "menu_layout"),
    ("shell", "chrome"),
    ("shell", "placements"),
    ("shell", "chrome_pixels"),
    ("explorer", "render"),
    ("explorer", "render_pixels"),
)


def wrapped(folder: str, name: str) -> str:
    path = SRC / folder / f"{name}.lua"
    if folder == "core":
        path = SRC.parent.parent / "kickside-module" / "src" / "desktop" / f"{name}.lua"
    source = path.read_text(encoding="utf-8")
    return "(function()\n" + source + "\nend)()"


def main() -> None:
    text = (HERE / "harness.lua").read_text(encoding="utf-8")
    for folder, name in MODULES:
        marker = f'dofile(BASE .. "{folder}/{name}.lua")'
        if marker not in text:
            raise SystemExit(f"harness.lua has no marker for {folder}/{name}")
        text = text.replace(marker, wrapped(folder, name))
    out = HERE / "combined.lua"
    if "--check" in sys.argv[1:]:
        if not out.exists() or out.read_text(encoding="utf-8") != text:
            raise SystemExit(f"stale: {out} differs from harness.lua and the current sources; run `make probes`")
        print(f"fresh: {out}")
        return
    out.write_text(text, encoding="utf-8")
    print(f"built: {out}")


if __name__ == "__main__":
    main()
