#!/usr/bin/env python3
"""
Generate AppIcon.icns for Quick Study.

Design: squircle with a deep-blue → violet gradient (MTG blue flavor),
a stylized open book centered, and a small sparkle nodding to the
"Quick Study" card. Pure Pillow — no asset dependencies.

Run from repo root:
    python3 scripts/generate-icon.py

Writes: Resources/AppIcon.icns (and a temporary iconset dir).
"""
from __future__ import annotations
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
OUT_ICNS = ROOT / "Resources" / "AppIcon.icns"


def squircle_mask(size: int) -> Image.Image:
    """Apple-style continuous rounded rectangle (squircle)."""
    n = 5.0  # superellipse exponent; 4–5 ≈ Apple's curve
    img = Image.new("L", (size, size), 0)
    px = img.load()
    cx = cy = size / 2.0
    r = size / 2.0
    for y in range(size):
        dy = (y + 0.5 - cy) / r
        for x in range(size):
            dx = (x + 0.5 - cx) / r
            v = abs(dx) ** n + abs(dy) ** n
            # soft 1-px feather to avoid hard alpha edge
            if v <= 0.985:
                px[x, y] = 255
            elif v <= 1.0:
                px[x, y] = int(255 * (1.0 - (v - 0.985) / 0.015))
    return img


def gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    img = Image.new("RGB", (size, size), top)
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        r = round(top[0] * (1 - t) + bottom[0] * t)
        g = round(top[1] * (1 - t) + bottom[1] * t)
        b = round(top[2] * (1 - t) + bottom[2] * t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def draw_book(canvas: Image.Image) -> None:
    """Open book centered on canvas. All coordinates scale with canvas size."""
    S = canvas.size[0]
    draw = ImageDraw.Draw(canvas, "RGBA")

    # Book footprint
    book_w = int(S * 0.62)
    book_h = int(S * 0.40)
    cx = S // 2
    cy = int(S * 0.54)
    left = cx - book_w // 2
    top = cy - book_h // 2
    right = cx + book_w // 2
    bottom = cy + book_h // 2

    # Shadow under the book
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse(
        [left + S * 0.02, bottom - S * 0.02, right - S * 0.02, bottom + S * 0.06],
        fill=(0, 0, 0, 110),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.012))
    canvas.alpha_composite(shadow)

    page = (245, 240, 225, 255)
    page_edge = (190, 175, 140, 255)
    spine = (60, 50, 110, 255)

    spine_w = int(S * 0.018)
    # Left page (slight tilt giving an open-book look)
    left_page = [
        (left, top + S * 0.012),
        (cx - spine_w // 2, top - S * 0.004),
        (cx - spine_w // 2, bottom - S * 0.004),
        (left + S * 0.01, bottom + S * 0.008),
    ]
    right_page = [
        (cx + spine_w // 2, top - S * 0.004),
        (right, top + S * 0.012),
        (right - S * 0.01, bottom + S * 0.008),
        (cx + spine_w // 2, bottom - S * 0.004),
    ]
    draw.polygon(left_page, fill=page, outline=page_edge)
    draw.polygon(right_page, fill=page, outline=page_edge)
    # Spine
    draw.polygon(
        [
            (cx - spine_w // 2, top - S * 0.004),
            (cx + spine_w // 2, top - S * 0.004),
            (cx + spine_w // 2, bottom - S * 0.004),
            (cx - spine_w // 2, bottom - S * 0.004),
        ],
        fill=spine,
    )
    # Text lines on each page
    line_color = (90, 80, 130, 200)
    for i in range(5):
        y = top + int(S * 0.045) + i * int(S * 0.045)
        draw.line(
            [(left + S * 0.04, y), (cx - spine_w - S * 0.02, y)],
            fill=line_color,
            width=max(2, S // 220),
        )
        draw.line(
            [(cx + spine_w + S * 0.02, y), (right - S * 0.04, y)],
            fill=line_color,
            width=max(2, S // 220),
        )


def draw_sparkle(canvas: Image.Image, cx: float, cy: float, radius: float) -> None:
    draw = ImageDraw.Draw(canvas, "RGBA")
    # 4-point star
    pts = []
    for i in range(8):
        ang = math.radians(i * 45 - 90)
        r = radius if i % 2 == 0 else radius * 0.32
        pts.append((cx + math.cos(ang) * r, cy + math.sin(ang) * r))
    glow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.polygon(pts, fill=(255, 245, 200, 220))
    glow_blurred = glow.filter(ImageFilter.GaussianBlur(radius * 0.15))
    canvas.alpha_composite(glow_blurred)
    draw.polygon(pts, fill=(255, 255, 255, 255))


def make_master(size: int = 1024) -> Image.Image:
    bg = gradient(size, (40, 60, 140), (120, 70, 180)).convert("RGBA")
    # Subtle inner light
    light = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ld = ImageDraw.Draw(light)
    ld.ellipse(
        [size * 0.05, -size * 0.25, size * 0.95, size * 0.55],
        fill=(255, 255, 255, 38),
    )
    light = light.filter(ImageFilter.GaussianBlur(size * 0.06))
    bg.alpha_composite(light)

    draw_book(bg)
    draw_sparkle(bg, size * 0.78, size * 0.30, size * 0.075)
    draw_sparkle(bg, size * 0.22, size * 0.74, size * 0.045)

    # Squircle clip
    mask = squircle_mask(size)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.paste(bg, (0, 0), mask)
    return out


ICON_SIZES = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]


def main() -> int:
    master = make_master(1024)
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "AppIcon.iconset"
        iconset.mkdir()
        for base, scale in ICON_SIZES:
            px = base * scale
            scaled = master.resize((px, px), Image.LANCZOS)
            suffix = "" if scale == 1 else "@2x"
            scaled.save(iconset / f"icon_{base}x{base}{suffix}.png")
        OUT_ICNS.parent.mkdir(parents=True, exist_ok=True)
        subprocess.check_call(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)]
        )
    print(f"wrote {OUT_ICNS}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
