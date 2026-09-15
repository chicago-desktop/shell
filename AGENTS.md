# Chicago shell module: instructions for coding agents

Read [README.md](README.md) for the module and local runtime setup.
For any window application, start with the canonical [SDK](docs/sdk.md) and
use [wippy-window-app](skills/wippy-window-app/SKILL.md). A window built live
through MCP or the HTTP workshop follows
[wippy-window-workshop](skills/wippy-window-workshop/SKILL.md). This applies to
registration, client geometry, scrolling, resize, input, state and rendering.
The [migration audit](docs/sdk-audit-2026-09-08.md) identifies specialized apps.
The [SDK review](docs/sdk-review-2026-09-08.md) lists what still diverges
between the two renderers and between windows, and the unification order.

New standard applications use registry metadata plus `sdk:app` and a component
tree. Do not copy a window loop or add a renderer to the theme for each app.
Extend the shared SDK when behavior belongs to multiple applications.

Other agents edit these working copies. Preserve their changes; never replace
an entire dirty file with an older copy. Verify module tests with the local
runtime containing `gfx` (Makefile), inspect rendering evidence, and check the
composed application. Do not restart shared durable flows to test a window.
