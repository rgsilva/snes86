#!/bin/sh
# Build a DOS-native JAVAC with the Small-C toolchain under runpc.
#
# STATUS: cc and asm succeed; the final link is the open step (see
# ../JAVAC-PORTING.md). This script documents the exact pipeline so the
# work can be finished; it is not wired into the default build.
#
# Prerequisites (not committed here):
#   - a Small-C kit with CC.EXE, ASM.EXE and the runtime object files
#     (Hendrix public-domain Small-C; the same kit the C-compiler
#     investigation used). Point $KIT at it.
#   - Microsoft LINK V2.00 (already in ../../msdos/LINK.EXE) or a newer
#     OMF linker for the open final step.
#   - ../../msdos/msdos.img (our free DOS 2.0) as the DOS host, and
#     ../../core-c/build/runpc.
#
# Pipeline (each stage on its own slim floppy so cc has room to write
# the ~110 KB .ASM — the floppy filling mid-write silently truncates it):
#
#   1. cat javac.c scmain.c  (CRLF) -> JAVAC.C on a floppy with CC.EXE
#      run:  cc javac -m                       -> JAVAC.ASM (~110 KB)
#   2. python3 tools/mergeseg.py JAVAC.ASM JAVAC.ASM
#      (coalesce cc's ~87 per-function segments into one CODE + one DATA
#       so LINK's segment table does not overflow)
#   3. JAVAC.ASM on a floppy with ASM.EXE
#      run:  asm javac -S3000 -NM              -> JAVAC.OBJ
#   4. JAVAC.OBJ + the runtime objects + a response file, with LINK.EXE
#      run:  link @JCR                         -> JAVAC.EXE   *** OPEN ***
#
# Step 4 currently fails "Too many segments or classes": with the symbol
# table set large enough for the whole program (-S3000), asm writes a
# bloated LNAMES record that overflows LINK V2.00's name table; a
# smaller -S drops real symbols. See JAVAC-PORTING.md for the ways out
# (newer linker / few-segment split / trimmed object set).
echo "This script is documentation; see JAVAC-PORTING.md."
echo "cc + asm succeed; 'link @JCR' is the open step."
