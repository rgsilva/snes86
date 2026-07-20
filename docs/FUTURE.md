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
