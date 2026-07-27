#!/usr/bin/env python3
"""winmouse.py — give a bring-your-own Windows 1.0x install a mouse driver.

    winmouse.py IN.img OUT.img SETUPDISK1.img [DRIVER]

Windows 1.x has no `.DRV` files on the installed disk: SETUP *links* the
selected display/keyboard/mouse/sound drivers into one `WIN100.BIN`, so the
mouse choice made at install time is frozen into that file. Both of the
installs in this repo's `disks/` were set up with **NOMOUSE.DRV** ("No
pointing device") — a 0x38-byte stub whose Inquire reports msExist = 0 — which
is why a Windows session on our machine issues no INT 33h and no port I/O at
all: there is nothing in it that could ever look for a mouse.

This script swaps that stub for a real driver taken from the user's own
Windows 1.01 SETUP floppy, without re-running SETUP.

How WIN100.BIN is put together (measured, by diffing the embedded modules
against the `.DRV` files they came from):

  * it is a chain of NE modules on 16-byte boundaries, KERNEL first;
  * each module keeps its original NE header verbatim except for three
    fields — `align` becomes 4 (paragraphs, not 512-byte sectors),
    `crc` is repurposed as the **paragraph address of the next module**
    (the chain link), and `nrestab` is rewritten to a small value the
    loader never reads (the nonresident-name table is not copied in);
  * segment-table `sector` fields become absolute paragraph addresses in
    WIN100.BIN — segments do NOT have to follow their own header, and
    non-preload segments point into WIN100.OVL instead.

That last property is what makes this safe: the replacement module keeps
the stub's header slot and its `crc` link, and its segment data is
*appended to the end of the file*, so every other byte of WIN100.BIN —
every other module, every other segment address — stays byte-identical.

The default driver is MOUSE.DRV, "Microsoft Mouse (Bus/Serial)": it probes
the bus card at 0x23C, falls back to a 1200-baud serial mouse on COM2 then
COM1, and speaks the classic 3-byte Microsoft protocol. That is what
runpc/dosboot emulate. The alternatives on the floppy are MSMOUSE1/2.DRV
(Mouse Systems, COM1/COM2), LMOUSE.DRV (Logitech) and JOYMOUSE.DRV (Kraft
joystick — rejected: it re-reads the game port with a 255-iteration timing
loop on every 18.2 Hz tick, ~2 550 guest instructions, which is ten times
the whole instruction budget of one SNES tick).
"""
import struct
import sys


# --------------------------------------------------------------- FAT12 --

