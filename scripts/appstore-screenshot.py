#!/usr/bin/env python3
"""Compose a Mac App Store screenshot from a window capture.

Takes a capture of the QuickStudy panel (ideally Cmd-Shift-4 -> Space window
capture, which keeps the drop shadow + alpha) and centers it on a gradient
canvas at an Apple-accepted macOS screenshot size.

Usage:
  python3 scripts/appstore-screenshot.py capture.png out.png [--size 2880x1800] [--scale 2.0]

Requires Pillow (same as generate-icon.py).
"""

import argparse
import sys

from PIL import Image

ACCEPTED = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}

# Diagonal gradient endpoints — deep indigo to warm violet, matches the
# wand-and-stars branding without competing with the panel content.
TOP_LEFT = (24, 22, 46)
BOTTOM_RIGHT = (92, 51, 113)


def gradient(size):
    w, h = size
    img = Image.new("RGB", size)
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x / (w - 1) + y / (h - 1)) / 2
            px[x, y] = tuple(
                round(a + (b - a) * t) for a, b in zip(TOP_LEFT, BOTTOM_RIGHT)
            )
    return img


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("capture")
    ap.add_argument("output")
    ap.add_argument("--size", default="2880x1800")
    ap.add_argument("--scale", type=float, default=2.0,
                    help="upscale factor for the captured window (default 2.0)")
    args = ap.parse_args()

    w, h = (int(v) for v in args.size.lower().split("x"))
    if (w, h) not in ACCEPTED:
        sys.exit(f"ERROR: {w}x{h} is not an accepted macOS App Store size: "
                 + ", ".join(f"{a}x{b}" for a, b in sorted(ACCEPTED)))

    win = Image.open(args.capture).convert("RGBA")
    if args.scale != 1.0:
        win = win.resize(
            (round(win.width * args.scale), round(win.height * args.scale)),
            Image.LANCZOS,
        )
    if win.width > w or win.height > h:
        win.thumbnail((round(w * 0.9), round(h * 0.9)), Image.LANCZOS)

    canvas = gradient((w, h))
    canvas.paste(win, ((w - win.width) // 2, (h - win.height) // 2), win)
    canvas.save(args.output, "PNG")
    print(f"wrote {args.output} ({w}x{h})")


if __name__ == "__main__":
    main()
