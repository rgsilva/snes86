# snes86 — an 8086 PC emulator for the SNES, in 65816 assembly

## Project goal

Boot a real x86 operating system on a **stock, unmodified SNES** by writing an
8086 real-mode emulator in 65C816 assembly, delivered as a plain flashable ROM.
Phase 1 target: an early MS-DOS (1.x/2.x era) `C:\>` prompt using only the
console's 128 KB WRAM. Later phases (ELKS, Minix 1.x/2.0, FreeDOS) unlock once
cart RAM exists, reusing the same emulator core.

Inspired by LinuxMD (Daniel Palmer's Linux port to the Mega Drive, June 2026),
but taking a different path: the SNES's 65C816 cannot run Linux natively (8/16-bit
CPU, no GCC/LLVM backend), so we emulate a 16-bit guest CPU that maps well onto
the 65816's 16-bit accumulator instead.

## Why 8086 as the guest

- 16-bit ALU ops map ~1:1 onto the 65816 with M=0 (16-bit accumulator) — no
  32-bit carry-chaining pain (that's why RV32 was deferred to a later phase).
- One emulator core unlocks multiple OSes: DOS, ELKS, Minix.
- Ugly part: ModRM decoding and variable-length instructions. Accepted cost.

## Hardware budget (stock SNES, phase 1)

- **WRAM 128 KB** total: bank $7E = guest conventional memory (~90 KB usable
  after emulator state), bank $7F = emulator state, dispatch temps, PPU console
  buffers, stack.
- **ROM (XIP)**: emulator code + guest BIOS + read-only "disk" images (DOS
  system files, .COM utilities). FastROM (3.58 MHz) required.
- **VRAM as block device**: text console needs only ~6 KB (font + tilemap);
  the remaining ~58 KB is a writable RAM disk, accessed by DMA during
  vblank/forced blank only. Budget it like a floppy: ~15 KB/s sustained,
  scratch storage only (a crash mid-write corrupts it).
- Guest register file + hot emulator state live in **direct page** (fastest
  memory on the 65816).

## Guest OS constraints (phase 1)

- MS-DOS 1.x/2.x boots in 64 KB-class machines (original IBM PC shipped with
  16–64 KB) → fits in the ~90 KB guest space. **FreeDOS does NOT fit** in
  stock WRAM (kernel wants several hundred KB) — cart-RAM tier only.
- ELKS and Minix want 256 KB+ guest RAM → cart-RAM tier only.
- CGA text mode 80×25 maps naturally onto a SNES BG layer tilemap.
  Note: SNES visible area is 32×28 tiles at 8×8 — need either a 40-column
  font strategy, hi-res mode 5, or horizontal scrolling for 80-column DOS.
  **Decision (M3 era): boot DOS in CGA 40×25 (mode 1), render on a SNES
  mode-5 512px-wide 64-column console; 80-col deferred.**

## Console / IO

- **Video**: PPU text console on BG1, 8×8 font, ring-buffer scrolling via
  vertical scroll register, dirty tiles DMA'd during vblank; the emulator core
  never blocks on rendering. Green "heartbeat" square in a corner (LinuxMD
  tradition), red square for disk activity.
- **Input**: SNES controller with on-screen keyboard (DONE: HDMA raster
  split fixes a 5-row QWERTY panel below the scrolling terminal; D-pad +
  A types through the INT 16h ring; B=BS, START=Enter, X=space, Y=shift,
  SELECT toggles. INT 16h AH=0 blocks by IP-rewind, so DEBUG etc. work). Real keyboard
  later via cart hardware (RP2040 + Pico-PIO-USB host — already proven in the
  keyboard-to-SNES project) or serial-over-cart.
- **No serial port on stock hardware**: development happens in emulators,
  hardware serial arrives with the cart-RAM tier.

## Cart tiers (later phases)

1. **Stock ROM** (phase 1): everything above. Zero extra hardware.
2. **FXPAK Pro custom FPGA core**: minimal custom mapper exposing ~8 MB of its
   16 MB PSRAM as writable banks + one memory-mapped UART register (USB serial
   console). Keep the mapper contract stupid (linear banks + 1 UART reg) so the
   same contract is trivially added to a software emulator.
3. **RP2040 custom cart** (plan B): PIO bus snooping, PSRAM, USB CDC serial,
   USB keyboard host.
4. Final boss (separate phase): RV32IMA emulator + mainline nommu Linux à la
   cnlohr's mini-rv32ima, needs tier 2/3 RAM. Same PPU console reused.

## Development pipeline (test pyramid)

1. **C prototype on PC first** (`core-c/`): 8086 core in portable C, validated
   against the SingleStepTests 8088 v2 vectors (hardware-captured) and by
   booting DOS under it on the desktop. Instant iteration.
2. **65816 port in Mesen2**: full debugger, memory/tilemap viewers, trace
   logging, Lua scripting (use Lua to dump the *guest* 8086 registers —
   debugger-inside-debugger). Unthrottled fast-forward + CPU overclock for
   speed. IMPORTANT: run periodic tests at true 3.58 MHz — vblank DMA budget
   is real-time dependent and overclock can mask races.
3. **Real hardware last**, via any SNES flash cart.
4. For cart-RAM tiers: patch Mesen2/bsnes with the (deliberately simple)
   mapper so the emulator is the reference implementation the FPGA must match.

## HLE BIOS strategy

No real BIOS binary. Guest IVT entries for INT 10h/11h/12h/13h/16h/1Ah point
at stubs; the emulator's int hook dispatches them natively (PPU console,
controller/keyboard, ROM/VRAM block devices). INT 13h reads are native block
copies — this makes DOS boot mostly run at native speed. Timer INT 8 at
~18.2 Hz derived from NMI (tick every 3–4 vblanks, alternating).

