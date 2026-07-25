#!/usr/bin/env python3
"""Generate disks/appmatrix/ — the copyrighted app-matrix TEST FIXTURE.

This reproduces the app set of the old developer C: as a plain directory
overlay for the packer (the suite builds the public image + this on top
via OVERLAYS; there is no public target). It runs ONLY on a machine that
has the local copyrighted software in disks/ (nothing here is ever
committed; disks/ is wholly gitignored). `make test-extra` re-runs it
before the app legs.

    mkappmatrix.py            generate disks/appmatrix/
    mkappmatrix.py --check    print the source manifest (present/missing
                              + which suite legs need each file); exit 1
                              if anything is missing

Everything the legs launch sits in the fixture ROOT (the root is on the
DOS PATH); nobody browses a test fixture, so the root soup is fine. The
Infocom interpreters are binary-patched to C:\\-root absolute data paths
(a patch can never be longer than the string it replaces).
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "appmatrix")

sys.path.insert(0, os.path.join(HERE, "..", "apps"))
from fatimg import read_img                     # noqa: E402

# Every disks/ input the fixture needs: (path, which legs / what for).
# The five suite legs are t_zork t_gwb t_ws t_mp t_m40; "matrix" marks
# apps that are only exercised by hand (docs/COMPATIBILITY.md).
SOURCES = [
    ("pcdos200-disk1.img",            "t_m40 (MODE.COM)"),
    ("gwbasic.exe",                   "t_gwb"),
    ("ws_installed.com",              "t_ws"),
    ("wordstar.img",                  "t_ws (overlays)"),
    ("mp_com_compaq.bin",             "t_mp"),
    ("multiplan2.img",                "t_mp (MP.LOD/SYS/DAT)"),
    ("zork1_snes.com",                "t_zork"),
    ("zork1/data/zork1.dat",          "t_zork"),
    ("zork1/setup.inf",               "t_zork"),
    ("zork1/_zork1.com",              "matrix (HHGTTG/WISH interpreter)"),
    ("tp301.img",                     "matrix (Turbo Pascal)"),
    ("bench_NortonSI/si45/SI.EXE",    "matrix"),
    ("rogue/rogue/10ROGUE.EXE",       "matrix"),
    ("elite/elite/elite.exe",         "matrix"),
    ("elite/elite/elitetrn.com",      "matrix"),
    ("starglider/Strglid/SGLIDER.EXE", "matrix"),
    ("zork2/zork2/_zork2.com",        "matrix"),
    ("zork2/zork2/data/zork2.dat",    "matrix"),
    ("zork3/zork3/_ZORK3.COM",        "matrix"),
    ("zork3/zork3/DATA/ZORK3.DAT",    "matrix"),
    ("planetfa/planetf/_PLANETF.COM", "matrix"),
    ("planetfa/planetf/data/PLANETFA.DAT", "matrix"),
    ("lgop/phobos1/leather.com",      "matrix"),
    ("lgop/phobos1/leather.dat",      "matrix"),
    ("hhgttg/HGG/hitchhik.dat",       "matrix"),
    ("wishbrin/wishbrin/wishbrin.dat", "matrix"),
    ("canyon.mid",                    "matrix (MIDI)"),
    ("canyon.snm",                    "matrix (MIDI)"),
    ("level1.mid",                    "matrix (MIDI)"),
    ("level1.snm",                    "matrix (MIDI)"),
    ("msdos.bmp",                     "matrix (VIEW)"),
]


def check():
    missing = 0
    for rel, legs in SOURCES:
        ok = os.path.exists(os.path.join(HERE, *rel.split("/")))
        if not ok:
            missing += 1
        print(f"  {'ok     ' if ok else 'MISSING'} disks/{rel}  [{legs}]")
    if missing:
        print(f"mkappmatrix: {missing} of {len(SOURCES)} inputs missing")
        return 1
    print(f"mkappmatrix: all {len(SOURCES)} inputs present")
    return 0


def rd(*p):
    return open(os.path.join(HERE, *p), "rb").read()


def infocom(com, *patches):
    """Patch an Infocom '96 interpreter's hardcoded file paths."""
    d = bytearray(com)
    for old, new in patches:
        i = d.find(old)
        assert i >= 0, old
        assert len(new) <= len(old), new
        d[i:i + len(old)] = new.ljust(len(old), b"\x00")
    return bytes(d)


def generate():
    f1 = read_img(os.path.join(HERE, "pcdos200-disk1.img"))
    ftp = read_img(os.path.join(HERE, "tp301.img"))
    fws = read_img(os.path.join(HERE, "wordstar.img"))
    fmp = read_img(os.path.join(HERE, "multiplan2.img"))

    zork1_raw = rd("zork1", "_zork1.com")

    root = {
        "CA.BAT": b"MIDPLAY C:\\MIDI\\CANYON.SNM\r\n",
        "L1.BAT": b"MIDPLAY C:\\MIDI\\LEVEL1.SNM\r\n",
        "MODE.COM": f1["MODE.COM"],          # 40/80-col switch (t_m40); PC-DOS —
                                             # absent from the MIT MS-DOS release
        "WS.COM": rd("ws_installed.com"),
        "WSOVLY1.OVR": fws["WSOVLY1.OVR"],
        "WSMSGS.OVR": fws["WSMSGS.OVR"],
        "MP.COM": rd("mp_com_compaq.bin"),
        "MP.LOD": fmp["MP.LOD"],
        "MP.SYS": fmp["MP.SYS"],
        "MP80.DAT": fmp["MP80.DAT"],
        "GWBASIC.EXE": rd("gwbasic.exe"),
        "SI.EXE": rd("bench_NortonSI", "si45", "SI.EXE"),
        "ROGUE.EXE": rd("rogue", "rogue", "10ROGUE.EXE"),
        "ELITE.EXE": rd("elite", "elite", "elite.exe"),
        "ELITETRN.COM": rd("elite", "elite", "elitetrn.com"),
        "SGLIDER.EXE": rd("starglider", "Strglid", "SGLIDER.EXE"),
        "ZORK1.COM": rd("zork1_snes.com"),
        "ZORK1.DAT": rd("zork1", "data", "zork1.dat"),
        "SETUP.INF": rd("zork1", "setup.inf"),
        "ZORK2.COM": infocom(rd("zork2", "zork2", "_zork2.com"),
                             (b"DATA\\ZORK2.DAT", b"C:\\ZORK2.DAT"),
                             (b"SAVE\\ZORK2.DAT", b"B:\\ZORK2.SAV")),
        "ZORK2.DAT": rd("zork2", "zork2", "data", "zork2.dat"),
        "ZORK3.COM": infocom(rd("zork3", "zork3", "_ZORK3.COM"),
                             (b"DATA\\ZORK3.DAT", b"C:\\ZORK3.DAT"),
                             (b"SAVE\\ZORK3.DAT", b"B:\\ZORK3.SAV")),
        "ZORK3.DAT": rd("zork3", "zork3", "DATA", "ZORK3.DAT"),
        "PLANET.COM": infocom(rd("planetfa", "planetf", "_PLANETF.COM"),
                              (b"DATA\\PLANETFA.DAT", b"C:\\PLANET.DAT"),
                              (b"SAVE\\PLANETFA.DAT", b"B:\\PLANET.SAV")),
        "PLANET.DAT": rd("planetfa", "planetf", "data", "PLANETFA.DAT"),
        "LGOP.COM": infocom(rd("lgop", "phobos1", "leather.com"),
                            (b"LEATHER.DAT", b"C:\\LGOP.DAT")),
        "LGOP.DAT": rd("lgop", "phobos1", "leather.dat"),
        "HHGTTG.COM": infocom(zork1_raw,
                              (b"DATA\\ZORK1.DAT", b"C:\\HHGTTG.DAT"),
                              (b"SAVE\\ZORK1.DAT", b"B:\\HHGTTG.SAV")),
        "HHGTTG.DAT": rd("hhgttg", "HGG", "hitchhik.dat"),
        "WISH.COM": infocom(zork1_raw,
                            (b"DATA\\ZORK1.DAT", b"C:\\WISH.DAT"),
                            (b"SAVE\\ZORK1.DAT", b"B:\\WISH.SAV")),
        "WISH.DAT": rd("wishbrin", "wishbrin", "wishbrin.dat"),
    }

    subdirs = {
        "PASCAL": {"TURBO.COM": ftp["TURBO.COM"],
                   "TURBO.MSG": ftp["TURBO.MSG"]},
        "MIDI": {"CANYON.MID": rd("canyon.mid"),
                 "CANYON.SNM": rd("canyon.snm"),
                 "LEVEL1.MID": rd("level1.mid"),
                 "LEVEL1.SNM": rd("level1.snm")},
        "VIEW": {"MSDOS.BMP": rd("msdos.bmp")},
    }

    os.makedirs(OUT, exist_ok=True)
    n = 0
    for nm, data in root.items():
        open(os.path.join(OUT, nm), "wb").write(data)
        n += 1
    for d, files in subdirs.items():
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
        for nm, data in files.items():
            open(os.path.join(OUT, d, nm), "wb").write(data)
            n += 1
    print(f"disks/appmatrix/: {n} files "
          f"({len(root)} root + {sum(len(f) for f in subdirs.values())} in "
          f"{len(subdirs)} dirs)")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--check":
        sys.exit(check())
    sys.exit(generate())
