#!/usr/bin/env python3
"""Rasterise the vendored Framework7 Icons (MIT) into the kiosk's f7_<name>[@2x].png files.

The sources live in assets/icons/framework7/. Glyphs are filled paths on a 56 unit canvas, so
they are filled even-odd and rendered black on transparent; the app tints them at runtime.
Needs Pillow. Output: ios-kiosk/resources/icons/f7_<name>.png (30 px) and @2x (60 px).
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import svg_path  # noqa: E402

SOURCE = os.path.join(ROOT, "assets", "icons", "framework7")
OUT = os.path.join(ROOT, "ios-kiosk", "resources", "icons")
VIEWBOX = 56.0
SIZE = 30

TRANSLATE = re.compile(r'transform="translate\(\s*([-\d.]+)[\s,]+([-\d.]+)\s*\)"')
PATH = re.compile(r'<path\b([^>]*?)\sd="([^"]+)"([^>]*)>', re.S)


def subpaths(text):
    out = []
    for before, data, after in PATH.findall(text):
        match = TRANSLATE.search(before + " " + after)
        dx, dy = (float(match.group(1)), float(match.group(2))) if match else (0.0, 0.0)
        for _closed, points in svg_path.flatten(" ".join(data.split()), curve_steps=24):
            out.append([(x + dx, y + dy) for x, y in points])
    if not out:
        raise SystemExit("no path in a Framework7 source")
    return out


def render(text, size, supersample=4):
    from PIL import Image, ImageChops, ImageDraw
    big = size * supersample
    scale = big / VIEWBOX
    mask = Image.new("1", (big, big), 0)
    for points in subpaths(text):
        if len(points) < 3:
            continue
        layer = Image.new("1", (big, big), 0)
        ImageDraw.Draw(layer).polygon([(x * scale, y * scale) for x, y in points], fill=1)
        mask = ImageChops.logical_xor(mask, layer)
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    image.putalpha(mask.convert("L"))
    return image.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    for entry in sorted(os.listdir(SOURCE)):
        if not entry.endswith(".svg"):
            continue
        name = entry[:-4]
        with open(os.path.join(SOURCE, entry), "r", encoding="utf-8") as handle:
            text = handle.read()
        for suffix, size in (("", SIZE), ("@2x", SIZE * 2)):
            render(text, size).save(os.path.join(OUT, "f7_" + name + suffix + ".png"), "PNG",
                                    optimize=True)
        print("f7_" + name)


if __name__ == "__main__":
    main()
