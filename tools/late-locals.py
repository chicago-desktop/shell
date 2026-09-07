#!/usr/bin/env python3
"""Находит `local`, объявленные ниже функции, которая их читает.

За одну ночь на этом споткнулись пять раз в трёх сессиях, и ни один случай не
дал отказа. Локальная переменная видна только НИЖЕ своего объявления; выше она
читается как глобальная, то есть `nil`. Симптомы не похожи ни друг на друга,
ни на причину: «attempt to call a non-function object», пустая строка вместо
текста, «композитор перестал отвечать», полоса без надписи, строка, уехавшая
за край растра.

`wippy lint` этого не ловит вовсе.

Ищутся только объявления УРОВНЯ ФАЙЛА (без отступа): одноимённые локальные
внутри разных функций — обычное дело и не ошибка. Внутрифункциональные
объявления той же переменной выше по файлу считаются перекрытием и снимают
подозрение.

    python3 tools/late-locals.py ../kickside-module ../windows-module
"""
import re
import sys
from pathlib import Path

DECL = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_][\w]*)\s*[=(]")
SHADOW = re.compile(r"^\s+local\s+(?:function\s+)?([A-Za-z_][\w]*)\b")

# Использование: имя, за которым идёт обращение — вызов, поле, индекс, метод.
#
# Слева обязана быть НЕ точка и не двоеточие: `widgets.whole(` — это поле
# чужой таблицы, а не наша локальная. Без этого условия инструмент считает
# ошибкой каждое определение метода и тонет в собственном шуме.
#
# Обращением считается и голое чтение: `chrome.MENU_BANNER = MENU_BANNER`
# присваивает nil, и это один из пяти настоящих случаев за ночь. Справа
# исключено `=` (кроме `==`), иначе ключ таблицы `{name = 1}` читался бы как
# чтение переменной.
USE = r"(?<![.:\w])({})\b(?!\s*=[^=])"

STRING = re.compile(r"""("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|\[\[.*?\]\])""", re.S)


def strip_noise(line: str) -> str:
    """Убирает строковые литералы и комментарий.

    Иначе `dofile("shell/pixels.lua")` читается как обращение к локальной
    `pixels`: инструмент, дающий ложные срабатывания, не используется никем.
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
                # Своя локальная внутри функции выше — это не наш случай.
                break
            # Определение метода на своей таблице — не использование.
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
            # Проверки и инструменты тоже наши, их не пропускаем: один из пяти
            # случаев был именно в пробнике.
            for number, name, declared_at, text in scan(path):
                total += 1
                print(f"{path}:{number}: читает {name!r}, объявленную ниже "
                      f"(строка {declared_at}) — здесь это nil")
                print(f"    {text}")
    if total == 0:
        print("поздних local не найдено")
        return 0
    print(f"\nнайдено: {total}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
