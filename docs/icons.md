# The icon set

A 32×32 icon is a thousand pixels. Primitives (`rect`, `set`) turn it into a
silhouette: the folder is recognizable, the computer is recognizable, but it is
"in the spirit of", not a copy. An exact copy is taken from a file, and since
2026-09-08 the module ships the original icons from `shell32.dll`.

This is **the owner's decision**, and it reverses the earlier one: until then
the theme deliberately drew "its own drawings, without copying Windows system
resources". What follows from that is in the section on the license.

## Where things are

- What: Icon files, 32×32 and 16×16, RGBA PNG; Where: `assets/icons/32/`, `assets/icons/16/`
- What: Where they were taken from, which number means what, how to rebuild; Where: `assets/icons/SOURCE.md`
- What: The filesystem through which they are read; Where: entry `chicago.shell.theme:icon_files` (`src/shell/_index.yaml`)
- What: Library: name → file → raster; Where: `src/shell/images.lua`, entry `chicago.shell.theme:images`
- What: Check that every icon is readable and has its size; Where: `test/src/images_test.lua`

The source is <https://github.com/trapd00r/win95-winxp_icons>, the `icons/`
directory, files `w95_1.ico` … `w95_72.ico`. They are numbered, not named; the
names were chosen from the contact sheet and recorded in `SOURCE.md`. Each `.ico`
holds two images, 32 and 16, both 16-colour; both were extracted, because
`gfx.image` reads PNG, GIF and JPEG, and does not read `.ico`.
Additionally, `w98_calculator.ico` and `w98_clock.ico` were taken from the same
repository; their original sizes 16 and 32 were also extracted without scaling.
The `key` icon — a key with the Windows flag, for the logon dialog — is absent
from Windows 95's `shell32.dll` and was taken from the Windows 98 set (`SOURCE.md`).
From the same place (2026-09-09) come `appwizard` ("Add/Remove Programs"),
`taskmgr` ("Task Manager"), `console` (the Bash window) and `user` (the logged-in
user in "Start"); for `user` the source has only 32×32, and the 16×16 was obtained
by halving — the only exception to "without scaling".

A program's file icon is its `meta.image`, unless the entry named
`meta.file_image`: Notepad's icon is `notepad` (a notepad with a pencil,
`w98_notepad`), while its `.txt` in the explorer is `text_document`, as in Windows.

The Bash window is an entry of THE BASE, and it deliberately has no `meta.image`
of its own: the icon names are a package of this shell, and the public module
does not know them. Its icon is named by `chicago.shell.programs:base_images`
— an entry of the same type `chicago.program_images` with which the application
assigns icons to workshop windows. A program's own `meta.image`, if present, takes precedence.

## How to use it

The library provides three things: a name for an item, a raster for a name, and
the whole overlay at once.

```lua
local images = require("images")

-- Icon name for a desktop, menu or explorer item, plus the overlay name.
local name, overlay = images.name_for(item)   -- "program", "shortcut_overlay"

-- Raster by name. Shared by everyone; do not draw into it.
local picture, why = images.get("folder", 32)

-- Everything at once: the item's icon and the shortcut overlay, into the theme's raster, by the corner.
local ok, why = images.icon(raster, x, y, item, 32)
if not ok then
    -- primitives, as before; show the reason at least once
end
```

`images.icon` is a `blit` without scaling. The coordinate is the top-left
corner, as with everything in `gfx`. The shortcut overlay (the arrow) is placed
in the bottom-left corner of the icon, as in Windows 95, and is always taken from the 16 set.

There are two sizes, and they are listed in `images.SIZES`: 32 for the desktop, the root
items of "Start" and the explorer's large grid, 16 for submenus, title bars and the taskbar.
A request for another size is a refusal, not
scaling: `gfx` deliberately has none, and a 16-colour icon stretched by one and a
half times stops being that icon.

### How an item gets its name

One table in `images.lua`, and no other — otherwise the folder on the desktop and
the folder in the explorer will one day turn out to be different folders:

