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

Anything past 108 KB has to come off the cartridge, and the code that makes that
possible is the `SA1` build flag. It buys one machine and one only: guest RAM above
108 KB is the SA-1 board's 256 KB of BW-RAM, banks `$40`–`$42` (the fourth, `$43`,
stays the B: disk), for a 300 KB guest. The board is a RAM expander and nothing
else — the SA-1 CPU is never released from reset; only the Super MMC and the BW-RAM
chip are used. Three variants ride it: `make msdos_sa1`, `make freedos`, and
`make elks`.

`SA1` is both the region layer and the machinery the layer needs: 16-bit accesses
that straddle the seam go through seam-safe helpers (`rd16m`/`wr16m`) that split
the word across regions, and every 16-bit path — the stack, `MOV`, the flattened
ALU bodies — routes through them. There used to be a second flag, `BIGMEM`, that
held the machinery separate from the machine, because the big guest could once be
aimed at either of two region layers: BW-RAM, or 64 KB of plain cartridge SRAM as
two 32 KB half-banks at `$70`/`$71`, which made a 172 KB guest. The SRAM layer is
gone — its last user, the ELKS ROM, moved to the SA-1 board — and with only one
big machine left the two flags were synonyms, so they were collapsed into `SA1`.
The name states the hardware requirement, which is the thing a reader most needs
to know.

BW-RAM banks are *contiguous* in SNES address space, unlike the `$70`/`$71`
half-banks were, so 24-bit pointer arithmetic carries `$40:FFFF → $41:0000` on its
own and the only real seam left in the guest is WRAM top → BW-RAM.

The fold itself is one rule — a naive pointer is `$7E5000 + linear`, so guest
RAM above 108 KB appears at naive banks `$80`–`$82` and folds to `$40`–`$42`
with the offset kept; naive `$83`+ is past the top of memory and is deliberately
left unfolded. The trap is *where* that rule has to be applied. Segment bases
are folded once at load time (`norm_base_x`), so `norm_ptr` normally only has to
catch a WRAM base spilling into `$80` — **except** that a `2E` (CS) segment
override deliberately feeds the *naive* `bCSc` base into the EA math, so a
CS-relative access can arrive at `norm_ptr` as `$81` or `$82`. Folding only
`$80` there looks correct and boots fine up to 172 KB of guest, because that is
exactly where naive bank `$80` runs out. Above it, MS-DOS 2.0 relocates SYSINIT to the
top of memory and runs it there, and SYSINIT is full of `2E A1` CS-relative
loads — every one of them silently read the SA-1 system-area mirror as 0, the
DOS kernel's INT 20h–2Fh vectors never got installed, and the `EXEC` of
`COMMAND.COM` fell through to the BIOS `IRET` stub. Every fold site
(`norm_base_x`, `norm_ptr`, `norm_ptr2`, `norm_fp`) must use the full
`$80`–`$82` map, not just `$80`.

That same "past the seam is real memory now" property is what makes the SA-1
build the only one whose B: sector copies have to be seam-aware: it is the only
machine where a B: drive and guest RAM above `$7F:FFFF` coexist, so a guest
sector buffer can straddle the seam, and naive `[mPTR],y` indexing would run off
into `$80:xxxx` — which on this map is the emulator's own low WRAM.

---

## The HLE BIOS and the "machine"

`snes/dosboot.asm` is the virtual PC around the CPU: the BIOS, the hardware, and the
boot path. Every guest IVT vector points at an `IRET` stub; an interrupt hook
dispatches BIOS calls natively.