Guest OS: MS-DOS 2.0 from Microsoft's MIT-licensed source release
(fallback: DOS 1.25 from the same repo). A: = read-only floppy image
in ROM; B: = ~58 KB VRAM RAM disk.

Licensing path for the distributable ROM: the MIT repo's `v2.0/bin/`
contains real MSDOS.SYS + COMMAND.COM binaries, and `v2.0/source/SKELIO.ASM`
is Microsoft's official skeleton OEM IO.SYS — we write our IO.SYS against
that template (targeting our HLE BIOS), giving a fully redistributable DOS.
The PC DOS 2.00 image used for bring-up stays local, never in the repo/ROM.

## Performance expectations (be honest in all docs/commits)

- 65816 @ 3.58 MHz FastROM, ~4–5 cycles avg per native instruction.
- Estimated 100–300 native instructions per emulated 8086 instruction
  → roughly a 0.03–0.1 MHz effective PC XT. Boot-to-prompt time: to be
  MEASURED from the C core's instruction count (M3.5), not guessed.
  Text-mode software usable-ish. This is a novelty/art project; speed is
  not the point, booting for real is.

## Milestones

- [x] M0: repo scaffolding, toolchain (pvsneslib: wla-65816 + wlalink; core in
      handwritten asm, scaffolding in C), Mesen2 installed
- [x] M1: PPU text console as a standalone SNES ROM (`snes/`). Mode-5
      hi-res 64x28: BG2 2bpp carries even text columns, BG1 4bpp odd ones
      (glyph in one half of each 16x8 tile pair), so a char write is one
      2-byte tilemap write and scrolling is a VOFS ring over the 32-row
      map. VRAM/VOFS writes flow through an NMI-drained queue. Verified
      headless in Mesen2 (testrunner + Lua screenshots). Controller input
      beyond a START demo deferred; keyboard deferred.
