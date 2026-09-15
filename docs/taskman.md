# Task Manager

Opens from "Start → Settings → Task Manager". The window is built on the
shell SDK: tabs, tables, frames with titles, gauges, graphs, the status
bar and the button are shared components, the same in cells and in pixels.
The window no longer has its own layout or renderers.

Four tabs: open applications, Wippy processes, performance and the node.
Data refreshes once a second (`definition.interval`). "Refresh", F5 and R
take a new sample immediately. Tabs switch with the mouse, with the ←/→ arrows
while the tab strip has focus, or with keys 1–4. Tables support the wheel, the
scrollbar, arrows, Page Up / Page Down, Home / End. The selection holds on to
the task identifier when a new sample changes the order of rows.

The graphs show the goroutine count and the heap in use; the scale adapts to the
history (`sdk:charts.round_ceiling`). CPU load percentage is not shown:
the `system` module does not provide it. The window's permissions allow reading
the runtime state and the window list. Ending processes has not been added.

`src/taskman/window.lua` is the SDK application (`init/view/update`), `model.lua` is
the history, the formats and stable sorting of processes; the graph and the scale
ceiling live in `windows.shell.sdk:charts`, because any window with a
history of a number needs them.

`test/src/taskman_test.lua` checks the SDK layout for overlaps at
three sizes and four tabs, keeping the selection by identifier, and the
live window inside a real compositor: tabs, row selection, "Refresh",
samples. The `paint-png` command creates four screenshots `taskman-*.png` with
demo data.
