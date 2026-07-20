# How snes86 works

snes86 runs an Intel 8086 PC on a Super Nintendo's 65C816. This document explains
the emulation core, the HLE BIOS "machine" around it, the `runpc` host emulator,
and the parity testing that keeps everything honest.

There are two implementations of the same 8086 core:

- `core-c/src/x86.c` — portable C. The correctness *oracle*: it's small, readable,
  and validated exhaustively against hardware-captured test vectors.
- `snes/cpu.asm` + `snes/cpu2.asm` — 65C816 assembly. The real thing that runs on
  the SNES. It's held bit-for-bit to the C core (see [Parity testing](#parity-testing)).

The guiding principle is HLE (high-level emulation): no real BIOS or option
ROM runs inside the guest. BIOS interrupts are serviced natively. This is why "what
boots on `runpc` is what boots on the SNES" — both share the same HLE contract.

---

## The 8086 core on a 65C816

### Threaded dispatch

The core runs in 65C816 native mode with A/X/Y 16-bit, direct page `D=$0000`, and
data bank `DBR=$7E` (guest RAM). The main loop is a threaded jump table: fetch
the opcode byte, `opcode*2`, `jmp (optable,x)`. Each instruction handler does its
work and tail-jumps to `step_next`, which fetches the *next* opcode and dispatches
again — there is no return to a central loop between instructions. ModRM decoding is
itself table-driven (`jmp (ea_tab,x)`). The guest IP rides in `Y` from fetch through
the end of each handler.

### The register file lives in the direct page

The 8086 register file is laid out in the 65C816 direct page in 8086 encoding order,
with `AX` at DP offset `$00`. Because a ModRM register field times two *is* the DP
offset, register access is a single direct-page instruction — the fastest memory the
65C816 has. Segment registers, the cached segment bases, IP, flags, and all emulator
scratch follow in the same page.

### Lazy flags

Computing all six arithmetic 8086 flags on every ALU op would be ruinous. Instead
each ALU handler stores its operands, result, carry-out, and a small kind code
(`ADD8`, `SUB16`, `LOG8`, …). The full FLAGS word is materialized only when something
actually reads it — a conditional jump, `PUSHF`, an interrupt, a trace snapshot —
via `flags_norm` (`jmp (norm_tab,x)`). Carry has a dedicated fast path because
`ADC`/`SBB`/`INC`/`DEC` need it constantly. The flag formulas match `core-c/src/x86.c`
exactly, down to the undefined-flag behavior of the BCD instructions.

### Memory: 24-bit long pointers

Guest physical memory is a flat window inside SNES WRAM. `GUEST_BASE` is the SNES
address of guest linear 0; in the DOS build it's `$5000` in bank `$7E`, so guest
linear `0x00000–0x1AFFF` (108 KB) maps to `$7E:5000 … $7F:FFFF`.

Each segment register keeps a cached 24-bit base pointer (`GUEST_BASE + seg*16`),
recomputed only when the segment loads. A memory access is then one 16-bit offset add
plus a `[dp]` long-indirect load/store — no per-access segment arithmetic. Guest
video memory (segments `B000`–`BFFF`) is mapped to a 16 KB CGA/MDA buffer at
`$7E:1000`, so writes to `B800:xxxx` land straight in the adapter RAM the renderer
scans out.

The BIGMEM variant extends the guest to 172 KB by adding 64 KB of cartridge SRAM
above WRAM; accesses that straddle the `$7E→$7F` bank seam take a save/restore slow
path. It's an experiment (see [FUTURE.md](FUTURE.md)), off by default.

---

## The HLE BIOS and the "machine"

`snes/dosboot.asm` is the virtual PC around the CPU: the BIOS, the hardware, and the
boot path. Every guest IVT vector points at an `IRET` stub; an interrupt hook
dispatches BIOS calls natively.

