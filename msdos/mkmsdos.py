#!/usr/bin/env python3
"""Build a 360 KB FAT12 MS-DOS 2.0 boot floppy for snes86.

Lays down our IO.SYS + the MIT MSDOS.SYS + COMMAND.COM, generates
bootparams.inc, assembles boot.asm with JWasm, and writes msdos.img.
IO.SYS is cluster 2 (contiguous) as the boot sector requires; MSDOS.SYS
follows contiguously so the boot sector can load it by sector run.
"""
import os
import struct
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
JWASM = os.path.join(HERE, "jwasm")

# FAT12 geometry: 360 KB, 2 sec/clus, 2 FATs x 2 sec, 112 root entries
SPC, SFAT, ROOTN, TOTAL = 2, 2, 112, 720
RS = ROOTN * 32 // 512              # root dir sectors (7)
DATA = 1 + 2 * SFAT + RS            # first data sector (cluster 2) = 12


def secs(data):
    return (len(data) + 511) // 512


def clus(data):
    s = secs(data)
    return (s + SPC - 1) // SPC


def main():
    io = open(os.path.join(HERE, "IO.SYS"), "rb").read()
    dos = open(os.path.join(HERE, "MSDOS.SYS"), "rb").read()
    cmd = open(os.path.join(HERE, "COMMAND.COM"), "rb").read()

    # AUTOEXEC.BAT: its mere presence skips the DOS 2.0 date/time prompt;
    # it sets the PATH and drops to C:. The content lives in autoexec.bat
    # (single source of truth): the C: packer ships a byte-identical copy,
    # because COMMAND.COM resumes batch processing BY BYTE OFFSET across
    # the drive change — a C: copy longer than A:'s resumes into garbage.
    autoexec = open(os.path.join(HERE, "autoexec.bat"), "rb").read()

    # CONFIG.SYS: the SHELL line's "A:\" argument becomes COMMAND.COM's
    # FCB1 drive byte, which is all DOS 2.0 INIT reads from it (COMDRV) —
    # it pins the transient-reload path to A:\COMMAND.COM. Without it,
    # COMDRV is 0 = "default drive": any program big enough to stomp the
    # transient (SCC) then exiting with B: or C: current wedges the
    # machine on "Insert COMMAND.COM disk in default drive" — B: and C:
    # carry no COMMAND.COM and the SNES has no disk to swap in.
    config = b"SHELL=A:\\COMMAND.COM A:\\ /P\r\n"

    files = [("IO.SYS", io, 0x27), ("MSDOS.SYS", dos, 0x27),
             ("COMMAND.COM", cmd, 0x00),
             ("CONFIG.SYS", config, 0x00),
             ("AUTOEXEC.BAT", autoexec, 0x00)]

    # allocate clusters sequentially from 2
    img = bytearray(TOTAL * 512)
    fat = bytearray(SFAT * 512)

    def setfat(n, v):
        o = n + n // 2
        if n & 1:
            fat[o] = (fat[o] & 0x0F) | ((v & 0xF) << 4)
            fat[o + 1] = (v >> 4) & 0xFF
        else:
            fat[o] = v & 0xFF
            fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    setfat(0, 0xFFD)
    setfat(1, 0xFFF)

    root = bytearray(RS * 512)
    layout = {}                     # name -> (start_cluster, start_sector, n_sectors)
    nclust = (TOTAL - DATA) // SPC  # data clusters (indices 2..nclust+1)
    nextc = 2
    for i, (nm, data, attr) in enumerate(files):
        nc = clus(data)
        start = nextc
        # writing past the disk/root would silently APPEND to the bytearray
        # (slice-assign past the end grows it) — fail loudly instead
        assert start - 2 + nc <= nclust, (
            f"msdos.img full: {nm} needs {nc} clusters, "
            f"only {nclust - (start - 2)} of {nclust} free")
        assert i < ROOTN, f"root dir full ({ROOTN} entries) at {nm}"
        for j in range(nc):
            c = start + j
            setfat(c, (c + 1) if j < nc - 1 else 0xFFF)
        sect = DATA + (start - 2) * SPC
        img[sect * 512:sect * 512 + len(data)] = data
        layout[nm] = (start, sect, secs(data))
        # directory entry
        base, ext = (nm.split(".") + [""])[:2]
        e = root[i * 32:i * 32 + 32]
        e = bytearray(32)
        e[0:8] = base.ljust(8).encode()
        e[8:11] = ext.ljust(3).encode()
        e[11] = attr
        struct.pack_into("<H", e, 26, start)
        struct.pack_into("<I", e, 28, len(data))
        root[i * 32:i * 32 + 32] = e
        nextc += nc

    # boot parameters
    io_lba, io_secs = layout["IO.SYS"][1], layout["IO.SYS"][2]
    dos_lba, dos_secs = layout["MSDOS.SYS"][1], layout["MSDOS.SYS"][2]
    inc = os.path.join(HERE, "bootparams.inc")
    with open(inc, "w") as f:
        f.write("IO_LBA   EQU %d\n" % io_lba)
        f.write("IO_SECS  EQU %d\n" % io_secs)
        f.write("DOS_LBA  EQU %d\n" % dos_lba)
        f.write("DOS_SECS EQU %d\n" % dos_secs)
    print("boot params: IO@%d(%d) DOS@%d(%d)" %
          (io_lba, io_secs, dos_lba, dos_secs))

    # assemble the boot sector
    binout = os.path.join(HERE, "boot.bin")
    subprocess.run([JWASM, "-bin", "-Fo=" + binout,
                    os.path.join(HERE, "boot.asm")], check=True, cwd=HERE)
    boot = open(binout, "rb").read()
    # JWasm ORG 7C00h emits from 0 with padding; take the sector at 7C00
    if len(boot) >= 0x7E00:
        boot = boot[0x7C00:0x7E00]
    boot = (boot + b"\x00" * 512)[:512]
    boot = bytearray(boot)
    boot[510:512] = b"\x55\xAA"

    # assemble the image: FAT1 at sector 1, FAT2 at sector 1+SFAT
    img[0:512] = boot
    img[1 * 512:1 * 512 + len(fat)] = fat
    img[(1 + SFAT) * 512:(1 + SFAT) * 512 + len(fat)] = fat
    img[(1 + 2 * SFAT) * 512:(1 + 2 * SFAT) * 512 + len(root)] = root

    out = os.path.join(HERE, "msdos.img")
    open(out, "wb").write(img)
    print("wrote", out, len(img), "bytes")


if __name__ == "__main__":
    main()
