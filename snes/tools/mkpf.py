#!/usr/bin/env python3
"""Emit the 8086 PF lookup table: byte value -> $04 if even parity else $00."""
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else "build"
os.makedirs(out, exist_ok=True)
tab = bytes(0x04 if bin(i).count("1") % 2 == 0 else 0x00 for i in range(256))
open(os.path.join(out, "pf.bin"), "wb").write(tab)
print("pf.bin 256 bytes")
