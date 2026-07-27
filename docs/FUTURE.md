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

## More guest RAM (make the big machine fast)

The default guest has ~108 KB — everything above that lives on the cartridge, and
the emulator has to fold guest addresses into it. `make msdos_sa1` does this with an
SA-1 board's 256 KB of BW-RAM and gets a 300 KB guest (plus a B: drive); it's what
revives memory-hungry titles like Rogue, and it's the machine FreeDOS and ELKS boot
on. There is only one big machine now — the older 172 KB cartridge-SRAM layer was
deleted once ELKS moved off it — so this is the single thing to make fast. The
cost today is that it is ~1.7× slower than the public build.

The slowdown is pure "correctness tax" from handling the WRAM↔cartridge address seam;
the standard build is untouched. There's a clear path to making it fast, if someone
wants it:

- Gate the per-instruction rebase behind an IP window (the big win, est.
  1.7× → ~1.2×). Today every instruction re-checks whether the code segment crosses
  the seam, even for code that provably can't. Caching the `[lo, hi)` IP range where
  the fetch pointer stays in one region, and only doing the full rebase when leaving
  it, removes ~90% of the overhead.
- Restore the chunked `REP MOVS/STOS` fast path, capped at the region boundary
  (the cap is the safety) — recovers the 7× block-move speedup the big machines
  currently give up.

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

