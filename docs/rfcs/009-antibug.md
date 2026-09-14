# FR-009. AntiBug — the test scanner in the style of a 1995 antivirus

**Genre:** component specification. Reader: the implementer, an agent or a
human.
**Status:** proposed, 2026-09-14. Decision of the owner: "Windows 95 had
Norton AntiVirus and the like; wippy can run tests inside the runtime — let
us have something like an antivirus shell where one runs the tests and
checks that the whole system works."
**References:** McAfee VirusScan for Windows 95 (the "Scan" window: tabs
`Where & What` / `Actions` / `Reports`, `Scan in:` with `Browse…`, `Include
subfolders`, `All files` / `Program files only`, the buttons `Scan Now` /
`Stop` / `New Scan` in a column at the right, a list of findings `Name` /
`Infected by` / `Status`, the status line `Scanned: N  Infected: N`, and the
"Scan complete. No infected files found." box); Norton AntiVirus for
Windows 95 (the scan progress table Memory / Boot records / Files ×
Scanned / Infected; `Virus List` with `Info`). The runtime side: the
`wippy.test` library (`test.run_cases`), the CLI runner
`wippy.test:runner`, the keeper module's `tests/run` handler.

## 1. The idea in one sentence

> **A scan is a run of test suites; an infected file is a failed test.**
> The window looks like VirusScan 95 and does what `wippy test` does, inside
> the running application, without blocking the shell.

## 2. What the runtime gives

- **Discovery:** registry entries with `meta.type: test` (`registry.find`),
  each `kind: function.lua`, `method: run`, with `meta.group`, `meta.suite`,
  `meta.order`, `meta.timeout` (default `30s`), `meta.comment`. A suite is
  the value of `meta.suite`; entries without one are the suite `other`.
- **Running one entry:** `funcs.new():async(id, {pid, topic, ref_id})`. The
  library streams messages to `pid` on `topic`: `test:plan` (all cases
  before anything runs — the denominator of a progress bar),
  `test:case:start`, `test:case:pass` (`suite`, `test`, `duration`),
  `test:case:fail` (+ `error`), `test:case:skip`, `test:complete` (`total`,
  `passed`, `failed`, `skipped`, `duration`), `test:error`. The function's
  return is the summary table (`status`, counts, `test_suites` keyed by
  name); the return and the last message race, so the reference runners wait
  up to a second for `test:complete` after the response channel fires. An
  entry that streams no case events is a plain function test: `false` is a
  failure.
- **Permissions:** the action is `funcs.call` on the entry id; the test runs
  **under the caller's actor** with the caller's policies. That is why the
  CLI runner has a wildcard policy: a test touching the database, `fs` or
  `gfx` fails under a narrow window scope. `process.listen` needs no right.
- **Not blocking:** `:async` returns a command whose `:response()` is a
  channel; the SDK loop takes extra channels through `context.watch` and
  delivers them to `update` as `{type = "channel"}` actions.

## 3. Trust: who runs the tests

The window is a program under the logged-on user (every window is). Tests
need more than a user has. Two shapes, the first preferred:

1. **A runner entry** `butschster.windows.antibug:runner` (`function.lua`)
   with its own `security.actor` and a policy like `wippy.test:runner_policy`
   (`actions: '*'`); the window calls it with `funcs.async` and the runner
   runs the entry with the events forwarded to the window's pid. Whether a
   `funcs` call honours the callee entry's declared actor must be
   **measured**, not assumed (the logon function of the stand runs "under
   its own actor" when called through `funcs` — check how that entry is
   declared and copy it). If it does, the window keeps a narrow scope.
2. If it does not, the window entry itself carries the wide policy: it is
   the trust anchor, the way the CLI runner is. Then it is opened from
   `Settings`, not `Programs`, and the README says why.

Either way `funcs.call` is granted on `*`: the set of test entries is not
known in advance.

## 4. The window

`butschster.windows.antibug:window`, an SDK application, 64×22 cells,
resizable, `group: Programs` (or `Settings`, §3), title `AntiBug`, image from
the module's icon assets (a fitting `w95_*`/`w98_*` picture — the
implementer picks; there is no antivirus icon in shell32).

Menu bar: **File** (`Scan Now  F5`, `Stop`, ―, `Exit`), **View** (`Refresh
list`, ―, `Show all results` checkmark, ―, `Reports`), **Help** (`About
AntiBug`).

Two tabs as VirusScan (`Actions` dropped: nothing to repair):

- **Where & What** — `Scan in:` a `select` of groups (`All groups` first,
  then every `meta.group`); `Include suites without a group` checkbox
  (`other`); `All tests` / `Only failed last time` radios; a `tree` of
  group → suite → entry with the counts, the selection choosing what to
  scan (an entry, a suite, a group, everything). At the right, one under
  another, the buttons `Scan Now` (default), `Stop`, `New Scan`.
- **Reports** — the log of the last scan: a `text` view, one line per case
  (`PASS suite/test 12 ms`, `FAIL suite/test: <error>`), the plan header and
  the summary at the end; `Save…` writes it through the file dialog
  (`sdk:filedialog`) as `antibug.log` — the one place the window writes.

Under the tabs, always visible:

