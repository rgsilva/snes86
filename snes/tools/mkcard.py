#!/usr/bin/env python3
"""Generate build/card.bmp - an original CC0 640x480 24-bit test card for
VIEW.COM (the demo-tune precedent: the build creates its own free sample
content). Deterministic, no dependencies.

Layout: corner checkerboards, a vertical luminance gradient field, a
central disc with rings, colour bars (exercises the mode-4 mapper), and
1/2/4-pixel gratings across the bottom (exercises true 640-wide mode 6).
"""
import struct
import sys

W, H = 640, 480
px = bytearray(W * H * 3)           # RGB, row 0 = top


def put(x, y, r, g, b):
    o = (y * W + x) * 3
    px[o] = r
    px[o + 1] = g
    px[o + 2] = b


BARS = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]

for y in range(H):
    for x in range(W):
        # base: vertical gradient
        v = 255 - (y * 255 // (H - 1))
        r = g = b = v
        # colour bars band
        if 300 <= y < 360:
            r, g, b = BARS[x * 8 // W]
        # gratings: 1px, 2px, 4px vertical stripes
        if 380 <= y < 460:
            p = 1 << ((x * 3) // W)   # 1, 2, 4
            on = (x // p) & 1
            r = g = b = 255 if on else 0
        # corner checkerboards (32px cells)
        if (x < 96 or x >= W - 96) and (y < 96 or y >= H - 96):
            on = ((x // 32) + (y // 32)) & 1
            r = g = b = 255 if on else 0
        put(x, y, r, g, b)

# central disc + rings
cx, cy = W // 2, 190
for y in range(H):
    for x in range(W):
        dx, dy = x - cx, (y - cy) * 4 // 3   # circular on a 4:3 display
        d2 = dx * dx + dy * dy
        if d2 < 70 * 70:
            put(x, y, 255, 255, 255)
        elif 90 * 90 < d2 < 100 * 100 or 120 * 120 < d2 < 130 * 130:
            put(x, y, 0, 0, 0)

# 8-bit palettised output (a third the size of 24-bit, and it exercises
# VIEW's palette path): entries 0-247 are greys, 248-255 the bar colours.
pal = bytearray()
for i in range(248):
    v = i * 255 // 247
    pal += bytes((v, v, v, 0))                        # BGRA
for r, g, b in BARS:
    pal += bytes((b, g, r, 0))


def index(r, g, b):
    if r == g == b:
        return r * 247 // 255
    return 248 + BARS.index((r, g, b))


data = bytearray()
for y in range(H - 1, -1, -1):       # bottom-up, as classic BMPs are
    for x in range(W):
        o = (y * W + x) * 3
        data.append(index(px[o], px[o + 1], px[o + 2]))
    # W=640 is already 4-aligned

ofs = 14 + 40 + 1024
hdr = b"BM" + struct.pack("<IHHI", ofs + len(data), 0, 0, ofs)
dib = struct.pack("<IiiHHIIiiII", 40, W, H, 1, 8, 0, len(data),
                  2835, 2835, 256, 0)
open(sys.argv[1], "wb").write(hdr + dib + pal + data)
print(f"card.bmp: {ofs + len(data)} bytes")
