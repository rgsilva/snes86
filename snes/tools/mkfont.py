#!/usr/bin/env python3
"""Build the SNES console fonts: full CP437, color-attribute encoding.

Console scheme: mode 5 forces 16x8 tiles, and a 16-wide map entry N
fetches 8x8 tiles N and N+1. Each text cell is one 8x8 half of that
pair; the OTHER half is left fully transparent so the partner layer
shows through:
  - BG2 (2bpp) shows the EVEN text columns: glyph in the LEFT half
  - BG1 (4bpp) shows the ODD text columns: glyph in the RIGHT half

COLOR ENCODING: glyph halves are opaque. Background pixels = color 1,
foreground pixels = color 2, so each palette holds one (bg, fg) pair
and per-cell CGA attributes map to per-tile palette selection. Char 0
is fully transparent (used to blank BG1 in 40-column mode).

Layout of font_bg2.bin (loaded to VRAM $1000, 12 KB):
  tiles   0-511: 256 CP437 chars as [glyph][blank]  (2bpp, 32 B/char)
  tiles 512-767: 128 chars stretched to the full 16px cell (40-col mode)
font_bg1.bin (loaded to VRAM $3000, 16 KB):
  tiles   0-511: 256 CP437 chars as [blank][glyph]  (4bpp, 64 B/char)

Sources: font8x8_basic.h (ASCII), font8x8_box.h (U+2500), and
font8x8_block.h (U+2580) — public domain, Daniel Hepper — plus a few
hand-drawn CP437 glyphs. LSB = leftmost pixel in the source data.
"""
import re
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "build")


def rev8(b):
    r = 0
    for i in range(8):
        if b & (1 << i):
            r |= 0x80 >> i
    return r


def load(fname, count):
    src = open(os.path.join(HERE, fname)).read()
    groups = re.findall(r"\{([^}]*)\}", src)
    out = []
    for g in groups[:count]:
        rows = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]{2}", g)]
        out.append([rev8(r) for r in rows] if len(rows) == 8 else [0] * 8)
    return out


basic = load("font8x8_basic.h", 128)
box = load("font8x8_box.h", 128)      # U+2500-257F
block = load("font8x8_block.h", 32)   # U+2580-259F

BLANK = [0] * 8
glyphs = {c: basic[c] for c in range(128)}

# CP437 $B3-$DA box drawing -> U+2500 block offsets
CP437_BOX = {
    0xB3: 0x02, 0xB4: 0x24, 0xB5: 0x61, 0xB6: 0x62, 0xB7: 0x56,
    0xB8: 0x55, 0xB9: 0x63, 0xBA: 0x51, 0xBB: 0x57, 0xBC: 0x5D,
    0xBD: 0x5C, 0xBE: 0x5B, 0xBF: 0x10, 0xC0: 0x14, 0xC1: 0x34,
    0xC2: 0x2C, 0xC3: 0x1C, 0xC4: 0x00, 0xC5: 0x3C, 0xC6: 0x5E,
    0xC7: 0x5F, 0xC8: 0x5A, 0xC9: 0x54, 0xCA: 0x69, 0xCB: 0x66,
    0xCC: 0x60, 0xCD: 0x50, 0xCE: 0x6C, 0xCF: 0x67, 0xD0: 0x68,
    0xD1: 0x64, 0xD2: 0x65, 0xD3: 0x59, 0xD4: 0x58, 0xD5: 0x52,
    0xD6: 0x53, 0xD7: 0x6B, 0xD8: 0x6A, 0xD9: 0x18, 0xDA: 0x0C,
}
for cp, u in CP437_BOX.items():
    glyphs[cp] = box[u]

# shades and blocks (U+2580 block offsets)
glyphs[0xB0] = block[0x11]            # light shade
glyphs[0xB1] = block[0x12]            # medium shade
glyphs[0xB2] = block[0x13]            # dark shade
glyphs[0xDB] = block[0x08]            # full block
glyphs[0xDC] = block[0x04]            # lower half
glyphs[0xDD] = block[0x0C]            # left half
glyphs[0xDE] = block[0x10]            # right half
glyphs[0xDF] = block[0x00]            # upper half

# a few hand-drawn CP437 essentials
glyphs[0xFA] = [0, 0, 0, 0x18, 0x18, 0, 0, 0]            # middle dot
glyphs[0xF9] = [0, 0, 0x18, 0x3C, 0x3C, 0x18, 0, 0]      # bullet
glyphs[0xFE] = [0, 0x3C, 0x3C, 0x3C, 0x3C, 0x3C, 0, 0]   # small square
glyphs[0x04] = [0x18, 0x3C, 0x7E, 0xFF, 0x7E, 0x3C, 0x18, 0]  # diamond
glyphs[0xF8] = [0x38, 0x44, 0x44, 0x38, 0, 0, 0, 0]      # degree sign
glyphs[0xF1] = [0x18, 0x18, 0x7E, 0x18, 0x18, 0, 0x7E, 0]  # plus-minus


def tile2bpp(rows, opaque=True):
    """2bpp tile: bg pixels = color 1 (plane 0), fg = color 2 (plane 1)."""
    out = bytearray()
    for r in rows:
        out += bytes(((~r & 0xFF) if opaque else 0, r))
    return out


def tile4bpp(rows, opaque=True):
    out = bytearray()
    for r in rows:
        out += bytes(((~r & 0xFF) if opaque else 0, r))
    out += bytes(16)                  # planes 2,3
    return out


TRANS2 = bytes(16)                    # fully transparent tiles
TRANS4 = bytes(32)


def stretch(rows):
    """8px glyph -> two 8px tiles, each pixel doubled (16px total)."""
    left, right = [], []
    for r in rows:
        lo = ro = 0
        for i in range(4):
            if r & (0x80 >> i):
                lo |= 0xC0 >> (2 * i)
            if r & (0x08 >> i):
                ro |= 0xC0 >> (2 * i)
        left.append(lo)
        right.append(ro)
    return left, right


bg2 = bytearray()                     # even columns: [glyph][blank]
bg1 = bytearray()                     # odd columns:  [blank][glyph]
for c in range(256):
    if c == 0:
        bg2 += TRANS2 + TRANS2
        bg1 += TRANS4 + TRANS4
        continue
    rows = glyphs.get(c, BLANK)
    bg2 += tile2bpp(rows) + TRANS2
    bg1 += TRANS4 + tile4bpp(rows)
for c in range(128):                  # 40-col fat font: whole cell opaque
    if c == 0:
        bg2 += TRANS2 + TRANS2
        continue
    l, r = stretch(glyphs.get(c, BLANK))
    bg2 += tile2bpp(l) + tile2bpp(r)

os.makedirs(OUT, exist_ok=True)
open(os.path.join(OUT, "font_bg2.bin"), "wb").write(bg2)
open(os.path.join(OUT, "font_bg1.bin"), "wb").write(bg1)
print(f"font_bg2.bin {len(bg2)} bytes, font_bg1.bin {len(bg1)} bytes")