- `item.kind`: `folder`, `directory`, `group`; icon: `folder`
- `item.kind`: `drive`; icon: `drive`
- `item.kind`: `program`, `window`; icon: `program`
- `item.kind`: `item`, `file`; icon: `document`
- `item.kind`: an item with `entry = chicago.shell.explorer:window`; icon: `my_computer`
- `item.kind`: `shortcut` to anything else; icon: `program` + overlay `shortcut_overlay`
- `item.kind`: `broken = true`; icon: no icon → the caller draws with primitives

An explicit `item.image` beats the kind. This is exactly the way to give a program its own icon:
the registry entry declares `meta.image: printer`, the catalog carries the field through to the
item, and the printer is drawn as a printer. A name that is not in `images.NAMES`
is **not substituted** with a similar one — `get` will refuse and name it. An icon that
"for some reason did not get drawn" is looked for in the drawing, not in a typo; here the typo
is named.

## Workshop window icons

Windows built in the workshop currently have no image field in storage.
The test stand can declare an entry `kind: registry.entry`, `meta.type: chicago.program_images` for them:

```yaml
- name: window_images
  kind: registry.entry
  meta:
    type: chicago.program_images
  data:
    images:
      "chicago.tui_desktop.apps:clock": clock
```

This is the styling of specific programs of the test stand, so the entry lives in the application.
The key is the exact `entry`, not the window caption. A program's own `meta.image`
takes precedence; declarations that contradict each other refuse with a reason.
The catalog applies the styling before passing the data to the desktop and the menu, and
`catalog.menu_items` preserves all fields when translating `width/height` into `w/h`.

## Three rules this rests on

**The file arrives as bytes through `fs`, not as a path inside `gfx`.** The same decision
as for the font: reading a file is governed by the process's permissions, and a module that
opens paths itself would be a road around them. So the actor that draws must
have `fs.get` on `chicago.shell.theme:icon_files`. The shell and the explorer
window today have `fs.get` on `*`, so it works — but the audit of 2026-09-08
disputes exactly that `*` on the window; when it is narrowed, this entry must be named
explicitly.

**A decoded raster lives as long as the process lives.** Rasters outlive the frame
([FR-005](rfcs/005-pixel-chrome.md) §4): an icon decoded anew on every frame would be a new
raster with the same version, and the surface would **not resend** it — the
old one would stay on screen. That is why the cache is in the library, not in the caller, and
that is why `forget()` exists only for tests.

**A refusal is remembered and named.** The theme calls this on every frame; there is no point
repeating `fs.get` sixty times a second for the same "no permission".
The first refusal is recorded with its reason (the directory did not open, the file was not read,
not decoded, wrong size), subsequent ones refer to it.

## How to add an icon

1. Find the number in the contact sheet — it can be built with the script from
   `SOURCE.md`, which also converts `.ico` to PNG.
2. Put `32/<name>.png` and `16/<name>.png` in place.
3. Add the name to `images.NAMES` and a row to the table in `SOURCE.md`.
4. `make test` — the test goes through all names and fails if a file is missing or
   the size is wrong.

The file name is the icon name; there are no two lists.

## The directory is declared by the module, not by the application

`icon_files` is an `fs.directory` with `base: module` and `directory: ./assets/icons`:
the path is resolved from the module root, not from the application's working directory. The
fonts are declared the same way (`chicago.shell.theme:fonts` over `./assets/fonts`,
Liberation under the OFL): icons and fonts are part of the look, and the application should
not have to know about them.

`auto_init: false` — read-only. The module must neither create the directory nor rearrange
permissions on someone else's artwork.

## License

This is Microsoft artwork. The source repository has no license at all. The module
is declared MIT, and the icons **do not fall under it** — `SOURCE.md` says so
directly.

There is one practical consequence: the directory is suitable for a local test stand and must not
travel to the Hub together with the module. Decided 2026-09-11, before the first publication:
`wippy.yaml` excludes `assets/icons/**/*.png`, while `SOURCE.md` ships. The
PNGs are excluded, not the whole directory, because the runtime does not create an `fs.directory`
entry with `auto_init: false` whose directory is missing. In the published module `icon_files`
opens empty, `images.get` refuses with a reason, and the icons are drawn with
primitives (section below). The same caveat is in LICENSE and README.

