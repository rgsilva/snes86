#!/usr/bin/env python3
"""Build the CGA chunky->planar lookup tables + CGA palette for the SNES.

A CGA byte holds 4 pixels of 2 bits, MSB-first: px0 = bits 7-6 ... px3 =
bits 1-0.  A SNES 2bpp tile line is two bytes: plane0 then plane1, MSB =
leftmost pixel.  One 8-pixel tile line comes from two CGA bytes bL|bR:

    word = HI[bL] | LO[bR]

where HI places bL's 4 pixels in bits 7-4 of each plane and LO places
bR's in bits 3-0.  The word is written to $2118/19 little-endian, which
lands plane0 in the low byte — exactly the VRAM layout.

Output: build/cgalut.bin = HI table (256 words) then LO table (256
words), 1 KB total; then 16 BGR555 words of the canonical CGA palette.
"""
import sys
import struct

out = sys.argv[1]


def planes(b):
    p0 = p1 = 0
    for i in range(4):                    # pixel 0 = leftmost = bits 7-6
        v = (b >> (6 - 2 * i)) & 3
        p0 |= (v & 1) << (3 - i)
        p1 |= (v >> 1) << (3 - i)
    return p0, p1


hi = []
lo = []
for b in range(256):
    p0, p1 = planes(b)
    hi.append((p1 << 12) | (p0 << 4))     # plane0 low byte, plane1 high
    lo.append((p1 << 8) | p0)

# canonical CGA 16-color palette -> BGR555
CGA_RGB = [
    (0x00, 0x00, 0x00), (0x00, 0x00, 0xAA), (0x00, 0xAA, 0x00),
    (0x00, 0xAA, 0xAA), (0xAA, 0x00, 0x00), (0xAA, 0x00, 0xAA),
    (0xAA, 0x55, 0x00), (0xAA, 0xAA, 0xAA), (0x55, 0x55, 0x55),
    (0x55, 0x55, 0xFF), (0x55, 0xFF, 0x55), (0x55, 0xFF, 0xFF),
    (0xFF, 0x55, 0x55), (0xFF, 0x55, 0xFF), (0xFF, 0xFF, 0x55),
    (0xFF, 0xFF, 0xFF),
]


def bgr555(r, g, b):
    return ((b >> 3) << 10) | ((g >> 3) << 5) | (r >> 3)


with open(out, "wb") as f:
    for t in (hi, lo):
        f.write(struct.pack("<256H", *t))
    f.write(struct.pack("<16H", *[bgr555(*c) for c in CGA_RGB]))
print(f"{out}: 1056 bytes (HI/LO planar LUTs + 16-color CGA palette)")
