# snes86

Run an IBM PC — MS-DOS and all — on a stock, unmodified SNES.

snes86 is an 8086 PC emulator written from scratch in 65C816 assembly. It boots
real MS-DOS 2.0 from a ROM "disk", renders CGA/MDA text and graphics, turns the
SNES sound chip into a MIDI synth, and runs period DOS software. It ships as a
single flashable `.sfc` — no special cartridge chip, no expansion hardware, just a
Super Nintendo.

<p align="center">
  <img src="docs/assets/boot.png" width="480" alt="MS-DOS 2.0 booting on snes86"><br>
  <sub>MS-DOS 2.0 booting on a stock SNES. More in <a href="docs/COMPATIBILITY.md">COMPATIBILITY.md</a>.</sub>
</p>

## Wait, what?

A Super Nintendo's CPU is a 16-bit 65C816 running around 3.5 MHz. snes86 makes it
impersonate an Intel 8086:

- a threaded-dispatch 8086 interpreter with a lazy-flags model — the guest register
  file lives in the 65C816 direct page, and 8086 FLAGS are only materialized when
  something actually reads them;
- an HLE BIOS — video, disk, keyboard and timer interrupts (INT 10h/11h/12h/13h/16h/
  1Ah) are serviced natively in 65C816 instead of by guest ROM code;
- a 24-bit guest memory model mapped into SNES WRAM, giving DOS ~108 KB;
- booting MIT-licensed MS-DOS 2.0, via an `IO.SYS` we wrote from scratch (Microsoft's
  release ships none for the IBM PC).

See [docs/INTERNALS.md](docs/INTERNALS.md) for how it all actually works — including
the C reference core, the `runpc` host emulator, and the CPU parity harness that
keeps the two implementations honest.

## How do we know it's correct?

The same 8086 core exists twice: once in portable C (`core-c/`) and once in 65C816
assembly (`snes/cpu.asm`). Both are held to the same standard:

- The C core passes 3,007,000 / 3,007,000 of the
  [SingleStepTests 8088 v2](https://github.com/SingleStepTests/8088) vectors — all
  323 opcode files, including undocumented opcodes, the REP-IDIV sign quirk,
  microcode-exact divide-error flags, and the 8088 DAA/AAA hardware quirks.
- The 65C816 core is diffed against the C core in lockstep: `test/parity.sh` runs
  random 8086 instruction streams through both and compares all 14 guest registers
  after every instruction. 12–20+ seeds × up to 2000 instructions: zero divergence.

## Try it

Flash `snes/build/dosboot.sfc` to a flashcart, or load it in an accurate emulator
such as [Mesen](https://www.mesen.ca/). You boot straight to `C:\>`.

The public ROM ships only free software: our own snes86 tools (with Turbo Pascal
source) — a MIDI player, a Sokoban game, benchmarks — plus a generated demo tune. To
run your own DOS programs, drop them in `snes/userware/` and rebuild (see
[docs/BUILDING.md](docs/BUILDING.md)).

## Build

```sh
cd snes && make dosboot      # -> build/dosboot.sfc   (the public ROM)
```

Prerequisites, the other build targets, and the self-hosted MS-DOS toolchain are in
[docs/BUILDING.md](docs/BUILDING.md).

## Docs

| doc | what |
|---|---|
| [docs/INTERNALS.md](docs/INTERNALS.md) | how an 8086 runs on a 65C816; the HLE BIOS; runpc; CPU parity testing |
| [docs/BUILDING.md](docs/BUILDING.md) | build the ROM + add your own software |
| [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | what runs, and the SNES-as-MIDI-synth feature |
| [docs/FUTURE.md](docs/FUTURE.md) | where this could go next |
| [docs/PROJECT.md](docs/PROJECT.md) | the original design brief + constraints |

## Layout

```
snes/            the SNES ROM: 8086 core (cpu.asm/cpu2.asm), HLE BIOS + machine
                 (dosboot.asm), SPC-700 MIDI synth (spc_midi.asm), build tools.
                 `make dosboot` -> build/dosboot.sfc
core-c/          reference 8086 core in portable C; the correctness oracle and
                 the `runpc` host PC emulator (also builds our IO.SYS).
msdos/           the free MS-DOS 2.0 build: our IO.SYS, boot sector, disk builder,
                 self-hosted link toolchain.
disks/           guest disk images + our tools' sources (large blobs gitignored).
docs/            documentation + the original design brief.
```

## Status

Developed and tested against the cycle-accurate [Mesen](https://www.mesen.ca/)
emulator, where it boots MS-DOS and runs a broad library of DOS software (see
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)). Real-hardware testing is still
pending — if you flash it to a cart, we'd love a report or a video.

## Legal & credits

MS-DOS 2.0 is MIT-licensed ([microsoft/MS-DOS](https://github.com/microsoft/MS-DOS)).
The public ROM contains only freely redistributable software — no copyrighted DOS
applications. Our own tools ship with source.

- Test vectors: [SingleStepTests/8088](https://github.com/SingleStepTests/8088) v2
  by Daniel Balsom, captured from a real AMD D8088.
- The microcode division routines and the undefined-flag behavior of the BCD
  instructions in `core-c/src/x86.c` are ported from
  [MartyPC](https://github.com/dbalsom/martypc) (MIT, © 2022–2026 Daniel Balsom),
  which derives from reenigne's 8086 microcode disassembly.
- Inspired by Daniel Palmer's LinuxMD (Linux on the Mega Drive).

Built with the help of AI.
