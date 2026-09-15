# FR-007. Notepad as in Windows 95

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** proposed, 2026-09-13. Decision of the owner: "bring Notepad to a
normal Windows 95 editor; study how it looked and what it allowed, and make
the same".
**References studied:** the Windows 95 Notepad screenshot in the GUIdebook
gallery (`General - Notepad`: menu bar File / Edit / Search / Help, a
fixed-pitch font, a vertical and a horizontal scrollbar, no toolbar, no
status bar); the Windows 95 "Open" common dialog (Look in, a list, File name,
Files of type, Open / Cancel); the Windows 95 keyboard reference
(daube.ch/share/win01.html).

## 1. What Windows 95 Notepad was

A single multi-line edit control filling the client, white, in the
fixed-pitch system font (Fixedsys), with a menu bar and nothing else: no
toolbar, no status bar. Title `Untitled - Notepad` or `<file name> - Notepad`
(the name without its path, a plain hyphen). The document is a plain-text
file up to 64 KB; larger files are refused with a message.

Menus, verbatim:

- **File**: `New`, `Open...`, `Save`, `Save As...`, ―, `Page Setup...`,
  `Print`, ―, `Exit`.
- **Edit**: `Undo  Ctrl+Z`, ―, `Cut  Ctrl+X`, `Copy  Ctrl+C`, `Paste  Ctrl+V`,
  `Delete  Del`, ―, `Select All`, `Time/Date  F5`, ―, `Word Wrap` (a
  checkmark when on; off by default).
- **Search**: `Find...`, `Find Next  F3`.
- **Help**: `Help Topics`, ―, `About Notepad`.

Editing is the standard edit control: a caret; typing inserts (no overwrite
mode); `Enter` breaks the line; `Tab` inserts a tab shown at eight columns;
`Backspace` / `Delete`; arrows, `Home` / `End` (line), `Ctrl+Home` /
`Ctrl+End` (document), `PgUp` / `PgDn` (a page), `Ctrl+Left` / `Ctrl+Right`
(a word); `Shift` with any movement extends the selection; `Ctrl+A` selects
all; a click puts the caret, a drag selects, a double-click selects a word,
`Shift`+click extends. The selection is drawn inverted (white on navy).
`Undo` is one level: it undoes the last edit and, chosen again, redoes it.
With Word Wrap off lines run past the right edge and a horizontal scrollbar
appears; with it on lines wrap at the client width and the horizontal bar
disappears. The vertical scrollbar is always there.

Dialogs and messages (title `Notepad` unless said otherwise):

- Closing, `New` or `Open...` with unsaved changes: `The text in the
  Untitled file has changed.` / `Do you want to save the changes?` with
  `Yes` / `No` / `Cancel` (`Untitled` is the file name when there is one).
- `Find`: a dialog titled `Find` with `Find what:` (a field), `Match case`
  (a checkbox), `Direction` (`Up` / `Down`, Down default), buttons `Find Next`
  and `Cancel`. `Find Next` (F3) repeats the last search from the caret; with
  nothing searched yet it opens the dialog.
- Not found: `Cannot find "<text>"`, OK.
- `Open...` of a name that does not exist: `Cannot find the <name> file.` /
  `Do you want to create a new file?`, `Yes` / `No` / `Cancel`.
- Too large: `This file is too large for Notepad to open.`, OK (the 64 KB
  rule; the original offered WordPad, we have none).
- `Time/Date` inserts the current time and date at the caret, `9:45 PM
  9/13/2026` (the US short forms the original used).
- `About Notepad`: the About sheet of this shell (name, module version, the
  licence note), not Microsoft's text.
- `Page Setup...` and `Print`: present, disabled — there is no printer here.
  A greyed item is honest; a working item that prints nothing is not.
- `Help Topics`: the message `Help is not available.`

## 2. What this needs that the SDK does not have

Today's Notepad (`windows.shell.viewers:notepad`) is a raw-tty viewer:
read-only, no menu, no caret, no SDK. The SDK's `input` is a single-line
field; `text` is a read-only scroller. So the work is four pieces, three of
them reusable beyond Notepad:

1. **A multi-line edit component** in the SDK (`editor` kind) — §3.
2. **A fixed-pitch face** in the theme's font set — §4.
3. **A file dialog** — Open / Save As as in Windows 95 — §5.
4. **The Notepad application** on the SDK, with the menus, the sheets and
   the file I/O — §6.

