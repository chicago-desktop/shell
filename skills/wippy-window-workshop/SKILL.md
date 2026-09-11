---
name: wippy-window-workshop
description: Build a window for the Wippy Windows 95 shell in the running runtime through the WindowsWorkshop MCP tool (or the HTTP workshop) — no files, no restart. Use when an agent connected over MCP must add, iterate, inspect or remove a shell window live. For windows that belong in module sources use wippy-window-app instead.
---

# Building shell windows through MCP

The workshop turns Lua source plus a short description into a registry entry of
the running desktop. The window shows up in the Start menu immediately, survives
restarts (the compositor restores stored windows on boot), and can be replaced
by building again under the same name.

Canonical contracts: the [window SDK](../../docs/sdk.md) for the component tree
and the base module README (`../kickside-module/README.md`, the section on
building a window in the running runtime — the workshop endpoint
`POST /api/v1/tui-desktop/apps`) for the storage and registry mechanics.

## Tool

`WindowsWorkshop` (kickside MCP, trait `app.workshop:trait`). One tool, `action`
selects what happens. Every answer is `{success, ...}`; a failure names the field
or the reason in `error`.

- **`build`** — arguments: `name`, `source`, `title`, `width`, `height`, `modules[]`, `imports{}`, `pixel_render`, `group`, `image`, `icon`, `window_type`, `resizable`, `in_menu`, `open`, `args`; effect: store + register; `replaced` says an older build was overwritten
- **`open`** — arguments: `entry` or `name`, `title`, `args`, `w`, `h`; effect: open a window by registry entry
- **`windows`** — arguments: —; effect: open windows with ids, geometry, `user` (who is logged on)
- **`screen`** — arguments: `id`; effect: the window's text screen — the only evidence a window works
- **`type`** — arguments: `id`, `text`, `enter`; effect: send keystrokes to a window
- **`close`** — arguments: `id`; effect: close a window
- **`list`** — arguments: —; effect: stored workshop windows with `live` (registered right now)
- **`remove`** — arguments: `name`; effect: delete from storage and registry; open windows keep running

If the trait is not active in the MCP session, activate it first:
`use_trait` with `app.workshop:trait` (the credential's `allowed_trait_ids` must
contain it — the MCP page of the app manages that).

Without MCP the same workshop is reachable over HTTP with an API token:
`POST /api/v1/tui-desktop/apps` takes the same fields as `build`;
`GET /api/v1/tui-desktop/apps`, `DELETE /api/v1/tui-desktop/apps/{name}`.
Open and inspect through the desktop command channel of the base README.

## Work sequence

1. Decide the shape with the SDK: a plain-data component tree (`column`, `row`,
   `list`, `table`, `input`, `button`, `checkbox`, `label`, `tabs`, `menu`,
   `tree`). Every interactive control gets a stable unique `id`. UI text is
   English.
2. Write `source` as an SDK application (template below). `init`, `view`,
   `update`, optional `interval` and `dispose`. Keep `view` pure: no I/O, no
   callbacks in the tree.
3. `build` with `imports = {app = "butschster.windows.sdk:app"}`,
   `pixel_render = "butschster.windows.sdk:render"`, a `group` folder
   (`Programs/<module>` style), an `image` from the icon catalog, and `open = true`.
4. Read the answer: `live` must be true; `error` names the field that failed.
5. Verify with `windows` (find the id) and `screen` (read the text). Resize
   below the intended size and scroll long lists through `type` if the window
   has them; a window that only rendered once is not verified.
6. Iterate: build again under the same name. Already open windows keep the old
   code until closed; close them and `open` again.
7. Remove probes and experiments with `remove`.

## Template: SDK window

```lua
local app = require("app")
local desktop = require("desktop")
local definition = {}

function definition.init(args, context)
    return {items = {"First", "Second", "Third"}, selected = 1, text = args or "", notice = "Pick an item"}
end

function definition.view(model, context)
    return {kind = "column", padding = 1, gap = 1, children = {
        {kind = "label", size = 1, text = "Workshop window · " .. context.width .. " x " .. context.height},
        {kind = "list", id = "items", items = model.items, selected = model.selected},
        {kind = "input", id = "text", size = 2, text = model.text},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "label", text = model.notice},
            {kind = "button", id = "ok", size = 12, text = "OK", default = true},
            {kind = "button", id = "close", size = 12, text = "Close"},
        }},
    }}
end

function definition.update(model, action, context)
    if action.id == "items" and action.type == "select" then model.selected = action.index
    elseif action.id == "text" and action.type == "change" then model.text = action.value
    elseif action.id == "ok" then model.notice = "Got: " .. model.text
    elseif action.id == "close" then context.close()
    elseif action.type == "key" and action.key_type == "esc" then context.close() end
end

local function main(first, id, args, viewport)
    app.run(definition, first, id, args, viewport)
end

return {main = main}
```

`build` call for it:

```json
{"action": "build", "name": "probe_list", "title": "Probe", "width": 60, "height": 20,
 "group": "Programs/Workshop", "image": "program",
 "imports": {"app": "butschster.windows.sdk:app"},
 "pixel_render": "butschster.windows.sdk:render", "open": true}
```

## Rules the workshop enforces

- `name`: lowercase latin letters, digits, underscore, starting with a letter.
  It is the key: building again replaces, `remove` deletes.
- `source` must return a table with `main`. An SDK window passes the four
  `main` arguments to `app.run` unchanged: the same code serves the cell mode
  (viewport + tty) and the pixel mode (state provider for the shared renderer).
- `modules` come from a whitelist: `json`, `sql`, `time` on top of the always
  present `tty`, `channel`, `process`. No `fs`, `env`, `exec`, `http`: window
  code arrives over the network and gets rights only to draw and read data.
- `imports` may name any `library.lua` of the registry; a dead id or a
  non-library is refused by field name. Alias `desktop` is reserved for the
  desktop library (`desktop.open`, `desktop.close`, `desktop.list`).
- `pixel_render` must be a library the theme registers (`butschster.windows.sdk:render`
  for SDK windows). Without it the window is cell-only.
- Rights: the window runs under the actor of the logged-on user (Windows logon)
  plus `app_window_scope` (process context, `db.get`, send to the compositor).
  Under a shell without logon it runs under the shell's actor. Neither grants
  spawning processes or changing the registry.
- Registry writes go through the compositor (`desktop.workshop` command):
  the MCP session scope denies `registry.apply`, so a desktop must be running;
  otherwise `build` stores the window and reports that it will register on the
  next start.

## Verification is the screen, not the answer

`build` succeeding proves the entry applied, not that the window draws. Open
it, read `screen`, and look for the labels and controls you expect. A window
that dies on its first frame disappears silently; `windows` then does not list
it. Common causes: a `nil` module, a control without `id`, a duplicated `id`, a
runtime call outside the whitelist, Lua's late `local` (declare everything a
function uses above that function).

## Pitfalls

- `input_schema` of a custom tool must be a YAML map, not a string; otherwise
  MCP shows the tool without arguments. The workshop tool is already correct.
- Long work belongs outside `update`: a synchronous request freezes the window.
  Watch a channel with `context.watch(ch)` and handle `{type = "channel"}`.
- `desktop.open` answers whether the command was sent, not that the window
  opened; check with `windows`.
- A window built by the workshop cannot read files or the environment even if
  a library it imports could: libraries bring their own modules, rights stay
  the window's.
