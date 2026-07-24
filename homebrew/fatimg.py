#!/usr/bin/env python3
"""Minimal FAT12 360 KB floppy toolkit for the homebrew build system.

Two jobs:
  * read_img(path)      -> {NAME: bytes} for a 180/360 KB floppy
  * Floppy(path)        -> clone a bootable image (msdos/msdos.img) and
                           append/replace root files, preserving the boot
                           sector and the IO.SYS/MSDOS.SYS cluster layout
                           the boot sector's baked-in sector runs expect.

Only root-directory files, which is all a scratch compile/test floppy
needs. Both FAT copies are kept in sync on save.
"""
import struct


def geometry(size):
    if size == 163840:                  # 160 KB single-sided, 1 FAT sector
        return 1, 1, 64
    if size == 327680:                  # 320 KB double-sided, 1 FAT sector
        return 2, 1, 112
    if size == 184320:                  # 180 KB
        return 1, 2, 64
    if size == 368640:                  # 360 KB
        return 2, 2, 112
    raise SystemExit(f"unsupported floppy size {size}")


def read_img(path):
    d = open(path, "rb").read()
    spc, sfat, rn = geometry(len(d))
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


class Floppy:
    def __init__(self, path):
        self.img = bytearray(open(path, "rb").read())
        self.spc, self.sfat, self.rn = geometry(len(self.img))
        self.dl = 1 + 2 * self.sfat + self.rn * 32 // 512
        self.nclust = (len(self.img) // 512 - self.dl) // self.spc

    # --- FAT helpers (first copy is authoritative; save() mirrors it) ---
    def _fe(self, n):
        o = 512 + n + n // 2
        v = self.img[o] | (self.img[o + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)

    def _sf(self, n, v):
        o = 512 + n + n // 2
        if n & 1:
            self.img[o] = (self.img[o] & 0x0F) | ((v & 0xF) << 4)
            self.img[o + 1] = (v >> 4) & 0xFF
        else:
            self.img[o] = v & 0xFF
            self.img[o + 1] = (self.img[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    def _roothdr(self):
        return (1 + 2 * self.sfat) * 512

    def _dirents(self):
        ro = self._roothdr()
        for i in range(self.rn):
            yield i, ro + i * 32

    def _find(self, name):
        n, _, ext = name.upper().partition(".")
        for i, off in self._dirents():
            e = self.img[off:off + 32]
            if e[0] in (0, 0xE5):
                continue
            if (e[0:8].decode("latin1").rstrip() == n and
                    e[8:11].decode("latin1").rstrip() == ext):
                return off
        return None

    def _free_cluster(self, start=2):
        for c in range(start, self.nclust + 2):
            if self._fe(c) == 0:
                return c
        raise SystemExit("floppy full")

    def replace(self, name, data):
        """Overwrite an existing root file in place (must not grow its
        cluster count — good enough for shrinking AUTOEXEC.BAT)."""
        off = self._find(name)
        assert off is not None, name
        first = struct.unpack_from("<H", self.img, off + 26)[0]
        ncl_new = max(1, (len(data) + self.spc * 512 - 1) // (self.spc * 512))
        # walk the old chain
        chain = []
        c = first
        while 2 <= c < 0xFF0:
            chain.append(c)
            c = self._fe(c)
        assert ncl_new <= len(chain), f"{name}: replacement grows the file"
        for k, c in enumerate(chain):
            if k < ncl_new:
                lba = self.dl + (c - 2) * self.spc
                ch = data[k * self.spc * 512:(k + 1) * self.spc * 512]
                span = bytearray(self.spc * 512)
                span[0:len(ch)] = ch
                self.img[lba * 512:(lba + self.spc) * 512] = span
                self._sf(c, 0xFFF if k == ncl_new - 1 else chain[k + 1])
            else:
                self._sf(c, 0)          # free the surplus
        struct.pack_into("<I", self.img, off + 28, len(data))

    def add(self, name, data, attr=0):
        for i, off in self._dirents():
            if self.img[off] in (0, 0xE5):
                break
        else:
            raise SystemExit("root directory full")
        n, _, ext = name.upper().partition(".")
        ent = bytearray(32)
        ent[0:8] = n.ljust(8).encode()
        ent[8:11] = ext.ljust(3).encode()
        ent[11] = attr
        ncl = max(1, (len(data) + self.spc * 512 - 1) // (self.spc * 512))
        chain = []
        c = 2
        for _ in range(ncl):
            c = self._free_cluster(c)
            chain.append(c)
            self._sf(c, 0xFFF)          # reserve so the next scan skips it
            c += 1
        for k, c in enumerate(chain):
            self._sf(c, 0xFFF if k == ncl - 1 else chain[k + 1])
            lba = self.dl + (c - 2) * self.spc
            ch = data[k * self.spc * 512:(k + 1) * self.spc * 512]
            span = bytearray(self.spc * 512)
            span[0:len(ch)] = ch
            self.img[lba * 512:(lba + self.spc) * 512] = span
        struct.pack_into("<HHH", ent, 22, 0x6000, 0x0668, chain[0])
        struct.pack_into("<I", ent, 28, len(data))
        self.img[off:off + 32] = ent

    def save(self, path):
        fo = 512
        self.img[fo + self.sfat * 512:fo + 2 * self.sfat * 512] = \
            self.img[fo:fo + self.sfat * 512]
        open(path, "wb").write(self.img)
