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

| target | OS | C: drive | for |
|---|---|---|---|
| `make dosboot` | MS-DOS 2.0 (MIT) | free — our tools + a demo | the public ROM |
| `make dev` | MS-DOS 2.0 | full local library (needs your own DOS software in `disks/`) | development |
| `make big` | MS-DOS 2.0 | full, 172 KB guest RAM | BIGMEM experiment |
| `make fs` | Flight Simulator self-boot | — | experiment |

Only `make dosboot` builds from committed, freely-redistributable files. The other
targets pull in software that lives only on a developer's machine (see
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
cd msdos
./build_io.sh       # -> IO.SYS + msdos.img   (needs ./jwasm and ../core-c/build/runpc)
```

`make dosboot` invokes this automatically when `io.asm` changes. See
[msdos/README.md](../msdos/README.md) for the full story.

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
