#!/usr/bin/env python3
"""Build the 360 KB A: boot image: PC DOS 2.00 system + selected utils
+ DEBUG (from disk 2) + Turbo Pascal + HELLO.PAS demo.

Reads FAT12 floppies (180/360 KB), writes a 360 KB FAT12 image whose
first two directory entries are IBMBIO/IBMDOS with IBMBIO contiguous at
cluster 2 (the boot sector requires that). The PC DOS boot sector is
reused with its BPB patched for 360 KB geometry.
"""
import os
import struct
import sys

DISKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "disks")
OUT = sys.argv[1] if len(sys.argv) > 1 else "build"

def read_img(path):
    d = open(path, "rb").read()
    if len(d) == 163840:
        spc, nfat, sfat, root_n, spt, heads = 1, 2, 1, 64, 8, 1
    elif len(d) == 327680:
        spc, nfat, sfat, root_n, spt, heads = 2, 2, 1, 112, 8, 2
    elif len(d) == 184320:
        spc, nfat, sfat, root_n, spt, heads = 1, 2, 2, 64, 9, 1
    elif len(d) == 368640:
        spc, nfat, sfat, root_n, spt, heads = 2, 2, 2, 112, 9, 2
    else:
        raise SystemExit(f"unsupported image {path}")
    root_secs = root_n * 32 // 512
    root_lba = 1 + nfat * sfat
    data_lba = root_lba + root_secs
    fat = d[512:512 + sfat * 512]
    def fat_ent(n):
        off = n + n // 2
        v = fat[off] | (fat[off + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)
    files = {}
    root = d[root_lba * 512:(root_lba + root_secs) * 512]
    for i in range(root_n):
        e = root[i * 32:(i + 1) * 32]
        if e[0] in (0, 0xE5) or e[11] & 0x08:
            continue
        name = e[0:8].decode("ascii", "replace").rstrip()
        ext = e[8:11].decode("ascii", "replace").rstrip()
        full = name + ("." + ext if ext else "")
        clus = struct.unpack_from("<H", e, 26)[0]
        size = struct.unpack_from("<I", e, 28)[0]
        data = bytearray()
        c = clus
        while 2 <= c < 0xFF0 and len(data) < size + 4096:
            lba = data_lba + (c - 2) * spc
            data += d[lba * 512:(lba + spc) * 512]
            c = fat_ent(c)
        files[full.upper()] = (bytes(data[:size]), e[11], e[22:26])
    return d, files

dos1, f1 = read_img(os.path.join(DISKS, "pcdos200-disk1.img"))
_, f2 = read_img(os.path.join(DISKS, "pcdos200-disk2.img"))



autoexec = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "autoexec.bat"), "rb").read()



want = []
for n in ("IBMBIO.COM", "IBMDOS.COM"):
    want.append((n, f1[n][0], 0x27))          # hidden+system+readonly
want.append(("COMMAND.COM", f1["COMMAND.COM"][0], 0x00))
want.append(("AUTOEXEC.BAT", autoexec, 0x00))

dosfiles = [(n, f1[n][0]) for n in
            ("CHKDSK.COM", "EDLIN.COM", "COMP.COM", "MORE.COM",
             "SORT.EXE", "FIND.EXE", "TREE.COM", "MODE.COM")]
dosfiles.append(("DEBUG.COM", f2["DEBUG.COM"][0]))
subdirs = [("DOS", dosfiles)]

# ---- build 360 KB image
TOTAL, SPC, SFAT, ROOTN = 720, 2, 2, 112
root_secs = ROOTN * 32 // 512
data_lba = 1 + 2 * SFAT + root_secs
nclust = (TOTAL - data_lba) // SPC

img = bytearray(TOTAL * 512)
boot = bytearray(dos1[0:512])                 # PC DOS boot code
struct.pack_into("<HBHBHHBHHH", boot, 11,
                 512, SPC, 1, 2, ROOTN, TOTAL, 0xFD, SFAT, 9, 2)
