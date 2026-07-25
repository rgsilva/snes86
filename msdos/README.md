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
(cd ../snes && make msdos OVERLAYS=../disks/appmatrix)  # + the local app fixture (dev only)
```

`make msdos` is the public build: MS-DOS 2.0 + the free C: (see
`snes/tools/mkhd_free.py`). A: comes from `build/msdos_a.img` (this
`msdos.img`); its `AUTOEXEC.BAT` content lives in `autoexec.bat` here —
the C: packer ships a byte-identical copy, because COMMAND.COM resumes
batch files BY BYTE OFFSET across the drive change. `CONFIG.SYS` (one
generated line: `SHELL=A:\COMMAND.COM A:\ /P`) pins COMMAND.COM's
transient-reload path to A: — without it DOS 2.0 reloads from the
*default* drive, so any program big enough to stomp the transient (SCC)
exiting with B: or C: current would wedge on "Insert COMMAND.COM disk"
with no disk to swap. `bin/` holds the
MIT MS-DOS 2.0 utilities that ship as `C:\DOS` (provenance below).
PC-DOS is retained only behind `.IFDEF PCDOS` in `dosboot.asm` (no
build target).

## Status

- ✅ Boots to `A>`/`C:\>`, VER/DIR work, on runpc **and** the SNES.
- ✅ 3-unit disk driver (A: floppy, B: SRAM floppy, C: hard disk) — the C: app
  library is reachable; `AUTOEXEC.BAT` sets PATH + drops to C:.
- ✅ Reproducible ROM: `make msdos` (public, free C:); OVERLAYS= for extras.
- ✅ App matrix re-run under MS-DOS on the SNES: GW-BASIC 3.23, WordStar 3.31,
  Multiplan, Zork/Infocom, Sokoban (CGA), CPUBENCH all load & run. Rogue needs
  ~120 KB (BIGMEM) — a memory-size edge, not an MS-DOS regression (MS-DOS
  leaves *more* free than PC-DOS: our IO.SYS is smaller than IBMBIO).

## The C:\DOS utilities (msdos/bin)

Original Microsoft binaries from the MIT-licensed MS-DOS source release,
fetched from https://github.com/microsoft/MS-DOS (`v2.0/bin/`), same
provenance as our `LINK.EXE`/`MASM.EXE`/`MSDOS.SYS`/`COMMAND.COM`
(license: `msdos/MSDOS-LICENSE`).

| file | sha256 | verified on snes86 |
|---|---|---|
| CHKDSK.COM | 75be6db096873aed6525e71dcacfe81a56ba038699600d5f203bb40d6a308201 | ✅ reports disk + free memory |
| DEBUG.COM | cbb171acca2a5581d926b6782aebeaad49111ecd359e64cf6f2e5dd0a000b4ca | ✅ dump/quit |
| EDLIN.COM | 799767e5bc6727fd3fb1b0c54a2099c5c53d46dcab5b7b5012b688f3c718b444 | ✅ runs; needs a writable drive (B: — C: is cartridge ROM) |
| FIND.EXE | d57bab73ba6a77be1aa8d2d3f1fd7d1d6ce6d459b2ab067d26cf63228e940198 | ✅ |
| MORE.COM | 56830889fef22d56ef5938df0394bf30a8416cc06225b8dc35adc74bb13416b7 | ✅ via `<` redirection (DOS 2.0 pipes want a writable temp file; C: is ROM) |
| SORT.EXE | f2135e16cd1ebff6233b4d01fcb7f73b311a1f5524ddca21056248b29fa015b8 | ✅ via `<` redirection |

Note: MODE.COM is not here — it was an IBM PC-DOS utility, absent from
Microsoft's OEM release, so the 40/80-column suite leg (`t_m40`) runs on
the apps fixture, which carries the PC-DOS copy locally.
