#!/bin/sh
# Rebuild javac.exe — the DOS-native JAVAC — with the Small-C toolchain
# running inside our own emulator (runpc, MS-DOS 2.0). This is the
# script that produced the committed homebrew/java/javac.exe.
#
# The Small-C 2.2 kit (public-domain, Hendrix) lives in the repo:
# freeware/cc/ carries CC.EXE, ASM.EXE and the exploded CLIB objects
# (lib/*.OBJ) — see freeware/cc/ORIGIN.md for provenance. KIT= can
# still point at an external kit ($KIT/CC.EXE, $KIT/ASM.EXE, and the
# objects in $KIT/libobjs/ or $KIT/lib/). LINK.EXE is Microsoft LINK
# V2.00 from msdos/ (also in the repo).
#
#   sh tools/mkjavac_dos.sh
#
# Pipeline (each stage sized so nothing hits the 360 KB floppy wall —
# that wall silently truncated the .ASM in early attempts):
#   1. cat javac.c scmain.c -> JAVAC.C (CRLF).  cc runs on the guest
#      with the toolchain on a READ-ONLY hard disk (runpc -d) and the
#      work files on the writable A: floppy (runpc -w).
#   2. tools/mergeseg.py: cc emits one CODE/DATA segment pair per
#      function (~87 segments) which overflows LINK V2.00's segment
#      table; coalesce to one CODE + one DATA.
#   3. asm (default symbol table: -S3000 corrupts the OBJ — the 16-bit
#      assembler's own data segment overflows — and is unnecessary).
#   4. link @JCR -> JAVAC.EXE, extracted from the A: floppy image.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
JAVA=$(dirname "$HERE")                       # homebrew/java
ROOT=$(cd "$JAVA/../.." && pwd)               # repo root
RUNPC="$ROOT/core-c/build/runpc"
[ -x "$RUNPC" ] || { echo "build core-c first (runpc missing)"; exit 1; }
KIT="${KIT:-$ROOT/freeware/cc}"                # the committed kit
[ -f "$KIT/CC.EXE" ] || { echo "no Small-C kit at $KIT"; exit 1; }
LIBOBJS="$KIT/libobjs"                         # external-kit layout...
[ -d "$LIBOBJS" ] || LIBOBJS="$KIT/lib"        # ...or freeware/cc's
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# ---- stage 0: sources and images -----------------------------------
cat "$JAVA/javac.c" "$JAVA/scmain.c" | perl -pe 's/\n/\r\n/' > "$W/JAVAC.C"
mkdir -p "$W/ov"
cp "$KIT/CC.EXE" "$KIT/ASM.EXE" "$W/ov/"
cp "$ROOT/msdos/LINK.EXE" "$W/ov/"
cp "$LIBOBJS"/*.OBJ "$W/ov/"
python3 - "$W" "$LIBOBJS" <<'PY'
import sys, os
W, LIBOBJS = sys.argv[1], sys.argv[2]
objs = sorted(o[:-4] for o in os.listdir(LIBOBJS) if o.endswith(".OBJ"))
names = ["JAVAC"] + ["C:"+o for o in objs]
lines, cur = [], ""
for n in names:
    if len(cur)+len(n)+1 > 100: lines.append(cur+"+"); cur = n
    else: cur = cur+"+"+n if cur else n
lines.append(cur)
open(W+"/JCR","w",newline="").write("\r\n".join(lines)+"\r\nJAVAC\r\nNUL\r\n;\r\n")
PY
(cd "$ROOT/snes" && OVERLAYS="$W/ov" python3 tools/mkhd_free.py build hd_jcbuild.img >/dev/null)
HD="$ROOT/snes/build/hd_jcbuild.img"

floppy() {  # floppy <img-out> <NAME=path>...
python3 - "$ROOT" "$W" "$@" <<'PY'
import sys
ROOT, W, out = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, ROOT+"/homebrew"); import fatimg
f = fatimg.Floppy(ROOT+"/msdos/msdos.img")
f.replace("AUTOEXEC.BAT", b"PROMPT $p$g\r\n")
for spec in sys.argv[4:]:
    name, path = spec.split("=", 1)
    f.add(name, open(path, "rb").read())
f.save(out)
PY
}

# ---- stage 1: cc on the guest ---------------------------------------
printf 'path c:\\\r\ncc javac -m\r\n' > "$W/C.BAT"
floppy "$W/f1.img" "JAVAC.C=$W/JAVAC.C" "C.BAT=$W/C.BAT"
printf '\r\rc\r' | "$RUNPC" -m 600 -l 20000000000 -w -d "$HD" "$W/f1.img" > "$W/cc.log" 2>&1
grep -q "invalid\|already defined\|missing token" "$W/cc.log" && { echo "cc errors - see $W/cc.log"; exit 1; }
python3 - "$ROOT" "$W" <<'PY'
import sys
ROOT, W = sys.argv[1], sys.argv[2]
sys.path.insert(0, ROOT+"/homebrew"); import fatimg
a = fatimg.read_img(W+"/f1.img").get("JAVAC.ASM", b"")
assert len(a) > 100000, "cc produced no/short JAVAC.ASM - see cc.log"
open(W+"/JAVAC1.ASM","wb").write(a)
PY

# ---- stage 2: merge segments (host side) ----------------------------
python3 "$HERE/mergeseg.py" "$W/JAVAC1.ASM" "$W/JAVAC.ASM"

# ---- stage 3+4: asm + link on the guest -----------------------------
printf 'path c:\\\r\nasm javac -NM\r\nlink @JCR\r\n' > "$W/B.BAT"
floppy "$W/f2.img" "JAVAC.ASM=$W/JAVAC.ASM" "JCR=$W/JCR" "B.BAT=$W/B.BAT"
printf '\r\rb\r' | "$RUNPC" -m 600 -l 50000000000 -w -d "$HD" "$W/f2.img" > "$W/asm.log" 2>&1
grep -q " 0 lines have errors" "$W/asm.log" || { echo "asm errors - see $W/asm.log"; exit 1; }
python3 - "$ROOT" "$W" "$JAVA" <<'PY'
import sys
ROOT, W, JAVA = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, ROOT+"/homebrew"); import fatimg
e = fatimg.read_img(W+"/f2.img").get("JAVAC.EXE", b"")
assert len(e) > 30000, "link produced no JAVAC.EXE - see asm.log"
open(JAVA+"/javac.exe","wb").write(e)
print("javac.exe rebuilt:", len(e), "bytes")
PY
