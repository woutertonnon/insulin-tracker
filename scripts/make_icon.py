#!/usr/bin/env python3
"""Generate a 1024x1024 app icon PNG using only the Python standard library.

Design: a teal→blue vertical gradient with a white droplet (insulin/glucose
motif). Written to both asset catalogs so iOS and watchOS each have an icon.
No third-party dependencies (Pillow etc.) required.
"""
import struct
import zlib
import math
import os

SIZE = 1024


def lerp(a, b, t):
    return a + (b - a) * t


def build_pixels():
    # Colors
    top = (13, 148, 136)     # teal-600
    bottom = (30, 64, 175)   # blue-800
    drop = (255, 255, 255)

    cx = SIZE / 2
    # Droplet: circle at bottom, point at top -> use a teardrop signed field.
    rows = []
    for y in range(SIZE):
        t = y / (SIZE - 1)
        bg = (
            int(lerp(top[0], bottom[0], t)),
            int(lerp(top[1], bottom[1], t)),
            int(lerp(top[2], bottom[2], t)),
        )
        row = bytearray()
        for x in range(SIZE):
            # Teardrop shape centered horizontally.
            # Lower part: circle radius R centered at (cx, cyc).
            R = SIZE * 0.20
            cyc = SIZE * 0.60
            inside = False
            dx = x - cx
            dy = y - cyc
            if dx * dx + dy * dy <= R * R:
                inside = True
            else:
                # Upper triangle/point from top of circle to a peak.
                peak_y = SIZE * 0.28
                top_y = cyc - R
                if peak_y <= y <= top_y:
                    # half width shrinks linearly to 0 at the peak
                    frac = (y - peak_y) / (top_y - peak_y)
                    half = R * frac
                    if abs(dx) <= half:
                        inside = True
            if inside:
                row += bytes(drop)
            else:
                row += bytes(bg)
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        c += struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        return c

    raw = bytearray()
    for r in rows:
        raw.append(0)  # filter type 0 (None)
        raw += r
    compressed = zlib.compress(bytes(raw), 9)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)  # 8-bit RGB
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", compressed)
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    print("wrote", path, os.path.getsize(path), "bytes")


def main():
    rows = build_pixels()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    targets = [
        os.path.join(here, "iOSApp", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
        os.path.join(here, "WatchApp", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"),
    ]
    for p in targets:
        write_png(p, rows)


if __name__ == "__main__":
    main()
