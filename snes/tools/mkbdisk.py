#!/usr/bin/env python3
"""System area (boot+FATs+root, 9 sectors) for the B: VRAM RAM disk.

Claims to be a standard 180 KB floppy (so DOS 2.0 media detection just
works) but only 72 sectors exist in VRAM; the FAT marks all clusters
past the backed region as bad, so DOS never allocates them.
"""
import os
import struct
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "build"
TOTAL = 360          # claimed sectors (180 KB)
BACKED = 64          # sectors actually backed by VRAM (36 KB)

bs = bytearray(512)
bs[0:3] = b"\xEB\xFE\x90"
bs[3:11] = b"snes86  "
struct.pack_into("<HBHBHHBHHH", bs, 11,
                 512, 1, 1, 2, 64, TOTAL, 0xFC, 2, 9, 1)
bs[510:512] = b"\x55\xAA"

fat = bytearray(2 * 512)
def setfat(n, v):
    off = n + n // 2
    if n & 1:
        fat[off] = (fat[off] & 0x0F) | ((v & 0xF) << 4)
        fat[off + 1] = (v >> 4) & 0xFF
    else:
        fat[off] = v & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | ((v >> 8) & 0xF)

setfat(0, 0xFFC)                     # media descriptor
setfat(1, 0xFFF)
nclust = TOTAL - 9 - 2               # last cluster number ~= 351
first_bad = BACKED - 9 + 2           # cluster mapping to first unbacked LBA
for c in range(first_bad, nclust + 3):
    setfat(c, 0xFF7)                 # bad cluster

root = bytearray(4 * 512)
root[0:11] = b"SNES86RAM  "
root[11] = 0x08                      # volume label

img = bytes(bs) + bytes(fat) * 2 + bytes(root)
assert len(img) == 9 * 512
os.makedirs(out, exist_ok=True)
open(os.path.join(out, "bdisk.bin"), "wb").write(img)
print(f"bdisk.bin: {len(img)} B, clusters 2-{first_bad-1} usable "
      f"({(first_bad-2)*512} bytes free), {first_bad}+ marked bad")
