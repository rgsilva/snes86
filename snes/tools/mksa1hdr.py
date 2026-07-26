#!/usr/bin/env python3
"""Post-link SNES header fixup for the SA-1 variant.

wla-dx can't emit an SA-1 cart header: the map-mode byte is stuck at
LoROM(+fast) and SRAMSIZE is capped at $07 (128 KB). Patch the two
bytes ($FFD5 map mode -> $23 SA-1, $FFD8 SRAM size -> $08 = 256 KB
BW-RAM) and recompute the checksum/complement pair.
"""
import sys

path = sys.argv[1]
d = bytearray(open(path, "rb").read())
HDR = 0x7FC0                              # LoROM-position header
d[HDR + 0x15] = 0x23                      # map mode: SA-1
assert d[HDR + 0x16] == 0x35, "cart type is not SA-1+RAM+battery"
d[HDR + 0x18] = 0x08                      # 256 KB BW-RAM
d[HDR + 0x1C:HDR + 0x20] = b"\xFF\xFF\x00\x00"  # canonical placeholder
chk = sum(d) & 0xFFFF                     # placeholder pair sums to $1FE
d[HDR + 0x1E] = chk & 0xFF
d[HDR + 0x1F] = chk >> 8
d[HDR + 0x1C] = (~chk) & 0xFF
d[HDR + 0x1D] = ((~chk) >> 8) & 0xFF
open(path, "wb").write(d)
print(f"mksa1hdr: {path} mapmode=$23 sram=$08 (256 KB BW-RAM) chk=${chk:04X}")