Note that no coprocessor is in play here — all speed comes from the console's own
65C816 doing the work. That stays true even on the SA-1 variant, where the board is
wired up purely for its BW-RAM and the SA-1 CPU is never released from reset.
Actually *running* guest code on an SA-1 (a second, faster 65C816) would be a
different project, and a large one.

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
  kernel and apps executing in place from cart ROM on the 300 KB SA-1 machine
  (see [INTERNALS](INTERNALS.md#booting-linux-the-elks-machine)). It moved there
  from a 172 KB cartridge-SRAM machine of its own, which both unified the
  codebase on one memory layer and turned out to be a real feature: at 172 KB the
  kernel could not fork `/etc/rc.sys` and `ls` ran out of memory, where at 300 KB
  the boot scripts run and 171 KB is free at the shell. It also gives the
  big-machine speedups above a real customer: the ELKS boot pays the seam tax in
  full.
- Another one landed the same week it was checked: **FreeDOS**. `make freedos`
  boots FreeDOS 1.3 to FreeCOM on the 300 KB SA-1 machine (it needs a big one —
  the kernel dies during init at 108 KB, and 172 KB was its exact floor). The kernel is 8086-clean and
  GPL, so unlike the dev C: it ships in a public ROM; `freedos/mkfreedos.py`
  fetches the official release and re-packs a 360 KB boot floppy. FreeCOM stays
  fully resident without XMS, but with 300 KB underneath it there is real room —
  `MEM` reports ~168 KB free for programs, and it moved to the SA-1 board partly
  to get that and partly because the board leaves B: intact. ELKS followed it
  there, and the old layer went with them.

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
   renderer prerequisite (below) was retired as a side effect — Windows'
   GUI came up through it unmodified. Covered by
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

### The dev workstation — SHIPPED, and it never needed the big machine

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

## Windows 1.01 — it boots on the SNES, and the d-pad is its mouse

Windows 3.0 is out of reach and stays out — but the box quotes were worth
checking, and one of them was wrong. Both were installed from real media and
run on `runpc`, and both **boot their GUI on our 8086 + HLE BIOS** (the CPU
and the machine are fine); the wall is purely RAM. Measured floors, not
box quotes — bisected with `runpc -m`, MS-DOS 3.30, `BUFFERS=2 FILES=20`,
CGA driver, C: read-only:

| | box quote | measured floor | free RAM it needs | verdict vs 364 KB ceiling |
|---|---|---|---|---|
| Windows 3.0 real mode | 640 KB / 384 KB free | **430 KB** (420 KB lean DOS) | ~381,900 bytes | **impossible** — 364 KB is only 372,736 bytes *total*, ~9 KB below what Windows wants free before DOS exists at all |
| Windows 2.03 | 512 KB | **343 KB** | ~306,700 bytes | **fits** — on the 364 KB (no-B:) SA-1 board, with ~21 KB spare. Not on the 300 KB board (43 KB short). |

So Windows 3.0 stays a desktop-core trophy: it installs and reaches Program
Manager in CGA 640×200 on `runpc` (~7 M guest instructions), and it can never
run on the console. Windows 2.03 reaches the MS-DOS Executive in <3 M guest
instructions and *does* fit the arithmetic — but it wants **DOS 3.x**: under
our MIT MS-DOS 2.0 it paints its logo, calls the DOS-3 internals (INT 21h
AH=52h list-of-lists, AH=57h) and exits silently, with or without a faked
version number. Shipping it would mean a DOS 3 on the cart *and* the whole
SA-1 BW-RAM-as-conventional-RAM plumbing *and* the read-only-C: work below —
i.e. all of Windows 1.01's milestone plus a new DOS. Windows 1.01 remains the
right first target.

Windows 3.1 and the Windows/286 + Windows/386 2.x variants need a 286/386
and are out on the CPU, not the RAM.

**Windows 1.01 is a different story: 8088, 256 KB, CGA, DOS 2.0 — the exact DOS
we already boot. It boots.** Microsoft Windows 1.01 comes up to its **MS-DOS
Executive** — the real GUI, in CGA mode 6 (640×200) — on the SA-1 ROM in Mesen:
title bar, `File`/`View`/`Special` menus, the A:/B:/C: drive buttons, the file
listing, the selection highlight, the dithered desktop — and it takes input
from the controller. Windows **1.04** does the same on the
same ROM (settles at frame 30 600, `PRACTICE.WRI` and all). Reproduce either
with

    ./snes/test/winsnes.sh ../disks/windows.img win_snes.png

which builds `build/msdos_sa1_overlay.sfc` with your Windows C: merged in,
checks it on `runpc` first, then drives Mesen headless — and finally diffs the
SNES's CGA bytes against the C core's render: **0 of 16 000 bytes differ**, so
this is not "looks the same", it is the same picture. Nothing about it ships:
Windows media is copyrighted, so like the dev C: this stays a bring-your-own
build, never a default target.

What it took, and what it did not:

1. **Memory — the SA-1 machine settles it.** The floor is **237 KB**, measured
   by bisection: at 236 KB the `WIN` loader dies with "Program too big to fit in
   memory," at 237 KB the Executive comes up, and 237 KB / 256 KB / 300 KB /
   640 KB all render a byte-identical screen. The old 236 KB plain-SRAM ceiling
   was *one kilobyte short* and the plan was to claw it back with a `SHELL=`
   launch; `make msdos_sa1` makes that moot with **300 KB**, 63 KB of headroom,
   and a writable B: still attached. The cost is that the ROM needs SA-1 support
   to run at all.
2. **True 640×200 mode 6 — already there** (step 0 of the image-viewer milestone
   above): mode 6 on hi-res BG2 as a 512-pixel window with L/R panning the
   remaining 128. Windows' GUI displays through it unmodified — the 512-pixel
   window happens to cut just right of the file list.
3. **No BIOS or CPU gap on the way in.** This is the surprise: getting to the
   Executive asks for INT 10h/11h/12h/13h/16h and INT 21h and nothing else — no
   INT 1Ch, no direct 6845 CRTC programming, no PIT/PIC reprogramming, no
   INT 33h, and (measured with `runpc -v`) **not a single port `OUT`** in the
   whole run. It never writes to disk either: 543 sectors read, 0 written. So
   the read-only C: is a non-issue for the boot, and the 65816 core needed no
   change at all — the SNES reaches the identical screen the C core does.

4. **Input took two unrelated fixes.** The Executive ignored the keyboard for
   a while; disassembling Windows' own INT 9 handler (IVT[9] goes from our
   `0000:04F0` stub to `0EAB:0199`) settled both halves at once:

   ```
   0EAB:0199  in   al,60h              ; it reads the port itself
              cmp  al,0F0h / jnc chain
              test al,80h  / jnz handle
              test byte [0418h],8 / jnz chain
              cmp  byte [0449h],4 / jc chain    <-- the gate
              ...
       chain: jmp far [cs:0185h]       ; = whatever INT 9 was before Windows
   ```

   **BDA 40:49.** Windows only claims the keyboard while the *BDA* says a
   graphics mode is up. Both cores tracked the video mode in their own state
   and wrote 40:49 exactly once, at reset, as 03 — so a Windows sitting in
   mode 6 read 03, took the `jc`, and handed every scancode back to the vector
   it had replaced: our IRET stub. INT 9 fired, the scancode was sitting in
   port 60h, and Windows threw it away. Both cores now keep 40:49/40:4A live
   on every mode change (INT 10h AH=00 and the direct port-3D8 path). Note
   what was *not* wrong: the port-60h latch, the 61h acknowledge and the EOI
   were all already fine, and Windows keeps its own 40:17 shift state from raw
   scancodes (its tracker is at `0EAB:02D3`), so the BIOS flags byte never
   mattered.

   **The interrupt shadow starved interrupts outright.** This was the SNES's
   separate "the raw-scancode queue stops draining" defect — same symptom, a
   different root cause. The threaded DOS build only reaches a delivery point
   every 64 instructions, and a pending sreg-load/STI shadow made `run_slow`
   skip that pass entirely and refuel another 64. A guest whose *every* 64-op
   window contains an STI or a segment load therefore never receives another
   interrupt — not IRQ1, not even the 18.2 Hz tick. Windows' idle loop is
   exactly that: instrumented, it took the shadow branch on 100% of passes.
   The shadow is now consumed after one instruction, which is what the C
   core's per-step retry already did. (Guest IF went from 75% to 96% of
   sampled frames.)

   With both fixed, the d-pad drives the Executive on the 300 KB SA-1 machine:
   eight Downs walk the selection down the file list and START opens the
   selected file (Windows answers with its own modal dialog, drawn by the
   GUI). The on-screen keyboard's sticky Shift/Ctrl now also arrive as real
   `2A/AA` and `1D/9D` make/break codes, since a hooked INT 9 derives the
   modifiers from the raw stream and never reads ours.

