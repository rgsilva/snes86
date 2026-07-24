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
make msdos        # -> build/msdos.sfc   (the public build; flash this)
```

`build/msdos.sfc` boots MS-DOS 2.0 to `C:\>`. Load it in Mesen (`make run` opens
the console demo; to run the DOS ROM point Mesen at `build/msdos.sfc`) or flash it
to a cart.

### Build targets

Every target boots the same 8086 core + HLE BIOS; they differ in what's on the C:
drive, and two of them change the memory size or what boots at all.

| target | output | C: drive | needs local (uncommitted) files? |
|---|---|---|---|
| `make msdos` | `build/msdos.sfc` | free — our tools + a demo | no — builds from the repo |
| `make freedos` | `build/freedos.sfc` | free (same as `msdos`) | no — FreeDOS auto-fetched |
| `make elks` | `build/elks.sfc` | — (boots Linux, not DOS) | no — ELKS images auto-fetched |
| `make dev` | `build/msdos_dev.sfc` | the full local app library | yes — your `disks/` software |
| `make big` | `build/msdos_big.sfc` | full library, 172 KB guest | yes |
| `make fs` | `build/dosboot_fs.sfc` | — (self-booting disk) | yes — the FS1 image |

What each one actually is:

- `make elks` — Linux on the SNES: boots [ELKS](https://github.com/ghaerr/elks)
  0.9.1 to a root shell on the 172 KB BIGMEM machine, with the kernel and userland
  executing in place from cartridge ROM. The kernel/ROMFS images are fetched from
  the official ELKS release by `test/fetch_elks.sh` on first build (GPL software —
  fetched, never committed, like the CPU test vectors); a custom-built ELKS can be
  copied over `build/elks_rom.bin` / `build/elks_romfs.bin` and wins. See
  [INTERNALS.md](INTERNALS.md#booting-linux-the-elks-machine) and
  [COMPATIBILITY.md](COMPATIBILITY.md#linux-on-the-snes-elks).
- `make msdos` — the public ROM (this is the one you flash). Its C: is built by
  `tools/mkhd_free.py` from committed, freely-redistributable files only: our
  MIDPLAY / MIDCONV MIDI tools, the SOKOBAN game, the VIEW picture viewer, the JAVA class-file interpreter (`C:\JAVA`),
  (with a generated CC0 test card in `C:\PICS`), and the SIEVE / HELLO /
  CGATEST / CGA6TST benchmarks (with source), plus a generated CC0 demo tune and
  `PLAY.BAT`. Anything you drop in `snes/userware/` is added under `C:\USER`.
  Builds with nothing but what's in this repo.

- `make freedos` — the same machine on the 172 KB BIGMEM base, booting
  [FreeDOS](https://www.freedos.org/) 1.3 to FreeCOM instead of MS-DOS.
  `freedos/mkfreedos.py` fetches the official FreeDOS 1.3 Floppy Edition on
  first build (GPL — fetched with a pinned sha256, cached in `freedos/cache/`,
  never committed) and assembles a minimal 360 KB boot floppy from it; the C:
  is the same free image as `make msdos`. FreeDOS needs the full 172 KB — the
  kernel dies during init at 108 KB — so there is no non-BIGMEM variant, and
  BIGMEM's B: drive is absent by design. See [freedos/README.md](../freedos/README.md).

- `make dev` — the same machine with the *full* C: (`tools/mkhd.py`): the complete
  local library used for compatibility testing (GW-BASIC, WordStar, Multiplan, the
  Infocom games, and so on). Those programs are copyrighted and are **not** in the
  repo — `mkhd.py` reads them straight out of your local `disks/` folder, so this
  target only builds on a machine that already has them. This is the day-to-day
  development ROM.

- `make big` — `dev` plus BIGMEM: the guest grows from ~108 KB to 172 KB by backing
  the extra conventional RAM with cartridge SRAM, which revives the memory-hungry
  Rogue. Same full C: as `dev`. It's an experiment —
  see BIGMEM in [INTERNALS.md](INTERNALS.md) and [FUTURE.md](FUTURE.md).

- `make fs` — boots the Microsoft Flight Simulator 1 self-booting disk directly
  instead of MS-DOS (FS1 skipped DOS and drove the hardware itself). Not a DOS
  program at all; a separate experiment. Needs the FS1 disk image locally.

Only `make msdos` builds from committed, freely-redistributable files; the rest
pull in software that lives only on a developer's machine (see
[COMPATIBILITY.md](COMPATIBILITY.md)). PC-DOS is no longer a build target; the code
path survives behind `.IFDEF PCDOS` in `dosboot.asm` but nothing builds it.

## Bring your own software

The public C: drive is deliberately small. To add your own DOS programs:

1. Drop `.COM` / `.EXE` files (and any data they need) into `snes/userware/`.
2. `make msdos` again.

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
is committed to the repo; `make msdos` just copies it. Rebuild it and commit the new
image whenever you change `io.asm`. See [msdos/README.md](../msdos/README.md) for the full
story.

## Testing

```sh
# 8086 core correctness (C reference vs SingleStepTests 8088 v2 vectors)
cd core-c && make && tests/vectors/fetch.sh   # one-time, ~760 MB of vectors
make test

# 65C816 core vs the C core, in lockstep, all 14 registers per instruction
cd snes && ./test/parity.sh                   # [seed] [count], default 1 1200

# end-to-end regression suite in Mesen (headless): MS-DOS boot + the app
# matrix + ELKS boot-to-login, plus parity and the runpc host smokes
cd snes && ./test/suite.sh          # ./test/suite.sh quick for the short loop
```

`runpc` also runs the guests on your desktop directly — handy for reproducing a
guest issue without the SNES layer:

```sh
printf '\r\r\r' | core-c/build/runpc -m 256 msdos/msdos.img    # boot MS-DOS

cd snes && make elks    # fetches the ELKS images on first run, then:
printf 'root\r' | ../core-c/build/runpc -m 172 -l 150000000 -kdelay 3000000 \
  -rom build/elks_rom.bin@e000 -rom build/elks_romfs.bin@8000 \
  -entry e000:0014                       # boot Linux, log in as root
```

(The `-l` bound matters for piped runs: an idle ELKS sits in HLT forever, unlike
DOS, which exits at the first key wait once stdin is drained. Run it without a
pipe for an interactive session — quit with Ctrl-].)

See [INTERNALS.md](INTERNALS.md) for what `runpc` is and how parity testing works.
