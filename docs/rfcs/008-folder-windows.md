# FR-008. Folder windows as in Windows 95

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** implemented 2026-09-14 as 57adaae; List is the SDK's
column-filled `icons` (`flow = "columns"`) since 2026-09-14. Deviation: the
toolbar buttons without pictures in the pack (Cut … the four views) carry
captions, and a narrow window clips the last ones.
**Proposed** 2026-09-13. Decision of the owner: "bring the file
explorer (My Computer) to the Windows 95 look: there were fewer buttons and
every folder opened in a new window".
**References studied:** Windows 95 screenshots (toastytech.com/guis/win95:
`My Computer` with drives, Control Panel and Printers in large icons, status
bar `5 object(s)`; a folder in Details with columns Name / Size / Type /
Modified; three cascaded folder windows, one per folder; the toolbar when
switched on: a folder combo, Up One Level, Map / Disconnect drive, Cut,
Copy, Paste, Undo, Delete, Properties, and the four view buttons — no Back
and no Forward, those came with Windows 98), the keyboard reference
(daube.ch/share/win01.html: Backspace up one level, F5 refresh, Ctrl+A,
Alt+Enter properties, F2 rename).

## 1. What a Windows 95 folder window was

A window titled by the folder (`My Computer`, `(C:)`, `My Folder`) with the
folder's icon in the title bar, a menu bar `File Edit View Help`, the
objects in one of four views, and a status bar `N object(s)` with a sizing
grip. **No toolbar by default** (`View → Toolbar` switches it on). **Every
folder opens in its own window**, cascaded from the parent; opening a folder
whose window is already open raises that window. `View → Options… → Folder`
offered the other mode, "a single window that changes as you open each
folder".

Menus, verbatim (items we cannot honour are present and disabled — a greyed
item is honest, a working item that does nothing is not):

- **File**: `Open` (the selection), ―, `Create Shortcut`, `Delete`,
  `Rename`, `Properties`, ―, `Close`. Create Shortcut / Delete / Rename
  disabled (the explorer does not write). `Properties` opens the properties
  sheet of the selection: for My Computer's root and for a drive the
  `System Properties` window the desktop's icon already names; for a folder
  or a file a sheet with name, type, location, size, modified (`Alt+Enter`).
- **Edit**: `Undo`, ―, `Cut`, `Copy`, `Paste`, `Paste Shortcut`, ―,
  `Select All  Ctrl+A`, `Invert Selection`. The first five disabled; the last
  two work (§4, multi-selection).
- **View**: `Toolbar` (checkmark), `Status Bar` (checkmark), ―, `Large
  Icons`, `Small Icons`, `List`, `Details` (a bullet on the current one), ―,
  `Arrange Icons ▸` (`by Name`, `by Type`, `by Size`, `by Date`, ―, `Auto
  Arrange` checkmark), `Line up Icons`, ―, `Refresh  F5`, `Options...`.
- **Help**: `Help Topics`, ―, `About Windows`.

The toolbar, when on, one row under the menu: a folder combo (the current
folder, its ancestors and the drives in the list), `Up One Level`, ―, `Cut`,
`Copy`, `Paste` (disabled), `Undo` (disabled), ―, `Delete` (disabled),
`Properties`, ―, `Large Icons`, `Small Icons`, `List`, `Details`. No Map /
Disconnect drive (no network drives here), no Back / Forward (Windows 98).

## 2. What changes from today's explorer

Today: one window, `File View Go Help`, a toolbar always on with 13 buttons
(Back / Forward / Up working, the rest greyed), a separate address row, only
Large Icons, single selection, navigation in place with a history, no
context menu, a custom renderer registered in the theme (`explorer:render`,
`explorer:render_pixels`, `chrome_pixels.VIEWS`).

After: the window is an **SDK application** (`pixel_render:
butschster.windows.sdk:render`), the custom renderer and its registration
are removed, the theme's `VIEWS` shrinks to the SDK and the picture viewer.
The reading side stays: `explorer:model` (paths, objects, drives, replies)
and `explorer:sources` (registry, `fs`) are kept and extended; only the
drawing and the input move to the SDK. The `Go` menu, Back and Forward, the
address row and the history are gone.

## 3. Windows and navigation

- **Open** of a folder object sends `desktop.open{entry =
  "butschster.windows.explorer:window", title = <folder name>, image =
  <folder's icon>, args = <path>}`. `main(service, window_id, args, …)`
  reads the path from `args` (today it ignores them and starts at the root).
  The base's `describe(window)` must report `args`, so that `desktop.list`
  lets the opener find an already open window for the same path and
  `desktop.focus` it instead of opening a second one (add `args` to
  `describe` in the base if it is not there).
- The window's title is the folder name: `My Computer` at the root, the
  drive's caption for a drive (`(C:)`-style captions stay what
  `model.drives` makes of the entry), the last path segment for a folder,
  `Control Panel` for the control panel (§5). The title-bar image: the root
  `my_computer`, a drive `drive`, a folder `folder_open`, the control panel
  its own picture if the pack has one, else `folder_open`.
- **Backspace** and `Up One Level` open (or raise) the parent folder's
  window; in the single-window mode they navigate in place.
- **The mode** is `View → Options…`: a sheet with the two radio buttons of
  Windows 95 (`Browse folders using a separate window for each folder`,
  default, and `Browse folders by using a single window that changes as you
  open each folder`), OK / Cancel; stored in `butschster_windows_settings`
  under `explorer_browse` (`separate` | `single`) through the persist repo
  the explorer already reaches for the desktop layout. New windows read it
  at start.
