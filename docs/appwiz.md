# Add/Remove Programs

Opens from "Start → Settings → Add/Remove Programs". A program here
is a wippy module: the list is assembled from the `ns.dependency` declarations in
the registry and the vendor cache (`hub.cache.list` gives the version pinned by the
lock and the size).

## What the window does and does not do

There is no way to remove or install a module in a running runtime: `wippy update`
does that from the declarations in the application's sources, and it takes effect
after a restart. So the window edits the **declarations file** — removes or appends
an `ns.dependency` entry — and says so in the status line: "Next: wippy update,
then a restart". It does not touch the registry or the Hub; it does not pull the
module from the Hub; checking the module name and its requirements is left to
`wippy update`, which will refuse loudly and by name.

- **Remove** — only for modules declared by the application. A dependency of
  another module ("required by module butschster.windows") and a module that lies
  only in the cache cannot be removed, and the window names the reason.
- **Install…** — asks for `org/name` in lowercase and appends an entry with
  version "any" and no parameters. The entry name is the second half of the module
  name; a taken name gives way to the `org-name` form: the runtime silently replaces
  entries with the same name, and other modules' `ns.requirement` break.
- The file is edited **as text**, not by rebuilding the YAML: the human's comments
  stay. What is removed is the item, the comments directly above it and one blank
  line; the tail up to the next item — its comment — is not touched. A test
  verifies that "append, then remove" returns the file byte for byte.

## What the application must provide

The declarations folder is named by the environment variable
`BUTSCHSTER_WINDOWS_DEPS_FS` — the identifier of an `fs.directory` entry over the
directory with the dependencies' `_index.yaml`. On the kickside test stand this is
`app.desktop:deps_source` over `src/app/deps`, set in `.wippy.yaml` as an override
of `app.env:defaults`. Without the variable the window works in "read-only" mode
and says what is missing.

The window's permissions (`butschster.windows.appwiz:window_scope`): read the
registry, read the module cache (`hub.cache.list`), the environment and the
declarations folder; neither spawn processes nor change the registry. The window
is built on the shell SDK
(`butschster.windows.sdk:app`): a table with columns, buttons, an input line — shared components,
both render modes.

## The cache trap

`hub.cache.list` lists everything that lies in the vendor directory, including the
sidecars `org/name-1.2.3.sha256` — with the file name in the `module` field. The
window's first snapshot showed 399 "modules". A module is `org/name` without dots
and with a non-empty version; the rest is dropped before merging.
