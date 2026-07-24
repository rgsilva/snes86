# MS-DOS 2.0 for snes86 (the free base OS)

This directory boots the **MIT-licensed** Microsoft MS-DOS 2.0
(github.com/microsoft/MS-DOS) on the snes86 machine, replacing the
copyrighted IBM PC-DOS 2.00 used during bring-up. MS-DOS 2.0 boots to `A>`
and runs on both the host emulator (`runpc`) and the SNES.

## Pieces

| file | what it is |
|---|---|
| `io.asm` | our hand-written **IBM-PC IO.SYS** — the machine-dependent half of MS-DOS 2.0. The MIT repo ships no IO.SYS (its `SKELIO.ASM` skeleton targets the Altos ACS-86C), so this implements the MS-DOS 2.0 device-driver ABI (CON/AUX/PRN/CLOCK/DISK) against our HLE BIOS (INT 10h/13h/16h/1Ah/12h). Links with the MIT `SYSINIT.OBJ`. |
| `boot.asm` | boot sector: loads IO.SYS → 0060:0000 and MSDOS.SYS → 0260:0000, jumps to IO.SYS. |
| `mkmsdos.py` | builds the 360 KB FAT12 boot floppy `msdos.img` (IO.SYS + MSDOS.SYS + COMMAND.COM), generates `bootparams.inc`, assembles the boot sector. |
| `build_io.sh` | builds `IO.SYS` (see below). |
| `MSDOS.SYS`, `COMMAND.COM` | MIT, from the microsoft/MS-DOS v2.0 release (the free OS). |
| `SYSINIT.OBJ`, `SYSIMES.OBJ` | MIT, linked into IO.SYS. |
| `LINK.EXE`, `EXE2BIN.EXE` | MIT, the original 1982 Microsoft tools — used *under our own runpc* to link IO.SYS. |
| `MSDOS-LICENSE` | the MIT license for all of the above Microsoft files. |

## Toolchain (self-hosted — the emulator builds its own OS)

Modern assemblers can't fully handle the 1982 sources/objects (jwlink
rejects the old OMF; JWasm chokes on `DOSMAC.ASM`'s old macros). So:

- **JWasm** ≥ 2.x (built locally from source: `github.com/JWasm/JWasm`, placed
  here as `./jwasm` — git-ignored) assembles our `io.asm` → `io.obj`.
- The **link is self-hosted**: `build_io.sh` puts `io.obj` + the MIT
  `SYSINIT.OBJ`/`SYSIMES.OBJ` + `LINK.EXE`/`EXE2BIN.EXE` on a scratch floppy and
  runs `LINK` + `EXE2BIN` **inside `runpc`** (our own 8086 emulator), then
  extracts `IO.SYS`. EXE2BIN's "base segment" prompt is answered `60`.

## Build + run

```sh
./build_io.sh          # -> IO.SYS + msdos.img   (needs ./jwasm, ../core-c/build/runpc)
# host:
printf '\r\r\r' | ../core-c/build/runpc -m 256 msdos.img -l 60000000
# SNES ROM (reproducible; builds IO.SYS + msdos.img + the ROM):
(cd ../snes && make msdos)    # -> snes/build/msdos.sfc  (PUBLIC: free C:)
(cd ../snes && make apps)     # -> + the local app-matrix fixture (dev only)
```

`make msdos` is the public build: MS-DOS 2.0 + the free C: (see
`snes/tools/mkhd_free.py`). A: comes from `build/msdos_a.img` (this
`msdos.img`); its `AUTOEXEC.BAT` content lives in `autoexec.bat` here —
the C: packer ships a byte-identical copy, because COMMAND.COM resumes
batch files BY BYTE OFFSET across the drive change. `bin/` holds the
MIT MS-DOS 2.0 utilities that ship as `C:\DOS` (see `bin/ORIGIN.md`).
PC-DOS is retained only behind `.IFDEF PCDOS` in `dosboot.asm` (no
build target).

## Status

- ✅ Boots to `A>`/`C:\>`, VER/DIR work, on runpc **and** the SNES.
- ✅ 3-unit disk driver (A: floppy, B: SRAM floppy, C: hard disk) — the C: app
  library is reachable; `AUTOEXEC.BAT` sets PATH + drops to C:.
- ✅ Reproducible ROM: `make msdos` (public, free C:) / `make apps` (+ fixture).
- ✅ App matrix re-run under MS-DOS on the SNES: GW-BASIC 3.23, WordStar 3.31,
  Multiplan, Zork/Infocom, Sokoban (CGA), CPUBENCH all load & run. Rogue needs
  ~120 KB (BIGMEM) — a memory-size edge, not an MS-DOS regression (MS-DOS
  leaves *more* free than PC-DOS: our IO.SYS is smaller than IBMBIO).
