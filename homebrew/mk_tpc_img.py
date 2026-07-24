#!/usr/bin/env python3
"""Build cache/tpc.img — a bootable scratch floppy that compiles one
Turbo Pascal source inside our own emulated MS-DOS 2.0 — or extract the
compiled .COM back out. Used by tpcompile.sh.

  mk_tpc_img.py build <tool>/<name>.pas    # clone msdos/msdos.img, add
                                           # TP3 + the source (+ *.inc)
  mk_tpc_img.py --extract NAME.COM <dest>  # pull the result back out

The boot base is our committed free MS-DOS floppy (msdos/msdos.img), so
with TP3 fetched (fetch_tp3.py) the whole compile pipeline runs from a
clean checkout — no copyrighted local disks involved. AUTOEXEC.BAT is
replaced with a bare PROMPT so the scratch boot is deterministic (the
shipping AUTOEXEC ends with `C:`, which has no meaning on a lone A:).
"""
import glob
import os
import sys

import fatimg

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
IMG = os.path.join(CACHE, "tpc.img")
BASE = os.path.join(HERE, "..", "msdos", "msdos.img")


def build(srcpath):
    src = os.path.join(HERE, srcpath)
    if not os.path.exists(src):
        raise SystemExit(f"{srcpath} not found under homebrew/")
    name = os.path.splitext(os.path.basename(src))[0].upper()
    fl = fatimg.Floppy(BASE)
    fl.replace("AUTOEXEC.BAT", b"PROMPT $P$G\r\n")
    for nm in ("TURBO.COM", "TURBO.MSG"):
        fl.add(nm, open(os.path.join(CACHE, nm), "rb").read())
    fl.add(name + ".PAS", open(src, "rb").read())
    stem = os.path.splitext(src)[0]
    for inc in sorted(glob.glob(stem + "*.inc")):
        fl.add(os.path.basename(inc).upper(), open(inc, "rb").read())
    os.makedirs(CACHE, exist_ok=True)
    fl.save(IMG)


def extract(name, dest):
    files = fatimg.read_img(IMG)
    if name.upper() not in files:
        raise SystemExit(f"{name} not found (compile failed?)")
    data = files[name.upper()]
    open(dest, "wb").write(data)
    print(f"{name} -> {dest} ({len(data)} bytes)")


if __name__ == "__main__":
    if sys.argv[1] == "--extract":
        extract(sys.argv[2], sys.argv[3])
    else:
        build(sys.argv[2])
