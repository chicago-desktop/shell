#!/usr/bin/env python3
"""Finds `local`s declared below the function that reads them.

In one night people tripped over this five times in three sessions, and not
one case produced a failure. A local variable is visible only BELOW its
declaration; above it, it is read as a global, that is, `nil`. The symptoms
resemble neither each other nor the cause: "attempt to call a non-function
object", an empty string instead of text, "the compositor stopped responding",
a bar without a label, a line that slid past the edge of the raster.

`wippy lint` does not catch this at all.

Only FILE-LEVEL declarations (no indentation) are searched: same-named locals
inside different functions are routine and not an error. In-function
declarations of the same variable higher up in the file count as shadowing and
lift the suspicion.

    python3 tools/late-locals.py ../tui-desktop ../shell
"""
import re
import sys
from pathlib import Path

DECL = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_][\w]*)\s*[=(]")
SHADOW = re.compile(r"^\s+local\s+(?:function\s+)?([A-Za-z_][\w]*)\b")

# A use: a name followed by an access — a call, a field, an index, a method.
#
# On the left there must be NEITHER a dot nor a colon: `widgets.whole(` is a
# field of someone else's table, not our local. Without this condition the
# tool counts every method definition as an error and drowns in its own noise.
#
# A bare read also counts as an access: `chrome.MENU_BANNER = MENU_BANNER`
# assigns nil, and that is one of the five real cases of that night. On the
# right, `=` is excluded (except `==`), otherwise the table key `{name = 1}`
# would be read as a read of the variable.
USE = r"(?<![.:\w])({})\b(?!\s*=[^=])"

STRING = re.compile(r"""("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[\[.*?\]\])""", re.S)


def strip_noise(line: str) -> str:
    """Removes string literals and the comment.

    Otherwise `dofile("shell/pixels.lua")` reads as an access to the local
    `pixels`: a tool that gives false positives is used by no one.
    """
    line = STRING.sub('""', line)
    comment = line.find("--")
    return line if comment < 0 else line[:comment]


def scan(path: Path):
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    declared: dict[str, int] = {}
    for number, line in enumerate(lines, 1):
        match = DECL.match(line)
        if match and match.group(1) not in declared:
            declared[match.group(1)] = number

    findings = []
    for name, declared_at in declared.items():
        pattern = re.compile(USE.format(re.escape(name)))
        for number, line in enumerate(lines[: declared_at - 1], 1):
            stripped = line.lstrip()
            if stripped.startswith("--"):
                continue
            shadow = SHADOW.match(line)
            if shadow and shadow.group(1) == name:
                # A local of its own inside a function above is not our case.
                break
            # A method definition on its own table is not a use.
            if re.match(r"\s*(?:local\s+)?function\s+[\w.]*\b" + re.escape(name) + r"\b", line):
                continue
            if pattern.search(strip_noise(line)):
                findings.append((number, name, declared_at, stripped[:70]))
                break
    return findings


def main(argv):
    roots = [Path(a) for a in argv[1:]] or [Path(".")]
    total = 0
    for root in roots:
        for path in sorted(root.rglob("*.lua")):
            # Tests and tools are ours too, we do not skip them: one of the five
            # cases was in the probe itself.
            for number, name, declared_at, text in scan(path):
                total += 1
                print(f"{path}:{number}: reads {name!r}, declared below "
                      f"(line {declared_at}) — here it is nil")
                print(f"    {text}")
    if total == 0:
        print("no late locals found")
        return 0
    print(f"\nfound: {total}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
