# Desktop context-menu contributions

Modules add items to the empty desktop's right-click menu through the registry:

```yaml
- name: desktop_properties
  kind: registry.entry
  meta: {type: chicago.desktop_menu, order: 900}
  data:
    text: Properties
    image: display_properties
    entry: chicago.display:window
    # args: an optional string passed to the window
```

`text` must be nonempty. `entry` must resolve to a window with
`meta.type: tui_desktop.window`. `image` is an optional shell icon or image-pack
reference. `args` is an optional string (encode structured arguments as JSON).
Order defaults to 100, ascending; equal values are sorted by declaration ID.

The shell reads declarations on every menu opening. Installed contributions
appear and removed contributions disappear on the next right click, without
restarting the desktop. Invalid declarations are skipped with a visible notice.
Registry failures also produce a notice. Desktop icon menus retain their own
Open/Rename/Delete behavior.

Choosing an item uses the compositor's normal window-opening path and the
logged-on identity, including the target's `meta.requires` check. Contributions
cannot supply shell actions or override identity. No shell import, executable
callback or privileged process is part of this declaration.

The lower-level compositor accepts `options.desktop_menu() -> items, reason`,
using its ordinary menu item format. Shell supplies this registry adapter;
other themes may supply their own. The earlier `desktop_properties` option is
used only when no menu callback was supplied.

Display is the first consumer, owned by `chicago/display`. The shell contains
no hardcoded reference to its window.
