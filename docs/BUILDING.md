# Building snes86

## Prerequisites

| tool | for | notes |
|---|---|---|
| WLA-DX (`wla-65816`, `wla-spc700`, `wlalink`) | assembling the SNES ROM | shipped with [PVSnesLib](https://github.com/alekmaul/pvsneslib); the Makefile expects it at `../../pvsneslib/devkitsnes/bin` (i.e. a `pvsneslib/` checkout next to this repo) |
| Python 3 | build-time asset generation + the test harness | standard library only — no `pip install` needed |
| a C compiler (`cc`, C11) | the `core-c` reference core + `runpc` | any clang/gcc |
| [JWasm](https://github.com/JWasm/JWasm) | rebuilding the MS-DOS `IO.SYS` | only if you change `msdos/io.asm`; build it and symlink as `msdos/jwasm` (see [MS-DOS toolchain](#the-ms-dos-toolchain-self-hosted)) |
| [Mesen](https://www.mesen.ca/) | running/testing the ROM | any accurate SNES emulator works; the test scripts drive Mesen |

## The ROM

```sh
cd snes
make dosboot        # -> build/dosboot.sfc   (the public build; flash this)
```

`build/dosboot.sfc` boots MS-DOS 2.0 to `C:\>`. Load it in Mesen (`make run` opens
the console demo; to run the DOS ROM point Mesen at `build/dosboot.sfc`) or flash it
to a cart.

### Build targets

Every target boots the same 8086 core + HLE BIOS; they differ in what's on the C:
drive, and two of them change the memory size or what boots at all.

| target | output | C: drive | needs local (uncommitted) files? |
|---|---|---|---|
| `make dosboot` | `build/dosboot.sfc` | free — our tools + a demo | no — builds from the repo |
| `make dev` | `build/dosboot_dev.sfc` | the full local app library | yes — your `disks/` software |
| `make big` | `build/dosboot_big.sfc` | full library, 172 KB guest | yes |
| `make fs` | `build/dosboot_fs.sfc` | — (self-booting disk) | yes — the FS1 image |

What each one actually is:

- `make dosboot` — the public ROM (this is the one you flash). Its C: is built by
  `tools/mkhd_free.py` from committed, freely-redistributable files only: our
  MIDPLAY / MIDCONV MIDI tools, the SOKOBAN game, and the SIEVE / HELLO / CGATEST
  benchmarks (all with Turbo Pascal source), plus a generated CC0 demo tune and
  `PLAY.BAT`. Anything you drop in `snes/userware/` is added under `C:\USER`.
  Builds with nothing but what's in this repo.

- `make dev` — the same machine with the *full* C: (`tools/mkhd.py`): the complete
  local library used for compatibility testing (GW-BASIC, WordStar, Multiplan, the
  Infocom games, and so on). Those programs are copyrighted and are **not** in the
  repo — `mkhd.py` reads them straight out of your local `disks/` folder, so this
  target only builds on a machine that already has them. This is the day-to-day
  development ROM.

- `make big` — `dev` plus BIGMEM: the guest grows from ~108 KB to 172 KB by backing
  the extra conventional RAM with cartridge SRAM, which revives the memory-hungry
  titles (Rogue, Elite, Starglider). Same full C: as `dev`. It's an experiment —
  see BIGMEM in [INTERNALS.md](INTERNALS.md) and [FUTURE.md](FUTURE.md).

- `make fs` — boots the Microsoft Flight Simulator 1 self-booting disk directly
  instead of MS-DOS (FS1 skipped DOS and drove the hardware itself). Not a DOS
  program at all; a separate experiment. Needs the FS1 disk image locally.

Only `make dosboot` builds from committed, freely-redistributable files; the rest
pull in software that lives only on a developer's machine (see
[COMPATIBILITY.md](COMPATIBILITY.md)). PC-DOS is no longer a build target; the code
path survives behind `.IFDEF PCDOS` in `dosboot.asm` but nothing builds it.

## Bring your own software

The public C: drive is deliberately small. To add your own DOS programs:

1. Drop `.COM` / `.EXE` files (and any data they need) into `snes/userware/`.
2. `make dosboot` again.

They land in `C:\USER`, which is on the DOS `PATH`, so you can run them from
anywhere at the `C:\>` prompt. The contents of `userware/` are git-ignored, so your
software never ends up in the repo.

Under the hood the free C: image is built by `snes/tools/mkhd_free.py`; the demo
tune (a public-domain melody sequenced as a CC0 MIDI + its `.SNM` conversion) is
generated at build time.

## The MS-DOS toolchain (self-hosted)

The MS-DOS boot floppy is the interesting part: the emulator builds its own OS.

Microsoft's MIT MS-DOS 2.0 release ships `MSDOS.SYS` + `COMMAND.COM` but no
`IO.SYS` for the IBM PC (its `SKELIO.ASM` skeleton targets a different machine), so
we wrote one — `msdos/io.asm` — implementing the MS-DOS device-driver ABI against
our HLE BIOS. Modern linkers can't consume the 1982 object files, so the link is
done inside `runpc` (our own 8086 emulator) using the original Microsoft
`LINK.EXE` + `EXE2BIN.EXE`:

```sh
cd msdos && ./build_io.sh      # or:  make -C snes io   (-> msdos/IO.SYS + msdos.img)
```

This needs `msdos/jwasm`, `core-c/build/runpc`, and a local DOS host image to boot the
linker — so it's a developer step, not part of the public build. Its output
`msdos/msdos.img` is a free floppy (our `IO.SYS` + the MIT `MSDOS.SYS`/`COMMAND.COM`) and
is committed to the repo; `make dosboot` just copies it. Rebuild it and commit the new
image whenever you change `io.asm`. See [msdos/README.md](../msdos/README.md) for the full
story.

## Testing

```sh
# 8086 core correctness (C reference vs SingleStepTests 8088 v2 vectors)
cd core-c && make && tests/vectors/fetch.sh   # one-time, ~760 MB of vectors
make test

# 65C816 core vs the C core, in lockstep, all 14 registers per instruction
cd snes && ./test/parity.sh                   # [seed] [count], default 1 1200

# end-to-end boot + app smoke tests in Mesen (headless)
cd snes && ./test/suite.sh
```

`runpc` also runs DOS on your desktop directly — handy for reproducing a guest
issue without the SNES layer:

```sh
printf '\r\r\r' | core-c/build/runpc -m 256 msdos/msdos.img    # boot MS-DOS
```

See [INTERNALS.md](INTERNALS.md) for what `runpc` is and how parity testing works.
