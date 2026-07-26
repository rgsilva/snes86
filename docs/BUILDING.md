# Building snes86

## Prerequisites

| tool | for | notes |
|---|---|---|
| WLA-DX (`wla-65816`, `wla-spc700`, `wlalink`) | assembling the SNES ROM | shipped with [PVSnesLib](https://github.com/alekmaul/pvsneslib); the Makefile expects it at `../../pvsneslib/devkitsnes/bin` (i.e. a `pvsneslib/` checkout next to this repo) |
| Python 3 | build-time asset generation + the test harness | standard library only — no `pip install` needed |
| a C compiler (`cc`, C11) | the `core-c` reference core + `runpc` | any clang/gcc |
| [JWasm](https://github.com/JWasm/JWasm) | rebuilding the MS-DOS `IO.SYS` | only if you change `msdos/io.asm`; build it and symlink as `msdos/jwasm` (see [MS-DOS toolchain](#the-ms-dos-toolchain-self-hosted)) |
| nasm + [RGBDS](https://rgbds.gbdev.io/) | rebuilding `GB.COM` + its homebrew carts (`apps/gb`) | only for `make apps` / `make recompile` there — the committed binaries stage without them (`brew install nasm rgbds`) |
| [Mesen](https://www.mesen.ca/) | running/testing the ROM | any accurate SNES emulator works; the test scripts drive Mesen |

## The ROM

```sh
make              # -> snes/build/msdos.sfc   (the public build; flash this)
```

Everything builds from the repo root (the root `Makefile` delegates to
`snes/`, `core-c/` and `apps/`). `snes/build/msdos.sfc` boots MS-DOS 2.0
to `C:\>`. Load it in Mesen (`make -C snes run` opens the console demo; to
run the DOS ROM point Mesen at `snes/build/msdos.sfc`) or flash it to a cart.

### Build targets

Every ROM target boots the same 8086 core + HLE BIOS; they differ in what's
on the C: drive, the memory size, or what boots at all. Outputs land in
`snes/build/`.

| target | output | what | needs local (uncommitted) files? |
|---|---|---|---|
| `make` / `make msdos` | `msdos.sfc` | MS-DOS 2.0, free C: | no — TP3 auto-fetched (compiles the apps) |
| `make freedos` | `freedos.sfc` | FreeDOS 1.3, 172 KB guest | no — FreeDOS auto-fetched |
| `make elks` | `elks.sfc` | ELKS (Linux), no DOS | no — ELKS images auto-fetched |
| `make msdos_big` | `msdos_big.sfc` | MS-DOS, 172 KB guest | no — TP3 auto-fetched |
| `make boot DISK=img` | `boot.sfc` | a self-booting disk, no DOS | the disk image |
| `make test` | — | the public suite | no (Mesen legs skip without Mesen) |
| `make test-extra` | — | the copyrighted app legs | yes — a complete `disks/` |
| `make apps` | — | force-rebuild every tool + verify | no |

**OVERLAYS** is a uniform optional flag on every DOS-booting target
(`msdos`, `msdos_big`, `freedos`, `boot`):
`make msdos OVERLAYS="path/to/dir path/to/floppy.img"` merges each
overlay's tree onto the free C: (last wins, with a warning) and writes
`snes/build/msdos_overlay.sfc` — an overlay build never clobbers the
clean artifact, and nothing copyrighted is ever baked into a default
build.

What each one actually is:

- `make elks` — Linux on the SNES: boots [ELKS](https://github.com/ghaerr/elks)
  0.9.1 to a root shell on the 172 KB BIGMEM machine, with the kernel and userland
  executing in place from cartridge ROM. The kernel/ROMFS images are fetched from
  the official ELKS release by `test/fetch_elks.sh` on first build (GPL software —
  fetched, never committed, like the CPU test vectors); a custom-built ELKS can be
  copied over `build/elks_rom.bin` / `build/elks_romfs.bin` and wins. See
  [INTERNALS](INTERNALS.md#booting-linux-the-elks-machine) and
  [COMPATIBILITY](COMPATIBILITY.md#linux-on-the-snes-elks).
- `make msdos` — the public ROM (this is the one you flash). Its C: is
  assembled by convention (`tools/mkhd_free.py`): every staged
  `apps/<tool>/build/` becomes `C:\<TOOL>` (MIDI, BENCH, SOKOBAN,
  VIEW, TED, JAVA, and the Small-C toolchain as `C:\CC` — see
  [apps/README](../apps/README.md)), `msdos/bin/` (the MIT MS-DOS
  utilities: CHKDSK, DEBUG, EDLIN, MORE, FIND, SORT) becomes `C:\DOS`,
  and `user/` at the repo root becomes
  `C:\USER`. The DOS `PATH` is `C:\;C:\DOS;C:\TED;C:\CC` — everything else
  is a `CD` away.

  **No app binaries are committed** — the build compiles every one of
  them from source, on the emulated machine itself: the Turbo Pascal
  tools (VIEW, TED, SOKOBAN, MIDPLAY/MIDCONV, SIEVE/HELLO, JAVA.COM)
  via `apps/tpcompile.sh` (TP3's IDE driven inside `runpc`), and
  `C:\JAVA\JAVAC.EXE` from `javac.c` with the public-domain Small-C kit
  committed in `apps/cc/` (`make -C apps/java javac-dos`, see
  [docs/notes/JAVAC-PORTING](notes/JAVAC-PORTING.md)). That makes
  **Turbo Pascal 3.01A a required build dependency of the MS-DOS
  images**: `apps/fetch_tp3.py` downloads it on first build (pinned
  sha256, cached in `apps/cache/`, checked against a local
  `disks/tp301.img` first) — the same fetch-at-build stance as the
  FreeDOS and ELKS images, since Borland retains all rights and we
  never redistribute it. First `make msdos` therefore needs the
  network (or the local disk image); after that everything is cached
  and the compiles are incremental.

- `make freedos` — the same machine on the 172 KB BIGMEM base, booting
  [FreeDOS](https://www.freedos.org/) 1.3 to FreeCOM instead of MS-DOS.
  `freedos/mkfreedos.py` fetches the official FreeDOS 1.3 Floppy Edition on
  first build (GPL — fetched with a pinned sha256, cached in `freedos/cache/`,
  never committed) and assembles a minimal 360 KB boot floppy from it; the C:
  is the same free image as `make msdos`. FreeDOS needs the full 172 KB — the
  kernel dies during init at 108 KB — so there is no non-BIGMEM variant, and
  BIGMEM's B: drive is absent by design. See [freedos/README](../freedos/README.md).

- `make msdos_big` — BIGMEM: the guest grows from ~108 KB to 172 KB by
  backing the extra conventional RAM with cartridge SRAM, which revives
  the memory-hungry Rogue (`make msdos_big OVERLAYS=disks/appmatrix` on a
  machine that has it). Same free C: as the public build. It's an
  experiment — see BIGMEM in [INTERNALS](INTERNALS.md) and
  [FUTURE](FUTURE.md).

- `make boot DISK=path/to/disk.img` — boots a self-booting disk directly
  instead of DOS: the disk replaces the A: floppy wholesale and the BIOS
  boots its sector 0 like any other. Two geometries are wired: 160 KB
  (40x1x8) and 360 KB (40x2x9), picked by file size. The proven tenant is
  the Microsoft Flight Simulator 1 disk (`make boot DISK=disks/fs1.img` —
  FS1 skipped DOS and drove the hardware itself; needs that image
  locally).

There is no public target for the copyrighted app matrix: the suite's
`make test-extra` builds its private fixture ROM by overlaying
`disks/appmatrix/` (generated by `disks/mkappmatrix.py`;
`--check` prints the manifest of required local files) onto the public
machine via the same OVERLAYS mechanism. Nothing from it ships.

Every target above builds from committed sources or auto-fetched
software (the ELKS/FreeDOS images, Turbo Pascal 3) — no binaries of
ours are committed, and nothing fetched is ever redistributed.
PC-DOS is no longer a build target; the code path survives behind
`.IFDEF PCDOS` in `dosboot.asm` but nothing builds it.

## Bring your own software

The public C: drive is deliberately small. To add your own DOS programs:

1. Drop `.COM` / `.EXE` files (and any data they need) into `user/` at the
   repo root.
2. `make msdos` again.

They land in `C:\USER` (`CD USER` to get there). The contents of `user/`
are git-ignored, so your software never ends up in the repo. For anything
bigger, build an overlay: `make msdos OVERLAYS=path/to/your-tree`
(-> `snes/build/msdos_overlay.sfc`).

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
image whenever you change `io.asm`. See [msdos/README](../msdos/README.md) for the full
story.

## Testing

The tiers, the full leg roster and the deep cuts are documented in
[TESTING](TESTING.md).

```sh
make test          # the public suite: parity + the runpc host smokes +
                   # the Mesen end-to-end legs (MS-DOS, ELKS, FreeDOS).
                   # QUICK=1 trims to parity + boot + cga (~3 min);
                   # without Mesen (e.g. CI) the Mesen legs + parity
                   # self-skip with one loud line.
make test-extra    # ONLY the copyrighted app legs (Zork/GW-BASIC/
                   # WordStar/Multiplan/MODE) on a private fixture ROM;
                   # refuses to run unless disks/ is complete
                   # (disks/mkappmatrix.py --check lists what's needed)
make apps          # FORCE-rebuild every app from source (TP3 inside
                   # runpc; javac.exe via Small-C) and verify — VIEW by
                   # render-vs-golden bit-compare, javac.exe by
                   # byte-compare against the clang build of the same
                   # compiler source. The regular image builds already
                   # compile the apps (nothing binary is committed);
                   # this is the force-everything canary

# 8086 core correctness (C reference vs SingleStepTests 8088 v2 vectors)
cd core-c && make && tests/vectors/fetch.sh   # one-time, ~760 MB of vectors
make test

# 65C816 core vs the C core, in lockstep, all 14 registers per instruction
cd snes && ./test/parity.sh                   # [seed] [count], default 1 1200
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

See [INTERNALS](INTERNALS.md) for what `runpc` is and how parity testing works.
