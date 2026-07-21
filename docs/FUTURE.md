# Where snes86 could go next

snes86 already boots MS-DOS and runs a broad software library. This page collects
directions it could grow — some easy, some hard, some maybe impossible. These are
ideas and notes for contributors, not commitments.

## Real hardware

The single most valuable next step, and the one thing we can't do ourselves right
now. Everything has been validated in the cycle-accurate Mesen emulator; a real
SNES/Super Famicom (via a flashcart) is the real test. Specifically worth checking:

- Does `dosboot.sfc` boot to `C:\>` on hardware?
- Does the B: SRAM drive persist across power cycles (battery-backed save)?
- Is the timing right? The BIOS clock and PC-speaker/MIDI pacing come off the SNES
  frame interrupt, which is what real hardware does too — but only hardware confirms.

Reports, screenshots, and videos are genuinely wanted. See
[COMPATIBILITY.md](COMPATIBILITY.md#help-wanted).

## More guest RAM (make BIGMEM fast)

The default guest has ~108 KB. The BIGMEM build extends it to 172 KB using
cartridge SRAM, which revives memory-hungry titles (Rogue) — but
it's currently ~1.7× slower than the standard build, so it's shipped only as an
experiment (`make big`).

The slowdown is pure "correctness tax" from handling the WRAM↔SRAM address seam; the
standard build is untouched. There's a clear path to making it fast, if someone wants
it:

- Gate the per-instruction rebase behind an IP window (the big win, est.
  1.7× → ~1.2×). Today every instruction re-checks whether the code segment crosses
  the seam, even for code that provably can't. Caching the `[lo, hi)` IP range where
  the fetch pointer stays in one region, and only doing the full rebase when leaving
  it, removes ~90% of the overhead.
- Restore the chunked `REP MOVS/STOS` fast path, capped at the region boundary
  (the cap is the safety) — recovers the 7× block-move speedup BIGMEM currently
  gives up.

There's also a known correctness edge (an instruction whose *immediate* spills across
the seam) that would need seam-safe operand fetch. Start at the `lda [bCS],y` fetch
sites in `cpu.asm`/`cpu2.asm` if you reopen this.

**Starglider regression (to investigate).** Starglider ran under the earlier PC-DOS
build but stopped working after the port to MS-DOS — it now crawls (apparently stuck
in its self-unpacker) and never reaches graphics. Something the MS-DOS port changed
broke it; bisecting the PC-DOS→MS-DOS diff is the place to start.

## CPU performance

The 65C816 core is already about 1.7× faster than the first working version,
through threaded dispatch, lazy flags, table-driven ModRM decode, inlined ALU/memory
paths, and DMA disk reads. The machine runs a few hundred guest instructions per
SNES frame.

Remaining ideas have diminishing returns and rising risk:

- inline the hot ALU register-register forms further (code-size cost);
- fold the memory-pointer helper into more operand paths;
- a jump table for the BIOS `INT` dispatch (small);
- the irreducible one: instruction fetch (`lda [bCS],y`) can't get much cheaper
  without bank-crossing surgery — high risk.

Note the SNES has no SA-1/SuperFX acceleration in play here — this is a stock
cartridge, so all speed comes from the 65C816 doing the work.

## Graphics beyond CGA text

Text modes and CGA graphics (320×200×4 / 640×200×2) work today. The frontier is
VGA Mode 13h (320×200×256) — the linear framebuffer a lot of later games and
demos use. The hard part is that a 64,000-byte framebuffer at `A000:` doesn't fit
alongside 108 KB of guest RAM plus the existing adapter RAM in the SNES's 128 KB of
WRAM. Candidate approaches (none trivial): a shrunk-guest VGA variant, write-through
streaming to VRAM, or a VRAM-backed framebuffer with a WRAM window. This is its own
milestone.

## The MIDI synth

