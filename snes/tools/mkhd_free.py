#!/usr/bin/env python3
"""Build the FREE C: fixed-disk image (build/hd_free.img) for the public release.

Unlike mkhd.py (the private developer build, which carries copyrighted DOS
software), this image contains ONLY freely redistributable material:

  * our own snes86 tools, shipped WITH Turbo Pascal source
    (MIDPLAY/MIDCONV, SOKOBAN, SIEVE, HELLO, BENCH, CGATEST);
  * a generated demo: a public-domain tune (Beethoven's "Ode to Joy",
    1824) sequenced here as an original CC0 MIDI + its .SNM conversion;
  * whatever the user drops into snes86/userware/  (bring-your-own DOS
    software -> appears in C:\\USER).  Empty by default.

Same geometry as mkhd.py (107x4x17, FAT12 partition at LBA 17) so the same
INT 13h driver + dosboot INCBIN work unchanged; the C: partition never boots
(only A: does), so its boot sector is synthesized here instead of copied from
a copyrighted DOS.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DISKS = os.path.join(HERE, "..", "..", "disks")
BUILD = os.path.join(HERE, "..", "build")
USERWARE = os.path.join(HERE, "..", "userware")
OUT = sys.argv[1] if len(sys.argv) > 1 else "build"

# --- geometry (identical to mkhd.py) ---
SPT, HEADS, CYLS = 17, 4, 107
TOTAL = SPT * HEADS * CYLS
PSTART = SPT
PSECS = TOTAL - PSTART
SPC, SFAT, ROOTN = 4, 6, 256
RS = ROOTN * 32 // 512
DATA0 = 1 + 2 * SFAT + RS
NCLUST = (PSECS - DATA0) // SPC      # data clusters (indices 2..NCLUST+1)


def rd(*p):
    return open(os.path.join(*p), "rb").read()


# ---- inline Turbo Pascal sources for the tiny demos (ours, CC0) ----
SIEVE_PAS = b"""program Sieve;  { BYTE benchmark, 10 iterations }\r
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

BENCH_PAS = b"""program Bench;  { self-timing micro-benchmarks via DOS clock }\r
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

README_TXT = b"""snes86 - MS-DOS 2.0 on a stock SNES.  Free public release.\r
\r
This C: drive ships only free software: our own snes86 tools (with Turbo\r
Pascal source) plus a generated demo.  No copyrighted DOS applications are\r
included -- add your own with the "bring your own software" step below.\r
\r
WHAT'S HERE\r
  C:\\MIDI    MIDPLAY / MIDCONV (SNES-MIDI tools) + DEMO.MID / DEMO.SNM\r
  C:\\BENCH   SIEVE, BENCH, HELLO, CGATEST  (+ .PAS source)\r
  C:\\GAMES   SOKOBAN  (+ .PAS source)\r
  C:\\USER    your own DOS software (see below)\r
\r
TRY IT\r
  C:\\> PLAY          play the demo tune on the SNES-MIDI synth\r
  C:\\> CD GAMES      then:  SOKOBAN\r
  C:\\> CD BENCH      then:  SIEVE   or   CGATEST\r
\r
BRING YOUR OWN SOFTWARE\r
  Drop .COM/.EXE files into  snes86/userware/  on your PC and rebuild the\r
  ROM (make msdos).  They appear here in C:\\USER, which is on the PATH,\r
  so you can run them from anywhere.  See BUILDING.md.\r
