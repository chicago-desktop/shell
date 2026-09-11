# Bash and "Run…"

"Start → Programs → Bash" opens the base's stock terminal window
`butschster.tui_desktop.desktop:window_pty`. The entry declares the title,
group and icon through `meta`; there is no separate copy of the PTY process.

Bash starts with `-i` and reads `~/.bashrc`. The application passes `HOME`
and `PATH` to the executor `butschster.tui_desktop:exec` through `default_env`:
`exec.native` itself does not inherit the OS environment. An example setup is in the
"Bash environment" section of the base's README. Without these variables programs from
`~/.local/bin` (for example, `claude`, `codex`) give `command not found`,
even when they are installed for the user. Check: `command -v claude codex`.

"Start → Run…" opens a command field. For example: `top`, `top -d 2`,
`claude` or `claude --resume`. Enter and "OK" run the command in a separate
Bash window, Escape and "Cancel" close the dialog. Tab moves between the field and the
buttons; the field supports arrows, Home/End, Backspace/Delete and Ctrl+A.

The command runs through `/bin/bash -ic`: arguments, quotes,
variables, pipelines and Bash's interactive setup are available. After the command
`exec /bin/bash -i` runs, so the output, the error and the shell prompt
remain. An explicit `exit` or `exec` in the command itself keeps its usual meaning.
The named program must be installed and reachable by Bash through PATH.

The dialog asks the compositor to open the window through `window_api.request` and closes
after a successful reply. It has no `exec.run` or `process.spawn` permissions.
The command is passed as a single `-c` argument, with quotes and backslashes
preserved: it is interpreted by Bash, not by Wippy's argument parser.

The dialog is built on the shell SDK (`butschster.windows.sdk:app`): a 32 px icon,
two hint lines as one multi-line label, an `input` field, the buttons "OK"
(the default), "Cancel" and "Browse…" — the last one opens "My Computer"
and waits for the compositor's reply over the same channel, without closing the dialog.
The window title is "Run" (`definition.title`), the ellipsis stays on the menu item. The
size of 50×10 cells follows the Windows 95 reference. It has no layout,
renderer or line editor of its own — it is the first window
moved to the SDK entirely. The compositor's reply to the request to open a window
arrives on its own channel (`context.watch`), so the dialog does not freeze.

Checks: `test/src/run_test.lua` — the launch spec, the SDK layout
and the default-button rule, the real menu and launching Bash under a PTY,
the terminal surviving after the dialog is closed, cancelling with Esc in cells mode.
`paint-png 8x18` saves the example `test/shots/run-bash.png`.

Bash windows use a black background and light-gray text by default. This
also applies to programs opened through "Run…". An ANSI color reset
returns these window colors; colors set explicitly by the application are kept.
The empty area and the inner edges of the frame also stay black.
