#!/usr/bin/env python3
"""Build a 360KB FAT12 disk. Default: bootable with DOS system
files (host testing); --plain: data disk only (the C: ROM disk).

  mkscratch.py OUT.img FILE [FILE...]   # DOS boot files + the given files
Each FILE may be `path` (root, basename uppercased), `NAME.EXT=path`,
or `DIR/NAME.EXT=path` (one level of subdirectory, created on demand).
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DISKS = os.path.join(HERE, "..", "..", "disks")
SPC, SFAT, ROOTN, TOTAL = 2, 2, 112, 720
RS = ROOTN * 32 // 512
DL = 1 + 2 * SFAT + RS


def read_img(path):
    d = open(path, "rb").read()
    spc, sfat, rn = {184320: (1, 2, 64), 368640: (2, 2, 112)}[len(d)]
    dl = 1 + 2 * sfat + rn * 32 // 512
    fat = d[512:512 + sfat * 512]

    def fe(n):
        o = n + n // 2
        v = fat[o] | (fat[o + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)

    out = {}
    root = d[(1 + 2 * sfat) * 512:(1 + 2 * sfat) * 512 + rn * 32]
    for i in range(rn):
        e = root[i * 32:i * 32 + 32]
        if e[0] in (0, 0xE5) or e[11] & 8:
            continue
        nm = (e[0:8].decode("latin1").rstrip() + "." +
              e[8:11].decode("latin1").rstrip()).rstrip(".")
        c = struct.unpack_from("<H", e, 26)[0]
        sz = struct.unpack_from("<I", e, 28)[0]
        b = bytearray()
        while 2 <= c < 0xFF0:
            lba = dl + (c - 2) * spc
            b += d[lba * 512:(lba + spc) * 512]
            c = fe(c)
        out[nm.upper()] = bytes(b[:sz])
    return out


def main():
    argv = sys.argv[1:]
    plain = "--plain" in argv
    if plain:
        argv.remove("--plain")
    out_path = argv[0]
    f1 = read_img(os.path.join(DISKS, "pcdos200-disk1.img"))
    img = bytearray(TOTAL * 512)
    dos1 = open(os.path.join(DISKS, "pcdos200-disk1.img"), "rb").read()
    boot = bytearray(dos1[0:512])
    struct.pack_into("<HBHBHHBHHH", boot, 11,
                     512, SPC, 1, 2, ROOTN, TOTAL, 0xFD, SFAT, 9, 2)
    img[0:512] = boot
    fat = bytearray(SFAT * 512)

    def sf(n, v):
        o = n + n // 2
        if n & 1:
            fat[o] = (fat[o] & 0xF) | ((v & 0xF) << 4)
            fat[o + 1] = (v >> 4) & 0xFF
        else:
            fat[o] = v & 0xFF
            fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0xF)

    sf(0, 0xFFD)
    sf(1, 0xFFF)
    root = bytearray(RS * 512)
    nc = [2]

    def put(nm, data, attr=0):
        n, _, e = nm.partition(".")
        ent = bytearray(32)
        ent[0:8] = n.ljust(8).encode()
        ent[8:11] = e.ljust(3).encode()
        ent[11] = attr
        struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, nc[0])
        struct.pack_into("<I", ent, 28, len(data))
        ncl = max(1, (len(data) + SPC * 512 - 1) // (SPC * 512))
        for k in range(ncl):
            c = nc[0] + k
            sf(c, 0xFFF if k == ncl - 1 else c + 1)
            lba = DL + (c - 2) * SPC
            ch = data[k * SPC * 512:(k + 1) * SPC * 512]
            img[lba * 512:lba * 512 + len(ch)] = ch
        nc[0] += ncl
        return ent

    idx = 0
    if not plain:
        for nm, at in [("IBMBIO.COM", 0x27), ("IBMDOS.COM", 0x27),
                       ("COMMAND.COM", 0)]:
            root[idx * 32:idx * 32 + 32] = put(nm, f1[nm], at)
            idx += 1
    subdirs = {}                # name -> list of (fname, data)
    for spec in argv[1:]:
        if "=" in spec:
            nm, _, path = spec.partition("=")
        else:
            path = spec
            nm = os.path.basename(path).upper()
        nm = nm.upper()
        if "/" in nm:
            dname, _, fname = nm.partition("/")
            subdirs.setdefault(dname, []).append(
                (fname, open(path, "rb").read()))
        else:
            root[idx * 32:idx * 32 + 32] = put(nm, open(path, "rb").read())
            idx += 1

    def mkent(nm, attr, clus, size):
        n, _, e = nm.partition(".")
        ent = bytearray(32)
        ent[0:8] = n.ljust(8).encode()
        ent[8:11] = e.ljust(3).encode()
        ent[11] = attr
        struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, clus)
        struct.pack_into("<I", ent, 28, size)
        return ent

    for dname, files in subdirs.items():
        ents = [put(fn, data) for fn, data in files]
        dclus = nc[0]
        dirdata = bytearray(SPC * 512)
        dot = mkent(".", 0x10, dclus, 0)
        dot[0:11] = b".          "
        dotdot = mkent("..", 0x10, 0, 0)
        dotdot[0:11] = b"..         "
        for j, e in enumerate([dot, dotdot] + ents):
            dirdata[j * 32:(j + 1) * 32] = e
        put(dname + ".", dirdata)   # allocates cluster, writes dirdata
        root[idx * 32:idx * 32 + 32] = mkent(dname, 0x10, dclus, 0)
        idx += 1

    img[512:512 + SFAT * 512] = fat
    img[512 + SFAT * 512:512 + 2 * SFAT * 512] = fat
    img[(1 + 2 * SFAT) * 512:(1 + 2 * SFAT) * 512 + len(root)] = root
    open(out_path, "wb").write(img)
    print(f"{out_path}: {idx} files")


if __name__ == "__main__":
    main()
