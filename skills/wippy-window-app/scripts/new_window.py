#!/usr/bin/env python3
"""Create a declarative window application without editing the shell."""
import argparse
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--namespace', required=True)
    parser.add_argument('--title', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*', args.namespace):
        parser.error('namespace must contain lowercase dot-separated identifiers')
    if not args.title.strip():
        parser.error('title must not be empty')
    target = args.output
    for name in ('window.lua', '_index.yaml'):
        if (target / name).exists():
            parser.error(f'refusing to overwrite {target / name}')
    source = Path(__file__).resolve().parents[1] / 'assets' / 'window.lua'
    declaration = f'''version: "1.0"
namespace: {args.namespace}
entries:
  - name: window
    kind: process.lua
    meta:
      type: tui_desktop.window
      title: {json.dumps(args.title, ensure_ascii=False)}
      image: program
      # No `group`: the program lands in catalog.DEFAULT_GROUP ("Programs").
      # A module's window names its own folder, e.g. `group: Programs/Bridge`;
      # `group: ""` puts it on the Start-menu root.
      width: 62
      height: 23
      window_type: app
      resizable: true
      pixel_render: windows.shell.sdk:render
      pixel_state: {args.namespace}:window
    source: file://window.lua
    method: main
    imports:
      app: windows.shell.sdk:app
    security:
      policies: [windows.shell.security:view_state]
'''
    target.mkdir(parents=True, exist_ok=True)
    (target / 'window.lua').write_text(source.read_text(), encoding='utf-8')
    (target / '_index.yaml').write_text(declaration, encoding='utf-8')
    print(f'Created {args.namespace}:window in {target}')


if __name__ == '__main__':
    main()
