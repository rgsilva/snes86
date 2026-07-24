#!/usr/bin/env python3
"""Build build/tedtest.img - a bootable PC-DOS 360K floppy carrying
TED.COM plus optional seed files, for driving the editor under runpc
(there is no B: on runpc; a writable A: is the honest test bed).

  mktedimg.py                    # disk with disks/ted.com
  mktedimg.py --seed NAME DATA   # also add file NAME with contents DATA
  mktedimg.py --extract NAME OUT # pull NAME out of the image afterwards

Layout logic mirrors mk_tpc_img.py (same geometry, same PC-DOS boot
trio from pcdos200-disk1.img).
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DISKS = os.path.join(HERE, "..", "..", "disks")
IMG = os.path.join(HERE, "..", "build", "tedtest.img")
SPC, SFAT, ROOTN, TOTAL = 2, 2, 112, 720
RS = ROOTN * 32 // 512
DL = 1 + 2 * SFAT + RS


def read_img(path):
    d = open(path, "rb").read()
    if len(d) == 184320:
        spc, sfat, rn = 1, 2, 64
    elif len(d) == 368640:
        spc, sfat, rn = 2, 2, 112
    else:
        raise SystemExit(f"unsupported image {path}")
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


def extract(name, dest):
    files = read_img(IMG)
    if name.upper() not in files:
        raise SystemExit(f"{name} not in {IMG}")
    open(dest, "wb").write(files[name.upper()])
    print(f"{name} -> {dest} ({len(files[name.upper()])} bytes)")


def build(seeds):
    f1 = read_img(os.path.join(DISKS, "pcdos200-disk1.img"))
    dos1 = open(os.path.join(DISKS, "pcdos200-disk1.img"), "rb").read()
    ted = open(os.path.join(DISKS, "ted.com"), "rb").read()

    img = bytearray(TOTAL * 512)
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
    for nm, at in [("IBMBIO.COM", 0x27), ("IBMDOS.COM", 0x27),
                   ("COMMAND.COM", 0)]:
        root[idx * 32:idx * 32 + 32] = put(nm, f1[nm], at)
        idx += 1
    root[idx * 32:idx * 32 + 32] = put("TED.COM", ted)
    idx += 1
    for nm, data in seeds:
        root[idx * 32:idx * 32 + 32] = put(nm.upper(), data)
        idx += 1

    img[512:512 + SFAT * 512] = fat
    img[512 + SFAT * 512:512 + 2 * SFAT * 512] = fat
    img[(1 + 2 * SFAT) * 512:(1 + 2 * SFAT) * 512 + len(root)] = root
    os.makedirs(os.path.dirname(IMG), exist_ok=True)
    open(IMG, "wb").write(img)
    print(f"tedtest.img: TED.COM + {len(seeds)} seed file(s)")


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
