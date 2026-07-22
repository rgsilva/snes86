#!/usr/bin/env python3
"""Build the C: fixed-disk image (build/hd.img): an XT-style hard disk.

Geometry 107 cyl x 4 heads x 17 spt (3.6 MB). LBA 0 holds an MBR whose
single FAT12 partition (type 01, boot flag set) starts at CHS (0,1,1) =
LBA 17, exactly like PC DOS 2.0's own FDISK would lay it out. PC DOS 2.0
IGNORES the partition BPB — IBMBIO computes the filesystem layout from
the partition size in the MBR. For 7259 sectors it derives 4 sectors/
cluster, 6-sector FATs, 256 root entries; the layout below must match
that derivation exactly (verified by tracing its INT 13h reads).

Root keeps only what MUST live there (FCB opens see root only: WordStar
and Multiplan overlays; Zork's patched absolute paths) plus a duplicate
AUTOEXEC.BAT so COMMAND.COM's batch processing survives the drive
change (it re-opens the batch file on the CURRENT drive after C:).
Everything else is organized in subdirectories.
"""
import os
import struct
import sys

DISKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "disks")
OUT = sys.argv[1] if len(sys.argv) > 1 else "build"

SPT, HEADS, CYLS = 17, 4, 107
TOTAL = SPT * HEADS * CYLS           # 7276 sectors
PSTART = SPT                         # partition at CHS (0,1,1)
PSECS = TOTAL - PSTART
SPC, SFAT, ROOTN = 4, 6, 256
RS = ROOTN * 32 // 512
DATA0 = 1 + 2 * SFAT + RS            # partition-relative first data LBA


def read_img(path):
    d = open(path, "rb").read()
    if len(d) == 163840:
        spc, sfat, rn = 1, 1, 64
    elif len(d) == 327680:
        spc, sfat, rn = 2, 1, 112
    elif len(d) == 184320:
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


bench = b"""program Bench;  { self-timing micro-benchmarks via DOS clock }\r
type Regs = record AX,BX,CX,DX,BP,SI,DI,DS,ES,Flags: integer; end;\r
var r: Regs;\r
    t0, t1: real;\r
    i, k, n, acc: integer;\r
    flags: array[0..8190] of boolean;\r
function Clock: real;\r
begin\r
  r.AX := $2C00; MsDos(r);\r
  Clock := Hi(r.CX)*3600.0 + Lo(r.CX)*60.0 + Hi(r.DX) + Lo(r.DX)/100.0;\r
end;\r
begin\r
  WriteLn('snes86 benchmark suite');\r
  t0 := Clock;\r
  for n := 1 to 3 do begin\r
    for i := 0 to 8190 do flags[i] := true;\r
    for i := 0 to 8190 do\r
      if flags[i] then begin\r
        k := i + i + 3 + i;\r
        while k <= 8190 do begin flags[k] := false; k := k + i + i + 3; end;\r
      end;\r
  end;\r
  t1 := Clock;\r
  WriteLn('Sieve x3:    ', (t1-t0):7:2, ' s');\r
  t0 := Clock; acc := 1;\r
  for i := 1 to 10000 do begin acc := acc * 13; acc := acc div 7; end;\r
  t1 := Clock;\r
  WriteLn('MulDiv 10k:  ', (t1-t0):7:2, ' s');\r
  t0 := Clock;\r
  for i := 1 to 200 do Write('.');\r
  WriteLn;\r
  t1 := Clock;\r
  WriteLn('Console 200: ', (t1-t0):7:2, ' s');\r
  WriteLn('(IBM PC/XT 4.77MHz for scale: ~2s / ~0.4s / ~0.1s)');\r
end.\r
"""