The SPC-700 currently runs an 8-voice General MIDI synth with a handful of BRR
instruments (see [INTERNALS.md](INTERNALS.md#the-snes-is-your-sound-card)). Room to
grow: richer/more accurate GM instruments, better drum mapping, and — much harder —
an OPL2/AdLib (FM) approximation for games that target port 388h instead of MIDI.

## More software and OSes

- The bring-your-own path (`userware/` → `C:\USER`) already lets anyone add their
  own DOS programs without touching the build.
- Other DOS versions, or entirely different self-booting guests (the Flight Simulator
  build already proves a non-DOS boot works via `make fs`), are open territory.

## Nested emulation (an emulator on the emulator)

An emulator running MS-DOS running *another* emulator: absurd, but a real
end-to-end stress test (CGA graphics, the 60 Hz BIOS tick, keyboard, and raw CPU
throughput, all at once). The bar sets the whole design: snes86's 8086
benchmarks at ~0.05–0.1× a real IBM XT, so anything that must emulate a
MHz-class CPU *in real time* (NES, Game Boy at speed, 8080 arcade) is hopeless.
But a single **"it booted" screenshot does not need real time** — just enough
headless minutes (or hours) to paint one frame. Under that bar:

- **CHIP-8 — greenlit, the clean win.** A ~35-opcode interpreted VM (4 KB RAM,
  64×32 mono, 60 Hz timer, one beeper), *not* a real CPU — so it runs at roughly
  authentic speed, actually *playable* rather than just screenshot-able. Write
  the interpreter in the Turbo Pascal 3 we already ship (self-hosted!) or drop a
  tiny `.COM` in `userware/`. 64×32 → CGA is trivial; the timer rides INT 1Ah/8;
  the beep hits the PC-speaker→SPC path. Pong / Brix / Tetris / Invaders. Fits
  the default 108 KB.

- **Z80MU + CP/M — greenlit, the deep-nesting stunt.** `Z80MU` was a real 1980s
  PC program that emulates a Z80 and boots CP/M: `65C816 → 8086 → Z80 → CP/M →
  WordStar-CP/M / Zork-CP/M`, quadruple nesting with period-authentic software.
  Text-only, so CGA/MDA and RAM are fine. Interactive speed is glacial (~1/100
  real Z80), so it's a "boots and runs a command" trophy, not a daily driver.

- **Game Boy — greenlit, the console trophy.** The payoff is the **Nintendo®
  boot logo** — the earliest iconic frame (a few hundred thousand cycles,
  reachable in minutes of headless run). GB has a framebuffer-style PPU (no
  beam-racing) and only 4 shades, which maps structurally clean onto CGA
  4-color (160×144 sits inside 320×200; colours come out "wrong", which is
  funnier). Cost: a from-scratch 16-bit **real-mode** SM83 core — no GB emulator
  ever ran on an 8086, and the 64 KB-segment / bank-switch dance is the fiddly
  part. Needs **BIGMEM** and no-MBC **32 KB** carts (Tetris, Dr. Mario,
  Alleyway).

Noted, but not greenlit:

- **Atari 2600 — a trap.** No framebuffer; the 6507 *races the beam*, so it needs
  cycle-exact 6507+TIA lockstep (that's why 2600 emulators wanted a 386, despite
  the machine having 128 *bytes* of RAM). Huge effort for any frame.
- **Atari 800 — a text gag at best.** Xformer proved PC-emulates-Atari-800 is
  real (but wanted a 286+); the achievable screenshot is the Atari BASIC
  `READY.` prompt. ANTIC's display list is the wall for real graphics.
- **NES — the original idea, biggest lift.** More PPU than the GB and worse CGA
  colour mapping; screenshot-only, BIGMEM, from-scratch core. If GB lands first,
  NES is "just" a bigger version of the same work.

Aside: we already nest — Infocom's Z-machine is a VM, so every Zork is
`snes86 → 8086 → Z-machine → story`. CHIP-8 just makes the inner VM graphical.