| INT | service |
|---|---|
| 10h video | set mode (40/80-col text, CGA graphics 4/5/6), cursor, scroll, read/write char+attr, teletype, set pixel / read pixel, palette/border. Includes an ANSI/CSI escape parser (cursor moves, clears, SGR colors) for `ANSI.SYS`-style output. |
| 11h equipment | returns "two floppies, 80×25 color". |
| 12h memory size | returns the guest RAM size (108 KB, or 172 under BIGMEM). |
| 13h disk | A: is a read-only floppy image in ROM (40 cyl / 1 head / 9 spt); B: is writable SRAM; C: is a hard-disk image. Reads are native DMA block copies. Services: reset, status, read, write, verify, get-params, seek, recalibrate. |
| 16h keyboard | read key (blocks by *rewinding IP* so the INT re-executes until a key arrives), peek/status, shift flags. Keys come from the guest BIOS keyboard ring or the emulator's own ring. |
| 1Ah timer | tick count (an ~18.2 Hz NMI-derived 16.16 accumulator, mirrored into the guest BDA), set tick count. |
| 9 (HW) | the keyboard hardware interrupt: port-60h scancode latch + queue. |

### The SNES is your sound card

The SNES has no MIDI hardware. Its audio is a whole separate computer — a Sony SPC-700
driving an 8-voice sample-playback DSP — and the main CPU can only reach it through four
one-byte mailbox registers at `$2140–$2143`. Getting DOS music software to play meant
bridging that gap in three places: get a synth program *into* the sound chip, teach it
General MIDI, and hand the guest something that looks like a MIDI card.

Uploading the synth. At power-on the SPC-700 runs only a small stock IPL ROM, so the
65C816 has to load our code into it first (`apu_upload` in `dosboot.asm`). That is the
SPC boot handshake: wait for the IPL's `$AA` "ready" byte, send a destination address
and a start command, then stream the program a byte at a time, each byte acknowledged by
echoing a rolling index back through `$2140`. snes86 uploads the assembled synth
(`spc_midi.asm` → `spc_midi64.bin`) to SPC address `$0200` and jumps to it. If the APU
never answers, the machine just runs silent — sound is best-effort and never holds up
the boot.

The synth. Once it's running (`spc_midi.asm`), the SPC program sets up the DSP — master
volume, a directory of BRR waveforms (square, triangle, saw, sine) and a noise channel
for drums — and then spins on a single mailbox byte. A command is packed as
`(seq << 4) | op` in port 3, with arguments in ports 0–2: op selects key-on, key-off,
all-notes-off, or a raw pitch. Key-on maps a General MIDI program to one of six
instruments (a sample plus an ADSR envelope), sets the chosen voice's pitch and volume,
and echoes the command byte back to acknowledge it. Eight DSP voices give eight-note
polyphony.

The card and the sequencer. To the guest, snes86 presents a small MIDI card at I/O port
`$330`: software streams four-byte packets `[delta-frames][status][data1][data2]` to it
and reads port `$331` for the number of free slots, so it can pace itself and never
overrun the buffer (writing `$331` resets and silences everything). Packets land in a
112-slot ring FIFO in WRAM. The piece that ties it together is that the NMI — vblank, 60
times a second — is both the clock and the *only* code that ever touches the mailbox.
Each frame the sequencer counts down each packet's frame-delta, fires the events that are
due (capped at eight per frame to keep the NMI short), turns MIDI note-on/off and
program-change into SPC key-on/off with voice allocation, and sends them across. Because
only the NMI drives the mailbox there is no reentrancy to defend against — even the PC
speaker path just sets a flag that the same NMI turns into a raw-pitch note on voice 7,
so `BEL` beeps come out of the synth too.

Why there's a conversion step. Turning a Standard MIDI File into those per-frame deltas
needs real tempo arithmetic (MIDI ticks and microseconds-per-quarter-note folded into
60ths of a second) — too slow to do live on the emulated 8086. So MIDCONV does it once,
offline, emitting a `.SNM` file that is exactly the packet stream the card wants; MIDPLAY
then just streams packets while watching the free-slot count, and the SNES itself parses
nothing. Both tools ship with Turbo Pascal source in `C:\MIDI`.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the MIDI feature from a user's view.

---

## runpc — the host emulator

`core-c/src/runpc.c` boots a PC disk image on the C core plus the *same* HLE BIOS,
wired to your terminal (stdin/stdout) and the disk image files. No BIOS binary runs
in the guest — exactly the SNES strategy. Boot is the real thing: load sector 0 to
`0000:7C00`, jump with `DL` = drive.

```
usage: runpc [-m kb] [-c] [-v] [-l steps] [-w] [-d disk.img] image.img
  -m KB     conventional memory reported to the guest (default 256)
  -c        exit at the first keyboard wait and print stats (boot-cost measure)
  -v        log the first occurrence of every INT xx / AH=yy (incl. DOS 21h)
  -l N      stop after N guest instructions
  -w        write the modified disk image back to file on exit
  -d img    attach a fixed disk as C: (DL=80h)
```