img[0:512] = boot

fat = bytearray(SFAT * 512)
def setfat(n, v):
    off = n + n // 2
    if n & 1:
        fat[off] = (fat[off] & 0x0F) | ((v & 0xF) << 4)
        fat[off + 1] = (v >> 4) & 0xFF
    else:
        fat[off] = v & 0xFF
        fat[off + 1] = (fat[off + 1] & 0xF0) | ((v >> 8) & 0xF)
setfat(0, 0xFFD)
setfat(1, 0xFFF)

root = bytearray(root_secs * 512)
next_c = 2

def mkent(name, attr, clus, size):
    n, _, e = name.partition(".")
    ent = bytearray(32)
    ent[0:8] = n.ljust(8).encode()
    ent[8:11] = e.ljust(3).encode()
    ent[11] = attr
    struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, clus)
    struct.pack_into("<I", ent, 28, size)
    return ent

def alloc(data):
    global next_c
    start = next_c
    ncl = max(1, (len(data) + SPC * 512 - 1) // (SPC * 512))
    for k in range(ncl):
        c = start + k
        setfat(c, 0xFFF if k == ncl - 1 else c + 1)
        lba = data_lba + (c - 2) * SPC
        chunk = data[k * SPC * 512:(k + 1) * SPC * 512]
        img[lba * 512:lba * 512 + len(chunk)] = chunk
    next_c = start + ncl
    return start

for i, (name, data, attr) in enumerate(want):
    n, _, e = name.partition(".")
    ent = bytearray(32)
    ent[0:8] = n.ljust(8).encode()
    ent[8:11] = e.ljust(3).encode()
    ent[11] = attr
    struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, next_c)  # 12:00 3-8-83
    struct.pack_into("<I", ent, 28, len(data))
    ncl = max(1, (len(data) + SPC * 512 - 1) // (SPC * 512))
    for k in range(ncl):
        c = next_c + k
        setfat(c, 0xFFF if k == ncl - 1 else c + 1)
        lba = data_lba + (c - 2) * SPC
        chunk = data[k * SPC * 512:(k + 1) * SPC * 512]
        img[lba * 512:lba * 512 + len(chunk)] = chunk
    root[i * 32:(i + 1) * 32] = ent
    next_c += ncl
    if next_c > nclust + 1:
        raise SystemExit("image full")

subdirs = [(n, f) for n, f in subdirs if f]
for k, (dname, dfiles) in enumerate(subdirs):
    dirdata = bytearray(SPC * 512)
    dc_pos = len(want) + k
    # entries for the files first (clusters allocated now)
    ents = []
    _dummy=0
    for fn, fd in dfiles:
        c0 = alloc(fd)
        ents.append(mkent(fn, 0x00, c0, len(fd)))
    dclus = alloc(bytes(dirdata))          # reserve dir cluster
    dot = mkent(".", 0x10, dclus, 0)
    dotdot = mkent("..", 0x10, 0, 0)
    dot[0:11] = b".          "
    dotdot[0:11] = b"..         "
    alle = [dot, dotdot] + ents
    for j, e in enumerate(alle):
        dirdata[j * 32:(j + 1) * 32] = e
    lba = data_lba + (dclus - 2) * SPC
    img[lba * 512:lba * 512 + len(dirdata)] = bytes(dirdata)
    root[dc_pos * 32:(dc_pos + 1) * 32] = mkent(dname, 0x10, dclus, 0)

img[512:512 + SFAT * 512] = fat
img[512 + SFAT * 512:512 + 2 * SFAT * 512] = fat
img[(1 + 2 * SFAT) * 512:(1 + 2 * SFAT) * 512 + len(root)] = root

os.makedirs(OUT, exist_ok=True)
out = os.path.join(OUT, "adisk.img")
open(out, "wb").write(img)
used = (next_c - 2) * SPC * 512
print(f"adisk.img: {len(want)} files, {used} bytes used, "
      f"{(nclust - (next_c - 2)) * SPC * 512} free")
