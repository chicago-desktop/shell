#!/usr/bin/env python3
"""Собрать combined.lua — сцены пробника плюс настоящие файлы темы.

Модули склеиваются в один файл нарочно: go-lua в этой сборке не даёт ни
`dofile`, ни `loadfile`, ни `load`, поэтому загрузить библиотеку с диска
изнутри Lua нечем. Каждый файл темы заворачивается в вызов функции — он и
так кончается `return`, — и кладётся в таблицу, которую отдаёт подменённый
`require`.

Пути считаются от расположения этого файла, а не от текущего каталога:
пробник запускают и из корня модуля, и из своей папки.
"""

import pathlib

HERE = pathlib.Path(__file__).resolve().parent
SHELL = HERE.parent.parent / "src" / "shell"
MODULES = ("palette", "glyphs", "widgets", "icons", "chrome")


def wrapped(name: str) -> str:
    source = (SHELL / f"{name}.lua").read_text(encoding="utf-8")
    return "(function()\n" + source + "\nend)()"


def main() -> None:
    text = (HERE / "harness.lua").read_text(encoding="utf-8")
    for name in MODULES:
        marker = f'dofile(BASE .. "{name}.lua")'
        if marker not in text:
            raise SystemExit(f"в harness.lua нет метки для {name}")
        text = text.replace(marker, wrapped(name))
    out = HERE / "combined.lua"
    out.write_text(text, encoding="utf-8")
    print(f"собрано: {out}")


if __name__ == "__main__":
    main()