5. **The mouse works — the d-pad drives the pointer.** Windows 1.x is a
mouse-first GUI, and it turns out the mouse was the *easy* half. There is no
INT 33h anywhere in it: SETUP **links** the chosen mouse driver into
`WIN100.BIN`, so the choice is frozen into that one file, and every driver on
the floppy talks to hardware directly (bus card at `0x23C`, three serial
protocols, and a Kraft joystick). Both installs in `disks/` were set up with
`NOMOUSE.DRV` — a 0x38-byte stub whose `Inquire` reports `msExist = 0` — which
is the real reason the earlier trace saw no INT 33h and no port I/O at all:
there was nothing in there that could look for a mouse.

`snes/tools/winmouse.py` relinks `WIN100.BIN` with the real
"Microsoft Mouse (Bus/Serial)" driver (see `snes/test/winmouse.sh`, which does
that and then proves the result on both cores). Both cores then emulate what
that driver asks for: an 8250 on **COM2** (`0x2F8`, IRQ3 → INT 0Bh) speaking
the classic 3-byte Microsoft protocol — RTS rising answers `'M'`, LSR bit 0
says a byte is waiting, IER bit 0 arms the interrupt. COM2 because that is the
port the driver tries first. The Kraft joystick driver was the tempting
alternative — a d-pad *is* a joystick — and was rejected on arithmetic: it
re-reads the game port with a 255-iteration timing loop on every 18.2 Hz tick,
~2 550 guest instructions, roughly ten times what one SNES tick can afford.

The last mile was not the mouse at all. `SYSTEM.DRV`'s INT 8 handler issues
OCW3 (`0x0B`) to the 8259 and reads port `0x20` back, and **skips its entire
timer-callback list unless that register reads zero** — and the callbacks are
where USER repaints the pointer through the display driver's `CheckCursor`.
Both cores answered `0xFF`, so Windows tracked the mouse perfectly (menus
opened, drive buttons selected) with no arrow ever drawn. Port `0x20` now
reads 0 on both: we vector IRQs straight at the IVT, nothing is ever in
service, and that is the honest answer.

On the console: with the on-screen keyboard closed **and** a guest driver
holding COM2 — only Windows ever does that, so nothing else changes — the
d-pad is the pointer, A is the left button and B the right. The d-pad feeds an
*intent* accumulator rather than a per-report delta, so a second of holding
right travels the same distance whether the guest managed fifteen reports or
one; a ramp takes it from 2 px/frame to 6. Y is stepped every other frame
because Windows doubles it on a 200-line CGA.

The keyboard was the other half of this, and it landed separately — see item 4
above, which was written while the mouse work was in flight. Between them the
Executive now answers a single controller both ways: pointer with the on-screen
keyboard closed, typing with it open.

Speed: reset → Executive is under **3 M guest instructions** (bisected on
`runpc`: 2 M is still the splash, 3 M is the Executive) and lands at **frame
32 100** on the SNES, to the frame, every run — about nine emulated minutes, and
roughly two host minutes in headless Mesen. That works out near 5 k guest
instructions/second, well under the usual 0.05–0.1× XT: a mode-6 GUI repaints
constantly and most of Windows lives above 108 KB, in the BW-RAM half of the
machine. Still ELKS-boot territory, well inside the "it booted" bar below.

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
  colour mapping; screenshot-only, needs the big machine, from-scratch core. If GB lands first,
  NES is "just" a bigger version of the same work.

Aside: we already nest — Infocom's Z-machine is a VM, so every Zork is
`snes86 → 8086 → Z-machine → story`. CHIP-8 just makes the inner VM graphical.
