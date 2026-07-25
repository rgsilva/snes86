#!/usr/bin/env python3
"""Coalesce Small-C's per-function CODE/DATA segments into one CODE and
one DATA segment.

cc (Hendrix Small-C) opens a fresh `CODE SEGMENT PUBLIC` / `DATA SEGMENT
PUBLIC` pair around every function, so a large program emits dozens of
segments and overflows Microsoft LINK V2.00's segment table. Since the
segments all share a name and the PUBLIC combine class, concatenating
their bodies is safe: the linker would have combined them anyway.

    mergeseg.py IN.ASM OUT.ASM

See JAVAC-PORTING.md for why this is necessary and the remaining
linker limitation it exposes.
"""
import sys

src = open(sys.argv[1]).read().replace("\r", "").split("\n")
extrns, code, data = [], [], []
mode = None
for line in src:
    s = line.strip()
    if s == "CODE SEGMENT PUBLIC":
        mode = "C"
    elif s == "DATA SEGMENT PUBLIC":
        mode = "D"
    elif s in ("CODE ENDS", "DATA ENDS"):
        mode = None
    elif s.startswith("ASSUME"):
        pass                                  # re-emitted once, below
    elif s.startswith("extrn"):
        if line not in extrns:
            extrns.append(line)
    elif s == "END" or s.startswith("END "):
        pass                                  # program end, re-added last
    elif mode == "C":
        code.append(line)
    elif mode == "D":
        data.append(line)

out = (["CODE SEGMENT PUBLIC", "ASSUME CS:CODE, SS:DATA, DS:DATA"]
       + extrns + code
       + ["CODE ENDS", "DATA SEGMENT PUBLIC"] + data
       + ["DATA ENDS", "END"])
open(sys.argv[2], "w", newline="").write("\r\n".join(out) + "\r\n")
print(f"mergeseg: {sys.argv[1]} -> {sys.argv[2]}: "
      f"{len(code)} code + {len(data)} data lines, 2 segments")
