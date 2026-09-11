#!/usr/bin/env python3
"""Draw the shell's own wallpapers — assets/wallpaper/*.png.

Original pixel art in the Windows 95 16-colour palette, not Microsoft
artwork, so unlike assets/icons these ship with the module (MIT). Two are
tiles, meant for "Tile"; one is a picture, meant for "Center".

    python3 tools/wallpapers.py [output_dir]
"""
import os
import sys

from PIL import Image

NAVY, BLUE, TEAL, CYAN = (0, 0, 128), (0, 0, 255), (0, 128, 128), (0, 255, 255)
BLACK, WHITE, GRAY, DGRAY = (0, 0, 0), (255, 255, 255), (192, 192, 192), (128, 128, 128)


def rivets() -> Image.Image:
    """A 32×32 navy plate with a bevelled edge and a rivet in each corner."""
    im = Image.new("RGB", (32, 32), NAVY)
    px = im.load()
    for i in range(32):
        px[i, 0] = px[0, i] = BLUE          # light edge top and left
        px[i, 31] = px[31, i] = BLACK       # dark edge bottom and right
    for cx, cy in ((5, 5), (26, 5), (5, 26), (26, 26)):
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                if dx * dx + dy * dy <= 5:
                    px[cx + dx, cy + dy] = GRAY
        px[cx - 1, cy - 1] = WHITE          # the highlight
        px[cx + 1, cy + 1] = DGRAY          # the shadow
    return im


def weave() -> Image.Image:
    """A 32×32 basket weave: teal strips over and under black."""
    im = Image.new("RGB", (32, 32), BLACK)
    px = im.load()
    for y in range(32):
        for x in range(32):
            band_x, band_y = x // 8, y // 8
            horizontal = (band_x + band_y) % 2 == 0
            along = (y % 8) if horizontal else (x % 8)
            if 1 <= along <= 6:
                px[x, y] = CYAN if along == 1 else (TEAL if along < 6 else DGRAY)
    return im


def sky() -> Image.Image:
    """A 320×200 picture: a sky in bands of the palette's blues and three clouds."""
    im = Image.new("RGB", (320, 200), NAVY)
    px = im.load()
    for y in range(200):
        for x in range(320):
            # A 2×2 ordered dither between the bands keeps it in 16 colours.
            level = y / 200 * 3 + ((x + y) % 2) * 0.5
            px[x, y] = (NAVY, BLUE, TEAL, CYAN)[min(3, int(level))]
    # A cloud is one silhouette: the union of its puffs, white above and grey
    # below a line through the cloud's own middle — shading each puff on its
    # own left grey crescents where a lower puff overlapped a higher one.
    for cx, cy, r in ((70, 60, 22), (200, 40, 28), (250, 130, 18)):
        puffs = [(cx + dx * r, cy + dy * r) for dx, dy in ((-1.2, 0.2), (0, 0), (1.1, 0.3), (0.4, -0.5))]
        shade = cy + r * 0.55
        for y in range(int(cy - 2 * r), int(cy + 2 * r) + 1):
            for x in range(int(cx - 3 * r), int(cx + 3 * r) + 1):
                if 0 <= x < 320 and 0 <= y < 200 and any((x - bx) ** 2 + (y - by) ** 2 <= r * r for bx, by in puffs):
                    px[x, y] = WHITE if y < shade else GRAY
    return im


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), "..", "assets", "wallpaper")
    os.makedirs(out, exist_ok=True)
    for name, draw in (("wallpaper_rivets", rivets), ("wallpaper_weave", weave), ("wallpaper_sky", sky)):
        path = os.path.join(out, name + ".png")
        draw().save(path, optimize=True)
        print("wrote", path)


if __name__ == "__main__":
    main()
