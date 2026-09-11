---
name: wippy-window-app
description: Add or repair a window application in the Wippy Windows shell. Use for registry registration, declarative window UI, client resize, scrolling, mouse input, lifecycle, and cell/pixel renderer integration in butschster/windows and butschster/tui-desktop. Keeps agents on the same SDK contract.
---

# Wippy window application

Use the installed module's [canonical SDK documentation](../../docs/sdk.md).
Resolve this skill's symlink before following relative paths. The documentation
and this skill are versioned together in `butschster/windows`; do not copy their
contracts into per-app notes. See [the existing-window audit](../../docs/sdk-audit-2026-09-08.md)
when repairing an older custom window.

## Work sequence

1. Identify the module containing the app and the runtime application's actual
   replacement/lock. Read its AGENTS.md. Inspect uncommitted changes before editing:
   multiple agents work these modules. Editing a published package's working copy
   does not update the running app unless it is replaced.
2. Default to `butschster.windows.sdk:app` and a plain-data component tree. Scaffold:
   `python3 <resolved-skill>/scripts/new_window.py --namespace my.documents --title Documents --output <module>/src/documents`.
   The generator refuses to overwrite files. Read the resulting declaration and
   change its icon, model and actions for the actual product. It writes no
   `group`, so the window lands in the default `Programs` folder; a module's
   window adds `group: Programs/<Module>`. The interface is English.
3. Declare one `process.lua` with `meta.type: tui_desktop.window`, exact title,
   dimensions, group and icon. Use `pixel_render: butschster.windows.sdk:render`
   and `pixel_state` pointing to this same process. Keep a single `main` wrapper
   passing arguments to `app.run`. Do not add an app-specific import to the theme.
4. Implement `init`, `view`, `update`, optional `interval`, `title` and `dispose`.
   `definition.title` (a string or a function of the model) is the window
   caption when it differs from the menu entry. Besides control actions,
   `update` receives `{type = "key"}` for a key no component took (close on
   Esc, refresh on F5), `{type = "channel"}` for a channel registered with
   `context.watch(ch)` (`context.unwatch(ch)` stops; a closed channel is
   dropped by itself), `resize`, `tick` and `close` (delivered before the loop
   exits: release resources, it cannot be cancelled). Return `false` from
   `update` when nothing changed to skip the redraw. Give every
   interactive control a stable unique ID. Keep callbacks and resource handles
   out of `view`'s tree. Handle service failures as visible states. Extend the
   app's own security policy only for resources and actions it actually needs.
5. Verify discovery from real registry metadata, open through the compositor,
   resize below the intended size, scroll a long list, replace it with an empty
   list, and close. Exercise both cells and pixels when advertised. Run module
   lint/tests using the runtime with `gfx`, then inspect an actual rendered PNG.
   Test the composed application without interrupting other agents' live flows.

## Invariants to preserve

- The compositor owns the frame, move/resize, window focus, stacking and PTY.
  An application owns client data and actions. Open other windows via
  `window_api`; never spawn Bash directly to imitate Run.
- Registry metadata discovers the app and its Start-menu group. A desktop
  shortcut is separate persisted user data. Do not maintain another app catalog.
- Client rectangles use 1-based cells and exclusive right/bottom bounds. Use one
  layout for rendering and hit tests; accept the actual client size. Pixel
  decoration and padding must stay inside those rectangles.
- Offsets are zero based. Use `scroll.clamp/reveal/wheel/bar/drag`, re-clamp after
  resize/data changes, and retain selection by identity. Grid rows may differ
  from list rows; declare that unit rather than inventing another scroll engine.
- Normalize events through `window_api` or `input`. Ignore key release for
  actions. Left press focuses/selects; SDK buttons and checkboxes activate on
  left release inside their rectangle (outside cancels). Wheel belongs to the
  panel under the cursor. Client motion/release can leave its bounds during capture.
- Render controls through shared `pixels.button/field/checkbox/edge`: two-pixel
  Win95 borders, a dotted focus rectangle, a separate default-button outline
  and single-pass gray disabled labels (no white text shadow at small sizes).
  Do not substitute a single `bevel`.
- Handle close and release resources within the compositor's grace period.
  Read files through a declared `fs` resource under the app's own policy.

## When the controls do not fit

PTY, graphs, trees and richer editors can use the documented custom-window
contract. First inspect the shared components: do not silently invent a new
`kind` or publish a new copy of input/scroll/layout code in the app. For reusable
controls extend the SDK and both backends with a behavior test and docs.

A custom pixel renderer is a theme extension requiring a declared import. It
returns the complete placement list every frame, holds rasters in the shared
store, writes only when dirty, and uses non-overlapping regions inside the
client. An unchanged raster must survive an unrelated frame. Verify several
updates, not just the first screenshot. State providers use `inputs`,
`input_event`, and `publish_state` rather than an ad hoc inbox protocol.

Report actual tests and remaining limitations. Do not claim a rebuild or live
restart unless it happened; Lua module changes through replacements do not
require rebuilding the Go runtime.