class Fat:
    """Just enough FAT12 to replace one file in a partitioned fixed disk."""

    def __init__(self, path):
        self.img = bytearray(open(path, "rb").read())
        d = self.img
        self.base = 0
        if d[510:512] == b"\x55\xaa" and d[11:13] != b"\x00\x02":
            for i in range(4):
                e = d[446 + 16 * i:446 + 16 * i + 16]
                if e[4]:
                    self.base = struct.unpack_from("<I", e, 8)[0] * 512
                    break
        bs = d[self.base:self.base + 512]
        self.bps = struct.unpack_from("<H", bs, 11)[0]
        self.spc = bs[13]
        res = struct.unpack_from("<H", bs, 14)[0]
        self.nfat = bs[16]
        self.rn = struct.unpack_from("<H", bs, 17)[0]
        self.spf = struct.unpack_from("<H", bs, 22)[0]
        tot = struct.unpack_from("<H", bs, 19)[0]
        self.fat0 = self.base + res * self.bps
        self.root = self.base + (res + self.nfat * self.spf) * self.bps
        self.data0 = self.root + self.rn * 32
        self.csz = self.spc * self.bps
        self.nclust = (tot - (res + self.nfat * self.spf)
                       - self.rn * 32 // self.bps) // self.spc + 2

    # FAT12 entries live in the first copy; save() mirrors them
    def get(self, n):
        o = self.fat0 + n + n // 2
        v = self.img[o] | (self.img[o + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)

    def set(self, n, v):
        o = self.fat0 + n + n // 2
        if n & 1:
            self.img[o] = (self.img[o] & 0x0F) | ((v & 0xF) << 4)
            self.img[o + 1] = (v >> 4) & 0xFF
        else:
            self.img[o] = v & 0xFF
            self.img[o + 1] = (self.img[o + 1] & 0xF0) | ((v >> 8) & 0xF)

    def chain(self, c):
        out = []
        while 2 <= c < 0xFF0:
            out.append(c)
            c = self.get(c)
        return out

    def cluster(self, c):
        o = self.data0 + (c - 2) * self.csz
        return o, o + self.csz

    def free(self):
        for n in range(2, self.nclust):
            if self.get(n) == 0:
                return n
        raise SystemExit("winmouse: no free clusters left on the image")

    def find(self, subdir, name):
        """-> (dirent offset, first cluster, size) for SUBDIR\\NAME."""
        def scan(ents_off, ents_len, want, isdir):
            for i in range(ents_off, ents_off + ents_len, 32):
                e = self.img[i:i + 32]
                if e[0] in (0, 0xE5):
                    continue
                nm = (e[0:8].decode("latin1").rstrip() + "." +
                      e[8:11].decode("latin1").rstrip()).rstrip(".").upper()
                if nm != want:
                    continue
                if bool(e[11] & 0x10) != isdir:
                    continue
                return i, struct.unpack_from("<H", e, 26)[0], \
                    struct.unpack_from("<I", e, 28)[0]
            return None
        hit = scan(self.root, self.rn * 32, subdir, True)
        if not hit:
            raise SystemExit(f"winmouse: no \\{subdir} directory on the image")
        buf = []
        for c in self.chain(hit[1]):
            a, b = self.cluster(c)
            buf.append((a, self.csz))
        for a, n in buf:
            hit = scan(a, n, name, False)
            if hit:
                return hit
        raise SystemExit(f"winmouse: \\{subdir}\\{name} not found")

    def read(self, first, size):
        out = bytearray()
        for c in self.chain(first):
            a, b = self.cluster(c)
            out += self.img[a:b]
        return bytes(out[:size])

    def write(self, dirent, first, data):
        """Overwrite a file, growing/shrinking its cluster chain."""
        need = max(1, (len(data) + self.csz - 1) // self.csz)
        chain = self.chain(first)
        while len(chain) < need:                 # grow
            n = self.free()
            self.set(n, 0xFFF)                   # claim it before free() runs again
            self.set(chain[-1], n)
            chain.append(n)
        for c in chain[need:]:                   # shrink
            self.set(c, 0)
        self.set(chain[need - 1], 0xFFF)
        del chain[need:]
        for i, c in enumerate(chain):
            a, _ = self.cluster(c)
            blk = data[i * self.csz:(i + 1) * self.csz]
            self.img[a:a + len(blk)] = blk
            if len(blk) < self.csz:
                self.img[a + len(blk):a + self.csz] = b"\0" * (self.csz - len(blk))
        struct.pack_into("<I", self.img, dirent + 28, len(data))

    def save(self, path):
        fat = self.img[self.fat0:self.fat0 + self.spf * self.bps]
        for i in range(1, self.nfat):            # keep every FAT copy in sync
            o = self.fat0 + i * self.spf * self.bps
            self.img[o:o + len(fat)] = fat
        open(path, "wb").write(self.img)


# ------------------------------------------------------- floppy reader --

def read_floppy(path):
    """{NAME: bytes} for an unpartitioned FAT12 floppy (BPB-driven)."""
    d = open(path, "rb").read()
    bps = struct.unpack_from("<H", d, 11)[0]
    spc, res, nfat = d[13], struct.unpack_from("<H", d, 14)[0], d[16]
    rn, spf = struct.unpack_from("<H", d, 17)[0], struct.unpack_from("<H", d, 22)[0]
    fat = d[res * bps:(res + spf) * bps]
    root = (res + nfat * spf) * bps
    data0 = root + rn * 32

    def fe(n):
        o = n + n // 2
        v = fat[o] | (fat[o + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)

    out = {}
    for i in range(rn):
        e = d[root + i * 32:root + i * 32 + 32]
        if e[0] in (0, 0xE5) or e[11] & 0x18:
            continue
        nm = (e[0:8].decode("latin1").rstrip() + "." +
              e[8:11].decode("latin1").rstrip()).rstrip(".").upper()
        c = struct.unpack_from("<H", e, 26)[0]
        sz = struct.unpack_from("<I", e, 28)[0]
        b = bytearray()
        while 2 <= c < 0xFF0:
            o = data0 + (c - 2) * spc * bps
            b += d[o:o + spc * bps]
            c = fe(c)
        out[nm] = bytes(b[:sz])
    return out


# ------------------------------------------------------------- NE bits --

NE = {"enttab": (0x04, "H"), "cbenttab": (0x06, "H"), "crc": (0x08, "I"),
      "flags": (0x0C, "H"), "cseg": (0x1C, "H"), "cmod": (0x1E, "H"),
      "cbnrestab": (0x20, "H"), "segtab": (0x22, "H"), "rsrctab": (0x24, "H"),
      "restab": (0x26, "H"), "modtab": (0x28, "H"), "imptab": (0x2A, "H"),
      "nrestab": (0x2C, "I"), "align": (0x32, "H")}


def nefield(buf, ne, name):
    o, f = NE[name]
    return struct.unpack_from("<" + f, buf, ne + o)[0]


def modules(bin_):
    """Walk WIN100.BIN's module chain -> [(offset, name)].

    KERNEL is the first NE header in the file (0x400 in both the 1.01 and
    1.04 builds, but found rather than assumed — the MZ header in front of
    it is not a real DOS stub and its e_lfanew points nowhere).
    """
    out = []
    o = next((i for i in range(0x40, min(len(bin_), 0x4000), 16)
              if bin_[i:i + 2] == b"NE" and 0 < nefield(bin_, i, "cseg") < 64
              and nefield(bin_, i, "restab") < 0x400), None)
    if o is None:
        raise SystemExit("winmouse: no NE module chain in WIN100.BIN")
    while True:
        if bin_[o:o + 2] != b"NE":
            raise SystemExit(f"winmouse: no NE module at {o:#x}")
        rt = nefield(bin_, o, "restab")
        ln = bin_[o + rt]
        out.append((o, bin_[o + rt + 1:o + rt + 1 + ln].decode("latin1")))
        nxt = nefield(bin_, o, "crc") * 16
        if nxt <= o or nxt >= len(bin_):
            return out
        if bin_[nxt:nxt + 2] != b"NE":
            return out                        # end of the driver chain
        o = nxt


def relink(bin_, drv, verbose=True):
    """Replace WIN100.BIN's MOUSE module with the one in DRV (an NE .DRV)."""
    mods = modules(bin_)
    slot = next((o for o, n in mods if n == "MOUSE"), None)
    if slot is None:
        raise SystemExit("winmouse: WIN100.BIN has no MOUSE module")
    link = nefield(bin_, slot, "crc")              # -> the next module
    room = link * 16 - slot
    if verbose:
        print(f"  MOUSE module slot {slot:#x}..{link * 16:#x} "
              f"({room} bytes), currently {nefield(bin_, slot, 'cseg')} segment(s)")

    ne = struct.unpack_from("<H", drv, 0x3C)[0]
    cseg = nefield(drv, ne, "cseg")
    al = nefield(drv, ne, "align")
    hdrlen = max(nefield(drv, ne, "enttab") + nefield(drv, ne, "cbenttab"),
                 nefield(drv, ne, "segtab") + cseg * 8,
                 nefield(drv, ne, "imptab") + 32)
    hdrlen = min(hdrlen, 0x100)
    if hdrlen > room:
        raise SystemExit(f"winmouse: driver header ({hdrlen}) exceeds the "
                         f"{room}-byte MOUSE slot")

    out = bytearray(bin_)
    hdr = bytearray(drv[ne:ne + hdrlen])
    struct.pack_into("<I", hdr, NE["crc"][0], link)      # keep the chain link
    struct.pack_into("<H", hdr, NE["align"][0], 4)       # paragraphs
    struct.pack_into("<I", hdr, NE["nrestab"][0], 0)     # not copied in
    struct.pack_into("<H", hdr, NE["cbnrestab"][0], 0)

    st = nefield(drv, ne, "segtab")
    for i in range(cseg):
        s, cb, fl, ma = struct.unpack_from("<HHHH", drv, ne + st + i * 8)
        src = s << al
        n = cb + (2 + 8 * struct.unpack_from("<H", drv, src + cb)[0]
                  if fl & 0x100 else 0)
        while len(out) % 16:
            out.append(0)
        dst = len(out)
        out += drv[src:src + n]
        struct.pack_into("<HHHH", hdr, st + i * 8, dst >> 4, cb, fl, ma)
        if verbose:
            print(f"  seg{i}: {n} bytes (flags {fl:#x}) appended at {dst:#x}")

    out[slot:slot + hdrlen] = hdr
    out[slot + hdrlen:link * 16] = b"\0" * (link * 16 - slot - hdrlen)
    # Pad to a whole 512-byte page, then claim one page MORE than the file
    # has. Measured the hard way: the loader reads exactly (e_cp - 1) * 512
    # bytes and ignores e_cblp, so anything past that point is never read.
    # The appended data segment arrived 0x210 of 0x2A7 bytes long and the
    # driver read its COM-port table out of the loader's leftovers — it
    # "found" a serial mouse on port 0x1E44 and initialised thin air.
    while len(out) % 512:
        out.append(0)
    struct.pack_into("<H", out, 2, 0)                  # e_cblp: full pages
    struct.pack_into("<H", out, 4, len(out) // 512 + 1)  # e_cp
    return bytes(out)


def main(argv):
    if len(argv) < 4:
        sys.exit(__doc__.strip().splitlines()[2].strip())
    src, dst, disk1 = argv[1], argv[2], argv[3]
    which = (argv[4] if len(argv) > 4 else "MOUSE.DRV").upper()

    drv = read_floppy(disk1).get(which)
    if drv is None:
        sys.exit(f"winmouse: {which} not on {disk1}")
    print(f"winmouse: {which} ({len(drv)} bytes) from {disk1}")

    fat = Fat(src)
    dirent, first, size = fat.find("WINDOWS", "WIN100.BIN")
    bin_ = fat.read(first, size)
    print(f"  WIN100.BIN {size} bytes; modules: "
          + " ".join(n for _, n in modules(bin_)))
    new = relink(bin_, drv)
    print(f"  WIN100.BIN -> {len(new)} bytes")
    fat.write(dirent, first, new)
    fat.save(dst)
    print(f"winmouse: wrote {dst}")


if __name__ == "__main__":
    main(sys.argv)
