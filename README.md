# snes86 — 8086 PC emulator for the SNES

Boot a real x86 OS on a stock SNES by emulating an 8086 in 65C816 assembly.
See `docs/PROJECT.md` for the full project brief, constraints and milestones.

## Layout

```
core-c/          M3: reference 8086 core in portable C (runs on the host).
                 Correctness oracle for the later 65816 port; validated
                 against the SingleStepTests 8088 v2 hardware-captured
                 vectors, then used to boot DOS on the desktop (runpc).
  src/           x86.h / x86.c — the core; runpc.c — HLE-BIOS DOS harness
  tests/         vector runner (Python + ctypes) and downloaded vectors
snes/            M1: mode-5 64x28 text console as a standalone SNES ROM
                 (WLA-DX asm). `make` builds build/console.sfc; `make run`
                 opens it in Mesen; test/run_test.sh does a headless
                 screenshot check. START types "dir" (canned listing —
                 real DOS output arrives at M6).
disks/           guest disk images (gitignored)
docs/            project brief, design notes
```

## Status

- **core-c passes 3,007,000/3,007,000 tests** (all 323 files) of the
  SingleStepTests 8088 v2 suite, including undocumented opcodes (SETMO,
  SALC, aliases), the REP-IDIV sign quirk, microcode-exact divide-error
  flags, and the 8088 DAA/AAA hardware quirks.
- **PC DOS 2.00 boots to a working `A>` prompt** under `runpc` (the HLE
  BIOS harness): DIR, VER, CHKDSK all work. With 96 KB guest RAM (the
  stock-SNES budget) CHKDSK reports 73,616 bytes free.
- **M3.5 measured: 63,162 guest instructions** from boot sector to the
  first DOS prompt, reading 129 disk sectors. SNES projection @3.58 MHz
  (100-300 native instructions per guest instruction, disk I/O via DMA
  block copies): **DOS prompt in roughly 10-30 seconds.**
- **M1 done: the SNES console ROM works** (verified in Mesen2 headless —
  see snes/test/m1_banner.png, m1_dir.png). Mode-5 hi-res 64x28 text via
  BG1/BG2 column interleave: char writes are single tilemap writes,
  scrolling is a scroll-register ring, all VRAM traffic queued through
  NMI. START "types" dir and prints the canned PC DOS 2.00 listing.
- **M4 done: the 65816 CPU core skeleton runs real 8086 code** —
  `snes/cpu.asm` (~140 opcodes: MOV/ALU/INC/DEC/PUSH/POP/Jcc/JMP/TEST/
  XCHG/LEA/flag ops) with lazy flags and cached segment bases, verified
  by lockstep parity: `snes/test/parity.sh` diffs all 14 guest registers
  against the C core after every instruction. 20+ random streams x 2000
  instructions: zero divergence.
- Next (M5): remaining opcode groups (string ops, shifts/rotates,
  MUL/DIV, CALL/RET/INT, prefixes, MOV sreg), $7F memory spill, then
  BIOS shims wiring the core to the M1 console.

## core-c quickstart

```
cd core-c
make                  # builds build/libem86.dylib + build/runpc
tests/vectors/fetch.sh   # one-time, ~760 MB of test vectors
make test             # full vector sweep (multiprocess)
python3 tests/run_vectors.py --files 00 F6.4 --fails 3   # focused run

./build/runpc ../disks/pcdos200-disk1.img       # interactive DOS (quit: Ctrl-])
printf '\r\rdir\r' | ./build/runpc ../disks/pcdos200-disk1.img   # scripted
./build/runpc -c ../disks/pcdos200-disk1.img    # boot-to-prompt stats (M3.5)
```

Disk images in `disks/` are gitignored: the PC DOS 2.00 image is
bring-up material only. The redistributable path for the SNES ROM is
MS-DOS 2.0 from Microsoft's MIT-licensed repo (`v2.0/bin/MSDOS.SYS` +
`COMMAND.COM` are real binaries there) plus our own IO.SYS written
against `v2.0/source/SKELIO.ASM`, the official OEM porting skeleton.

## Provenance / credits

- Test vectors: [SingleStepTests/8088](https://github.com/SingleStepTests/8088)
  v2 by Daniel Balsom (MartyPC), captured from a real AMD D8088.
- The microcode division routines (CORD/PREIDIV/POSTIDIV/NEGATE) and the
  undefined-flag behavior of the BCD instructions in `core-c/src/x86.c` are
  ported from [MartyPC](https://github.com/dbalsom/martypc)
  (MIT License, Copyright 2022-2026 Daniel Balsom), which in turn derives
  from reenigne's 8086 microcode disassembly.
- Inspired by Daniel Palmer's LinuxMD (Linux on the Mega Drive).