sieve = b"""program Sieve;  { BYTE benchmark, 10 iterations }\r
const Size = 8190;\r
var flags: array[0..Size] of boolean;\r
    i, prime, k, count, iter: integer;\r
begin\r
  WriteLn('BYTE Sieve, 10 iterations');\r
  for iter := 1 to 10 do begin\r
    count := 0;\r
    FillChar(flags, SizeOf(flags), 1);\r
    for i := 0 to Size do\r
      if flags[i] then begin\r
        prime := i + i + 3;\r
        k := i + prime;\r
        while k <= Size do begin\r
          flags[k] := false;\r
          k := k + prime;\r
        end;\r
        count := count + 1;\r
      end;\r
  end;\r
  WriteLn(count, ' primes (expect 1899)');\r
end.\r
"""

hello = b"""program Hello;\r
var i: integer;\r
begin\r
  for i := 1 to 3 do\r
    WriteLn('Hello from a SNES! (', i, ')');\r
end.\r
"""


AUTOEXEC = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             "autoexec.bat"), "rb").read()

f1 = read_img(os.path.join(DISKS, "pcdos200-disk1.img"))
ftp = read_img(os.path.join(DISKS, "tp301.img"))
fws = read_img(os.path.join(DISKS, "wordstar.img"))
fmp = read_img(os.path.join(DISKS, "multiplan2.img"))
ws_com = open(os.path.join(DISKS, "ws_installed.com"), "rb").read()
mp_com = open(os.path.join(DISKS, "mp_com_compaq.bin"), "rb").read()
zork_com = open(os.path.join(DISKS, "zork1_snes.com"), "rb").read()
sok_com = open(os.path.join(DISKS, "sokoban.com"), "rb").read()
mid_com = open(os.path.join(DISKS, "midplay.com"), "rb").read()
mc_com = open(os.path.join(DISKS, "midconv.com"), "rb").read()
mc_pas = open(os.path.join(DISKS, "midconv.pas"), "rb").read()
snm_canyon = open(os.path.join(DISKS, "canyon.snm"), "rb").read()
snm_doom = open(os.path.join(DISKS, "level1.snm"), "rb").read()
mid_pas = open(os.path.join(DISKS, "midplay.pas"), "rb").read()
mid_canyon = open(os.path.join(DISKS, "canyon.mid"), "rb").read()
mid_doom = open(os.path.join(DISKS, "level1.mid"), "rb").read()
sok_pas = open(os.path.join(DISKS, "sokoban.pas"), "rb").read()
zork_dat = open(os.path.join(DISKS, "zork1", "data", "zork1.dat"), "rb").read()
setup_inf = open(os.path.join(DISKS, "zork1", "setup.inf"), "rb").read()


def infocom(com, *patches):
    """Patch an Infocom '96 interpreter's hardcoded file paths."""
    d = bytearray(com)
    for old, new in patches:
        i = d.find(old)
        assert i >= 0, old
        assert len(new) <= len(old), new
        d[i:i + len(old)] = new.ljust(len(old), b"\x00")
    return bytes(d)


def rd(*p):
    return open(os.path.join(DISKS, *p), "rb").read()


