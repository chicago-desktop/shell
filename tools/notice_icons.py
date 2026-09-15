#!/usr/bin/env python3
"""Draw the notification pictures — assets/icons/{16,32}/{info,warning,error}.png.

Original pixel art in the Windows 95 16-colour palette, not Microsoft
artwork: a blue disc with a white "i", a yellow triangle with a black "!",
a red disc with a white cross. Hard edges, no smoothing, each size drawn on
its own grid and never scaled, like the rest of the pack. The balloon tips
and the message windows of the shell's notifications draw them
(docs/icons.md, "The notification pictures").

    python3 tools/notice_icons.py [icons_dir]
"""
import os
import sys

from PIL import Image

CLEAR = (0, 0, 0, 0)
BLACK, WHITE = (0, 0, 0, 255), (255, 255, 255, 255)
NAVY, BLUE = (0, 0, 128, 255), (0, 0, 255, 255)
MAROON, RED = (128, 0, 0, 255), (255, 0, 0, 255)
YELLOW = (255, 255, 0, 255)


def fill(px, x0, y0, x1, y1, ink):
    """A rectangle, both corners inclusive."""
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            px[x, y] = ink


def disc(size, face, edge):
    """A disc filling the square, a one-pixel edge of its own colour."""
    im = Image.new("RGBA", (size, size), CLEAR)
    px = im.load()
    centre = (size - 1) / 2
    radius = size / 2 - 0.5
    for y in range(size):
        for x in range(size):
            distance = ((x - centre) ** 2 + (y - centre) ** 2) ** 0.5
            if distance <= radius - 1:
                px[x, y] = face
            elif distance <= radius + 0.25:
                px[x, y] = edge
    return im


def info(size):
    """A blue disc with a white "i": a dot, a stem with a serif and a foot."""
    im = disc(size, BLUE, NAVY)
    px = im.load()
    if size == 16:
        fill(px, 7, 3, 8, 4, WHITE)
        fill(px, 6, 6, 8, 6, WHITE)
        fill(px, 7, 7, 8, 11, WHITE)
        fill(px, 6, 12, 9, 12, WHITE)
    else:
        fill(px, 14, 5, 17, 8, WHITE)
        fill(px, 12, 11, 17, 12, WHITE)
        fill(px, 14, 13, 17, 23, WHITE)
        fill(px, 12, 24, 19, 25, WHITE)
    return im


def warning(size):
    """A yellow triangle with a black edge and a black "!"."""
    im = Image.new("RGBA", (size, size), CLEAR)
    px = im.load()
    top, bottom = 1, size - 2
    centre = (size - 1) / 2
    for y in range(top, bottom + 1):
        half = (y - top) / (bottom - top) * (size / 2 - 1)
        for x in range(size):
            dx = abs(x - centre)
            if dx <= half - 1 and y < bottom:
                px[x, y] = YELLOW
            elif dx <= half + 0.5:
                px[x, y] = BLACK
    if size == 16:
        fill(px, 7, 5, 8, 10, BLACK)
        fill(px, 7, 12, 8, 13, BLACK)
    else:
        fill(px, 14, 10, 17, 21, BLACK)
        fill(px, 14, 24, 17, 27, BLACK)
    return im


def error(size):
    """A red disc with a white cross, two pixels thick at 16, three at 32."""
    im = disc(size, RED, MAROON)
    px = im.load()
    low, high, extra = (4, 11, 1) if size == 16 else (9, 22, 2)
    for step in range(high - low + 1):
        for thick in range(extra + 1):
            for x in (low + step + thick, high - step - thick):
                if low <= x <= high:
                    px[x, low + step] = WHITE
    return im


PICTURES = {"info": info, "warning": warning, "error": error}


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "assets", "icons")
    for size in (16, 32):
        folder = os.path.join(out, str(size))
        os.makedirs(folder, exist_ok=True)
        for name, draw in PICTURES.items():
            path = os.path.join(folder, name + ".png")
            draw(size).save(path)
            print(path)


if __name__ == "__main__":
    main()
