#!/usr/bin/env python3
"""Builds Frenzy's app icon from Resources/AppIcon-source.png (the "Ember glow" paper fold, made with Codex image
generation, chosen by the founder on 8 Nov 2026).

Crops the tile out of the generated picture, re-shapes it to Apple's macOS icon grid (an 824 px rounded square,
continuous corners, inside a 1024 px canvas with the standard soft drop shadow), then writes
Resources/AppIcon-1024.png and Resources/AppIcon.icns with every size from 16 px to 1024 px.

Usage: python3 scripts/make-app-icon.py   (needs Pillow; iconutil ships with macOS)
"""
import os, shutil, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Resources", "AppIcon-source.png")
# The tile inside the generated 1024 picture, inset a few pixels so its own soft edge and shadow are dropped.
TILE = (61, 62, 949, 950)
CANVAS, BODY = 1024, 824

def squircle_mask(size, n=5.0, scale=4):
    """Continuous-corner rounded square (superellipse), drawn large then scaled down for smooth edges."""
    big = size * scale
    mask = Image.new("L", (big, big), 0)
    pts = []
    import math
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s = math.cos(t), math.sin(t)
        x = (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
        y = (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)
        pts.append(((x + 1) / 2 * (big - 1), (y + 1) / 2 * (big - 1)))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)

def main():
    src = Image.open(SRC).convert("RGBA")
    tile = src.crop(TILE).resize((BODY, BODY), Image.LANCZOS)
    mask = squircle_mask(BODY)
    tile.putalpha(mask)
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2
    # Apple's template shadow: soft, a little below the tile.
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 70), (off, off + 12), mask)
    shadow = shadow.filter(ImageFilter.GaussianBlur(14))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile, (off, off))
    out = os.path.join(ROOT, "Resources", "AppIcon-1024.png")
    canvas.save(out)
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.mkdir(iconset)
        for size in (16, 32, 128, 256, 512):
            canvas.resize((size, size), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}.png"))
            canvas.resize((size * 2, size * 2), Image.LANCZOS).save(os.path.join(iconset, f"icon_{size}x{size}@2x.png"))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ROOT, "Resources", "AppIcon.icns")], check=True)
    print("wrote Resources/AppIcon-1024.png and Resources/AppIcon.icns")

if __name__ == "__main__":
    sys.exit(main())
