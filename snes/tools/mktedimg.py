#!/usr/bin/env python3
"""Build build/tedtest.img — a bootable 360K floppy carrying TED.COM
plus optional seed files, for driving the editor under runpc (there is
no B: on runpc; a writable A: is the honest test bed).

  mktedimg.py                    # disk with homebrew/ted/ted.com
  mktedimg.py --seed NAME DATA   # also add file NAME with contents DATA
  mktedimg.py --extract NAME OUT # pull NAME out of the image afterwards

The boot base is our committed free MS-DOS floppy (msdos/msdos.img) via
homebrew/fatimg.py, so this runs from a clean checkout. AUTOEXEC.BAT is
replaced with a bare PROMPT (the shipping one ends with `C:`, which has
no meaning on a lone A:).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
IMG = os.path.join(HERE, "..", "build", "tedtest.img")

sys.path.insert(0, os.path.join(ROOT, "homebrew"))
import fatimg                                    # noqa: E402


def build(seeds):
    fl = fatimg.Floppy(os.path.join(ROOT, "msdos", "msdos.img"))
    fl.replace("AUTOEXEC.BAT", b"PROMPT $P$G\r\n")
    fl.add("TED.COM",
           open(os.path.join(ROOT, "homebrew", "ted", "ted.com"),
                "rb").read())
    for nm, data in seeds:
        fl.add(nm.upper(), data)
    os.makedirs(os.path.dirname(IMG), exist_ok=True)
    fl.save(IMG)
    print(f"tedtest.img: TED.COM + {len(seeds)} seed file(s)")


def extract(name, dest):
    files = fatimg.read_img(IMG)
    if name.upper() not in files:
        raise SystemExit(f"{name} not in {IMG}")
    open(dest, "wb").write(files[name.upper()])
    print(f"{name} -> {dest} ({len(files[name.upper()])} bytes)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--extract":
        extract(sys.argv[2], sys.argv[3])
    else:
        seeds = []
        args = sys.argv[1:]
        while args and args[0] == "--seed":
            seeds.append((args[1], args[2].encode("latin1")))
            args = args[3:]
        build(seeds)