A clipboard shared between windows does not exist in the base (windows are
processes; the terminal's clipboard is unreachable). v1 keeps the clipboard
**inside the application's model**: Cut / Copy / Paste work within one
Notepad window. The base may later get a `desktop.clipboard` command; the
component is written so that the application supplies the clipboard text,
not the component.

## 3. The `editor` component (SDK)

A declarative component like the others: the tree carries the node, the
interaction carries the state, handlers stay in the application.

```lua
{kind = "editor", id = "doc", text = "…",   -- text is the initial value; the state owns it afterwards
 wrap = false, tab = 8, font = "mono", read_only = false}
```

State (`interaction.editors[id]`, the same map the single-line field uses,
by a distinct shape): `lines` (an array of strings, runes), `caret = {line,
col}`, `anchor = {line, col} | nil` (the other end of the selection), `top`
and `left` (scroll in rows and columns), `undo = {…} | nil` (one level:
the text and caret before the last edit, and whether the last Undo restored
it, so the next Undo redoes), `dirty` (changed since the last `mark`).

Rules:

- **Keys**, exactly §1: runes, `enter`, `tab`, `backspace`, `delete`, the
  four arrows, `home`, `end`, `pgup`, `pgdown`, `ctrl+home`, `ctrl+end`,
  `ctrl+left`, `ctrl+right`, `shift` with any movement extends from the
  anchor, `ctrl+a`. `ctrl+z` / `ctrl+x` / `ctrl+c` / `ctrl+v` are **not** taken
  by the component: they reach the application as raw keys and the
  application calls the editor's functions (§3, API) — the clipboard is the
  application's. `esc` is not taken either.
- **Mouse**: a press puts the caret at the cell (a proportional font is not
  the case here: the face is fixed-pitch, a column is a column); a drag with
  the button held selects from the press; a double-click selects the word
  under it; `shift`+press extends; the wheel scrolls three rows; the
  scrollbars behave as the SDK's (`text` kind) do.
- **Word wrap** (`wrap = true`): lines are broken for display at the client
  width on the last space, else hard at the width; the model keeps the real
  lines; caret movement up/down walks display rows. The horizontal
  scrollbar exists only with `wrap = false`; the vertical bar always.
- **Tab** is shown at the next multiple of `tab` columns and is one rune in
  the model.
- **Actions** emitted: `{type = "change", id}` after every edit (the
  application redraws the title's asterisk-free state — Windows 95 shows no
  marker, the state is only asked on close); `{type = "caret", id}` on
  movement is not emitted (nothing shows it).
- **Font**: in pixels `font = "mono"` selects the fixed-pitch face of §4;
  the component measures columns as `mono:measure("M")` and draws the
  selection as an inverted band per row; the caret is a 1-px bar as the
  field's. In cells the terminal is fixed-pitch by nature. **No
  proportional editor**: `font` other than `"mono"` is refused by
  `ui.problem`.
- **Limits**: none in the component; the application enforces 64 KB.

API for the application (`editor` library, pure):

- `editor.text(state) -> string` (lines joined with `\n`; files are written
  with `\n` — the original wrote CRLF, a Linux stand writes LF).
- `editor.set(state, text)` — replace everything, caret at the start, undo
  cleared, `dirty = false`.
- `editor.selection(state) -> string | nil`, `editor.replace_selection(state,
  text)` (insert when there is no selection), `editor.delete_selection`,
  `editor.select_all`, `editor.undo(state)` (the one-level toggle),
  `editor.insert(state, text)`.
- `editor.find(state, needle, {match_case, direction}) -> found: boolean`
  — from the caret (after the selection when searching down, before it when
  up), selects the match and scrolls to it.
- `editor.mark(state)` — the saved point (`dirty = false`);
  `editor.dirty(state)`.

Tests: the model functions in a pure test file with a mutation each (insert,
break, join on backspace, word jump both ways, selection extension, undo
toggle, find up/down/case, wrap rows); a plan test that the bars appear as
§1 says; a pixels test with 1×1 probes that the selection band and the caret
are where the columns say; a cells test with exact rows.

## 4. The fixed-pitch face

The theme loads `LiberationMono-Regular.ttf` from the same font entry as the
Sans faces (`src/windows.lua`, `FONT_FACE` and neighbours) at the interface
size, and passes it as `fonts.mono`. The Liberation fonts are the stand's
`app.desktop:system_fonts`; a font set without a Mono file leaves
`fonts.mono = nil`, and the editor then draws with `fonts.face` and says so
once in the log — a Notepad in the wrong font is better than no Notepad.
`use_fonts` makes a new set, so the rows repaint.

## 5. The file dialog (Open / Save As)

The Windows 95 common dialog, as an in-window sheet the SDK builds
(`ui.file_dialog(spec)` in a new `windows.shell.sdk:filedialog`
library), 426×264 px in the original — here 44×16 cells:

- title `Open` / `Save As`; row 1: `Look in:` and a `select` of places —
  every drive of "My Computer" (the explorer's drive enumeration:
  `src/explorer/model.lua` `DRIVE_KINDS`, read through `registry`) and the
  current folder's ancestors; an `Up One Level` button at its right (the
  original had four buttons; one is enough and honest).
