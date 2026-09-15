# Where the icons come from

The original Windows 95 icons from `shell32.dll`, taken from
<https://github.com/trapd00r/win95-winxp_icons> (the `icons/` directory, files
`w95_N.ico`), where they lie numbered and without names. Here two images are
extracted from each `.ico` — 32×32 and 16×16, both 16-color — and saved as
RGBA PNG, because `gfx.image` reads PNG/GIF/JPEG and does not read `.ico`.

**This is Microsoft artwork, not part of the module under MIT.** The source
repository has no license. The directory is fit for the local stand and must not
go to the Hub together with the module — though the module is not published there
anyway while `gfx` is not in a runtime release.

For `calculator` and `clock` the files `w98_calculator.ico` and `w98_clock.ico`
are taken from the same repository. This is the Windows 98 set, two source sizes
each; no scaling is applied during extraction.

The mapping of numbers to names was chosen by eye from a contact sheet; the
disputable ones were left out. The file name is the icon's name in `images.lua`.

- File: calculator; Source: w98_calculator; What it shows: a calculator
- File: clock; Source: w98_clock; What it shows: an analog clock
- File: my_computer; Source: w95_16; What it shows: a computer with a monitor
- File: folder; Source: w95_4; What it shows: a closed folder
- File: folder_open; Source: w95_5; What it shows: an open folder
- File: recycle_bin; Source: w95_32; What it shows: an empty recycle bin
- File: recycle_bin_full; Source: w95_33; What it shows: a full recycle bin
- File: programs; Source: w95_37; What it shows: a folder with windows — "Programs"
- File: settings; Source: w95_36; What it shows: a folder with tools — "Settings"
- File: documents; Source: w95_69; What it shows: a shelf with books — "Documents"
- File: find; Source: w95_23; What it shows: a magnifying glass over a document — "Find"
- File: help; Source: w95_24; What it shows: a book with a question mark — "Help"
- File: run; Source: w95_25; What it shows: a window with a clock — "Run"
- File: shutdown; Source: w95_46; What it shows: a computer with a monitor — "Shut Down" (until 2026-09-09 it was w95_27, a computer with an arrow)
- File: program; Source: w95_3; What it shows: an empty window — the default program
- File: document; Source: w95_2; What it shows: a document with text
- File: text_document; Source: w95_60; What it shows: a text document
- File: drive; Source: w95_8; What it shows: a hard disk
- File: floppy; Source: w95_7; What it shows: a 3.5″ floppy drive
- File: cdrom; Source: w95_12; What it shows: a CD-ROM
- File: network_drive; Source: w95_10; What it shows: a network drive
- File: printer; Source: w95_17; What it shows: a printer
- File: control_panel; Source: w95_20; What it shows: panels — "Control Panel"
- File: fonts; Source: w95_39; What it shows: a folder with letters — "Fonts"
- File: desktop; Source: w95_35; What it shows: a desk with a lamp — "Desktop"
- File: windows; Source: w95_40; What it shows: the Windows flag — the "Start" button
- File: shortcut_overlay; Source: w95_30; What it shows: the shortcut arrow (overlaid in the corner)
- File: network; Source: w95_14; What it shows: a globe — "Network"
- File: network_neighborhood; Source: w95_18; What it shows: two computers — "Network Neighborhood"
- File: documents_stack; Source: w95_43; What it shows: a stack of documents
- File: program_settings; Source: w95_61; What it shows: a window with a gear
- File: system; Source: w95_22; What it shows: gears in a box — "System"
- File: regedit; Source: w98_regedit; What it shows: registry cubes — "Registry" (the Windows 98 set)
- File: regedit_string; Source: w98_regedit_string; What it shows: "ab" — a string value in the registry viewer
- File: regedit_binary; Source: w98_regedit_binary; What it shows: "011" — a binary value in the registry viewer

Rebuild from the source: clone the repository, for each `w95_N.ico` open it with
PIL, set `im.size = (32, 32)` (and `(16, 16)`), `convert("RGBA")`, and save a PNG
with the same name in `32/` and `16/`.

## The Windows 98 set: "Settings" programs, the console, the user

Taken 2026-09-09 from the same repository, files `w98_*.ico`; extracted without
scaling, except where noted.

- File: appwizard; Source: w98_appwizard; What it shows: a wizard window with a panel of icons — "Add/Remove Programs"
- File: taskmgr; Source: w98_computer_taskmgr; What it shows: a computer with a cardiogram on the screen — "Task Manager"
- File: console; Source: w98_console_prompt; What it shows: a black window with `C:\_` — the Bash window
- File: display_properties; Source: w98_display_properties; What it shows: a monitor with a palette — "Display Properties"
- File: notepad; Source: w98_notepad; What it shows: a notepad with a pencil — "Notepad"
- File: user; Source: w98_address_book_user; What it shows: a human head in profile — the logged-in user in "Start". **The `.ico` has only 32×32**; 16×16 is obtained by halving (NEAREST, alpha forced to 0/255), because the pack must provide both sizes, and `gfx` has no scaling.
- File: dialup; Source: w98_conn_dialup_alt; What it shows: a globe and a telephone — a dial-up connection; the "Connections" window in "Settings" (`chicago.connections:window`, which now carries its own copy). Added 2026-09-11. **The `.ico` has only 32×32**; 16×16 is the same halving as for `user` (NEAREST, alpha forced to 0/255).

## The logon key

- File: key; Source: `key_win-0.png` (32) and `key_win-1.png` (16) from
  <https://win98icons.alexmeub.com/> — the Windows 98 set, the same Microsoft
  artwork as above; this icon is not in the Windows 95 `shell32.dll`
  (w95_1…w95_72); What it shows: a key with the Windows flag — the icon of the
  "Welcome to Windows" dialog (`chicago.shell.logon`).

## The notification pictures — original art

Not from any Microsoft set: drawn by `tools/notice_icons.py` (2026-09-16),
pixel art in the 16-colour palette, both sizes drawn on their own grid, none
scaled — under the module's MIT license, unlike everything above.

- File: info; Source: tools/notice_icons.py; What it shows: a blue disc with a white "i" — an information balloon or message
- File: warning; Source: tools/notice_icons.py; What it shows: a yellow triangle with a black "!" — a warning
- File: error; Source: tools/notice_icons.py; What it shows: a red disc with a white cross — an error
