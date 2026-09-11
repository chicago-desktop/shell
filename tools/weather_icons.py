#!/usr/bin/env python3
"""Draw the weather icons of the shell — assets/weather/{32,16}/weather_*.png.

Original pixel art in the Windows 95 palette (flat fills, a one-pixel black
outline), not Microsoft artwork: unlike assets/icons these ship with the
module. Every icon is a stack of masks painted from the back to the front;
a mask is filled with its color and outlined where a 4-neighbour is outside
it, so an overlapping shape (a cloud over the sun) keeps its own edge.

    python3 tools/weather_icons.py        # rewrites both sizes
"""
import math
import os
import sys

from PIL import Image

BLACK = (0, 0, 0, 255)
WHITE = (255, 255, 255, 255)
GRAY = (192, 192, 192, 255)
DGRAY = (128, 128, 128, 255)
YELLOW = (255, 255, 0, 255)
BLUE = (0, 0, 255, 255)
CYAN = (0, 255, 255, 255)
CLEAR = (0, 0, 0, 0)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets", "weather")


def disc(cx, cy, r):
    return lambda x, y: (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= r * r


def box(x0, y0, x1, y1):
    return lambda x, y: x0 <= x < x1 and y0 <= y < y1


def union(*masks):
    return lambda x, y: any(m(x, y) for m in masks)


def minus(a, b):
    return lambda x, y: a(x, y) and not b(x, y)


def segment(x0, y0, x1, y1, half):
    """Points within `half` of the segment — a thick line."""
    dx, dy = x1 - x0, y1 - y0
    length2 = dx * dx + dy * dy or 1

    def inside(x, y):
        px, py = x + 0.5, y + 0.5
        t = max(0.0, min(1.0, ((px - x0) * dx + (py - y0) * dy) / length2))
        return math.hypot(px - (x0 + t * dx), py - (y0 + t * dy)) <= half
    return inside


def paint(img, mask, color, outline=BLACK):
    w, h = img.size
    px = img.load()
    for y in range(h):
        for x in range(w):
            if mask(x, y):
                px[x, y] = color
    if outline is None:
        return
    for y in range(h):
        for x in range(w):
            if not mask(x, y):
                continue
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if not (0 <= nx < w and 0 <= ny < h) or not mask(nx, ny):
                    px[x, y] = outline
                    break


def cloud(s, dx=0, dy=0):
    """A cloud filling the icon: three bumps on a flat base."""
    k = s / 32
    return union(
        disc((10 + dx) * k, (18 + dy) * k, 6 * k),
        disc((17 + dx) * k, (14 + dy) * k, 8 * k),
        disc((24 + dx) * k, (18 + dy) * k, 6 * k),
        box(round((5 + dx) * k), round((18 + dy) * k), round((29 + dx) * k), round((26 + dy) * k)),
    )


def sun(s, cx, cy, r):
    k = s / 32
    rays = []
    for i in range(8):
        a = i * math.pi / 4
        rays.append(segment(cx + math.cos(a) * (r + 2 * k), cy + math.sin(a) * (r + 2 * k),
                            cx + math.cos(a) * (r + 6 * k), cy + math.sin(a) * (r + 6 * k),
                            max(0.6, 1.2 * k)))
    return disc(cx, cy, r), union(*rays)


def draw_sun(img, s):
    k = s / 32
    body, rays = sun(s, 16 * k, 16 * k, 7 * k)
    paint(img, rays, YELLOW)
    paint(img, body, YELLOW)


def draw_sun_cloud(img, s):
    k = s / 32
    body, rays = sun(s, 11 * k, 11 * k, 6 * k)
    paint(img, rays, YELLOW)
    paint(img, body, YELLOW)
    paint(img, cloud(s, 3, 5), WHITE)


def draw_cloud(img, s):
    paint(img, cloud(s, 0, 2), WHITE)


def draw_fog(img, s):
    k = s / 32
    paint(img, cloud(s, 0, -4), GRAY)
    for row in (24, 28):
        paint(img, box(round(4 * k), round(row * k), round(28 * k), round((row + 2) * k)), DGRAY, None)


def draw_rain(img, s):
    k = s / 32
    paint(img, cloud(s, 0, -5), WHITE)
    for col in (9, 16, 23):
        paint(img, segment((col + 1) * k, 23 * k, (col - 1) * k, 30 * k, max(0.6, 1.0 * k)), BLUE, None)


def draw_snow(img, s):
    k = s / 32
    paint(img, cloud(s, 0, -5), WHITE)
    arm = max(1, round(2.5 * k))
    for col, row in ((9, 26), (16, 28), (23, 26)):
        cx, cy = round(col * k), round(row * k)
        paint(img, union(box(cx - arm, cy, cx + arm + 1, cy + 1), box(cx, cy - arm, cx + 1, cy + arm + 1)), CYAN, None)


def draw_storm(img, s):
    k = s / 32
    paint(img, cloud(s, 0, -5), DGRAY)
    bolt = union(segment(18 * k, 19 * k, 14 * k, 26 * k, 1.4 * k), segment(14 * k, 26 * k, 19 * k, 25 * k, 1.0 * k),
                 segment(19 * k, 25 * k, 15 * k, 31 * k, 1.4 * k))
    paint(img, bolt, YELLOW)


def moon(s, cx, cy, r):
    k = s / 32
    return minus(disc(cx, cy, r), disc(cx + 5 * k, cy - 4 * k, r - 1 * k))


def draw_moon(img, s):
    k = s / 32
    paint(img, moon(s, 15 * k, 17 * k, 9 * k), YELLOW)


def draw_moon_cloud(img, s):
    k = s / 32
    paint(img, moon(s, 11 * k, 11 * k, 8 * k), YELLOW)
    paint(img, cloud(s, 3, 5), WHITE)


ICONS = {
    "weather_sun": draw_sun,
    "weather_sun_cloud": draw_sun_cloud,
    "weather_cloud": draw_cloud,
    "weather_fog": draw_fog,
    "weather_rain": draw_rain,
    "weather_snow": draw_snow,
    "weather_storm": draw_storm,
    "weather_moon": draw_moon,
    "weather_moon_cloud": draw_moon_cloud,
}


def main():
    for size in (32, 16):
        folder = os.path.join(ROOT, str(size))
        os.makedirs(folder, exist_ok=True)
        for name, draw in ICONS.items():
            img = Image.new("RGBA", (size, size), CLEAR)
            draw(img, size)
            img.save(os.path.join(folder, name + ".png"))
            print(f"{size:>2} {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
