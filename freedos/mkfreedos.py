#!/usr/bin/env python3
"""Build the FreeDOS A: boot floppy for `make freedos`.

Downloads the official FreeDOS 1.3 Floppy Edition (GPL — fetched at build
time and cached, never committed, same policy as the ELKS images), pulls
KERNEL.SYS (the 8086 build), FreeCOM and MEM.EXE out of its 720 KB boot
disk, and assembles a minimal 360 KB boot floppy that fits snes86's A:
geometry (40 cyl x 2 heads x 9 spt). The FreeDOS FAT12 boot sector reads
its geometry from the BPB, so the 720 KB sector-0 code boots the 360 KB
layout after the BPB fields are re-patched; KERNEL.SYS is still placed
first and contiguous, belt and braces.

Why a floppy at all: FreeDOS needs the BIGMEM machine's full 172 KB (the
kernel dies during init at 108 KB) and boots to FreeCOM at exactly 172 KB
— measured on runpc before this target existed.

Usage: mkfreedos.py <output.img>     (cache lands in freedos/cache/)
"""
import hashlib
import io
import os
import struct
import sys
import urllib.request
import zipfile

URL = ("https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/"
       "distributions/1.3/official/FD13-FloppyEdition.zip")
SHA256 = "75a4e11a7fce6f124e20927b3022b4b715a2a3f7324c5f5bfea42d90d80eb072"
BOOTDISK = "720k/x86BOOT.img"          # member holding kernel + FreeCOM

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")
ZIPPATH = os.path.join(CACHE, "FD13-FloppyEdition.zip")

# ---------------------------------------------------------------- fetch

def fetch():
    if not os.path.exists(ZIPPATH):
        os.makedirs(CACHE, exist_ok=True)
        print(f"fetching {URL} ...", file=sys.stderr)
        with urllib.request.urlopen(URL, timeout=120) as r:
            data = r.read()
        with open(ZIPPATH + ".part", "wb") as f:
            f.write(data)
        os.replace(ZIPPATH + ".part", ZIPPATH)
    got = hashlib.sha256(open(ZIPPATH, "rb").read()).hexdigest()
    if got != SHA256:
        os.unlink(ZIPPATH)
        sys.exit(f"mkfreedos: {ZIPPATH}: sha256 mismatch\n"
                 f"  got  {got}\n  want {SHA256}\n"
                 "(deleted — re-run to re-download)")
    return zipfile.ZipFile(ZIPPATH).read(BOOTDISK)

# ------------------------------------------------- FAT12 reader (source)

class Fat12:
    def __init__(self, img):
        self.img = img
        (self.bps,) = struct.unpack("<H", img[11:13])
        self.spc = img[13]
        (self.res,) = struct.unpack("<H", img[14:16])
        self.nfat = img[16]
        (self.rootn,) = struct.unpack("<H", img[17:19])
        (self.spf,) = struct.unpack("<H", img[22:24])
        self.fat = img[self.res * self.bps:(self.res + self.spf) * self.bps]
        self.root = (self.res + self.nfat * self.spf) * self.bps
        self.data0 = self.root + self.rootn * 32

    def chain(self, c):
        out = []
        while 2 <= c < 0xFF0:
            out.append(c)
            off = c + c // 2
            v = struct.unpack("<H", self.fat[off:off + 2])[0]
            c = (v >> 4) if c & 1 else (v & 0xFFF)
        return out

    def read_clusters(self, chain):
        csz = self.spc * self.bps
        return b"".join(self.img[self.data0 + (c - 2) * csz:
                                 self.data0 + (c - 2) * csz + csz]
                        for c in chain)

    def scan(self, raw):
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] & 0x08:
                continue
            name = e[:8].decode().strip()
            ext = e[8:11].decode().strip()
            yield ((name + "." + ext if ext else name), e[11],
                   struct.unpack("<H", e[26:28])[0],
                   struct.unpack("<I", e[28:32])[0])

    def find(self, path):
        raw = self.img[self.root:self.root + self.rootn * 32]
        parts = path.upper().split("/")
        for depth, want in enumerate(parts):
            for name, attr, clus, size in self.scan(raw):
                if name != want:
                    continue
                if depth == len(parts) - 1:
                    return self.read_clusters(self.chain(clus))[:size]
                raw = self.read_clusters(self.chain(clus))
                break
            else:
                sys.exit(f"mkfreedos: {path} not found in {BOOTDISK}")