# Six more v3 games. Data files live in C:\ root (the patched absolute
# paths), saves default to B:. HHGTTG and Wishbringer ship no 8086
# interpreter in the '96 re-release, so they get a re-patched Zork 1 one
# (all these interpreters are the same ZIP build with different strings).
zork1_raw = rd("zork1", "_zork1.com")
inf_games = [
    ("ZORK2.COM", infocom(rd("zork2", "zork2", "_zork2.com"),
        (b"DATA\\ZORK2.DAT", b"C:\\ZORK2.DAT"),
        (b"SAVE\\ZORK2.DAT", b"B:\\ZORK2.SAV")),
     "ZORK2.DAT", rd("zork2", "zork2", "data", "zork2.dat")),
    ("ZORK3.COM", infocom(rd("zork3", "zork3", "_ZORK3.COM"),
        (b"DATA\\ZORK3.DAT", b"C:\\ZORK3.DAT"),
        (b"SAVE\\ZORK3.DAT", b"B:\\ZORK3.SAV")),
     "ZORK3.DAT", rd("zork3", "zork3", "DATA", "ZORK3.DAT")),
    ("PLANET.COM", infocom(rd("planetfa", "planetf", "_PLANETF.COM"),
        (b"DATA\\PLANETFA.DAT", b"C:\\PLANET.DAT"),
        (b"SAVE\\PLANETFA.DAT", b"B:\\PLANET.SAV")),
     "PLANET.DAT", rd("planetfa", "planetf", "data", "PLANETFA.DAT")),
    ("LGOP.COM", infocom(rd("lgop", "phobos1", "leather.com"),
        (b"LEATHER.DAT", b"C:\\LGOP.DAT")),
     "LGOP.DAT", rd("lgop", "phobos1", "leather.dat")),
    ("HHGTTG.COM", infocom(zork1_raw,
        (b"DATA\\ZORK1.DAT", b"C:\\HHGTTG.DAT"),
        (b"SAVE\\ZORK1.DAT", b"B:\\HHGTTG.SAV")),
     "HHGTTG.DAT", rd("hhgttg", "HGG", "hitchhik.dat")),
    ("WISH.COM", infocom(zork1_raw,
        (b"DATA\\ZORK1.DAT", b"C:\\WISH.DAT"),
        (b"SAVE\\ZORK1.DAT", b"B:\\WISH.SAV")),
     "WISH.DAT", rd("wishbrin", "wishbrin", "wishbrin.dat")),
]
gwbasic = open(os.path.join(DISKS, "gwbasic.exe"), "rb").read()
hello_com = open(os.path.join(DISKS, "hello.com"), "rb").read()
sieve_com = open(os.path.join(DISKS, "sieve.com"), "rb").read()
# M15 (BIGMEM 172 KB) revivals: these need >108 KB to load
elite_exe = rd("elite", "elite", "elite.exe")
elite_trn = rd("elite", "elite", "elitetrn.com")
sglider_exe = rd("starglider", "Strglid", "SGLIDER.EXE")

# quick MIDI test shortcuts (root is on the PATH, so "CA"/"L1" work
# from anywhere; absolute .SNM paths so cwd doesn't matter)
CA_BAT = b"MIDPLAY C:\\MIDI\\CANYON.SNM\r\n"
L1_BAT = b"MIDPLAY C:\\MIDI\\LEVEL1.SNM\r\n"

rootfiles = [
    ("AUTOEXEC.BAT", AUTOEXEC),
    ("CA.BAT", CA_BAT),
    ("L1.BAT", L1_BAT),
    ("WS.COM", ws_com),
    ("WSOVLY1.OVR", fws["WSOVLY1.OVR"]),
    ("WSMSGS.OVR", fws["WSMSGS.OVR"]),
    ("MP.COM", mp_com),
    ("MP.LOD", fmp["MP.LOD"]),
    ("MP.SYS", fmp["MP.SYS"]),
    ("MP80.DAT", fmp["MP80.DAT"]),
    ("ZORK1.DAT", zork_dat),
    ("SETUP.INF", setup_inf),
] + [(dn, dd) for _, _, dn, dd in inf_games]
subdirs = [
    ("BASIC", [("GWBASIC.EXE", gwbasic)]),
    ("MIDI", [("MIDPLAY.COM", mid_com), ("MIDPLAY.PAS", mid_pas),
              ("MIDCONV.COM", mc_com), ("MIDCONV.PAS", mc_pas),
              ("CANYON.MID", mid_canyon), ("LEVEL1.MID", mid_doom),
              ("CANYON.SNM", snm_canyon), ("LEVEL1.SNM", snm_doom)]),
    ("PASCAL", [("TURBO.COM", ftp["TURBO.COM"]),
                ("TURBO.MSG", ftp["TURBO.MSG"]),
                ("HELLO.PAS", hello),
                ("HELLO.COM", hello_com)]),
    ("BENCH", [("SI.EXE", rd("bench_NortonSI", "si45", "SI.EXE")),
               ("REPBENCH.COM", open(os.path.join(
                   os.path.dirname(os.path.abspath(__file__)),
                   "..", "build", "repbench.com"), "rb").read()),
               ("CPUBENCH.COM", open(os.path.join(
                   os.path.dirname(os.path.abspath(__file__)),
                   "..", "build", "cpubench.com"), "rb").read()),
               ("CGATEST.COM", open(os.path.join(
                   os.path.dirname(os.path.abspath(__file__)),
                   "..", "build", "cgatest.com"), "rb").read()),
               ("SIEVE.PAS", sieve),
               ("SIEVE.COM", sieve_com),
               ("BENCH.PAS", bench)]),
    ("GAMES", [("ZORK1.COM", zork_com),
               ("SOKOBAN.COM", sok_com), ("SOKOBAN.PAS", sok_pas),
               ("ROGUE.EXE", rd("rogue", "rogue", "10ROGUE.EXE")),
               ("ELITE.EXE", elite_exe), ("ELITETRN.COM", elite_trn),
               ("SGLIDER.EXE", sglider_exe)] +
               [(cn, cd) for cn, cd, _, _ in inf_games]),
]

