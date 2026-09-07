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
SRC = HERE.parent.parent / "src"
# Файлы темы и файлы окна «Мой компьютер». Второе здесь потому, что содержимое
# окна — такие же строки и арифметика, как тема, и проверяется тем же способом:
# полноэкранную программу иначе не посмотреть вовсе.
MODULES = (
    ("shell", "palette"),
    ("shell", "glyphs"),
    ("shell", "widgets"),
    ("shell", "icons"),
    ("shell", "chrome"),
    ("explorer", "model"),
    ("explorer", "render"),
)


def wrapped(folder: str, name: str) -> str:
    source = (SRC / folder / f"{name}.lua").read_text(encoding="utf-8")
    return "(function()\n" + source + "\nend)()"


def main() -> None:
    text = (HERE / "harness.lua").read_text(encoding="utf-8")
    for folder, name in MODULES:
        marker = f'dofile(BASE .. "{folder}/{name}.lua")'
        if marker not in text:
            raise SystemExit(f"в harness.lua нет метки для {folder}/{name}")
        text = text.replace(marker, wrapped(folder, name))
    out = HERE / "combined.lua"
    out.write_text(text, encoding="utf-8")
    print(f"собрано: {out}")


if __name__ == "__main__":
    main()