- the findings `table`: `Name` (suite/test), `Infected by` (the first line
  of the error), `Status` (`Failed` / `Skipped` / `Passed` — passed rows
  only with `Show all results`), `Time`; double-click or Enter on a row
  opens the "Virus Info" sheet: the full error text (wrapped), the suite,
  the entry id, the duration, `OK`.
- a progress row: `Scanning: <suite>/<test>` and a horizontal `gauge`
  (cases done / cases planned; before the plan of the current entry
  arrives, entries done / entries chosen);
- the status bar: `Scanned: N   Infected: M   Skipped: K   Time: 12.3 s`,
  and `Idle` / `Scanning…` / `Stopped` / `Complete` at the right.

Behaviour:

- `Scan Now` runs the chosen entries **sequentially**, one `funcs.async` at
  a time, watching the listen channel and the response channel; the next
  starts when the previous answered and its `test:complete` arrived (or a
  second passed). The per-entry timeout is `meta.timeout`; a timed-out entry
  is one failed finding `timeout after 30s`.
- `Stop` finishes the current entry and starts no other (a running entry
  cannot be killed — the button says `Stop after current` while one runs).
- `New Scan` clears the findings and the log; `Refresh list` re-reads the
  registry.
- When a scan ends, the VirusScan box: `Scan complete.` / `No infected
  tests found.` or `N infected test(s) found.`, `OK`; and a tray notice is
  **not** sent (the taskbar shows notices; nothing else).
- Closing while scanning: the close gate asks `A scan is running. Stop and
  exit?` `Yes` / `No` (`context.stay()` on No). The running entry finishes
  on its own in the runtime; its events go to a pid that is gone.
- The window keeps the last results in its model only; nothing is stored.

## 4a. Scan targets beyond the registry (decision of the owner, 2026-09-14)

"It feels like the tests of wippy itself, of kickside and so on are
missing." They are: the registry holds only the application's own suites
(§5); Hub modules publish without their tests, and the runtime's tests are
Go. So `Scan in:` lists **targets**, and a target is one of three kinds:

- **`registry`** — the running application's test entries (§2–§4), the
  default target `This computer`.
- **`wippy`** — a module working copy on disk: the scan runs the module's
  tests the way `make test` does (`cd <dir>/test && <wippy> test --host
  <host>`, the binary and host from the target's declaration; the local
  runtime build by default, `~/repos/wippy/runtime/dist/wippy-linux-amd64`)
  as a child process through the `exec` module, and parses its output
  line by line into cases (the runner's text lines — the implementer reads
  `wippy/test/display.lua` for the exact forms of a passed, failed and
  skipped case, of a suite header and of the final counts; if the runner has
  a machine-readable mode, use it instead of parsing).
- **`go`** — a Go module: `go test -json ./...` in the directory, parsed
  from its event stream (`Action` = `run` / `pass` / `fail` / `skip` /
  `output`, `Package`, `Test`, `Elapsed`); a failed test's `Infected by` is
  the last `output` lines of that test.

Targets are **registry entries of the application**, found like widgets and
image packs: `meta.type: windows.antibug_target` with `meta.title`,
`meta.kind` (`wippy` | `go`), `meta.dir` (absolute), `meta.wippy` (the
binary, optional), `meta.host` (optional), `meta.order`. The stand declares
four: `Wippy runtime` (go, `~/repos/wippy/runtime`), `tui-desktop` (wippy,
`~/repos/wippy/kickside-module`), `Windows shell` (wippy,
`~/repos/wippy/windows-module`), and the registry target needs no entry.
Rights: `exec` for the runner (§3), on the declared directories only if the
policy can name them; the window itself never execs.

The child runs for minutes: its output arrives through a channel the
window watches, one case at a time into the findings and the log, the
progress gauge counting cases against the previous scan's total of that
target (the first scan of a target shows entries done / entries known,
i.e. the gauge fills only at the end — say `first scan` in the progress
row). `Stop` kills the child (`exec` gives the handle) and marks the target
`Stopped`. A target whose command cannot start (no binary, no directory) is
one failed finding with the reason.

`Scan in: All targets` runs them one after another; the Reports tab keeps
one log with a header per target.

## 5. Where the tests come from on this stand

The stand's own `app_*` suites (`src/app/*/_index.yaml`, `meta.type: test`),
and whatever vendored modules declare. The shell module publishes without
its tests (`exclude_meta.type: [test]`), but as a replacement from the
working copy its `test/` is not loaded by the application either (it is a
separate app with its own lock). So on the stand AntiBug scans the
application's tests, not the shell's — and says so in `About`.

## 6. Tests and evidence

A pure model (`src/antibug/scan.lua`): the tree from a fake registry
listing; the choice of entries for every selection shape; the state machine
fed with fake events (`plan` → progress denominator, `pass`/`fail`/`skip`
counts, `complete` before/after the response, the one-second grace, the
timeout, `Stop` between entries); the findings table rows and the log
lines; the "Show all" filter; the summary box text. Mutation each. The
window: `update` per menu item and button, the close gate; a live test in
the module harness that scans one real test entry of the harness (there
are hundreds) and sees its cases arrive. Shots: `antibug.png` mid-scan with
two findings, and `antibug-complete.png` with the box.

## 7. Not in v1

Running suites in parallel; killing a running entry; scheduling ("Scan at
startup"); an Auto-Protect tray flower; repairing anything; a virus list
of all cases (the tree already lists entries; cases are known only when an
entry runs); the CLI's coloured output.