# GB.COM - the Game Boy emulator (gbdos/), when built: emulator + boot ROM
# + homebrew test carts, plus any .gb the user drops in disks/gb/.
GBD = os.path.join(DISKS, "..", "gbdos")
if os.path.exists(os.path.join(GBD, "build", "GB.COM")):
    gbfiles = [("GB.COM",
                open(os.path.join(GBD, "build", "GB.COM"), "rb").read())]
    for fn, rel in (("SMOKE.GB", ("build", "smoke.gb")),
                    ("JOY.GB", ("build", "joy.gb")),
                    # fast-paced boot ROM: same logo, short waits - at
                    # snes86 speed the authentic pacing takes ~30 min
                    ("DMGBOOT.BIN", ("roms", "dmg_boot_fast.bin")),
                    ("DMGSLOW.BIN", ("roms", "dmg_boot.bin"))):
        p = os.path.join(GBD, *rel)
        if os.path.exists(p):
            gbfiles.append((fn, open(p, "rb").read()))
    gd = os.path.join(DISKS, "gb")
    if os.path.isdir(gd):
        for fn in sorted(os.listdir(gd)):
            if fn.lower().endswith(".gb"):
                gbfiles.append((fn.upper(),
                                open(os.path.join(gd, fn), "rb").read()))
    subdirs.append(("GB", gbfiles))

# ---- build the image
img = bytearray(TOTAL * 512)

mbr = bytearray(512)
e = 0x1BE
mbr[e] = 0x80                                  # boot indicator
mbr[e + 1:e + 4] = bytes([1, 1, 0])            # CHS start (0,1,1)
mbr[e + 4] = 0x01                              # type: FAT12
mbr[e + 5:e + 8] = bytes([HEADS - 1,
                          SPT | (((CYLS - 1) >> 8) & 3) << 6,
                          (CYLS - 1) & 0xFF])  # CHS end
struct.pack_into("<II", mbr, e + 8, PSTART, PSECS)
mbr[510:512] = b"\x55\xAA"
img[0:512] = mbr

dos1 = open(os.path.join(DISKS, "pcdos200-disk1.img"), "rb").read()
boot = bytearray(dos1[0:512])
struct.pack_into("<HBHBHHBHHH", boot, 11,
                 512, SPC, 1, 2, ROOTN, PSECS, 0xF8, SFAT, SPT, HEADS)
struct.pack_into("<H", boot, 0x1C, PSTART)     # hidden sectors
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
for nm, data in rootfiles:
    root[idx * 32:idx * 32 + 32] = put(nm, data)
    idx += 1
for dname, files in subdirs:
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

path = os.path.join(OUT, "hd.img")
open(path, "wb").write(img)
used = (nc[0] - 2) * SPC * 512
free = ((PSECS - DATA0) // SPC * SPC * 512) - used
print(f"hd.img: {idx} root entries, {used} bytes used, {free} free "
      f"({TOTAL * 512} image)")
