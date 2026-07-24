# Where snes86 could go next

snes86 already boots MS-DOS and runs a broad software library. This page collects
directions it could grow — some easy, some hard, some maybe impossible. These are
ideas and notes for contributors, not commitments.

## Real hardware

The single most valuable next step, and the one thing we can't do ourselves right
now. Everything has been validated in the cycle-accurate Mesen emulator; a real
SNES/Super Famicom (via a flashcart) is the real test. Specifically worth checking:

- Does `msdos.sfc` boot to `C:\>` on hardware?
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
- One of them landed: **Linux**. `make elks` boots ELKS 0.9.1 to a root shell —
  kernel and apps executing in place from cart ROM on the BIGMEM machine (see
  [INTERNALS.md](INTERNALS.md#booting-linux-the-elks-machine)). It also gives the
  BIGMEM speedups above a real customer: the ELKS boot pays the seam tax in full.
- Another one landed the same week it was checked: **FreeDOS**. `make freedos`
  boots FreeDOS 1.3 to FreeCOM on the BIGMEM machine (172 KB is its exact
  floor — the kernel dies during init at 108 KB). The kernel is 8086-clean and
  GPL, so unlike the dev C: it ships in a public ROM; `freedos/mkfreedos.py`
  fetches the official release and re-packs a 360 KB boot floppy. Note the
  arena is tight: FreeCOM stays fully resident without XMS, so big .COMs won't
  fit — the growth path is the same SRAM-bank lever as Windows 1.01 below.

## Homegrown userware: VIEW, a C toolchain, vi, a JVM

A wave of "what's the dumbest thing it could run" ideas with one shared
virtue: all four would be ours or public domain, so unlike the copyrighted
classics in the gallery they can ship **in the public ROM**. One is greenlit,
the rest are queued.

### VIEW.COM — an image viewer (greenlit, in progress)

Show a photo fullscreen on the SNES — decoded by a DOS program on the
emulated 8086, not pre-baked by the build. The plan:

1. **Output is CGA mode 4** (320×200×4): nearest-neighbor scale with
   letterboxing, then a 4×4 ordered (Bayer) dither into the fixed CGA
   palette — integer math only. Mode 6 (640×200 mono) would double the
   resolution but waits on the true-640 renderer (M10p6, in the Windows
   section below): the SNES currently draws mode 6 squashed through the
   mode-4 path.
2. **Formats: BMP first** (8-bit palettized and 24-bit uncompressed), then
   **GIF87a** — LZW is period-perfect, and its ~20 KB decode tables fit the
   default 108 KB machine with room to spare. JPEG is a stretch goal
   (integer IDCT + Huffman is period-plausible; expect minutes per image).
3. **Turbo Pascal 3 with inline asm** for the dither/blit inner loop,
   source shipped — like SOKOBAN and MIDPLAY before it.
4. **Row-streaming decode**: one scanline in flight, so RAM use stays flat
   regardless of source image size.
5. **Content licensing, the usual rule**: the build generates an original
   CC0 test-card image (the demo-tune precedent), and real photos are
   bring-your-own via `userware/`. Gallery screenshots come from Mesen,
   as always.
6. **Slideshow controls**: any key advances, ESC quits; L/R could toggle
   the two CGA palettes (cyan/magenta/white vs green/red/brown).

Development loop: iterate against `runpc -cga` PPM dumps, finish in Mesen.

### A C compiler on (and in) the ROM — queued

Turbo Pascal 3 proves a compiler runs on this machine, but TP3 is
copyrighted and can't ship. **Small-C** (Hendrix) is public domain, was born
on 64 KB CP/M machines, and its companion Small Assembler is PD too — a
fully redistributable C toolchain that fits the 108 KB build. Land it and
every flashcart becomes a self-contained C dev machine out of the box.
(Fallback candidate: Dunfield's MICRO-C; licensing to verify for either.)

### vi — queued

Not vim — even the 16-bit DOS builds of vim want most of 640 KB. The port
target is **levee**, the tiny vi clone ELKS already ships, with the
public-domain **Stevie** as fallback; cross-compile with gcc-ia16 + libi86
or Open Watcom. It wants the *standard* build, and that's a feature: BIGMEM
eats the B: SRAM drive, and B: is the whole point — `:wq` writes to
battery-backed cartridge SRAM, so edits survive power-off like a game save.
First step when picked up: build it, boot it, prove `:wq` round-trips.
Together with Small-C this becomes the real milestone: the **self-hosted
dev workstation** — write `HELLO.C` in vi, compile it, run it, entirely on
the console.

### A JVM — queued

Not a real JVM (the class library alone dwarfs 172 KB) — a **class-file
interpreter that runs real `javac` output**: a constant-pool parser, an
operand-stack loop (~50 opcodes covers integer arithmetic and control
flow), `invokestatic`, `System.out.println` as a native shim, and a bump
allocator instead of a GC. `HelloWorld.class` is ~400 bytes. The Z-machine,
CHIP-8 and GB.COM already establish that we like nested VMs; this one's
headline is *"write once, run anywhere" — verified on a Super Nintendo*.
Bonus deliverable: SIEVE in Java vs Pascal vs C, all timed on the console.

## Windows 1.01 — proof of concept done, fit + renderer next

Windows 3.0 is out of reach and stays out: its real mode — already the
low-memory fallback — wants 640 KB installed / 384 KB free and DOS 3.1+, more
than twice anything this cart can back (see the RAM levers above; even wiring
every theoretical LoROM SRAM bank stays emulator-only fantasy). Windows 2.03
(512 KB, DOS 3.0) sits on the same wrong side of the wall.

**Windows 1.01 is a different story: 8088, 256 KB, CGA, DOS 2.0 — the exact DOS
we already boot. Step 1 is done, and it worked better than hoped.**

Both Windows **1.01 and 1.04** boot all the way to a working **MS-DOS
Executive** — the real GUI, in CGA mode 6 (640×200) — on `runpc` (the C
reference core, bit-identical to the SNES 65816 core, under MS-DOS 2.0 with a
Windows install on C:). Menus, drive icons, the file listing, keyboard
navigation: all there. The HLE BIOS surface (INT 10h/11h/12h/13h/16h/1Ah + the
B800 framebuffer) is sufficient as-is; no missing interrupt was hit. So the
CPU and the machine are proven — what's left is SNES-specific plumbing:

1. **Memory — the tight part.** The measured floor is **237 KB**: at 236 KB the
   `WIN` loader dies with "Program too big to fit in memory," at 237 KB the
   Executive comes up. The SNES's realistic ceiling is **236 KB** (108 KB WRAM +
   a full 128 KB SRAM, which the cart header already declares — today only 64 KB
   is wired, banks `$72/$73` are the lever). That is *one kilobyte short* in the
   naive layout. The kilobyte is recoverable: running `WIN.COM` as the DOS
   `SHELL` drops resident `COMMAND.COM` (~2.6 KB) and clears 236 KB with room —
   the catch is that Windows 1.x locates its startup files via the *current
   directory*, so a `SHELL=` launch (CWD = boot-drive root) fails with "Cannot
   find Windows startup files" until the install is laid out so the root is the
   Windows directory. That layout work is the milestone's known-hard step.
   (A 192 KB-SRAM *emulator* config — 300 KB guest — clears it trivially for a
   Mesen-first demo, like BIGMEM before it.)
2. **True 640×200 mode 6** (also under graphics above): Windows draws CGA hi-res,
   and the host renders it at full 640; the SNES side still renders mode 6
   squashed as mode 4 (see M10p6). SNES mode 5 gives 512 wide — pan the rest like
   the 80-column text trick. Until then the GUI would show, but horizontally
   wrong.
3. **Survive the read-only C:** — Windows writes `WIN.INI` and temp files at
   runtime; patch or shim them (BIGMEM eats the B: SRAM disk, so the writable
   bits need an INT 21h-level detour or tolerated failures).
4. **SNES Mouse → INT 33h** (optional, delightful): the SNES Mouse exists, the
   auto-read port is already polled, and the Executive is fully keyboard-drivable
   in the meantime.

Speed: reaching the Executive is ~2–3 M guest instructions, so at snes86's
~0.05–0.1× XT that's on the order of a minute or two — ELKS-boot territory, well
inside the "it booted" bar below. (Windows media is copyrighted, so like the dev
C: it can never ship in a public ROM — this stays a bring-your-own build.)

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

- **Game Boy — landed, then graduated.** The payoff happened here: the
  **Nintendo® boot logo** and the **Tetris® title screen**, rendered by
  our from-scratch real-mode SM83 core inside DOS inside the SNES — the
  shots are in the [compatibility gallery](COMPATIBILITY.md#gallery).
  The emulator now lives as its own project,
  [gameboy8086](https://github.com/rgsilva/gameboy8086): pure 8086
  assembly, Blargg cpu_instrs 11/11 (verified independently under
  DOSBox-X locked to a real 8086 CPU model), dmg-acid2 ~90%. It still
  runs on snes86 the bring-your-own-software way: build `GB.COM` there
  and drop it plus a 32 KB cart into `userware/`.

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