- [x] M2: VRAM RAM disk = drive B: (36 KB across three free VRAM regions,
      one 512-byte sector per vblank via DMA ch1, read via the $2139
      prefetch recipe). Poses as a 180 KB floppy; clusters past the
      backed 72 sectors are marked bad in the FAT so DOS never allocates
      them (~32 KB usable). Verified: COPY COMMAND.COM B:, CHKDSK B:
      (clean FAT walk, correct bad/free byte counts), DIR B:.
      Demo buttons: START=dir b:, SELECT=copy command.com b:, Y=chkdsk b:.
- [x] M3: 8086 core in C on PC (passes all 3,007,000 SingleStepTests 8088 v2
      vectors), boots PC DOS 2.00 to a working A> prompt via HLE BIOS (runpc)
  - [x] M3.5: **63,162 guest instructions boot→prompt, 129 sectors read.**
        SNES @3.58MHz projection: ~10-30 s to the DOS prompt (compute
        8-24 s at 100-300 native/guest + ~4 s disk DMA at ~15 KB/s).
        CHKDSK with 96 KB guest RAM: 73,616 bytes free after DOS 2.00.
- [x] M4: 65816 dispatch loop skeleton (`snes/cpu.asm`): DP register file
      with cached segment bases, JMP (abs,X) dispatch, table-driven ModRM,
      lazy flags (kind/a/b/res/cf, CF fast path), ~140-opcode slice.
      Lockstep parity harness (`snes/test/parity.sh`): random constrained
      streams run through the C core (x86trace) and the 65816 core in
      Mesen2, all 14 registers compared after every instruction.
      Status: 20+ seeds x up to 2000 instructions, zero divergence.
      M4 guest window: linear < 56 KB ($7E:2000+); $7F spill in M5.
- [x] M5a: full opcode coverage in the 65816 core (`snes/cpu2.asm`):
      prefixes, sreg ops + base cache, strings + REP, grp2 shifts
      (bit-stepped, SETMO), grp3 with software MUL and the CORD microcode
      division port, CALL/RET/far/INT/IRET/LOOP, hardware-exact BCD.
      Parity: 12 random streams x 2000 instructions + directed streams
      (INT/IRET, far flow, LES/LDS, divide errors, REP-IDIV) — zero
      divergence vs the C core.
- [x] M5b: 24-bit long-pointer memory model (guest 96 KB across $7E/$7F,
      parity-revalidated), HLE BIOS in `snes/dosboot.asm` (INT 10h → mode-5
      console, INT 13h → 180 KB ROM disk in banks 2-7, INT 16h keyboard
      ring, INT 11h/12h/1Ah). IRET stub lives at 0000:04F0 (BDA scratch —
      0000:0600 gets clobbered by the boot sector's directory read!).
      FastROM done: header FASTROM + .BASE $80, $420D=1, reset/NMI
      jml to the fast mirrors, disk reads from banks $82+. Boot clock:
      6.15 s vs 7.14 s SlowROM (WRAM stays slow; output is frame-bound).
- [x] M6: **PC DOS 2.00 boots to a working A> prompt in Mesen2**
      (snes/test/dos_boot.png). Boot-to-prompt ~7 emulated seconds.
      START types "dir" through the INT 16h ring: real COMMAND.COM
      executes it, real FAT walk, real output (dos_dir.png). Boot
      verified in lockstep vs the C core for 57k+ steps (tracewin.sh;
      clocks frozen in trace mode — INT 1Ah ticks are environmental).
- [ ] M7: DOS boots on real hardware, stock SNES, flash cart
- [ ] M8+: cart-RAM tier (FXPAK gateware or RP2040 cart) → ELKS/Minix/FreeDOS

## Style / working preferences

- Direct, pragmatic, honest tradeoffs. Prefer iterative hands-on validation
  over theory. Comment the *why* in hot asm paths (cycle counts matter).
- Owner: Ricardo (Brazil). Comments/docs in English; commit messages in English.