# ------------------------------------------------- FAT12 writer (360 KB)
# 360 KB layout: 1 reserved + 2 FATs x 2 + 7 root (112 entries), data at
# sector 12, 2 sectors/cluster -> 354 clusters.

SECT, SPC, SPF, ROOTN, TOTAL = 512, 2, 2, 112, 720
DATA0 = 1 + 2 * SPF + (ROOTN * 32) // SECT      # first data sector (12)
NCLUST = (TOTAL - DATA0) // SPC                 # 354

def build(bootsec, files, out):
    img = bytearray(TOTAL * SECT)
    bs = bytearray(bootsec)
    # re-patch the 720K BPB for 360K: total sectors, media byte, FAT size.
    struct.pack_into("<H", bs, 19, TOTAL)       # total sectors (16-bit)
    bs[21] = 0xFD                               # media descriptor: 360K
    struct.pack_into("<H", bs, 22, SPF)         # sectors per FAT
    struct.pack_into("<I", bs, 32, 0)           # 32-bit total: unused
    img[0:SECT] = bs

    fat = bytearray(SPF * SECT)
    fat[0:3] = b"\xFD\xFF\xFF"

    def setfat(c, v):
        off = c + c // 2
        cur = struct.unpack("<H", fat[off:off + 2])[0]
        cur = (cur & 0x000F) | (v << 4) if c & 1 else (cur & 0xF000) | v
        struct.pack_into("<H", fat, off, cur)

    nextc, rooti = 2, 0
    for name, data in files:
        base, _, ext = name.partition(".")
        need = max(1, -(-len(data) // (SPC * SECT)))
        if nextc + need - 2 > NCLUST:
            sys.exit(f"mkfreedos: {name} overflows the 360K floppy")
        first = nextc
        for i in range(need):                    # contiguous chain
            setfat(nextc, 0xFFF if i == need - 1 else nextc + 1)
            pos = (DATA0 + (nextc - 2) * SPC) * SECT
            img[pos:pos + len(data[i*SPC*SECT:(i+1)*SPC*SECT])] = \
                data[i * SPC * SECT:(i + 1) * SPC * SECT]
            nextc += 1
        ent = struct.pack("<8s3sB10x", base.ljust(8).encode(),
                          ext.ljust(3).encode(), 0x20)
        ent += struct.pack("<HHHI", 0x6000, 0x5AF5, first, len(data))
        pos = SECT + 2 * SPF * SECT + rooti * 32   # root dir
        img[pos:pos + 32] = ent
        rooti += 1

    img[SECT:SECT + SPF * SECT] = fat
    img[SECT + SPF * SECT:SECT + 2 * SPF * SECT] = fat
    with open(out, "wb") as f:
        f.write(img)
    print(f"{out}: {TOTAL*SECT} bytes, {rooti} files, "
          f"{NCLUST - (nextc - 2)} clusters free")

# ----------------------------------------------------------------- main

FDCONFIG = (b"!LASTDRIVE=D\r\n"
            b"!BUFFERS=15\r\n"                  # trimmed for the 172K box
            b"!FILES=20\r\n"
            b"SHELL=A:\\COMMAND.COM A:\\ /E:512 /P=A:\\AUTOEXEC.BAT\r\n")

AUTOEXEC = (b"@ECHO OFF\r\n"
            b"SET PATH=A:\\;C:\\;C:\\MIDI;C:\\BENCH;C:\\GAMES;C:\\USER\r\n"
            b"VER\r\n"
            b"ECHO FreeDOS on a SNES. C: has the usual free tools.\r\n")

if __name__ == "__main__":
    src = Fat12(fetch())
    build(src.img[0:512], [
        ("KERNEL.SYS",  src.find("KERNEL.SYS")),          # first + contiguous
        ("COMMAND.COM", src.find("FREEDOS/BIN/COMMAND.COM")),
        ("MEM.EXE",     src.find("FREEDOS/BIN/MEM.EXE")),
        ("FDCONFIG.SYS", FDCONFIG),
        ("AUTOEXEC.BAT", AUTOEXEC),
    ], sys.argv[1])
