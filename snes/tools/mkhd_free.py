#!/usr/bin/env python3
"""Build the C: fixed-disk image (build/hd_free.img) — THE packer.

The layout is convention, not configuration:

  * every homebrew/<tool>/build/  ->  C:\\<TOOL>   (run `make stage` there
    first; snes/Makefile's homebrew-stage target does them all)
  * msdos/bin/                    ->  C:\\DOS      (MIT MS-DOS utilities)
  * user/ at the repo root        ->  C:\\USER     (bring-your-own .COMs)
  * C:\\AUTOEXEC.BAT is a byte-identical copy of A:'s (msdos/autoexec.bat):
    COMMAND.COM resumes batch processing BY BYTE OFFSET across the A:->C:
    drive change, so a C: copy longer than A:'s resumes into garbage.

OVERLAYS (env var: whitespace/comma-separated paths) merge extra trees
into the image, last wins with a warning — plain directories (one level
of subdirs) or FAT12 floppy images (flat, into the root). That is how
the copyrighted app-matrix test fixture rides on top of the free image:

    make msdos OVERLAYS=../disks/appmatrix

Geometry: 107 cyl x 4 heads x 17 spt, FAT12 partition at LBA 17 — see
the original derivation notes in git history (PC DOS 2.0's FDISK layout,
verified against IBMBIO's INT 13h reads).
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOTDIR = os.path.abspath(os.path.join(HERE, "..", ".."))
HOMEBREW = os.path.join(ROOTDIR, "homebrew")
DOSBIN = os.path.join(ROOTDIR, "msdos", "bin")
USERDIR = os.path.join(ROOTDIR, "user")
AUTOEXEC_SRC = os.path.join(ROOTDIR, "msdos", "autoexec.bat")
OUT = sys.argv[1] if len(sys.argv) > 1 else "build"

sys.path.insert(0, HOMEBREW)
import fatimg                                    # noqa: E402

# --- geometry ---
SPT, HEADS, CYLS = 17, 4, 107
TOTAL = SPT * HEADS * CYLS
PSTART = SPT
PSECS = TOTAL - PSTART
SPC, SFAT, ROOTN = 4, 6, 256
RS = ROOTN * 32 // 512
DATA0 = 1 + 2 * SFAT + RS
NCLUST = (PSECS - DATA0) // SPC


def valid83(nm):
    n, _, ext = nm.partition(".")
    return (nm == nm.upper() and 1 <= len(n) <= 8 and len(ext) <= 3
            and "." not in ext)


# ---- collect the tree: {None: [(name, bytes)...], "SUBDIR": [...]} ----
tree = {None: []}
warn = lambda m: print("mkhd_free.py: " + m, file=sys.stderr)


def place(sub, name, data, origin):
    name = name.upper()
    assert valid83(name), f"{origin}: {name} is not a valid 8.3 name"
    bucket = tree.setdefault(sub, [])
    for i, (nm, _) in enumerate(bucket):
        if nm == name:
            where = sub or "C:\\"
            warn(f"overlay overwrites {where}\\{name} ({origin})")
            bucket[i] = (name, data)
            return
    bucket.append((name, data))


place(None, "AUTOEXEC.BAT", open(AUTOEXEC_SRC, "rb").read(), "autoexec")

# homebrew tools, by convention
for tool in sorted(os.listdir(HOMEBREW)):
    b = os.path.join(HOMEBREW, tool, "build")
    if not os.path.isdir(b):
        continue
    files = sorted(f for f in os.listdir(b)
                   if os.path.isfile(os.path.join(b, f)))
    if not files:
        raise SystemExit(f"homebrew/{tool}/build/ is empty — "
                         f"run `make -C homebrew/{tool} stage`")
    for f in files:
        place(tool.upper(), f, open(os.path.join(b, f), "rb").read(),
              f"homebrew/{tool}")

# C:\DOS — the MIT MS-DOS 2.0 utilities (msdos/bin/, when present)
if os.path.isdir(DOSBIN):
    for f in sorted(os.listdir(DOSBIN)):
        if f.upper().endswith((".COM", ".EXE")):
            place("DOS", f, open(os.path.join(DOSBIN, f), "rb").read(),
                  "msdos/bin")

# C:\USER — bring-your-own software from user/ at the repo root
userfiles = []
if os.path.isdir(USERDIR):
    for f in sorted(os.listdir(USERDIR)):
        p = os.path.join(USERDIR, f)
        if (os.path.isfile(p) and not f.startswith(".")
                and f.upper() not in ("README.MD", "README.TXT")):
            userfiles.append(f)
for f in userfiles:
    place("USER", f, open(os.path.join(USERDIR, f), "rb").read(), "user/")
if not userfiles:
    place("USER", "READ.ME",
          b"Put your own DOS .COM/.EXE files in user/ at the repo root\r\n"
          b"and run 'make msdos'.  They will appear here.\r\n", "user/")

# overlays: directories (one subdir level) or FAT12 floppies (flat root)
for ov in os.environ.get("OVERLAYS", "").replace(",", " ").split():
    ov = os.path.abspath(ov)
    if os.path.isdir(ov):
        for entry in sorted(os.listdir(ov)):
            p = os.path.join(ov, entry)
            if entry.startswith("."):
                continue
            if os.path.isfile(p):
                place(None, entry, open(p, "rb").read(), ov)
            elif os.path.isdir(p):
                for f in sorted(os.listdir(p)):
                    fp = os.path.join(p, f)
                    if os.path.isfile(fp) and not f.startswith("."):
                        place(entry.upper(), f, open(fp, "rb").read(), ov)
    elif os.path.isfile(ov):
        for nm, data in sorted(fatimg.read_img(ov).items()):
            place(None, nm, data, ov)
    else:
        raise SystemExit(f"overlay not found: {ov}")

# ---- emit the image ----
img = bytearray(TOTAL * 512)

mbr = bytearray(512)
e = 0x1BE
mbr[e] = 0x80
mbr[e + 1:e + 4] = bytes([1, 1, 0])
mbr[e + 4] = 0x01
mbr[e + 5:e + 8] = bytes([HEADS - 1,
                          SPT | (((CYLS - 1) >> 8) & 3) << 6,
                          (CYLS - 1) & 0xFF])
struct.pack_into("<II", mbr, e + 8, PSTART, PSECS)
mbr[510:512] = b"\x55\xAA"
img[0:512] = mbr

# synthesized (non-booting) partition boot sector: jump + OEM + BPB + sig
boot = bytearray(512)
boot[0:11] = b"\xEB\x3C\x90" + b"MSDOS2.0"
struct.pack_into("<HBHBHHBHHH", boot, 11,
                 512, SPC, 1, 2, ROOTN, PSECS, 0xF8, SFAT, SPT, HEADS)
struct.pack_into("<H", boot, 0x1C, PSTART)
boot[510:512] = b"\x55\xAA"
img[PSTART * 512:(PSTART + 1) * 512] = boot

fat = bytearray(SFAT * 512)


def sf(n, v):
    o = n + n // 2
    if n & 1:
        fat[o] = (fat[o] & 0xF) | ((v & 0xF) << 4)
        fat[o + 1] = (v >> 4) & 0xFF
    else:
        fat[o] = v & 0xFF
        fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0xF)


sf(0, 0xFF8)
sf(1, 0xFFF)
root = bytearray(RS * 512)
nc = [2]


def put(nm, data, attr=0):
    n, _, ext = nm.partition(".")
    ent = bytearray(32)
    ent[0:8] = n.ljust(8).encode()
    ent[8:11] = ext.ljust(3).encode()
    ent[11] = attr
    struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, nc[0])
    struct.pack_into("<I", ent, 28, len(data))
    ncl = max(1, (len(data) + SPC * 512 - 1) // (SPC * 512))
    # writing past the partition would silently APPEND to the img bytearray
    # (slice-assign past the end grows it) — fail loudly instead
    assert nc[0] - 2 + ncl <= NCLUST, (
        f"hd_free.img full: {nm} needs {ncl} clusters, "
        f"only {NCLUST - (nc[0] - 2)} of {NCLUST} free")
    for k in range(ncl):
        c = nc[0] + k
        sf(c, 0xFFF if k == ncl - 1 else c + 1)
        lba = PSTART + DATA0 + (c - 2) * SPC
        ch = data[k * SPC * 512:(k + 1) * SPC * 512]
        img[lba * 512:lba * 512 + len(ch)] = ch
    nc[0] += ncl
    return ent


def mkent(nm, attr, clus, size):
    n, _, ext = nm.partition(".")
    ent = bytearray(32)
    ent[0:8] = n.ljust(8).encode()
    ent[8:11] = ext.ljust(3).encode()
    ent[11] = attr
    struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, clus)
    struct.pack_into("<I", ent, 28, size)
    return ent


idx = 0
for nm, data in tree[None]:
    assert idx < ROOTN, f"root dir full ({ROOTN} entries) at {nm}"
    root[idx * 32:idx * 32 + 32] = put(nm, data)
    idx += 1
for dname in sorted(k for k in tree if k is not None):
    files = tree[dname]
    assert idx < ROOTN, f"root dir full ({ROOTN} entries) at {dname}"
    assert len(files) <= (SPC * 512) // 32 - 2, \
        f"C:\\{dname}: {len(files)} files exceed a one-cluster directory"
    ents = [put(fn, data) for fn, data in files]
    dclus = nc[0]
    dirdata = bytearray(SPC * 512)
    dot = mkent(".", 0x10, dclus, 0)
    dot[0:11] = b".          "
    dotdot = mkent("..", 0x10, 0, 0)
    dotdot[0:11] = b"..         "
    for j, en in enumerate([dot, dotdot] + ents):
        dirdata[j * 32:(j + 1) * 32] = en
    put(dname + ".", dirdata)
    root[idx * 32:idx * 32 + 32] = mkent(dname, 0x10, dclus, 0)
    idx += 1

fo = (PSTART + 1) * 512
img[fo:fo + SFAT * 512] = fat
img[fo + SFAT * 512:fo + 2 * SFAT * 512] = fat
ro = (PSTART + 1 + 2 * SFAT) * 512
img[ro:ro + len(root)] = root

path = os.path.join(OUT, sys.argv[2] if len(sys.argv) > 2 else "hd_free.img")
img = bytes(img)
if not (os.path.exists(path) and open(path, "rb").read() == img):
    open(path, "wb").write(img)
used = (nc[0] - 2) * SPC * 512
free = (NCLUST * SPC * 512) - used
dirs = ", ".join(sorted(k for k in tree if k is not None))
print(f"{os.path.basename(path)}: [{dirs}] {idx} root entries, "
      f"{used} bytes used, {free} free")
