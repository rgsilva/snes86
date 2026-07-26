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
[COMPATIBILITY](COMPATIBILITY.md#help-wanted).

## More guest RAM (make BIGMEM fast)

The default guest has ~108 KB. The BIGMEM build extends it to 172 KB using
cartridge SRAM, which revives memory-hungry titles (Rogue) — but
it's currently ~1.7× slower than the standard build, so it's shipped only as an
experiment (`make msdos_big`).

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
instruments (see [INTERNALS](INTERNALS.md#the-snes-is-your-sound-card)). Room to
grow: richer/more accurate GM instruments, better drum mapping, and — much harder —
an OPL2/AdLib (FM) approximation for games that target port 388h instead of MIDI.

## More software and OSes

- The bring-your-own path (`user/` → `C:\USER`) already lets anyone add their
  own DOS programs without touching the build.
- Other DOS versions, or entirely different self-booting guests (the Flight Simulator
  build already proves a non-DOS boot works via `make boot DISK=`), are open territory.
- One of them landed: **Linux**. `make elks` boots ELKS 0.9.1 to a root shell —
  kernel and apps executing in place from cart ROM on the BIGMEM machine (see
  [INTERNALS](INTERNALS.md#booting-linux-the-elks-machine)). It also gives the
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

### VIEW.COM — an image viewer (SHIPPED; GIF/JPEG still open)

Show a photo fullscreen on the SNES — decoded by a DOS program on the
emulated 8086, not pre-baked by the build. **Landed**: `VIEW.COM` ships
in `C:\VIEW` on the C: image — a Turbo Pascal 3 program (source
alongside, compiled by `apps/tpcompile.sh` driving TP3 *on the emulated
8086*) that renders 8/24/32-bit BMPs (top-down or bottom-up) **and
8-bit RLE PCX** — the native DOS image format of the era — with
aspect-correct fit and 4×4 ordered dither: `VIEW PIC.BMP` for 640×200
halftone (mode 6), `VIEW PIC.PCX 4` for 320×200 four-colour, and
`VIEW *.BMP` for a wildcard slideshow (any key advances, ESC quits —
the world's slowest digital photo frame). The build generates
`CARD.BMP` *and* `CARD.PCX`, the same original CC0 test card in both
formats (`apps/view/mkcard.py`), and the suite + CI assert the two renders
are bit-identical — one compare covers the whole PCX decoder. Fun TP3
fact: it has no 32-bit integers, so VIEW never seeks backward — target
rows are walked in the order the file stores them, read in buffered
batches, and every seek is a small forward skip. The inner loops —
fetch/scale, dither/pack, the B800 blit, and the PCX RLE stepper — are
hand-written 8086 machine code fed to TP3's `inline()` (generated by
`tools/mkviewasm.py` — TP3 keeps SS≠DS, which cost one afternoon of
stores vanishing into the stack segment), cutting a full paint from ~20
emulated minutes to ~4½. Watching it crawl up the screen is still part
of the charm. Still open from the plan below: GIF87a, JPEG, a palette
toggle. The original plan:

1. **Step 0, the M10p6 renderer — DONE.** CGA mode 6 (640×200 mono) now
   renders true-width on the SNES: the whole frame stays in SNES hi-res
   mode 5 with the bitmap on BG2, shown as a 512-pixel window that L/R
   pan across the 640 — same trick as 80-column text. The conversion is
   cheaper than mode 4 (a 1bpp CGA byte *is* the SNES plane-0 byte), the
   char-index ceiling is beaten by HDMA-rebanding the BG2 character base
   per row group, and the on-screen keyboard survives untouched. Every
   bring-your-own mode-6 program is un-squashed, and the Windows 1.01
   renderer prerequisite (below) is retired as a side effect. Covered by
   `test/t_cga6.lua` (Mesen) + a runpc PPM check in the suite and CI;
   `CGA6TST.COM` ships in `C:\BENCH`. (See INTERNALS.md for the how —
   including the native-stack lesson it re-taught.)
2. **Two output modes**: CGA mode 4 (320×200×4 — color, 4×4 ordered
   Bayer-dithered into the fixed palette) and mode 6 (640×200 —
   double-resolution mono halftone, newspaper style). Integer math only,
   nearest-neighbor scale, letterboxed. A viewer nicety: VIEW can center
   photos in a 512-wide region of mode 6, so the whole image is visible
   with no panning at all.
3. **Formats: BMP first** (8-bit palettized and 24-bit uncompressed), then
   **GIF87a** — LZW is period-perfect, and its ~20 KB decode tables fit the
   default 108 KB machine with room to spare. JPEG is a stretch goal
   (integer IDCT + Huffman is period-plausible; expect minutes per image).
4. **Turbo Pascal 3 with inline asm** for the dither/blit inner loop,
   source shipped — like SOKOBAN and MIDPLAY before it.
5. **Row-streaming decode**: one scanline in flight, so RAM use stays flat
   regardless of source image size.
6. **Content licensing, the usual rule**: the build generates an original
   CC0 test-card image (the demo-tune precedent), and real photos are
   bring-your-own via `userware/`. Gallery screenshots come from Mesen,
   as always.
7. **Slideshow controls**: any key advances, ESC quits; L/R pans in
   mode 6, and toggles the two CGA palettes in mode 4
   (cyan/magenta/white vs green/red/brown).

Development loop: iterate against `runpc -cga` PPM dumps, finish in Mesen.

### The dev workstation — SHIPPED, and it never needed BIGMEM

Small-C 2.2 + Small Assembler (public domain) + the MIT `LINK.EXE`
now ship in `C:\CC` (`apps/cc/`) and
**compile, assemble, link and run C programs inside the emulated DOS
2.0 on the stock 108 KB machine** — `CC HELLO` on a writable drive does
the whole cycle (~14 minutes at SNES speed, measured; period-perfect). The two
walls that had it "verified but held" both dissolved on close reading:
the assembler fits 108 KB once its default 1000-symbol table is trimmed
(`-S200 -NM` — the earlier attempt had passed the *default* size), and
the "cc changes drive and can't write to read-only C:" behavior was
never cc at all — DOS 2.x simply cannot exec by explicit path (that's
DOS 3.0), so the tools are found via `PATH` and the current drive stays
on the user's writable disk, exactly where the outputs land. With the
B: write fix, the full workstation works on today's standard build:
write C in TED, `CC` it, run it, save it to battery SRAM — all on the
console. Still open here: more Java opcodes, and maybe — maybe — C
ports of TED/VIEW now that the toolchain can build on-machine.

### The editor — SHIPPED as TED (vi declined)

`TED.COM` ships at `C:\` on both images, with its Turbo Pascal source:
a modeless, controller-first editor — d-pad moves, typing inserts, and
the Y button (Esc) opens a status-row menu (Save / save As / Load /
seaRch / Goto / Undo line / Quit) navigated by d-pad + START, so
commands cost zero on-screen-keyboard trips. Measured on the SNES:
**3 frames (~50 ms) per keystroke** — live typing in pure TP3, no
inline asm needed. Line-table buffer (2000 lines × 255 chars), TABs
preserved, long lines pan under the cursor. The flagship trick: saving
to `B:` writes battery-backed cartridge SRAM, so your edits survive
power-off like a game save (`TED B:NOTE.TXT`). Shipping it also fixed a
real machine bug: B: *writes* had never worked — the INT 13h vdisk
rejected the two-sided addressing our own IO.SYS generates ("Disk error
writing drive B" since day one; nothing had ever tested a B: write).
`t_ted` (Mesen) and `ted-host` (runpc) regression-guard it.

A vi port (levee/Stevie) was evaluated and declined: no cross-toolchain
on hand, unverifiable levee licensing, and modal editing is
gamepad-hostile — every `i`/`Esc`/`:wq` is an on-screen-keyboard
expedition. Together with Small-C, TED still completes the
**self-hosted dev workstation**: write `HELLO.C` in TED, compile it,
run it, entirely on the console.

### A JVM — SHIPPED

`JAVA.COM` runs real `javac --release 8` bytecode on the emulated 8086
(and therefore on a SNES): a class-file interpreter, `javac` on the
desktop and the JVM on the guest, exactly the Z-machine split the repo
already celebrates. Ships in `C:\JAVA` on both C: images with five
samples and their sources; the compiled class files are committed so
the ROM builds without a JDK.

Written in Turbo Pascal 3 (`disks/JAVA.pas` + three `.INC` includes),
with the 32-bit `int` arithmetic — every Java `int` is a hi/lo pair on
this 16-bit machine — done in hand-written 8086 via `inline()`. Scope,
deliberately small: static methods of one class, ints, `int[]`/
`boolean[]`, `String` + `StringBuilder` concat, `System.out.println/
print`, `System.in.read()`. No `long`/`float`/`double`, no user objects,
no exceptions, no GC. About 40 bytecodes plus a dozen `java/lang` HLE
shims cover the samples; an unsupported opcode or method stops with a
message naming the culprit.

Speed is interpreted-bytecode-on-an-interpreted-CPU: HelloWorld is
instant, Fibonacci a blink, and one BYTE-sieve pass is a few minutes of
honest thinking on the SNES (it prints its BIOS-tick count on exit — the
three-language benchmark table, Java vs Pascal vs C, is one Small-C away).

**Update: JAVAC shipped too.** The desktop half of the Z-machine split
is now optional: `C:\JAVA\JAVAC.EXE` compiles the same Java subset *on
the machine* (`JAVAC HELLO.JAV B:HELLO.CLA`, then `JAVA B:HELLO`), and
the `.JAV` sources ship alongside the `.CLA`s because the console can
now build them itself. It is our own single-pass compiler in C
(`apps/java/javac.c`), compiled to a DOS binary by the Small-C 2.2
toolchain running on MS-DOS 2.0 inside our own emulator — and the clang
build of the same source emits byte-identical class files (the
16-bit/32-bit-host parity was a design goal, not luck). Compiling
JAVAC's own 40 KB source ON the SNES was considered and dropped:
Small-C cannot compile it there (symbol tables, memory), and Ricardo
called it — build locally, ship the binary. The vintage-toolchain
fight that produced it (three separate 1980s walls) is documented in
[docs/notes/JAVAC-PORTING](notes/JAVAC-PORTING.md).
Open extensions if anyone wants them: `long` (a second pair), `switch`
tables, more of `java/lang`, and an asm dispatch loop for the 5-10×.

### Repo housekeeping — DONE

The great reorg landed: the on-machine software lives in `apps/<tool>/`
(one folder per tool, per-tool Makefiles staging exactly what ships as
`C:\<TOOL>`; ours and third-party merged — a package that is not ours
carries a provenance section in its README, with hashes), the packer walks it
by convention, `disks/` is purely bring-your-own media (zero gitignore
exceptions), `user/` at the repo root is the BYO drop-in, TP3 is
fetched-not-committed for the `recompile` pipeline, the MIT MS-DOS
utilities ship as `C:\DOS`, and the copyrighted dev C: became the
suite's OVERLAYS test fixture.

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
2. **True 640×200 mode 6 — DONE** (landed as step 0 of the image-viewer
   milestone above): the SNES now renders mode 6 on hi-res BG2 as a
   512-pixel window with L/R panning the remaining 128. Windows' GUI
   would display correctly today; this prerequisite is retired.
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

- **Game Boy — landed, graduated, shipped back home.** The payoff happened here: the
  **Nintendo® boot logo** and the **Tetris® title screen**, rendered by
  our from-scratch real-mode SM83 core inside DOS inside the SNES — the
  shots are in the [compatibility gallery](COMPATIBILITY.md#gallery).
  The emulator's home is its own project,
  [gb8086](https://github.com/rgsilva/gb8086): pure 8086
  assembly, Blargg cpu_instrs 11/11 (verified independently under
  DOSBox-X locked to a real 8086 CPU model), dmg-acid2 ~90% — and it
  ships here again as [apps/gb](../apps/gb/README.md) → `C:\GB`, with
  homebrew test carts. Game ROMs stay bring-your-own: a 32 KB no-MBC
  cart via `user/` or a `B:` disk.

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
