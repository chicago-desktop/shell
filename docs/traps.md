# Traps

Engineering notes on what has already broken in this module — most of it
silently. They stood in the [README](../README.md) until 2026-09-11 and moved
here as they were, one heading per trap, so that the README stays a reference.

Six findings of one night, and not one of them produced a failure. What they share is not only
silence: **each half was right on its own, and so both sides
looked tested.** Reading this before touching the code is cheaper than
finding it all again.

## `string.format("%x")` prints the hex of the number's TEXT here

In this runtime `string.format("%02x", 255)` returns `"323535"` — the hex codes of
the characters "2", "5", "5" — not `"ff"`. It fails no call and looks like a
color: `"#" .. string.format("%02x%02x%02x", r, g, b)` builds a string that goes
straight into a style or a raster as some other color, and the first sign is a
spectrum that runs the wrong way. Build hex digits by hand (`ui.spectrum_color`
does, and says why) and check a color by its value in a test, not by its look.

The float verbs are broken for integers too: `string.format("%.1f", 3)` returns
`"%!f(lua.LInteger=3)"`, and `%e`/`%g` the same — go-lua's integer type has no
formatter of its own, so Go's `fmt` gets an `int64` for a float verb. Safe on an
integer: `%d %i %o %c %s`. The rule: **a float verb gets a float (`x + 0.0`),
hex is built by hand.** The calculator's `%.12g` does the first
(`calc/engine.lua`), as a guard: go-lua's `tonumber` returns a float even for an
integer today, so the integer only arrives once it keeps integers as Lua 5.3
does; the cause and the failing test are in
`kickside/docs/bugreports/go-lua-string-format-hex.md`.

## The folder path is parsed by the CATALOG, and only by it

`meta.group` is a string like `System Tools/Network`; it is turned into a list of segments by
`chicago.shell.programs:catalog`, and the depth cut is there too
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

## A hit the compositor cannot read is a missing hit

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

## A function nobody calls is green in any suite

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

## Lint with THE build that has `gfx`

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

## Late `local`s are checked, not remembered

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

## A declared module without a granted permission stays silent instead of refusing

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

## Runtime errors are userdata: read the kind, and `system.*` calls a refusal Invalid

An error from a runtime module is userdata with `kind()`, `message()` and
`details()`. `tostring(err)` keeps the text and loses the kind — and the kind is
the only thing that tells "not allowed" from "not there". `env.get` marks a
refusal `PermissionDenied`. `system.*` does not: it answers a permission refusal
with `Invalid` and a message starting `permission denied`, and `Invalid` alone
also means "empty host identifier". So a refusal from `system.*` is recognised
by the kind AND the start of the message.

Both rules live in one place each — `chicago.shell.config:environment`
(`read`, `read_or`) and `chicago.shell.config:system` (`facts.denied`,
`facts.reason`) — and windows call them instead of reading `env` or `system`
themselves. Three windows each had their own `snapshot()` and each turned a
refusal into a value: zero memory, "unnamed" node, "(none)" leader.

## A window is told when it loses the keyboard

The compositor never told a window it had lost focus. A button armed by a press
whose release went to another window — or was lost when the window was
minimized — stayed armed, and a release arriving later activated it; a captured
scrollbar drag stayed captured the same way.

The base now sends `{type = "focus", focused = false|true}` — the runtime's own
terminal focus event — after the frame in which the top visible window changes:
the window that lost the keyboard first, then the one that got it. A window that
has not drawn its first frame is told on the next one. A PTY window forwards the
event to its program, and the runtime's PTY proxy writes `\e[I`/`\e[O` only when
the program asked for focus reports (mode 1004): bash gets nothing. The SDK
drops what was armed or captured on `focused = false` (`app.focus`) and redraws
only when something was held; an application's `update` does not see the event.

The base side is in `kickside-module`'s working copy until its commit; checked
by `window_focus_test` there and `sdk_focus_test` here.

## The character set does NOT move into pixels

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

## With the release runtime the module no longer loads

The entries `chicago.shell.theme:pixels` and `…:rasters` declare the `gfx` module,
and it is **not in the release runtime**. `wippy` from PATH (0.3.40a) does not load the module
AT ALL — not "without pixels", but entirely, together with the shell in cells:

```
unresolved dependencies after retry: chicago.shell.theme:pixels …
node with ID {chicago.shell.theme pixels …} not found
```

The cause cannot be guessed from this message, so it is written down here. A
local runtime build is required — `~/repos/wippy/runtime/dist/wippy-linux-amd64`;
in the `Makefile` it is substituted through the `WIPPY` variable, and is overridden with one
line: `make test WIPPY=wippy`.

**This is neither a trifle nor forever.** Until `gfx` is released, the module cannot be
published to the Hub and cannot be brought up on a machine without a local build. There is one
condition for lifting this: `gfx` in the release runtime.

It is worth remembering separately that this is NOT the same as the fallback path in cells
([FR-005](rfcs/005-pixel-chrome.md) §8b). That one is about a terminal without graphics: the shell must work in
a plain xterm. This one is about a runtime without the module, and here the shell does not work
at all.

## The go-lua trap that cost a day here

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

## `table.concat(t, sep, j + 1, j)` is `t[j]` here, not ""

```lua
table.concat({"a", "b"}, "", 3, 2)   -- "b" in this runtime; "" in Lua
```

An empty range at the end of a table gives its last element back. With `j = 0`
there is no `t[0]`, so the common `table.concat(t, "", 1, 0)` does return "" and
hides the trap. It surfaced in the editor's model: the tail after a caret at a
line's end is exactly such a range, and typing "abc" gave "abca". No error, a
letter too many. Join a range of runes through a helper that returns "" when
`from > to` (`slice` in `chicago.shell.sdk:editor`); the tripwire that
fails once the VM is fixed is in `test/src/editor_model_test.lua`.
