# AntiBug

Opens from "Start → Programs → AntiBug". A test scanner in the style of McAfee
VirusScan 95 ([FR-009](rfcs/009-antibug.md)): a scan is a run of test entries,
an infected test is a failed case. The window runs the application's
`meta.type: test` entries inside the running runtime — what `wippy test` does —
and the targets the application declares (module working copies, Go modules),
one item at a time and without blocking the shell.

"Where & What" chooses what to scan: `Scan in:` — `This computer` (the
registry's tests), a declared target, or `All targets`; `Include suites without
a group`, `All tests` / `Only failed last time`, and the tree of group → suite
→ entry, with a row per target; the selection scans an entry, a suite, a group,
a target or everything. `Scan Now`, `Stop` and `New Scan` stand at the right.
"Reports" is the log of the last scan, one line per case and a header per
target; `Save…` writes it through the file dialog as `antibug.log`. Under the
tabs: the findings (failures and skips; passes with View → Show all results;
Enter or a double click opens "Virus Info"), the progress gauge and the status
bar. A scan ends with the "Scan complete." box. Closing while a scan runs asks
first.

**Who runs the tests.** Measured, not assumed (`test/src/antibug_actor_test.lua`):
a `funcs` call runs the callee under the actor its entry declares, with its
declared policies added to the caller's scope; an entry without a `security`
block runs as its caller. So the window keeps a narrow scope — the compositor,
the registry, the drives, and `funcs.call` on the runner only — and calls
`butschster.windows.antibug:runner`, which has its own actor and a wide policy,
like the CLI runner's; a test entry declares no actor and runs under it. The
runner runs only `meta.type: test` function entries and declared targets. The
user group's own `funcs.call` does not cover `butschster.windows.*`, so no
other window reaches the runner.

**Test entries.** Sequential: `funcs.async` of the runner, its answer channel
and the window's event topic watched through `context.watch`; an entry is done
when it answered and its `test:complete` arrived, or a second after the
answer; its `meta.timeout` (30 s by default) makes a timed-out entry one
failure. `Stop` lets the running entry finish (it cannot be killed) and starts
no other. The gauge counts the entry's planned cases.

**Targets** (§4a). A registry entry of the application with `meta.type:
windows.antibug_target`, `meta.title`, `meta.kind` (`wippy` | `go`),
`meta.dir`, `meta.env` (the child's environment), and for `wippy` the optional
`meta.wippy` (the binary, `wippy` from PATH if absent — declare the local build
explicitly) and `meta.host` (`wippy.terminal:host` if absent). The child gets
nothing of the runtime's environment — exec.native does not inherit it, and a
`${env:HOME}` placeholder in the module's exec entry was measured to fail the
whole boot where the variable is not in the environment registry — so a target
declares what it needs: `go` PATH and a HOME (or GOCACHE and GOPATH), the wippy
runner HOME and PATH, which the harness it boots reads through `${env:…}`. `wippy` runs `<wippy> test --host <host>` in
`<dir>/test`, as `make test` does; `go` runs `go test -json ./...` in `<dir>`.
The runner builds the command from the registry entry — never from the
window's arguments — with no shell, and spawns the target process
(`butschster.windows.antibug:target`) under its own actor on the host of the
`process_host` requirement; that process runs the child through `exec`
(`butschster.windows.antibug:exec`, which passes HOME and PATH), parses its
output into case events for the window as they come, and kills the child on
`Stop`. The window never execs. A target that cannot start is one finding with
the reason; a bad exit with no failed case is one finding too.

Every child runs under `nice -n 19`: a module's suite or a Go build takes every
core, and on the live shell a scan of the runtime (a full build of it, 19385
build-cache files in ten minutes) left OK and × unanswered. `Stop` kills the
child itself; a Go build's compile and test children finish on their own, at
that priority. A scan redraws at most every 200 ms: every case is an event, a
suite sends hundreds a second, and a frame per event made the window publish
its whole tree to the compositor as often; the end of a scan is drawn at once.

The wippy runner has no machine-readable mode, so its text is parsed: the
progress line (`  ⠋ <suite> (i/n) <entry>`) names the entry, `    o <case>
<time>` / `    x <case>` / `    - <case> (skipped)` are the cases, and the
failures' text comes from the `Failures` block at the end (`<describe> >
<test>` and its lines). `go test -json` gives tests and subtests; a failure's
`Infected by` is its last output lines, a package that does not build is one
`[build failed]` finding with the compiler's lines. The gauge counts cases
against the target's previous scan; on its first scan it counts the entries the
runner announced and says `first scan`. On this stand the runtime's packages
that need the sqlite header build only with `CGO_CFLAGS`; without it they come
back as `[build failed]`.

`src/antibug/scan.lua` is the pure model (the tree, the choice, the state
machine over the test events, the findings, the log, the box); `targets.lua`
the declarations, the commands and the two parsers, pure; `window.lua` the SDK
application; `runner.lua` the runner; `target.lua` the target process.
`test/src/antibug_test.lua` covers the model with fake events, every menu item
and button, the close gate, Save…, a live scan of a real harness entry through
the real runner, and the shots `test/shots/antibug.png` and
`antibug-complete.png`; `antibug_targets_test.lua` the parsers on output
captured from the real tools (`test/fixtures/antibug`), the target's state
machine, and a live scan of a Go target through the runner, the target process
and `exec`.