## What is connected and what remains

`pixels.icon` first calls `images.icon`, on refusal draws with primitives and
writes the reason to the `chicago.icons` log once. A broken shortcut stays
noticeable: it is drawn as a primitive with a red cross.

The real icons are connected to the desktop, the root items of "Start" (32 px),
submenus (16 px), the "Start" button, title bars and the taskbar. The pixel
explorer window uses 32 px. Its pixel backend is connected via
`meta.pixel_render` and `meta.pixel_state`; in cell mode the previous look is kept.

`meta.image` passes through the catalog into the menu, the desktop shortcuts and the explorer model.
The compositor also passes `meta.image` to title bars and the taskbar. An unknown name is kept all the way to the loader, so that
the refusal names the typo; no other system icon is chosen in its place.

The look is checked by `paint-png`: `desktop.png` shows the open "Programs",
`menu-empty.png` and `menu-failure.png` — an empty and an unavailable catalog,
`stock-icons.png` — all 32 icons in both sizes. `menu-icons.png` goes
through the adapter of the live shell and shows the same programs in the menu and on the desktop.
`explorer-native.png` shows the pixel explorer with large drive icons.

Drive icons by kind (`floppy`, `cdrom`, `network_drive`) are in the set, but
the explorer does not yet distinguish the `fs.*` kinds, so all drives are drawn as `drive`.

## Image packs of other modules

The pack above is the shell's own, and its list is fixed in `images.NAMES`.
Pictures of other modules and of the application do not go into it: they come
in their own pack, found at run time.

A pack is any `fs.*` entry that declares `meta.type: chicago.images`, with the
icons lying as `<size>/<file>.png` and pictures of any size as
`pictures/<file>.png`:

```yaml
- name: images
  kind: fs.directory
  meta:
    type: chicago.images
  directory: ./src/app/workshop/images
```

A picture of a pack is named `<entry id>/<file>` — `app.workshop:images/mine` —
wherever a name is taken: `meta.image` of a program, the `image` of an SDK
`image`, `button` or `ui.message`, a workshop window's `image`.

- **The pack is looked up in the registry when a picture is asked for**, not
  when the library loads. A pack applied to the live registry, and a file added
  to a pack's folder, are drawn without touching the shell. A pack picture is
  looked at again every `images.PACK_RECHECK_SECONDS` (5): a refused one is
  asked again (a pack registered a minute later shows up then), a read one is
  compared with its file — the same bytes keep the same raster, so the surface
  resends nothing, and a REPLACED file becomes a new raster without a restart.
- **Only an entry that declared itself a pack is read as one.** A window names
  the picture, and a drive of the stand or someone's data is not a pack; such a
  name refuses with "is not an image pack".
- **A name is not a path.** The file is one segment of letters, digits, `_`
  and `-`; anything else is "no such icon", and `..` never reaches the
  filesystem.
- **The sizes are the folders the author drew**, up to 256; the picture must be
  exactly the size asked for. There is no scaling here either.
- **`pictures/` holds pictures of any width and height**, beside the size
  folders: `pictures/<file>.png` is what the SDK's `picture` component draws
  ([sdk.md](sdk.md), "Pictures") — a 360×40 heading, a 180×120 illustration —
  named `<entry id>/<file>` like the rest (`images.picture`). It is not a size:
  an icon, a button or a title never reads it, and a picture never reads a size
  folder. It is read, looked at again and kept by the same rules, so a file
  replaced there is a new raster without a restart.
- **Reading a pack takes `registry.get` as well as `fs.get`.** The compositor
  holds both already (the icon folder, the program catalog), so a pack needs no
  permission of its own. Any other process that paints pictures — a PNG probe,
  a custom renderer's provider — needs both: without `registry.get` a pack
  picture is refused as "no image pack", and a button or a title falls back to
  its caption or the default icon, which reads as "the picture is not there"
  rather than as a permission.