- the list: folders first, then files that match the type, with the small
  icons the explorer uses (`folder`, and the file's association icon);
  double-click on a folder enters it, on a file accepts; a single click puts
  the name into `File name`.
- `File name:` an `input`; `Files of type:` a `select` with `Text Documents
  (*.txt)` and `All Files (*.*)`; buttons `Open` / `Save` and `Cancel`
  (`Open` is the default).
- Result to the application: `{drive, path}` — the form the explorer already
  passes to the viewers (`files.encode`) — or nil on Cancel.
- Reading directories is the explorer's `sources` library, and it is the
  application that reads: the sheet's builder and its `update` are pure,
  and when the sheet needs another place it answers `{read = {drive, path}}`
  for the application to read and pass back as `spec.objects`. So the
  library holds no permissions and the window's own `fs.get` and
  `process.registry` do the work. The Notepad entry gains `registry` in `modules` and
  `process.registry` in its policy for the drive list; nothing else.

Tests: the tree passes `ui.problem` and lays out at 44×16 in both modes
without overlaps; entering a folder, going up, filtering by type, the
double-click and the default button, the result shape; a PNG shot
`test/shots/filedialog.png`.

## 6. The Notepad application

`windows.shell.viewers:notepad` becomes an SDK application
(`pixel_render: windows.shell.sdk:render`, `pixel_state` itself),
64×20 cells, resizable, `group: Programs`, the same `opens` list and images.

- **Without arguments** — `Untitled - Notepad`, an empty document. With the
  explorer's `{drive, path}` — the file, title `<name> - Notepad`. The title
  is set at open by the explorer today with an em-dash; the application sets
  it itself with the plain hyphen and keeps it right after `Save As`. (If the
  base has no command to rename a window from inside, add `desktop.title`
  to the base — the compositor already redraws the title bar on state.)
- The tree: `menu` (§1, with the shortcut column and the checkmark — see
  §7) over one `editor` filling the client; no status bar, no toolbar.
- Every item of §1 wired as §1 says; `Ctrl+Z/X/C/V`, `Del`, `F3`, `F5` as
  raw keys. `Exit` closes through the same "save changes?" gate as the
  close button (the SDK delivers `close` as an action before the loop
  ends; the application answers the sheet and closes or stays).
- Files: read and written with `fs.get(drive)` handles (`readfile` /
  `writefile`), the viewers' `files` library; `Save` on an untitled
  document is `Save As`; a file over 64 KB is refused with the message of §1
  before anything is read into the editor.
- Clipboard: the model's `clipboard` string; `Paste` disabled while it is
  empty, `Cut` / `Copy` / `Delete` disabled without a selection, `Undo`
  disabled without an undo point — as the original greyed them.

Tests: a pure test of the application's `update` for each menu item (a
fixture `fs` stand-in), the close gate with all three answers, the find
sequence, the 64 KB refusal, the title after Save As; `test/shots/notepad.png`
with a few lines of text, a selection and the Edit menu open, in pixels and
in cells.

## 7. Small SDK additions the menus need

- `menu` items take `shortcut = "Ctrl+Z"` drawn right-aligned in a column
  after the widest text (the popup's width grows by the widest shortcut plus
  two cells), and `checked = true` drawn as `✓` in cells and a 7-px check
  glyph in pixels at the left margin (Windows 95 draws the check in the
  8-px column before the text). `disabled` already exists.
- `F10` opens the first menu, as in Windows (the comment in `ui.lua` promises
  it; it is not implemented).

## 8. Not in v1

A clipboard shared between windows or with the terminal; printing; a font
dialog (Windows 98); drag-and-drop of text; the Windows 95 Notepad's
`.LOG` trick; overwrite mode; right-to-left text.