- The window is 48×16 cells (Windows 95's My Computer was about 260×220 px
  on a 640×480 screen; ours is a 1000-px-wide desktop, 480 px is the same
  share), resizable; the compositor cascades new windows as it does today.

## 4. Views, selection, sorting

- **Large Icons** — the SDK `icons` component (the grid the desktop and the
  Start menu use), 32-px pictures, captions under them, as today.
- **Small Icons** — the same grid with 16-px pictures and the caption to the
  right, rows 1 cell high, several columns (`icons` with `small = true`; add
  the option to the component if it lacks it).
- **List** — small icons in columns filled top to bottom, then the next
  column, scrolling horizontally by columns (`icons` with `small = true,
  flow = "columns"`; see docs/sdk.md).
- **Details** — the SDK `table` with `Name` (small icon + name), `Size`
  (`133KB`, empty for folders), `Type` (`File Folder`, `Text Document`, the
  handling program's title with `Document` — what Windows showed for a
  registered type — or `<EXT> File` for an unknown one), `Modified`
  (`7/11/95 9:50 AM`, the US short form).
- **Selection** is a set: click selects one, `Ctrl`+click toggles,
  `Shift`+click selects the range in view order, `Ctrl+A` all, `Invert
  Selection`; arrows move the focus and select one; the status bar's right
  field says `N object(s) selected` with the selected size when more than
  one, else the object's detail.
- **Sorting**: name (default), type, size, date; `Arrange Icons` sets it and
  `Auto Arrange` keeps the grid packed (the only arrangement we have — the
  item is checked and disabled: icons here cannot be dragged loose). `Line up
  Icons` is present and disabled for the same reason.
- **Open** (double-click, Enter, `File → Open`): a folder → §3; a file → the
  associated program as today (`associations.open`); a drive → its window.
- **Right click** on an object: a context menu `Open`, ―, `Properties`
  (the compositor gives the SDK a `context` action with the pointer; the
  window shows the SDK `menu` popup at it); on the empty field: `View ▸`
  (the four views), `Arrange Icons ▸`, ―, `Refresh`, ―, `Properties`.
- **Keys**: arrows, Home / End, PgUp / PgDn, Enter, Backspace, F5, Ctrl+A,
  Alt+Enter, Esc closes a menu; F2 / Delete are present in the menus and
  disabled, the keys do nothing.

## 5. The root and the Control Panel

The root (`My Computer`) lists the drives (as today: `fs.directory` and
`fs.embed` entries) **and a `Control Panel` folder**. Windows 95's root also
had `Printers` and `Dial-Up Networking`; we have neither, and an empty
folder that promises something is worse than none.

`Control Panel` lists the programs of the catalog's `Settings` group —
Display, System, Network, Add/Remove Programs, Users, Services, … — as
objects with their own pictures; opening one opens its window. The list
comes from `programs:catalog`, which `explorer:model` already imports. In
Details its columns are Name / Type (`Control Panel item`) / Comment (the
entry's `meta.comment`).

The pseudo-folders `programs`, `desktop`, `windows` of today's path grammar
stay reachable by path (the tests use them) but are not shown at the root:
Windows 95 had no such folders in My Computer.

## 6. Status bar

Left field `N object(s)` (`(plus M hidden)` when the reader hid dotfiles —
it does not today; leave the words out until it does), right field as §4.
For a drive's root the right field shows what the reader knows: the entry
id and kind (today's `detail`). `View → Status Bar` hides the row.

## 7. SDK additions this needs

- `menu`: `checked` (a checkmark), `bullet` (a radio mark), `shortcut`
  column, one level of submenus (`items = {…}` on an item opens to the
  right, as the Start menu's folders do), `F10`. Shared with FR-007 §7.
- `icons`: `small = true` (16-px pictures, caption at the right, 1-row
  cells) and a multi-selection set (`selected = {id = true}`) with the
  Ctrl / Shift rules of §4.
- `table`: a picture in the first column (`image` on a cell), multi-selection
  as for `icons`.
- Nothing else: the toolbar is a `row` of `button`s with `image`, the folder
  combo is a `select`, the sheets are `ui.message` / a small tree.

## 8. Tests and evidence

- The model: path grammar and parent unchanged; `Control Panel` objects;
  sorting by the four keys; the selection set operations; the Details cells
  (size, type, date formats); reply handling as today.
- The window: a pure test of `update` for every menu item; opening a folder
  sends `desktop.open` with the path in `args` and, when a window with the
  same args is listed, `desktop.focus` instead; Backspace in both modes;
  the toolbar and status bar toggles; the four views lay out without
  overlaps at 48×16 and at 72×22 in both modes.
- Shots: `test/shots/explorer-*.png` replaced by `mycomputer.png` (root,
  large icons, no toolbar), `folder-details.png` (a drive folder in Details
  with the toolbar on) and `folder-context.png` (the object context menu).
- Removed: `explorer:render`, `explorer:render_pixels`, their tests
  (`render_test.lua`, `explorer_pixels_test.lua`, `explorer_composer.lua`),
  the `VIEWS` entry and the imports in `src/shell/_index.yaml`.

## 9. Not in v1

Writing (cut, copy, paste, delete, rename, new folder), drag-and-drop,
loose icon positions, per-folder view memory, `Printers`, `Dial-Up
Networking`, the two-pane `Windows Explorer`, type-ahead selection, hidden
files.
