# butschster/windows — a Windows 95-style shell for the terminal desktop

New window applications: [SDK](docs/sdk.md),
[skill for agents](skills/wippy-window-app/SKILL.md),
[audit of existing windows](docs/sdk-audit-2026-09-08.md).
A declarative application needs only a registry entry and a component tree;
its renderer does not need to be wired into the theme separately.

A teal desktop, gray windows with a bevelled frame and a blue title bar,
a taskbar with a "Start" button, a list of open windows and a clock, a program menu
that is filled from the registry, and desktop icons that the user moves around.

There is not a single line of window mechanics of its own here. Window hosting, programs under
a PTY, the command channel and the workshop stay in
[butschster/tui-desktop](https://github.com/butschster/tui-desktop); the shell
calls its compositor with its own theme. A copy of the compositor would drift from
the original on the very first edit, and that would be discovered a week later on the live
test stand.

## Where to start

**A local runtime build is required.** `wippy` from PATH does NOT LOAD this module
at all — neither in pixels nor in cells: the theme entries declare the `gfx` module, and it
is not in the release. The message explains nothing (`node with ID … not
found`); details are [below](#with-the-release-runtime-the-module-no-longer-loads).

```bash
WIPPY=~/repos/wippy/runtime/dist/wippy-linux-amd64   # build with gfx

# in cells — works in any terminal
$WIPPY run --host butschster.windows:terminal windows

# in pixels — one-pixel edges, real icons and captions
BUTSCHSTER_WINDOWS_PIXELS=1 $WIPPY run --host butschster.windows:terminal windows
```

Pixel mode needs two things, and without either of them the shell comes up **in
cells and states the reason in the log**: a terminal with sixel or kitty that answered
the cell-size query, and a TrueType font directory (`app:system_fonts`,
overridden by `BUTSCHSTER_WINDOWS_FONTS`). Look in the log for the line
`pixel mode` — it is written before any attempt.

**Almost everything can be checked without occupying the test stand**:

```bash
make lint                                    # late locals + lint with the gfx build
make test                                    # 295 tests
cd test && $WIPPY run --host wippy.terminal:host paint-png 10x20   # PNG into test/shots
```

The probes have to be built, and the repository contains none of them — neither binaries nor
`combined.lua`. **In `go.mod` of both, the path to `go-lua` is ABSOLUTE**; adjust it
for your machine:

```bash
cd tools/themeprobe && go build ./... && python3 build.py && ./themeprobe combined.lua
cd tools/pixelprobe && go build ./... && python3 build.py && ./pixelprobe combined.lua
```

The first prints a frame in cells, the second the slicing of placements, the hits and the cost
of a keypress. `build.py` glues the scenes together with the CURRENT theme files, so
it has to be rerun after every edit.

The screenshot `test/shots/desktop.png` is the fastest way to see what will end up
on screen: **probes check the parts, the screenshot checks the whole, and these are different checks.**
In one night the screenshot found three defects that no probe showed:
icons without captions, windows without title buttons and an unfilled window body. Each
piece on its own was correct.

## `--host` is now mandatory for ALL application commands

Terminal host autodetection in the CLI is just a count of `terminal.host` entries
in the whole registry (`cmd/wippy/cmd/run.go:findTerminalHost`). The shell brings
its own host because it needs `hide_logs`, and from that moment autodetection
refuses to choose. This is the price of a second shell, not a defect.

```bash
$WIPPY run  --host butschster.windows:terminal       windows   # this shell
$WIPPY run  --host butschster.tui_desktop:terminal   desktop   # the base's shell
$WIPPY run  --host wippy.terminal:host               register-webhook
$WIPPY test --host wippy.terminal:host
```

Taking someone else's host instead of our own is not an option: the stock `wippy.terminal:host` comes with
`hide_logs: false` and carries the application's background processes — switch it and
the application loses its log. And without log suppression a runtime line breaks
the frame for good: the surface differ believes it is the only writer to
the terminal, and it does not redraw lines that have not changed.

## The registry declares what can be launched; the shell stores what lies where

This separation is the heart of the module, and everything else follows from it.

An icon's position, an open folder, the order on the desktop — these are what the user
moves. They have no place in the declaration: otherwise dragging an icon would edit
the sources. And the other way round — the program list is not stored in state, otherwise
an installed module would not appear in the menu until someone presses "refresh".

### How a program gets into the menu

Through a process entry with `meta.type: tui_desktop.window` — the same type the
base reads, so that one entry works in both shells. Registration requires no edits in
modules.

The shell reads from the entry:

- `title` — the name in the menu and on the shortcut; without it the identifier serves as the name.
- `group` — the menu folder path: `System Tools` or `System Tools/Network`. Nesting up to
  three levels; a deeper menu is unreadable in a terminal, and the extra segments
  are dropped, rather than the program being dropped.
- `order` — the order within the folder; without it, alphabetical, and the unordered ones come
  after those that have an order.
- `icon` — one or two characters; without it `▢`.
- `image` — the name of a raster icon from the [library](docs/icons.md). The icons themselves are
  Microsoft artwork: they are not covered by MIT and are not included in the published module,
  see the icons' [License](docs/icons.md#license).
- `width`, `height` — the window size on opening.
- `args` — the default launch argument.
- `desktop: true` — a request to put a shortcut on the desktop when the program first appears.
- `resizable: false` — the size is fixed: the corner cannot be dragged, there is no "maximize" button
  in the title bar, `desktop.resize` answers with a refusal. For windows whose layout
  is computed for one size — the calculator, a properties dialog. Read by the base's
  compositor; the theme chooses the buttons by the same field.

Menu folders are given by the path in `group`, not by a separate entry: a folder without
programs is meaningless, and one declared separately drifts apart from its
contents when a module is removed.

### SDK windows: "Date/Time", calculator, registry, task manager, "Run…"

Five shell programs are built on the window SDK (`butschster.windows.sdk:app`,
[docs/sdk.md](docs/sdk.md)): the application gives a component tree and changes
the model on actions, while the layout, hits, scrolling and both renderers
are provided by the SDK. They have no paints of their own, no state provider, no
second geometry for the mouse; in pixel mode they are drawn by the shared
`butschster.windows.sdk:render`, in text mode by the same components in cells.
Renderers of their own remain with the explorer and the image viewer.

- Window: Date/Time; Entry: `butschster.windows.datetime:window`; What's inside: tabs, a month calendar with today's date, an analog clock, digital time, the time zone; **read-only** — there is nothing to adjust, "OK" and "Cancel" close it, "Apply" is disabled for good
- Window: Calculator; Entry: `butschster.windows.calc:window`; What's inside: the standard Windows 95 view: the display, Back/CE/C, memory MC/MR/MS/M+, digits in blue, operations in red; it calculates like a desk calculator — an operation is applied immediately, 2 + 3 × 4 = 20; keyboard and mouse go into the same button. A window on the shell SDK: works both in cells and in pixels
- Window: Registry Editor; Entry: `butschster.windows.regedit:window`; What's inside: regedit: on the left a tree of namespaces split by dots and of the entries inside them, on the right `kind`, `meta.*` and `data.*` of the selected entry, at the bottom the path `Registry\a\b\name`. The [+] box, Enter and → expand, ← collapses or goes to the parent, the wheel and the scrollbar scroll; F5 rereads. **Read-only** (FR-004 §3.4): the `regedit_state` policy has `registry.find` but not `registry.apply`. A window on the shell SDK (the `tree` component)
- Window: Task Manager; Entry: `butschster.windows.taskman:window`; What's inside: open applications, Wippy processes, performance and the node on four tabs, refreshed every second; opened from Start → Settings → Task Manager. Details: [docs/taskman.md](docs/taskman.md)
- Window: Run…; Entry: `butschster.windows.run:window`; What's inside: a command field; Enter or "OK" starts the command in its own Bash window, which is the base's terminal window; opened from Start → Run…. Details: [docs/run.md](docs/run.md)

"Date/Time" has `resizable: false`, the calculator too; the registry editor can be resized. The taskbar clock opens "Date/Time": the host
declares this with a `windows.taskbar_clock` entry (below).

**How the theme finds `render`.** `require` can only load declared `imports`,
not an arbitrary id from the registry, so the compositor cannot call `render`
— the theme calls it, and every such library is imported into
`chrome_pixels` statically and named in the `VIEWS` table by the id of its entry.
The contract is the same for all of them:

```lua
lib.placement(window, inner, cell, fonts, store)
-- -> placement {id, raster, x, y, cols, rows} | a list of such | nil, reason
```

`inner` is the rectangle inside the frame in screen cells, `cell` is the cell
size, `fonts` is the theme's `{face, bold}`, `store` is the theme's raster store:
what is taken from it by a state-fingerprint key survives the frame and is swept away
together with the window. A new **specialized** view is a `render` entry in the theme's `imports` plus a line
in `VIEWS`; a window that names a `render` that is not in `VIEWS` gets not
emptiness but a text with the reason on the face of the window. While the view waits for its first state,
the theme shows `content_state.caption`, if the provider gave one.

**Slicing follows what changes.** For the clock, a second resends only
the raster with the dial and the digital time; the calendar and the buttons lie in their own;
for the calculator, a keypress resends the display and the row of the pressed button. The measure is
the same as for the theme: the same frame once more moves not a single version
(`views_test`).

Window screenshots are written by `paint-png` (`test/shots/datetime.png`,
`test/shots/calc.png`, `test/shots/regedit.png`, `test/shots/taskman-*.png`,
`test/shots/run-bash.png`) — the clock hands, the month grid and the caption colors cannot be
seen otherwise. All five SDK windows also work in cells: the analog clock there
turns into a digital one, the rest is drawn by the same components.

### What lies where in "Start"

The menu root is the "Programs" folder, the "Settings" folder, "Run…" and
"Shut Down". "My Computer" is not shown in the menu (`in_menu: false`
on the explorer entry, owner's decision 2026-09-09): it is opened from the desktop,
and a shortcut to a hidden program works. Above
all this, if the shell was brought up with logon, is the name of the logged-on user with
the `user` icon and a rule under it (since 2026-09-09): the line cannot be selected, it has
no hit and no number, the cursor steps over it. The name is set by `chrome.use_user`
from the logon result; both themes read the same `chrome.session`. Without logon there is no
such line: a desktop under a service actor, signed with someone's name, would look like
someone else's logon. The folder
of a program is named by `meta.group`, the separator under a line by `meta.separator_after`,
the place in the folder by `meta.order`; a folder stands where its earliest
program is (which is why "Programs" is above "Settings", and not alphabetically). In
"Settings" live "Registry Editor" and "Task Manager" — what configures
and shows the system itself; everything else is in "Programs". A program without
`group` also goes into "Programs" (`catalog.DEFAULT_GROUP`) — that is how
windows built by the workshop over HTTP, which have nowhere to declare a folder, get there.
Only an explicit `group: ""` puts a program at the root; that is how "Run…" is declared.

**Rule for a new program: a folder in "Programs" is a wippy module.**
A program here is essentially a module's window, and people look for it by module. The windows of the
shell itself (Notepad, Calculator…) lie directly in "Programs"; a program
that cannot be opened by itself (the image viewer — only through a file from
the explorer) is not shown in the menu, `in_menu: false`;
a window of any other module declares `group: Programs/<Module>` — "Programs/
Content Machine", "Programs/Bridge". What configures or shows the
system itself (Registry Editor, Task Manager) goes into "Settings". A workshop window names
its folder with the `group` field in `POST /tui-desktop/apps`; without it, it goes into "Programs"
without a module, and that is visible in the menu at once.

**Mouse hover drives the menu**: the line under the pointer is highlighted, the folder
under it expands, a deeper submenu goes away — the last two with a delay
of 300 ms, as in Windows, so that a diagonal path into a submenu does not close it.
The mechanics are in the base (`butschster/tui-desktop`, `hover_menu`), the theme only
draws the selected line; in pixels the panel is redrawn because
`selected` is part of its raster key.

### Add/Remove Programs

Start → Settings → Add/Remove Programs shows the wippy modules — the
`ns.dependency` declarations plus the vendor cache with version and size — and
edits the application's declarations file: it removes and appends entries. The
change takes effect after `wippy update` and a restart, which the window says
itself; it does not touch the registry or the Hub. The declarations folder is
named by `BUTSCHSTER_WINDOWS_DEPS_FS`. Details: [docs/appwiz.md](docs/appwiz.md).

### System Properties

A right click on a desktop icon opens a context menu at the pointer:
"Open" (in bold — the same as a double click) and "Properties", if the program's entry
declared `meta.properties` — the identifier of the properties window. For
"My Computer" this is `butschster.windows.sysprops:window`, "System
Properties", like System Properties in Windows 95: three tabs on the SDK.

- **General** — the runtime node and role, the number of Lua modules, the host, PID and directory,
  the runtime's processors and memory. There is deliberately no version number here: the runtime
  does not expose it to Lua, and an invented number is worse than a missing one.
- **Device Manager** — a tree: process hosts (`system.hosts`), file
  systems, databases, HTTP and terminals from the registry by kind PREFIX
  (`fs.`, `db.`, `http.`, `terminal.`) and Lua modules (`system.modules`).
  An empty group stays, marked "(none)": otherwise "no databases" would be
  indistinguishable from "registry not read". The caption under the tree shows the details of
  the selected line.
- **Performance** — memory and goroutines as gauges, a resource table;
  refreshed every two seconds while this tab is open.

The window only reads: `system.read` and `registry.find`, no writes to the registry, no
spawning of processes. "OK" and "Cancel" close it the same way.

The menu is drawn by the same `chrome.menu_layout` as "Start", from `anchor` in
the metrics: one panel at the anchor, without the banner, folders and icons, shifted
inward at the right and bottom edges of the screen; in pixels one line per item. Both
modes take it from one place — a context-menu painter of its own would have
drifted from "Start" on the first edit.

### Display Properties

A right click on the empty desktop gives "Properties" (named to the compositor as
`desktop_properties`), and the same window is in "Start → Settings": the Windows 95
Display Properties in two tabs.

- **Background** — the desktop color: a list of standard colors and a monitor preview
  (the SDK `monitor` component). "Apply" and "OK" write the choice into the shell's
  settings (`butschster_windows_settings`, key `desktop_color`) and ask
  the compositor to reread the desktop (`desktop.refresh`); it repaints the desktop and
  the icons in both modes through `chrome.use_desktop` — one point for the palette,
  cell styles, widgets and icons. An icon raster carries the desktop color in its key,
  so it is repainted together with the desktop. There is deliberately no pattern or wallpaper: the desktop in
  pixel mode is cells, and a full-screen raster would be resent on
  every change of a window on top of it.
- **Settings** — resolution (cells and pixels from `screen` and `cell` in
  `desktop.list`) and palette, read-only: the size is set by the terminal, TrueColor
  is forced by the runtime.

The color from the database is validated on read (`#rrggbb`): an invalid string is not
accepted and goes to the log, and the desktop stays as it was.

### Shut Down and the taskbar clock

The last item of "Start" is "Shut Down" with the `shutdown` icon (since
2026-09-09 it is `w95_46`, a computer with a monitor, as in the Windows 95 menu) and
a separator. It stays available even when the menu is cut on a short screen.
A click or Enter closes the shell's windows, shows a black screen with
the words "It's now safe to turn off your computer." — like Windows 95
after shutdown — holds it for five seconds (`chrome.FAREWELL_HOLD`) and only
then shuts down the application. Ctrl+Q is the emergency exit; it has no farewell
screen. The command does not shut down the terminal's operating system.

The window for the clock on the right is declared by the application. Example:

```yaml
- name: taskbar_clock
  kind: registry.entry
  meta:
    type: windows.taskbar_clock
  data:
    entry: app:clock_window
```

The declaration is optional and must be unique. A click opens
the named window; another click raises the already open one and restores
a minimized one. The identifier is set by the host; the theme does not derive it from the caption.

In "My Computer" the wheel scrolls the grid by one row. The scrollbar
arrows, Page Up and Page Down also work. The shell passes the wheel to
the content area of the window under the pointer; an open menu takes the input for itself.

### Desktop shortcuts

A shortcut stores a **reference** to a registry entry, not the program's code: the program
is updated — the shortcut leads to the new version. Hence three rules, each of
which would have cost a day of investigation had it been broken.

**A shortcut to a vanished entry stays and is drawn broken.** A missing icon
reads as "I deleted it by accident", a broken one as "the program is gone". These
are different statements, and substituting one for the other is not allowed.

**A program with `desktop: true` gets a shortcut exactly once, ever.**
The mark that the program has already been offered lives in a separate table
`butschster_windows_desktop_seeded` and is never deleted — including when
the shortcut itself is deleted. Without this, deleting an icon would not work at all: it
would come back on every start, and a person would decide that deletion is broken.

**This table must not be cleaned.** It is not a cache. Cleaning it would give the person back all
the shortcuts they ever threw away, and it would look not like someone else's
cleanup but like broken icon deletion.

**Deleting a desktop folder moves its contents back onto the desktop**, rather than deleting them
along with it. A cascade would carry away icons the user had put into it, and
there would be nothing to restore them from; the handler's answer names the number moved out.

### What stands on the desktop at first start

An empty desktop does not explain what to do with it, so the shell puts furniture there:
**"My Computer"** — a shortcut to the explorer of the test stand. The "Programs" folder on
the desktop stood there until 2026-09-09 and was removed by the owner's decision: it duplicated
"Start" and stood empty; for those who already have it, the offered mark remains,
and it is not created again.

Only what has something behind it is created. A "Recycle Bin" is deliberately
absent: an icon that does nothing looks like a working part of the system, and the
first thing people will ask about it is why it does not work. "Network
Neighborhood" is not furniture: it is a program (`butschster.windows.network:window`)
that asks for its own shortcut with `desktop: true`, so it reaches the desktop the
way any program shortcut does, by the rule below.

Furniture counts as offered by the same rule as program shortcuts:
thrown away — does not come back. Furniture keys start with `!`, which cannot
occur in a registry entry identifier (it is always `namespace:name`) —
so a furniture key is guaranteed not to collide with a program key in the same column.

A shortcut to a program that is not in the catalog **is skipped rather than created
broken**: a broken icon on the very first start cannot be explained. A skipped one
will be created when the program appears — and precisely for this reason it is not
marked as offered.

### Who chooses the place

An icon whose place **nobody has named** is stored without coordinates — `x` and `y`
are empty, and that is a statement, not an omission. The place for such an icon is chosen by
the compositor at frame time: only it knows the screen width. The shell at start
does not know it yet, and a place it chose could turn out to be past the edge — and an icon
past the edge is not clipped, it **disappears entirely and silently**, that is, exactly the way
the FR forbids a broken shortcut to behave.

As soon as the place is named — by dragging, by a `POST` with `x`/`y` or by a `PATCH` —
the icon becomes **placed**, and the compositor no longer rearranges it.
Even if the screen got narrower and the icon went past the edge: in real Windows 95 an icon that went
past the edge does not come back by itself, and "moved it and restarted — the icon is in the same
place" would stop being true if we started moving what a person placed.

There is deliberately no separate "placed by a person" flag in the schema. A flag next to
the columns it describes is a second source of truth, and the schema would allow
it to contradict them: "placed" with empty coordinates and "not placed" with
coordinates set by hand. Sorting that out would fall to whoever finds
the icon in the wrong place.

Zero instead of empty is the worst possible outcome: zero is a **place**, and
the icon would become placed in the top left corner. That is why there is no zero instead of `nil`
on any path.

Dragging is driven by the compositor, while the place is written by the shell —
`options.move_desktop_item(id, x, y)`, through the same repository as the
`PATCH` handler. A second way to write the place would drift from the first on the first edit.
Coordinates arrive already snapped to the grid: the snapping is done by the compositor, which
has the screen size.

A failed write **does not bring down the frame**: the icon stays where it was, and
the reason is returned to the compositor. A desktop that vanished because of a database failure is worse than
an icon that did not move.

**The shell does not store icon selection.** The compositor holds it: a saved
selection would survive a restart, which a person does not expect.

## What has already broken silently here

Six findings of one night, and not one of them produced a failure. What they share is not only
silence: **each half was right on its own, and so both sides
looked tested.** Reading this before touching the code is cheaper than
finding it all again.

### The folder path is parsed by the CATALOG, and only by it

`meta.group` is a string like `System Tools/Network`; it is turned into a list of segments by
`butschster.windows.programs:catalog`, and the depth cut is there too
(`catalog.MAX_DEPTH`). The theme receives the path **already parsed** and knows nothing
about the slash.

It was not always so, and the price is known. The theme parsed the path a SECOND time, expecting
a string — while the catalog had long been putting a table there. The check `type(item.group) ==
"string"` never fired once: the path came out empty, the folder was not created,
the program went to the top level. **No failure, no trace: the program is visible,
just not where it was asked to be.**

The same class as `id` instead of `action` in a hit and as the two style tables:
two representations of the same thing, and the discrepancy is silent.

The depth cut lived there twice as well — as a constant of its own in the theme. Now there is
one number: whoever parses the path limits it, and the cascade is stopped by the width of the
screen, and that limit is a real one.

**The whole path "group → folder → expansion" was green and never once
traversed**: the harness had not a single entry with `meta.group`. Now there is one —
`app:grouped_probe`, created for the sake of one line in the declaration.

### A hit the compositor cannot read is a missing hit

There is ONE compositor for both modes, and it, not the theme, dictates the shape of hits. A click
on a hit of the wrong shape simply does nothing — no failure, no trace.

That is how, on the first live run of pixel mode, two clicks disappeared at once:

- **"Start" gave `id = "menu"` instead of `action = "menu"`.** The compositor
  checks `spot.id` FIRST: seeing it, it looks for a window with that name, does not
  find one and silently does nothing, and the menu branch is unreachable;
- **desktop icons gave ONE hit for three lines** with a `bottom_row` field,
  which the compositor does not know at all: it checks `event.y == spot.row`. An icon
  would respond to a click on the picture and not on the caption.

Both would have passed a check of "no fewer than two hits". That is why the probe does not
COUNT them but **compares them with what character mode returns for the same
state** — by number and by the set of fields. If they differ, it goes red with both
shapes in the message.

### A function nobody calls is green in any suite

`chrome_pixels.fill` was written and called by nothing: the compositor in
pixel mode skipped it. On the very first live run it fell over on
`widgets.styles.desktop`, which did not exist — the desktop style lived in a
second, almost identical table in the theme.

Two things follow from this, and both cost a live run.

**Two tables of the same thing diverge exactly on the keys that are rarely
needed by both.** The styles are merged into one, `widgets.styles`, and the theme takes that same one.

**A function without a caller is checked by nothing.** The test now calls BOTH
fills — it should not be possible to break them separately.

Of the same family is the third finding of that evening: three probe scenes were named
"desktop icons" and drew emptiness, because `scene()` did not pass
state to `chrome.fill`. A probe that lies by default is worse than a missing one — people
refer to it.

### Lint with THE build that has `gfx`

`wippy lint` from PATH answers "No issues found" on pixel code — not
because the code is clean, but because the release runtime has no `gfx` types at all,
and the calls `raster:text`, `raster:blit`, `gfx.font` are nameless to it.

The local build found a type error in a `raster:text` argument in the same code.
That is, **all pixel code linted with the release build has not been
linted**.

`make lint` takes the build from the `WIPPY` variable and so checks for real;
`wippy lint` by hand does not. This is of the same kind as the other night findings:
a tool answers "all good" because it cannot look.

**Do not silence the check for a whole raster.** The font arrives in the theme as a field
of an ordinary table and does not have the `gfx.Font` type; declaring `any` on the raster means
switching off COORDINATE checking along with it, and a coordinate error (`y = 0`
with one-based coordinates) has already cost one round. The type is named and
cast at one spot: `local bold = given :: gfx.Font`.

### Late `local`s are checked, not remembered

A local variable is visible only BELOW its declaration; above it, it reads
as a global, that is, as `nil`, and no failure happens. A function is not
called, a caption is not drawn, a permission is not checked — and not a single error.

In one night this class bit five times, and all five were found by a live run or
a screenshot, none by a test. That is why it is now checked statically:

```bash
python3 tools/late-locals.py src
```

It runs in `make lint` before `wippy lint`, because it is cheaper and because
`wippy lint` does not catch this at all.

### A declared module without a granted permission stays silent instead of refusing

It cost two empty runs, which is why it is here and not in a comment.

The shell had `modules: [env]`, but the policy had no `env.get` action. And
`env.get_all` returned an **empty table**: it puts only permitted
keys into it and does not complain about a refusal at all. That is, a person's request to switch on
pixel mode looked like "the person did not ask".

A neighboring trap of the same evening: **`env.get` sees only the file
store.** For a variable from the process environment it answers "environment
variable not found", that is, `VARIABLE=1 wippy run …` does not work.

The three outcomes can be told apart only by the KIND of error, not by its text: for a
permission refusal `kind` equals `PermissionDenied`, and that is a constant, while the text changes.
A permission refusal must be called a permission refusal — it is the only one of the
reasons that a person cannot fix by setting a variable.

It is checked by a rule, not by a list: `wiring_test` takes from every process
entry its `modules`, from its policies their actions, and requires a permission for every
module that is gated by permissions. A list would have to be extended with every new
entry, and it would be forgotten exactly on the one where it matters.

**Open item (2026-09-11): the reverse check is not a rule yet.** "A process declares
no module it does not use" looks checkable by grep, and is not, yet. The runtime
builds the imports of every node from that node's own `modules`
(`component.BuildImports(cfg.Imports, cfg.Modules)` for libraries, processes and
functions alike), and every library here declares what it requires. So the
`modules` of a process serve only its own source file. By that rule the shell
process declares nine modules its file never requires (channel, env, json, process,
registry, sql, time, tty, uuid; `json` was dropped on 2026-09-11), and 23 more
entries fail it — API functions, windows, and the deliberate `gfx` markers on
libraries. Trimming them would also blind the check above, which reads only a
process's own `modules`. The order is therefore: first make the rights check read
the whole import closure, then trim the entries, then add the reverse check.

## Pixel mode: who switches it on

The mechanics make the decision, but they cannot ask the terminal: the compositor entry
does not declare `gfx`. So the question is asked by the shell, which passes to `library.run`
three things — `pixels`, `cell_size` (as a FUNCTION, not a value: the size changes
when a person changes the terminal font) and the pixel theme.

Rasters are drawn at 1:1 scale: `cols × cell_w` by `rows × cell_h`, icons
stay 16×16/32×32 px. There is no 95% factor in the shell. On `resize`
the runtime updates the cell size from the PTY's pixel dimensions; the shell updates
the geometry of the theme and the clients, and the store recreates rasters of the needed size.
A runtime build with PTY geometry updates is required. If the terminal or SSH
does not pass pixels through the PTY, the answer to the initial query remains: after
changing the terminal font in such an environment the shell has to be restarted.

**It is switched on explicitly, by the variable `BUTSCHSTER_WINDOWS_PIXELS=1`**, not by the presence of
graphics: a terminal that can do sixel is no reason to draw the interface differently
from what a person asked for.

Every refusal along the way leaves the shell in cells and **names the reason** in
the log: no graphics, the terminal did not report the cell size, no font was found.
Pixel mode that silently failed to turn on looks like "somehow the old way",
and a person goes looking for a breakage where there is none.

The font arrives **as bytes** through `fs` (the directory is `BUTSCHSTER_WINDOWS_FONTS`,
by default `app:system_fonts`), not by a path inside `gfx`: reading a file is
governed by the process's permissions, and a module that opens paths by itself would be a road
around them. Bold is a separate file, not an option.

The regular and bold fonts are Liberation Sans 13 px with anti-aliasing:
`gfx.font(bytes, {size = 13, smooth = true})`. Threshold black-and-white rendering
of this small TrueType font lost thin strokes. The setting is stored in
the font and applies to all captions of the shell and the clients; frames and icons
stay without anti-aliasing. A local runtime build with the
`smooth` option of `gfx.font` is required; an individual `raster:text` call can override it.
The `paint-png` command also saves `font-comparison.png`: identical captions
without anti-aliasing and with it, for visually checking the small strokes.

In the "Start" menu and its submenus the names of folders and programs are set in the regular
weight. Window titles, the "Start" button and the side
caption of the menu remain bold. The menu background is `#c0c0c0`, the selection `#000080`.

### Pixel geometry and window background

The title geometry follows Windows 95: an 18 px blue bar, above it two
rows of frame (face and light), the window frame on the sides and bottom — 4 px in the order of
the original (outside face and black, inside light and shadow). The reservation is rounded
up to whole terminal rows, and the bar lives in ONE row as long as the row
is not shorter than 16 px: with a 20 px cell this is exactly the original's 18 px, with 16 px the bar
shrinks to 14 px (buttons 12×10, no window icon — 16 px would lie on the frame).
The window's menu bar lies right under the bar. The title takes two rows only
with a cell shorter than 16 px. Previously a 20 px bar with the frame took two rows with
a 20 px cell and left a dead gray 18 px strip under the title.

Title buttons are 16×14 px via the shared `pixels.button`, two pixels from the edges of
the bar; the marks are rasters from the original (`pixels.caption_mark`): a 6×2 bar,
a 9×9 box, an 8×7 cross; on a small cell the same, four pixels smaller.
"Minimize" and "maximize" stand flush, "close"
stands apart, two blue pixels from the frame. Each button gets its own whole
input cells and is drawn only inside them, so with a 10 px cell
"close" is two pixels narrower (14) and the gap before it is four pixels instead of
two; with an 8 px cell everything matches pixel for pixel.
Their pixel rectangle and the cells it covers are determined together
in `title_buttons`: all covered rows are clickable, and there are no hits into the client.
The client, dragging and resizing use `window_insets`, so
enlarging the title does not overlap the window content. The button sets differ
for a normal window, a dialog and a tool window.

The explorer toolbar has 23×22 px buttons centered in their cells
(`tool_span`, three cells at 10 px), as on the folder window toolbar of the original.
SDK tabs are labels with a bevelled corner and no bottom edge, the active one two
pixels higher and merged with the page; SDK menu headings are centered in their cells
with a highlight six pixels wider than the text; the group frame is etched
(`pixels.etched`).

The explorer address field is 24 px high including the sunken frame,
and is centered in the minimum number of terminal rows. The 16 px icon and the text
fit inside the frame; the whole height of these rows is clickable, the drop-down list
and the file field start below it. In cell mode the address stays single-line.

**The fill stays in cells.** The compositor calls `chrome.fill` for the desktop,
then for each visible window in stacking order — the optional
`chrome.window_background(canvas, window)` and its contents. A normal window
gets a white client area, a dialog a gray one. The background of the upper window covers
the text of the lower one even before the application's first frame.

Pixel placements of icons and frames are clipped by the rectangles of the windows above
them. The clipped fragments are cached together with the source rasters: an unchanged
frame does not redraw the pictures. The menu and the taskbar are drawn on top of windows.

Icons are taken from a pack of original 32×32 and 16×16 px PNGs; the pixel grid is computed
from the cell size and the room for two caption lines. The "Start" menu uses
the text width from the font. The taskbar reserves at least 28 px,
root menu items at least 32 px, submenus at least 24 px; sizes are rounded up to whole
cells. Buttons have inner padding, and captions are moved away from icons.
Taskbar buttons have 3 px above and below, and 2 px between neighboring buttons.
Root items of "Start" use 32 px icons, submenus 16 px.
For tall items `row` and `bottom_row` define the whole click area,
while keeping one keyboard step per item. In character mode the
old grid remains.

"My Computer" declares `meta.pixel_render` and `meta.pixel_state`. If the theme
confirms support through `chrome.renders(id)`, the compositor starts
the state provider and hands drawing to the theme. The explorer uses the same
controller and `render.layout` for both modes. In pixel mode
`render.pixel_metrics` sets a grid of at least 88×72 px, 32 px icons,
a toolbar of at least 26 px and a scrollbar of at least 16 px;
sizes are rounded to cells. Captions are drawn by the theme font at 13 px.
Input, including the wheel, arrows and resizing, uses the same layout.
The theme keeps four rasters per window: menu, tools, field and status.
Without support for this renderer the window stays in cells.
`paint-png 8x18` saves `shots/explorer-native.png` with this geometry.

### The character set does NOT move into pixels

`▢`, `▤`, `▸` and the rest of the pseudo-graphics are characters, and in pixel mode they are
drawn by the font. Liberation Sans has no geometric shapes, and **a missing
rune advances like a space**: emptiness comes out in its place, and there is no failure
at all.

Caught by a screenshot: the first "Start" menu in pixels came out with an empty column
where the icons stand in cells, and without submenu arrows. Not one test
noticed it — the line was drawn, the width matched.

That is why on the pixel path icons are drawn from PNG, arrows with primitives, and
the layout gives the backends two different fields: `text` with the icon character for
cells and `label` without it for pixels. One field for both modes would mean
that one of them draws emptiness.

## Where an exact copy runs into the terminal

A list, not scattered caveats: such places get found anew unless they are
enumerated in one place. Each one is a trade-off, not unfinished work.

- In Windows 95: Dialog button 75×23 px; Here: 80×20 px; Why: 23 px does not fit the 10×20 grid, and the place and size of an interactive detail are whole cells ([FR-005](docs/rfcs/005-pixel-chrome.md) §4a). A button whose hit is not a whole number of cells catches its neighbor's clicks — and that is a defect you cannot see in a screenshot
- In Windows 95: Icons — 32×32 and 16×16 rasters; Here: original PNGs without scaling; Why: 32 icons; source, usage and distribution terms — in [docs/icons.md](docs/icons.md)
- In Windows 95: Arrow cursor, shadows, sounds; Here: none; Why: the terminal offers no way to deliver them
- In Windows 95: Fill of any shape; Here: fill in cells, pixels only where a boundary lies inside a cell; Why: a full-area raster costs 43 ms per frame, and the cost comes from the number of pixels, not from complexity ([FR-005](docs/rfcs/005-pixel-chrome.md) §3a)
- In Windows 95: The vertical caption "Windows 95"; Here: the caption "Wippy 2026" (this is a wippy system, not Windows): in pixels a rotated string; in cells one letter per row, and on a short panel only part of the word is visible; Why: in cells a letter takes up a cell, and the length of the caption runs into the number of menu items. Previously it disappeared SILENTLY in that case; now it is visibly cut

The rule for sizes of interactive details: **decoration is free,
interaction is quantized.** An edge can be one pixel, but the mouse sends
coordinates in cells; SGR 1006 knows no others.

## With the release runtime the module no longer loads

The entries `butschster.windows.shell:pixels` and `…:rasters` declare the `gfx` module,
and it is **not in the release runtime**. `wippy` from PATH (0.3.40a) does not load the module
AT ALL — not "without pixels", but entirely, together with the shell in cells:

```
unresolved dependencies after retry: butschster.windows.shell:pixels …
node with ID {butschster.windows.shell pixels …} not found
```

The cause cannot be guessed from this message, so it is written down here. A
local runtime build is required — `~/repos/wippy/runtime/dist/wippy-linux-amd64`;
in the `Makefile` it is substituted through the `WIPPY` variable, and is overridden with one
line: `make test WIPPY=wippy`.

**This is neither a trifle nor forever.** Until `gfx` is released, the module cannot be
published to the Hub and cannot be brought up on a machine without a local build. There is one
condition for lifting this: `gfx` in the release runtime.

It is worth remembering separately that this is NOT the same as the fallback path in cells
([FR-005](docs/rfcs/005-pixel-chrome.md) §8b). That one is about a terminal without graphics: the shell must work in
a plain xterm. This one is about a runtime without the module, and here the shell does not work
at all.

## The mouse is the main way, arrows the second, no digits

Real Windows 95 had no digit shortcuts, and there are none here either:
a person who opens programs with the mouse reads a column of digits before menu items
as the question "what are these for".

It is worth remembering WHERE they came from, because the mistake repeats
itself: the probe could not send mouse events, and a check had no other way to
open a window. **A limitation of the tool leaked into the interface.** The tool
is fixed — the base's
[`tools/tui-probe.py`](https://github.com/butschster/tui-desktop/blob/main/tools/tui-probe.py)
sends real SGR 1006 mouse events — and the digits are gone. The rule for the
future: when something cannot be checked with the mouse, the probe gets fixed;
no visible button is added for the sake of a check.

The keyboard remains the second way and works the same as in Windows 95: in
the menu `↑`/`↓` move the selection, `→` opens a submenu, `←` closes it,
`Enter` opens, `Esc` closes the menu; in a window with icons the arrows move
the selection across the grid, `Enter` opens.

**The theme does not remember the selected menu line — the compositor names it.** The theme
draws a frame and keeps nothing between frames; `chrome.menu` takes the number of the
selected line in the deepest open panel and **marks the
drawn line with a `cursor` field in the hit markup**. The compositor does not
recompute what is selected — it reads what was drawn. A second count
would drift from the first, and `Enter` would open a line other than the one
that is highlighted.

Every menu hit has `level` and `slot` — the panel level and the number of the
selectable line in it. Only selectable lines count: hints and the "…N more"
cut-off also occupy lines, but there is no reason for the cursor to stop on them.

## What the theme draws and what the window draws

The boundary runs along the window rectangle, and it is strict:

**Theme** — the outer window frame, the title bar, the title buttons, the
taskbar, the "Start" menu, the desktop icons. All of this is about the screen as a whole.

**Window** — everything inside the client area: menu bar, toolbar,
contents, status bar. The compositor gives the window the whole rectangle
inside the frame, and what is drawn there is the window's business.

The lines and the object counter are determined by the window controller. In cell mode it
draws them into the viewport; in pixel mode it sends the state to the compositor through
`window_api.publish_state`. The theme calls the window's drawing library,
and the compositor mechanics do not parse the contents of the state.

So that the desktop and the window do not end up with two mismatched buttons, the primitives —
character set, palette, button, sunken field, bevelled edge — lie in a
shared library that both import. The theme keeps for itself only what
knows about the screen as a whole.

## How a window talks to the compositor

With two things, and both come from the base's library
`butschster.tui_desktop.desktop:window_api`. The window has no protocol of its own.

**The compositor's name arrives in the process context**, and the library reads it.
A constant of its own would work only under this shell: under any other the window
would address a non-existent process, and `open` does not wait for an answer — that is,
a miss would look indistinguishable from a real opening.

**The answer comes through its own channel, not through the inbox.** A loop that reads the inbox for the sake of
an answer takes **everything** from there and throws away whatever is not its answer; in
a window, commands can arrive through the same inbox, and an eaten command is indistinguishable
from one never received — the window simply does not react, and people will look in the compositor,
where everything works.

There are two ways, and **mixing them in one window is not allowed**: a subscription takes
`desktop.reply` for itself, and it will no longer be in the inbox.

- What: `desktop.request(topic, body)` + `desktop.replies()`; When: for a window that draws itself: the channel goes into its own `select` next to events
- What: `desktop.ask(topic, body)`; When: where the frame can stand still: while waiting, the window is not drawn

"My Computer" uses the first. Input is not lost while waiting in either
case — keys, mouse, resizing and closing travel to the window **through
the viewport**, not as messages — but in the second case the frame stands still.

The answer arrives **wrapped**: `payload` is userdata, and inside there is sometimes also
an array of one element. A field read directly will be `nil` without
an error, that is, "the compositor answered with emptiness".

`src/api/control.lua` is left as it was: it is an HTTP handler, nobody needs its inbox
any more, and the naive form of waiting is harmless there. Moving this code
into a window is not allowed.

## The shell can be brought up right inside a test

It was believed that the mechanics could not be checked without a real terminal. Wrong:
**the shell's screen does not have to be a terminal.** `tty.viewport` is created right in
the test function, `view:grant()` gives it to the spawned process — by the same
mechanism the compositor hands screens to its windows — and inside runs
the real `butschster.windows:shell` entry, not a copy of it for the test.

The price of this misconception has already been paid: the `desktop.refresh` command, which the layout
handlers send **after every edit**, was never executed in the base. It
landed in the "no such window" branch because it names no window, and silently
did nothing. From outside this looks like "an icon appears only after a
restart" — that is, like a layout defect, not like a command that did not fire.

That is why `shell_test` checks not the shape of the registry but the whole chain: a row
written — the shell nudged — the shell reread and returned the new number of
rows. The check has been checked by mutation: with a command that does not exist, it goes red.

Wait for **the name in the process registry**, not for time: the name appears when
the shell is ready to accept commands, while a random sleep gives now a false failure, now a
test that "sometimes passes".

## Handlers

All of them are behind the application's authenticated router (`app:api` by default),
so the full path on the test stand looks like `/api/v1/windows/...`.

- `GET /windows/programs` — the catalog from the registry: programs, menu folders,
  order.
- `GET /windows/desktop` — desktop shortcuts and folders; a shortcut to a vanished entry
  is marked `broken`.
- `POST /windows/desktop` — create a shortcut or folder: `kind`, `entry`, `title`,
  `x`, `y`, `parent_id`.
- `PATCH /windows/desktop/{id}` — move or rename. `entry` and
  `kind` do not change: substituting the entry under the same icon means launching something other than
  what is seen. `parent_id: null` moves an icon out of a folder onto the desktop.
- `DELETE /windows/desktop/{id}` — remove a shortcut or folder.
- `GET /windows/status` — whether the shell is alive, its windows and the restore report
  for workshop windows.

**There is no handler for creating a program and there will not be one.** Programs appear
by installing a module or by building a window through the base's workshop
(`POST /tui-desktop/apps`). A creation handler of our own would mean a second source
of truth next to the registry, and they would drift apart on the first module removal.

Three things the answers say outright, because silence here is read
wrongly:

- **`existed` on deletion.** "Deleted something non-existent" and "deleted" are different
  answers, otherwise a typo in an identifier looks like success.
- **`shell` on every mutating handler.** The compositor rereads the layout on
  command, not every frame, so the handler nudges it. If it did not nudge —
  `refreshed: false` with a reason; the row is written anyway, and presenting it as
  a failure is not allowed. A stopped shell is not an error: the layout can be edited even
  with the desktop switched off.
- **`catalog_error`.** An unreadable catalog does not hide the desktop: icons are returned, but
  without the broken mark — blaming a working program on the basis of an
  unread catalog is worse than staying silent.

## A refusal must name its reason

The rule that is easiest to break here, with the most expensive consequences:
**an empty list and "could not read" are different statements.** A person
who got the first instead of the second goes to look for the error in their own application, where
there is none.

That is why `catalog.list()` returns different VALUES, not different contents:
an empty catalog is a table and a `nil` reason, an unreadable registry is `nil` and a string.
The menu must show the reason as text.

The same goes for the restore report of workshop windows. The terminal host's log
is silenced deliberately, so a refusal told only in the log is told to
no one: `GET /windows/status` is the only place where a person will see it.

## Development

`make` already knows about the local build: the target takes it from the `WIPPY` variable,
so `make lint` checks for real, while `wippy lint` by hand does not.

```bash
make setup     # wippy update here and in test/
make lint      # late locals + lint with the gfx build
make test      # SQLite
make postgres-up && make test-pg && make postgres-down
make verify    # setup + check + lint + test
make probes    # rebuild tools/*probe/combined.lua from the current sources
make check-probes  # fail when a probe's combined.lua is stale
make shots     # PNG snapshots into test/shots (CELL=10x20 names the cell) — a wippy run
```

Snapshots (`test/shots/*.png`) are refreshed by `make shots`. It brings the
application up, so a person runs it; lint and test never do. The snapshots are
evidence for the eye: no test compares them, so a snapshot that did not change
is not a check that passed.

A full `make verify` requires a local runtime build with `gfx` and the base in
`../kickside-module`, so it does not run in CI: GitHub Actions
(`.github/workflows/verify.yml`) checks only `make check` and late `local`s.

Tests live in `test/` and bring the module up as a separate application. The shell
can be launched from there by hand:

```bash
cd test && $WIPPY run --host butschster.windows:terminal windows
```

### The base is taken from a working copy

`butschster/tui-desktop` is not yet published to the Hub, so it is connected
by a replacement in `.wippy.yaml` — at the module root and in `test/`. **Condition for removal:** as
soon as the base is published, remove both replacements; otherwise the module builds only
on a machine where the needed directory lies next to it.

### The go-lua trap that cost a day here

In go-lua v1.5.18 (pinned in wippy 0.3.35a) a tail call of a yield function from
the base frame of a coroutine **is not executed at all** — silently, in 0 ms, with no
error. From outside it is indistinguishable from "the function honestly returned emptiness".

```lua
-- trap: the call will NOT happen
return library.run(options)

-- the right way
local ok, err = library.run(options)
return ok, err
```

All Go yields have the same form: `process.send`, `channel.select`, receiving from
a channel, `sql.get`. The rule until the VM is fixed: a function does not end with a bare
`return <yield-call>(...)`.

## "My Computer": drives are registry entries

The window `butschster.windows.explorer:window` is an ordinary registry program
(`meta.type: tui_desktop.window`), and the shell finds it with the same
`registry.find` as everything else. The first-start furniture leads to it.

**The shell does not create drives — it shows them.** A drive here is an
`fs.directory` or `fs.embed` entry, and almost every installed module
brings some: on the test stand there are sixty-eight of them. Hence both rules at once.

- A drive declared by an installed module appears **by itself**, without an edit in
  the shell. A drive table of our own would mean it does not appear until someone
  writes it in by hand.
- A drive that is not in the registry **will not be there**. A drawn `C:` is an object
  that does not exist, and the first question would be why it does not
  open.
- Contents are read by the `fs` module under the window's own permissions. A drive
  that is declared but inaccessible answers with a **reason**, not with emptiness.

The root of "My Computer" holds only file systems. Programs, registry
entries of other kinds and service folders do not get there. The search uses
the top-level `.kind` field; `kind` without the dot does not filter by entry kind.

### Caption, counter and scrollbar — three places where it is easy to lie

- **The caption is the entry name**, not the full identifier: in twelve cells
  `wippy.facade:public_files` does not fit and is cut exactly where
  the difference begins. A name that occurs twice (`ui_static_fs` is brought by
  several modules) is extended with the namespace — and with a **space**, not
  a colon: the caption wraps on spaces, and `keeper ui_static_fs`
  falls onto two lines. The full identifier is not lost: it is in
  the status bar when the icon is selected.
- **The counter counts what is shown.** The top level of the desktop is only what
  lies ON the desktop: if it also showed the contents of folders, every nested icon
  would be visible twice.
- **A row that did not fit is not hidden.** The grid step is four lines,
  the picture is three, and rows are counted by the picture: otherwise a whole row disappears, and
  along with it a scrollbar appears that would not be there without it. Everything that did not
  fit goes to the scrollbar — with arrows that can be
  clicked. The scrollbar is drawn only when there is something to scroll: with
  fully visible contents it would be a promise that there is more somewhere.

### One layout, two backends

`butschster.windows.explorer:render` is split into three parts, and the split is not
cosmetic.

- Part: `render.layout`; What it does: WHAT and WHERE: lines, field, grid, icon rectangles, hits. Not a single paint
- Part: `render.cells`; What it does: draws with characters into a `tty` canvas
- Part: `render_pixels.paint`; What it does: draws with pixels into rasters

The shell must work in a plain xterm, where there are no graphics at all ([FR-005](docs/rfcs/005-pixel-chrome.md)
§8b), and it has no right to die there silently. The price of the second backend is paid
precisely by their layout being shared.

**Hits are computed by the layout, not by the drawing.** Previously they were returned by whoever
drew, and that was right while there was one drawer. With two drawers, "one
table" no longer means "the function that draws" but the layout: two backends
each computing hits in their own way would drift apart silently, and a click would land on
a neighbor in one of the two modes. The icon rectangle is still
taken from the shared grid: in cell mode through `icons.box`, in pixel mode
through `render.pixel_metrics`. A test compares the plan with the drawing and with input.

**The pixel backend is a separate entry, not a branch inside `render`.** An entry
that declared `gfx` does not load at all on a runtime without it. The rule: `gfx`
is declared only by whoever does not exist without it.

**Rasters are taken from the store and not created anew.** A raster recreated
every frame is not a slow screen but a WRONG one: the surface compares
a buffer by its number, and a picture that changed but lies in a new buffer
does not get sent at all. Yesterday's clock stays on screen, and not a single sign
of breakage.

The frame is sliced by ROWS ([FR-005](docs/rfcs/005-pixel-chrome.md) §3): menu, toolbar, field,
status bar — four placements. One for the whole window would mean that
selecting an icon redraws both the menu and the status bar.

### The window's view lives outside the window's process

The contents are drawn by `butschster.windows.explorer:render` — a library that
needs only `tty`. That way the frame can be viewed with the `tools/themeprobe` probe without
the runtime and without the test stand, and a full-screen program cannot be checked otherwise at all:
it writes not lines but a stream with absolute positioning.

Hits are returned by `render.hits` from the shared plan. In cell mode drawing is done by
`render.cells`, in pixel mode by `render_pixels.paint`. The window controller reads
the sources and handles input; the compositor passes the state to the theme without knowing
about the menu, drives and files inside the window.

### Window permissions: read and ask, but not spawn

The policy `butschster.windows.security:explorer_window` grants `registry.find`,
`db.get`, `fs.get`, `process.send` and `process.registry`. **`spawn` and `exec`
are not there** — a window with the right to spawn processes will sooner or later launch something other than
what a file was opened with. It can open a neighboring window only by asking
the compositor, and the compositor decides by itself.

The compositor command is called `desktop.focus`; "raise" is the model's
intent, not a topic name. Sending a topic the compositor does not have means
getting neither a window nor a refusal.