"""

PLAY_BAT = b"MIDPLAY C:\\MIDI\\DEMO.SNM\r\n"

# A: already sets PATH + PROMPT and drops to C:; this C:\AUTOEXEC.BAT only
# needs to exist so COMMAND.COM's batch processing survives the drive change.
AUTOEXEC = (b"PATH C:\\;C:\\MIDI;C:\\BENCH;C:\\GAMES;C:\\USER\r\n"
            b"PROMPT $P$G\r\n")


# ---- generate the CC0 demo: "Ode to Joy" (Beethoven, 1824, public domain) ----
def gen_demo_mid():
    """Return a format-0 Standard MIDI File of the Ode to Joy melody."""
    DIV = 480
    Q = DIV                      # quarter note
    H = DIV * 2                  # half note
    DQ = DIV * 3 // 2            # dotted quarter
    E = DIV // 2                 # eighth
    # (semitone, duration) - E4=64 F4=65 G4=67 A4=69 D4=62 C4=60
    melody = [
        (64, Q), (64, Q), (65, Q), (67, Q),
        (67, Q), (65, Q), (64, Q), (62, Q),
        (60, Q), (60, Q), (62, Q), (64, Q),
        (64, DQ), (62, E), (62, H),
        (64, Q), (64, Q), (65, Q), (67, Q),
        (67, Q), (65, Q), (64, Q), (62, Q),
        (60, Q), (60, Q), (62, Q), (64, Q),
        (62, DQ), (60, E), (60, H),
    ]

    def vlq(n):
        out = bytearray([n & 0x7F])
        n >>= 7
        while n:
            out.insert(0, (n & 0x7F) | 0x80)
            n >>= 7
        return bytes(out)

    trk = bytearray()
    trk += vlq(0) + bytes([0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])   # 500000 us/qn
    for note, dur in melody:
        trk += vlq(0) + bytes([0x90, note, 100])    # note on
        trk += vlq(dur) + bytes([0x80, note, 0])    # note off
    trk += vlq(0) + bytes([0xFF, 0x2F, 0x00])       # end of track

    hdr = b"MThd" + struct.pack(">IHHH", 6, 0, 1, DIV)
    return hdr + b"MTrk" + struct.pack(">I", len(trk)) + bytes(trk)


def mid_to_snm(mid):
    """Port of MIDCONV.PAS: format-0 SMF -> .SNM 4-byte packet stream."""
    p = [0]

    def nb():
        b = mid[p[0]] if p[0] < len(mid) else 0xFF
        p[0] += 1
        return b

    def readvar():
        v = 0
        for _ in range(4):
            b = nb()
            v = v * 128 + (b & 0x7F)
            if b < 0x80:
                break
        return v

    # header
    for _ in range(8):
        nb()                                    # MThd + length
    nb(); nb()                                  # format (0)
    nb(); nb()                                  # ntrks
    division = nb() * 256 + nb()
    for _ in range(8):
        nb()                                    # MTrk + length

    out = bytearray()
    npk = [0]

    def sendpk(d, s, d1, d2):
        out.extend([d & 0xFF, s & 0xFF, d1 & 0xFF, d2 & 0xFF])
        npk[0] += 1

    scale = [500000.0 / (division * 16667.0)]
    pending = [0]
    carry = [0.0]

    def emit(s, d1, d2):
        while pending[0] > 255:
            sendpk(255, 0, 0, 0)
            pending[0] -= 255
        sendpk(pending[0], s, d1, d2)
        pending[0] = 0

    def adddelta(ticks):
        fd = ticks * scale[0] + carry[0]
        pending[0] += int(fd)
        carry[0] = fd - int(fd)

    rstatus = 0
    while True:
        adddelta(readvar())
        if p[0] > len(mid):
            break
        b = nb()
        if b >= 0x80:
            if b < 0xF0:
                rstatus = b
                b = nb()
            elif b == 0xFF:
                mt = nb()
                ln = readvar()
                if mt == 0x2F:
                    break
                if mt == 0x51:
                    tmp = 0
                    for _ in range(ln):
                        tmp = tmp * 256 + nb()
                    scale[0] = tmp / (division * 16667.0)
                else:
                    for _ in range(ln):
                        nb()
                rstatus = 0
                continue
            else:
                ln = readvar()
                for _ in range(ln):
                    nb()
                rstatus = 0
                continue
        if rstatus >= 0x80:
            hi = rstatus >> 4
            if hi in (0x8, 0x9, 0xA, 0xB, 0xE):
                d1 = b
                b = nb()
                if hi in (0x8, 0x9):
                    emit(rstatus, d1, b)
            elif hi in (0xC, 0xD):
                if hi == 0xC:
                    emit(rstatus, b, 0)

    sendpk(0, 0xFF, 0, 0)                        # all notes off
    while (len(out) // 4) % 32:                  # pad to a 128-byte block
        sendpk(0, 0, 0, 0)
    return bytes(out)


def collect_userware():
    """Flat .COM/.EXE/.BAT/etc from userware/ -> list[(NAME, bytes)]."""
    SKIP = {"README.MD", "README.TXT"}
    files = []
    if os.path.isdir(USERWARE):
        for nm in sorted(os.listdir(USERWARE)):
            fp = os.path.join(USERWARE, nm)
            if (os.path.isfile(fp) and not nm.startswith(".")
                    and nm.upper() not in SKIP):
                files.append((nm.upper(), open(fp, "rb").read()))
    return files


demo_mid = gen_demo_mid()
demo_snm = mid_to_snm(demo_mid)

user_files = collect_userware()
if not user_files:
    user_files = [("READ.ME", b"Put your own DOS .COM/.EXE files in "
                              b"snes86/userware/ and run 'make msdos'.\r\n"
                              b"They will appear here, on the PATH.\r\n")]

rootfiles = [
    ("AUTOEXEC.BAT", AUTOEXEC),
    ("README.TXT", README_TXT),
    ("PLAY.BAT", PLAY_BAT),
]
subdirs = [
    ("MIDI", [("MIDPLAY.COM", rd(DISKS, "midplay.com")),
              ("MIDPLAY.PAS", rd(DISKS, "midplay.pas")),
              ("MIDCONV.COM", rd(DISKS, "midconv.com")),
              ("MIDCONV.PAS", rd(DISKS, "midconv.pas")),
              ("DEMO.MID", demo_mid),
              ("DEMO.SNM", demo_snm)]),
    ("BENCH", [("SIEVE.COM", rd(DISKS, "sieve.com")),
               ("SIEVE.PAS", SIEVE_PAS),
               ("BENCH.PAS", BENCH_PAS),
               ("HELLO.COM", rd(DISKS, "hello.com")),
               ("HELLO.PAS", rd(DISKS, "HELLO.pas")),
               ("CGATEST.COM", rd(BUILD, "cgatest.com"))]),
    ("GAMES", [("SOKOBAN.COM", rd(DISKS, "sokoban.com")),
               ("SOKOBAN.PAS", rd(DISKS, "sokoban.pas"))]),
    ("USER", user_files),
]

# ---- build the image (same layout math as mkhd.py) ----
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
for nm, data in rootfiles:
    assert idx < ROOTN, f"root dir full ({ROOTN} entries) at {nm}"
    root[idx * 32:idx * 32 + 32] = put(nm, data)
    idx += 1
for dname, files in subdirs:
    assert idx < ROOTN, f"root dir full ({ROOTN} entries) at {dname}"
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

path = os.path.join(OUT, "hd_free.img")
open(path, "wb").write(img)
used = (nc[0] - 2) * SPC * 512
free = ((PSECS - DATA0) // SPC * SPC * 512) - used
print(f"hd_free.img: {idx} root entries, {len(user_files)} user file(s), "
      f"demo {len(demo_mid)}B MID / {len(demo_snm)}B SNM, "
      f"{used} bytes used, {free} free")