runpc earns its keep three ways:

1. A development mirror. Reproduce a guest bug on the desktop, with tracing, in
   milliseconds — no SNES layer in the way. If it misbehaves here, it'll misbehave
   there.
2. The reference side of parity. A trace build (`x86trace`) drives the C core in
   lockstep against the 65C816 core (below).
3. It builds our OS. Modern linkers can't read 1982 object files, so
   `msdos/build_io.sh` runs the original Microsoft `LINK.EXE` + `EXE2BIN.EXE`
   *inside runpc* to link our `IO.SYS`. The emulator builds the operating system it
   then boots.

---

## Parity testing

Correctness rests on two independent comparisons. Don't conflate them.

### 1. C core vs hardware vectors

`core-c/tests/run_vectors.py` drives the C core (as a shared library, via `ctypes`)
through the [SingleStepTests 8088 v2](https://github.com/SingleStepTests/8088)
vectors — one file per opcode, captured from a real AMD D8088. For each vector it
sets the initial registers + RAM, single-steps once, and compares the final
registers, segment registers, IP, flags, and every touched RAM byte. Undefined flag
bits are masked per-opcode from `metadata.json`, so only architecturally-defined bits
are checked.

Result: 3,007,000 / 3,007,000 across all 323 opcode files — including
undocumented opcodes (`SETMO`, `SALC`, aliases), the REP-IDIV sign quirk,
microcode-exact divide-error flags, and the 8088 `DAA`/`AAA` quirks.

```sh
cd core-c && make test
python3 tests/run_vectors.py --files 00 F6.4 --fails 3   # focused
```

### 2. C core vs 65C816 core, in lockstep

This is the one that guards the actual SNES port. `snes/test/parity.sh`:

1. Generate a random-but-constrained 8086 instruction stream
   (`test/gen_stream.py`): segments pinned, effective-address base registers kept
   in-window, forward-only jumps, `SP` never clobbered — so both cores stay inside
   the mapped memory window. On top of the random units (string ops, shifts, `GRP3`,
   `CALL`/`RET`, `LOOP`, BCD, segment loads, prefixed memory ops, …) it appends
   directed streams for paths random can't safely emit: software `INT`/`IRET`,
   far `CALL`/`JMP`/`RETF`, `LES`/`LDS`, divide-error traps, and the AAM/AAD/BCD
   sweep.
2. Reference trace: `core-c/build/x86trace` runs the stream on the C core and
   prints all 14 register words per instruction → `expected.txt`.
3. Device-under-test: `build/cputest.sfc` — a headless ROM (no PPU, no NMI) that
   `.INCBIN`s the same stream, runs it through the real `cpu.asm`/`cpu2.asm`, and
   writes a 14-word register snapshot per instruction into WRAM, with sentinels
   (`$CAFE` = done, `$0BAD` = hit an unimplemented opcode). It runs under Mesen
   headless; a Lua runner dumps the snapshots → `got.txt`.
4. Compare: `test/compare.py` diffs the two traces field-by-field and prints the
   first divergence (with disassembled context) or
   `PARITY OK: N instructions, all 14 registers identical at every step`.

Both sides start from an identical canonical state (fixed register seeds, code at
linear `0x1000`, a known data pattern at `0x3000`). The 14 compared fields are
`AX CX DX BX SP BP SI DI ES CS SS DS IP FL`.

```sh
cd snes && ./test/parity.sh 1 1200      # seed, instruction count
```

A companion harness (`test/tracewin.sh`) runs the same lockstep comparison during an
*actual DOS boot* — tens of thousands of instructions — to catch divergences that
only a real workload reaches.

---

## Where to look

| you want… | start at |
|---|---|
| the CPU core + dispatch + lazy flags | `snes/cpu.asm` (header block is the best summary) |
| memory access, segment bases, string/mul/div, BIGMEM seam | `snes/cpu2.asm` |
| the HLE BIOS, the machine, the MIDI card, boot | `snes/dosboot.asm` |
| the SPC-700 synth | `snes/spc_midi.asm` |
| the C reference core | `core-c/src/x86.c` |
| the host PC / build environment | `core-c/src/runpc.c` |