| INT | service |
|---|---|
| 10h video | set mode (40/80-col text, CGA graphics 4/5/6), cursor, scroll, read/write char+attr, teletype, set pixel / read pixel, palette/border. Includes an ANSI/CSI escape parser (cursor moves, clears, SGR colors) for `ANSI.SYS`-style output. |
| 11h equipment | returns "two floppies, 80×25 color" — on every machine, since B: always has somewhere to live: 32 KB of cart SRAM on the public build, BW-RAM bank `$43` on the SA-1 board. |
| 12h memory size | returns the guest RAM size — 108 KB, or 300 on the SA-1 board. |
| 13h disk | A: is a read-only 360 KB floppy image in ROM banks 2–13 (40 cyl × 2 heads × 9 spt); B: is a writable battery-backed disk — 32 KB of cart SRAM normally, BW-RAM bank $43 on the SA-1 board; C: is a hard-disk image, whose upper 2 MB needs a bank fixup on the SA-1 map ($C0-$DF linear, not the LoROM mirrors). Reads are native DMA block copies. Services: reset, status, read, write, verify, get-params, seek, recalibrate. |
| 16h keyboard | read key (blocks by *rewinding IP* so the INT re-executes until a key arrives), peek/status, shift flags — the extended API (AH=10h/11h/12h) aliases onto these, since the single unfiltered ring makes the extended read the same read (that's how F11/F12 from the on-screen keyboard reach a guest). Keys come from the guest BIOS keyboard ring or the emulator's own ring. |
| 1Ah timer | tick count (an ~18.2 Hz NMI-derived 16.16 accumulator, mirrored into the guest BDA), set tick count. |
| 9 (HW) | the keyboard hardware interrupt: port-60h scancode latch + queue. A guest that installs its own INT 9 handler owns the keyboard: the queue is delivered as IRQ1 and the BIOS ring stops being filled. Such a handler reads the scancode from port 60h and derives Shift/Ctrl/Alt from the raw stream itself, so make/break codes for the modifiers are queued around the key (`2A/AA`, `1D/9D`) — and it may gate on the BDA video-mode byte at 40:49, which the video code therefore keeps live on every mode change (Windows 1.01 does exactly this). |

### The display: CGA on a SNES PPU

The guest believes it's driving a CGA card; the renderer turns that into SNES tiles and
palettes every frame. Writes to `B800:xxxx` land in the 16 KB adapter RAM at `$7E:1000`,
and a per-frame scanner rebuilds the visible screen from it — the CPU core never blocks on
drawing.

Text, and the 64-column trick. The console runs in PPU mode 5, which is 512 pixels wide —
exactly 64 character columns of 8 pixels. Mode 5 is also a two-layer mode, and snes86 uses
both at once: each 16-pixel tile slot carries two character cells, the even column on BG2
(2bpp) and the odd column on BG1 (4bpp). A character is therefore a single tilemap write,
and vertical scrolling is a ring over the tile rows via the scroll register. The 8×8 font
(`snes/tools/mkfont.py`) is emitted as two copies to match — 2bpp for BG2, 4bpp for BG1 — and
DMA'd into VRAM at boot.

Colours, without a 256-entry palette. A CGA cell is a character plus an attribute byte
(foreground, background, blink) — far more fg/bg combinations than the SNES has palettes
for, so snes86 hands them out on demand. Glyphs are drawn with palette colour 1 as their
background and colour 2 as their foreground, so one SNES palette encodes exactly one CGA
(background, foreground) pair. Two are fixed: pair 0 is the classic green-on-black DOS
console, pair 7 is the on-screen keyboard's yellow highlight. The rest are dynamic — the
first time an attribute byte appears on screen, `sr_alloc` claims a free palette, writes
that attribute's two colours into CGRAM during vblank, and records it in a lookup table;
the scanner then points each cell at whatever palette its attribute resolved to. A handful
of pairs are available (1–3 and 5–6); once they're spent, further attributes fall back to
green. Pair 4 is unusable for text — its 2bpp CGRAM entries *are* pair 1's 4bpp ones — which
is exactly why the CGA graphics palette gets to live there (see below). The 16 CGA colours
themselves become 15-bit SNES RGB through a build-time table
(`snes/tools/mkcgalut.py`), and ANSI.SYS SGR colours map in through a small ANSI→CGA index table.

40 and 80 columns. Modes 0/1 are 40 columns, modes 2/3 are 80. The physical console is 64
columns wide, so 40-column text just fits. Eighty don't — so the scanner renders a 64-column
window into the full-width buffer and lets you pan it: the L/R shoulder buttons slide `kPAN`
from 0 to 16, moving the window across the 80 columns. The buffer always holds the true
80×25; you're just seeing 64 of them at a time.

CGA graphics. The four-colour modes (4/5 — 320×200) switch the display to a third layer,
BG3, with its own 2bpp tilemap and tiles in VRAM: 256 of the 320 pixels are on screen and
L/R hardware-scroll to the rest. The guest's bitmap in adapter RAM is blitted into the
tiles one tile row per frame (a full repaint every 25 frames), the four-colour CGA palette
goes to CGRAM, and `INT 10h` teletype in a graphics mode blits font glyphs straight into
the bitmap; scrolling shifts the whole bitmap up eight scanlines.

The graphics palette gets its own CGRAM group. The bitmap layers are 2bpp, so a tilemap
palette *p* maps pixel values 1–3 onto CGRAM 4*p*+1…4*p*+3 — and value 0 is transparent on
any SNES background layer, so the CGA background colour is simply the backdrop (CGRAM 0).
`pal_apply` puts values 1–3 in group 4 (CGRAM 17–19), the one 2bpp group with no text pair
of its own. That keeps the CGA colours clear of pair 0 (CGRAM 1/2) — which is what the
on-screen keyboard's normal keys are drawn in, and which the guest's palette would otherwise
repaint out from under them: in mode 6 both entries became the mono foreground and every key
label vanished into its own background, leaving only the pair-7 highlight visible. Group 4's
2bpp entries are dynamic pair 1's 4bpp entries, so `gfx_exit` puts those two colours back on
the way out (`t_kbdgfx` is the regression leg).

Mode 6 — CGA's 640×200 hi-res mono — gets its own machine. The whole frame stays in SNES
mode 5 (the same 512px hi-res the text console uses) with the bitmap on BG2 as 2bpp tiles,
shown as a 512-pixel window that L/R pan across the 640 by re-render, exactly like 80-column
text. The conversion is almost free — a 1bpp CGA byte *is* the SNES plane-0 byte, so unlike
mode 4 there are no lookup tables — but the window is 1,600 tiles and a 2bpp layer can only
address 1,024 from one char base, so the HDMA channel that splits the screen for mode 4
(no longer needed: there's no mode split) is repurposed to re-point the BG2 character base
per band of tile rows. The on-screen keyboard survives untouched: its maps and fonts stay
resident, and the keyboard region's HDMA entries simply point BG2 back at the text font.

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

See [COMPATIBILITY](COMPATIBILITY.md) for the MIDI feature from a user's view.

### A real keyboard: the Pico adapter on port 2

The plain cartridge (`msdos.sfc`, and the `make boot` ROMs) also takes keys from
the Pico W adapter built for [SNOS](https://github.com/rgsilva/snos): a Pico W on
controller port 2 with a USB-console or Bluetooth keyboard behind it. The firmware
is SNOS's, unchanged (`pico/` and `docs/pico-adapter.md` in that repository cover
the wiring and the protocol); snes86 speaks just enough of its link to be handed
the keyboard channel. The SA-1 machines assemble without any of this. All of it is
`pk_*` in `dosboot.asm`.

The wire. Five conductors, the console is the master: each bit is a `$4016` write
(LATCH carries the console's bit) followed by a `$4017` read (DATA1 returns the
adapter's bit, inverted, and the read is the clock). A frame is 64 bytes each way,
MSB first, and the adapter finds its start by the 300 µs of silence before it.
`pk_xfer` is that exchange, with the bit cell SNOS runs on real hardware.

The link. A frame is `[seq][ack][flags][checksum]` and then records
`[channel][length][bytes]`. The console probes with bare frames; once an adapter
answers it sends SYN until the adapter acknowledges it, and takes nothing before
that, so keys left in the adapter by an earlier session are dropped rather than
typed. After that it only acknowledges. Channel `$11` records are key bytes; every
other channel is stepped over.

The keys. The firmware has already translated its US layout, so a key arrives as
ASCII, Ctrl-letter as 1–26, or `$1C`–`$1F` for an arrow. `tools/mkpickeys.py`
generates the table that turns each byte back into the INT 16h word and the
modifier a guest with its own INT 9 handler must see held around it, and the key
goes through `kb_push`, the same door the on-screen keyboard uses. In between sits
a 127-byte FIFO, drained only while the INT 16h ring and the INT 9 queue have
room; while the FIFO could not hold another frame the console stops asking, and
the adapter keeps the keys.

What the firmware does not send, snes86 cannot type: there are no function keys,
no Alt, no Home/End/PgUp/PgDn/Ins/Del and no key releases on the wire. The
on-screen keyboard still has F1–F12.

The cost. One exchange is ~107,000 master cycles, 79 scanlines, close to a third
of a frame, so the NMI rations them. The adapter writes its next frame when an
exchange ends and holds one more in front of it, so a key crosses on the third
exchange after it is pressed. Periodic exchanges therefore come in pairs, a frame
apart, and the frame after any exchange *peeks*: it clocks three bytes of the frame
the adapter has staged (a burst the adapter drops by its length, as it drops the
auto-joypad read) and runs another exchange only if the flags say there are
records. Nothing starts past scanline 116 (CGA mode 4 keeps the NMI busy until
line 86): the handler has to be out before the next vblank. The time between
pairs depends on what the guest is doing:

| the guest… | a pair every | costs |
|---|---|---|
| has no adapter answering | 240 frames | under 1% |
| is blocked in INT 16h AH=0 | every frame | nothing it could use |
| got a key in the last second | 4 frames | |
| keeps asking INT 16h AH=1 for a key | 8 frames | |
| is doing something else | 16 frames | about 6% (measured on `DIR`) |

Measured against the adapter model in `test/t_pico.lua`: a key typed at an idle
`C:\>` reaches the guest in 50–150 ms, and in 35–85 ms once typing is under way.

---

## Booting Linux: the ELKS machine

`make elks` builds `snes/build/elks.sfc`: the same 8086 core and HLE BIOS, reshaped to
boot [ELKS](https://github.com/ghaerr/elks) 0.9.1 — a real Linux-family kernel for
real-mode x86 — to a root shell. Everything below is `.IFDEF ELKS`-gated; the DOS
builds are byte-identical with the variant compiled out.

It needs the SA-1 cartridge, like `msdos_sa1` and `freedos`, and for Linux that is
not a detail. On the old 172 KB machine the kernel could not fork `/etc/rc.sys`
and `ls` answered *"not enough memory"*; at 300 KB `rc.sys` runs, `ls` works, and
`meminfo` reports 233 KB used / 171 KB free where it used to report 105 KB free.
Moving ELKS onto the SA-1 board was what let the second region layer be deleted,
so the unification and the feature arrived together.

**Execute-in-place from cartridge ROM.** ELKS's ROM configuration keeps kernel
*code* in ROM and only its data in RAM, and since v0.9.0 application text also runs
in place from the ROM filesystem. snes86 maps two windows of the guest's 1 MB
address space straight onto cart ROM banks: the 64 KB kernel at guest `E0000`
(banks 14–15) and the 128 KB ROMFS at `80000` (banks 16–19). RAM is the 300 KB
SA-1 pool — with the kernel's code out of the way, 171 KB is free for processes
at the shell. Boot enters the kernel image's option-ROM INT 19h handler
at `E000:0014`; the root filesystem mounts from the ROMFS window with zero disk
I/O.

**The fold, and why bases stay naive.** The two windows live at naive banks
`$86`–`$8D` (a naive pointer is `$7E5000 + linear`), which is clear of the
`$80`–`$82` range the SA-1 layer folds into BW-RAM — that disjointness is why the
two schemes compose without either having to know about the other. The SA-1 Super
MMC is programmed at reset so that `$80–$BF:8000` is the plain LoROM view of the
low 2 MB, so a window bank addresses exactly the ROM file bank it always did. A
guest pointer into a window has to land in a LoROM bank's `$8000–$FFFF` half: `bank = B0 + (F>>15)`, `off = $8000 |
(F & $7FFF)` for window offset `F`. The crucial design rule, learned the hard way:
**segment bases are left "naive"** (plain `GUEST_BASE + seg*16`), and the fold
happens exactly once, at point of use, on the summed pointer (`norm_ptr` /
`norm_ptr2` / `norm_fp`). Folding bases first looks cheaper but is unsound — the
folded space is not closed under 16-bit offset arithmetic (a carry past a 32 KB
chunk top lands in the next bank's low half, which aliases with legitimate folded
pointers). Naive space *is* closed, so folding the sum is always unambiguous. The
fetch path keeps a dedicated naive CS base (`bCSc`) as its only fold input; the
per-instruction rebased `bCS` the fetch sites read through is derived scratch,
never an input. The CS-override prefix points at `bCSc` for the same reason.

**The seam bounce.** An instruction *starting* in the last bytes of a 32 KB chunk
spills its operand bytes past the bank top — naively into the next bank's low half
(open-bus mirrors, not ROM). When `fetch_rebase` sees the fetch pointer within 5
bytes of a chunk top, it copies 8 bytes (chunk tail + next chunk head) into a WRAM
bounce buffer and fetches that one instruction from there; the next instruction
re-derives from `bCSc` and leaves the bounce automatically. This single bug —
kernel code crossing the chunk boundary at file offset `$7FFF` — once explained
every mysterious ELKS symptom at once (failed forks, a missing login prompt,
phantom output).

**An interrupt wakes HLT.** DOS itself never executes HLT; ELKS idles in it. Two
rules born here and since promoted to every build (a DOS app idling in `STI;HLT`
used to freeze the machine): `run_slow`'s tick/key delivery clears `gHALT` when it
vectors an interrupt (8086 semantics — otherwise a HLT with a tick already pending
vectors the handler and then re-parks forever with the handler's IF=0), and the
halted `wai` loop re-enters `run_slow` on IF=1 instead of parking. IF=0 still parks:
that's a genuinely dead guest.

**The interrupt shadow.** A real 8086 holds interrupt delivery off for one
instruction after any segment-register load (`MOV`/`POP sreg`) and after `STI` —
that's what makes a `MOV SS,x` / `MOV SP,y` stack switch atomic and the `STI;HLT`
idiom safe. Both cores implement it (`gINHIB` here, the inhibit latch in
`core-c`), and the deterministic trace tick honors it identically on both sides: a
tick due during the shadow lands one instruction late, in lockstep.

**Small BIOS honesty.** INT 15h answers CF=1/AH=86h (the XT "unsupported" reply —
vectoring to the IRET stub makes ELKS's A20 probe "succeed" with garbage); port 64h
reads as an idle keyboard controller; INT 13h reports no fixed disk (banks 14+ hold
the ELKS images, not C:); BW-RAM is zeroed at reset so the machine is deterministic
and matches the C-core oracle (Mesen randomizes and persists it).

**Lockstep, deep.** `test/elkstrace.sh` is tracewin's ELKS twin, with one upgrade:
both sides tick *deterministically on the instruction count* — `runpc -T` fires
its timer every N instructions and treats a halted CPU as no-op steps, and the
TRACE build mirrors `x86_irq` exactly (IF=0: dropped; IF=1: wake + vector) from a
countdown of its own. That makes windows valid at any depth: the ELKS boot was
verified register-exact against the C core through step 450,000 — through init,
fork and exec. (ELKS TRACE builds also relocate trace records into the VBUF
adapter RAM: the DOS location is live guest memory during an ELKS boot, and the
text page gets overwritten by the guest's own console output — both produced
convincing phantom divergences before they were evicted.)

---

## runpc — the host emulator

`core-c/src/runpc.c` boots a PC disk image on the C core plus the *same* HLE BIOS,
wired to your terminal (stdin/stdout) and the disk image files. No BIOS binary runs
in the guest — exactly the SNES strategy. Boot is the real thing: load sector 0 to
`0000:7C00`, jump with `DL` = drive.

```
usage: runpc [-m kb] [-c] [-v] [-l steps] [-w] [-d disk.img] [-T steps]
             [-kdelay N] [-rom FILE@SEG] [-entry SEG:OFF] [-tick N]
             [-cga out.ppm] image.img
  -m KB     conventional memory reported to the guest (default 256)
  -c        exit at the first keyboard wait and print stats (boot-cost measure)
  -v        log the first occurrence of every INT xx / AH=yy (incl. DOS 21h)
  -l N      stop after N guest instructions
  -w        write the modified disk image back to file on exit
  -d img    attach a fixed disk as C: (DL=80h)
  -T N      print a "T ..." register-state line per step for the first N steps
            (stderr); freezes INT 1Ah ticks for lockstep traces
  -kdelay N hold keyboard input until step N (ELKS's login flushes the tty,
            eating anything typed during boot)
  -rom F@S  map a file read-only at hex segment S in the 1 MB space (the ELKS
            kernel + ROMFS windows); verified unwritten at exit
  -entry S:O start at SEG:OFF instead of the boot sector (diskless ROM boot)
  -tick N   timer cadence in instructions (default 15000; ~800 mimics the SNES)
  -cga f    dump the CGA B800 bitmap to f as a PPM on exit / mode-away
  -krate N  instructions between piped keys (default 16384) — full-screen
            guests that flush type-ahead per screen need a slower script
  -dump S:O,L  hexdump L bytes of guest memory from SEG:OFF (all hex) to
            stderr at exit; pipe it to `ndisasm -b 16` to read guest code
```

A guest that executes HLT with IF=1 idles (skip to the next tick and wake) instead
of ending the run; under `-T` the timer fires *deterministically on the instruction
count* and a halted CPU burns steps one at a time, mirroring the SNES TRACE build
exactly — that's what lets ELKS lockstep run arbitrarily deep.

runpc earns its keep four ways:

1. A development mirror. Reproduce a guest bug on the desktop, with tracing, in
   milliseconds — no SNES layer in the way. If it misbehaves here, it'll misbehave
   there.
2. The reference side of parity. A trace build (`x86trace`) drives the C core in
   lockstep against the 65C816 core (below).
3. It builds our OS. Modern linkers can't read 1982 object files, so
   `msdos/build_io.sh` runs the original Microsoft `LINK.EXE` + `EXE2BIN.EXE`
   *inside runpc* to link our `IO.SYS`. The emulator builds the operating system it
   then boots.
4. It brought up Linux. ELKS booted to a login prompt on runpc (`-rom`/`-entry`)
   before a single line of 65C816 changed — every HLE gap surfaced at desktop
   speed, and runpc then served as the oracle that debugged the SNES machine
   (see [Booting Linux](#booting-linux-the-elks-machine)).

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
only a real workload reaches. Its ELKS twin (`test/elkstrace.sh`) goes further:
with deterministic instruction-counted ticks on both sides, its windows are valid
at any depth, and the ELKS boot is verified register-exact through step 450,000.

---

## Where to look

| you want… | start at |
|---|---|
| the CPU core + dispatch + lazy flags | `snes/cpu.asm` (header block is the best summary) |
| memory access, segment bases, string/mul/div, the SA-1 seam | `snes/cpu2.asm` |
| the HLE BIOS, the machine, the MIDI card, boot | `snes/dosboot.asm` |
| the Pico keyboard on port 2 | `pk_*` in `snes/dosboot.asm`, `snes/tools/mkpickeys.py`, `snes/test/t_pico.lua` |
| the ELKS variant: ROM windows, folds, seam bounce | `snes/elks.asm` + the `.IFDEF ELKS` blocks in `cpu.asm`/`cpu2.asm`/`dosboot.asm` |
| the deep ELKS lockstep harness | `snes/test/elkstrace.sh` |
| the SPC-700 synth | `snes/spc_midi.asm` |
| the C reference core | `core-c/src/x86.c` |
| the host PC / build environment | `core-c/src/runpc.c` |
