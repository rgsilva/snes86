# What runs on snes86

snes86 runs ordinary DOS software — it emulates an 8086 and an IBM-PC-class BIOS, so
period programs generally just work. This page lists what's been exercised.

Two things to keep in mind:

- The public ROM ships only free software (our own tools + a demo). Everything else
  below is bring-your-own: drop it in `snes/userware/` and rebuild (see
  [BUILDING.md](BUILDING.md)). A "✅ tested" mark means the emulator runs it, not that
  it's included.
- Everything here was verified against the cycle-accurate Mesen emulator. Real
  hardware is still pending — see [Help wanted](#help-wanted).

## Gallery

All captured from snes86 running in Mesen.

<table>
<tr>
<td align="center"><img src="assets/boot.png" width="400"><br><sub>MS-DOS 2.0 booting to <code>C:\></code></sub></td>
<td align="center"><img src="assets/pcdos.png" width="400"><br><sub>PC DOS 2.00 — the original bring-up target</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/gwbasic.png" width="400"><br><sub>GW-BASIC 3.23</sub></td>
<td align="center"><img src="assets/tp3.png" width="400"><br><sub>Turbo Pascal 3.01 — the compiler that builds our tools</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/wordstar.png" width="400"><br><sub>WordStar 3.31</sub></td>
<td align="center"><img src="assets/multiplan.png" width="400"><br><sub>Multiplan</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/zork.png" width="400"><br><sub>Zork I — Infocom interactive fiction</sub></td>
<td align="center"><img src="assets/zork2.png" width="400"><br><sub>Zork II: The Wizard of Frobozz</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/zork3.png" width="400"><br><sub>Zork III: The Dungeon Master</sub></td>
<td align="center"><img src="assets/planetfall.png" width="400"><br><sub>Planetfall</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/wishbringer.png" width="400"><br><sub>Wishbringer</sub></td>
<td align="center"><img src="assets/sokoban.png" width="400"><br><sub>Sokoban — our own CGA game, with source</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/rogue.png" width="400"><br><sub>Rogue — the roguelike that named the genre (needs BIGMEM)</sub></td>
<td align="center"><img src="assets/fs1.png" width="400"><br><sub>Microsoft Flight Simulator 1 (<code>make fs</code>)</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/si.png" width="400"><br><sub>Norton SI — Computing Index 0.0 vs the IBM/XT</sub></td>
<td align="center"><img src="assets/midi.png" width="400"><br><sub>MIDPLAY — the SNES as a MIDI synth</sub></td>
</tr>
<tr>
<td align="center"><img src="assets/gameboy.png" width="400"><br><sub>GB.COM — a Game Boy inside DOS inside a SNES: the boot logo, four machines deep</sub></td>
<td align="center"><img src="assets/tetris.png" width="400"><br><sub>Tetris® (1989) title screen — a real cartridge running on GB.COM, on the SNES</sub></td>
</tr>
<tr>
<td align="center" colspan="2"><img src="assets/elks.png" width="480"><br><sub>ELKS 0.9.1 — Linux on the SNES: boot, <code>login: root</code>, <code>uname</code>, <code>meminfo</code>. Kernel and apps execute in place from cartridge ROM (<code>make elks</code>)</sub></td>
</tr>
<tr>
<td align="center" colspan="2"><img src="assets/freedos.png" width="480"><br><sub>FreeDOS 1.3 — kernel + FreeCOM booting to <code>A:\></code> on the 172 KB machine, reading the C: tools (<code>make freedos</code>)</sub></td>
</tr>
<tr>
<td align="center" colspan="2"><img src="assets/view.png" width="480"><br><sub>VIEW.COM — our Turbo Pascal BMP viewer halftoning the MS-DOS logo in CGA mode 6, true 640×200 on hi-res BG2 (M10p6). The image is decoded pixel-by-pixel on the emulated 8086; the full paint takes a few minutes of watching it crawl up the screen, exactly as the eighties intended</sub></td>
</tr>
</table>

> 🎬 The MIDI synth is best heard, not screenshotted — there's a short clip of the demo
> tune playing in [The SNES is your sound card](#the-snes-is-your-sound-card) below.

## Tested software

| category | software | status | notes |
|---|---|---|---|
| OS / shell | MS-DOS 2.0 (MIT) | ✅ shipped | `DIR`, `PATH`, `PROMPT`, batch files, `VER`, redirection |
| | ELKS 0.9.1 (Linux) | ✅ shipped | its own ROM (`make elks`): boots to a root shell; `sh`, `uname`, `ls`, `meminfo`, … — see [Linux on the SNES](#linux-on-the-snes-elks) |
| | FreeDOS 1.3 | ✅ shipped | its own ROM (`make freedos`, BIGMEM): kernel + FreeCOM to `A:\>`, runs the C: tools — see [FreeDOS on the SNES](#freedos-on-the-snes) |
| | PC DOS 2.00 | ✅ tested | the original bring-up target; MS-DOS ships instead, but `.IFDEF PCDOS` still boots it |
| Our tools | MIDPLAY / MIDCONV | ✅ shipped | the SNES-MIDI synth (below), with source |
| | SOKOBAN | ✅ shipped | our own CGA-graphics game, with source |
| | SIEVE / BENCH / HELLO / CGATEST / CGA6TST | ✅ shipped | our benchmarks + demos, with source |
| | VIEW | ✅ shipped | our BMP/PCX picture viewer (Turbo Pascal, with source): 640×200 ordered-dither halftone or 320×200 four-colour, wildcard slideshows (`VIEW *.BMP`); `C:\PICS` ships generated test cards |
| | GB.COM | ✅ tested | our Game Boy emulator, now its own project: [gameboy8086](https://github.com/rgsilva/gameboy8086) — the shots above were taken here |
| Languages | GW-BASIC 3.23 | ✅ tested | interpreter loads and runs |
| | Turbo Pascal 3 | ✅ tested | the compiler that builds our own tools |
| Applications | WordStar 3.31 | ✅ tested | full-screen editor, overlays load from C: |
| | Multiplan | ✅ tested | spreadsheet grid, `.LOD`/`.SYS` overlays |
| Interactive fiction | Zork I–III, Planetfall, Leather Goddesses, Hitchhiker's Guide, Wishbringer | ✅ tested | Infocom's later 8086 interpreter |
| Games | Rogue | ✅ tested* | *needs BIGMEM (see [Memory](#memory)) |
| | Tetris (Game Boy, 1989) | ✅ tested | runs *inside* [GB.COM](https://github.com/rgsilva/gameboy8086) — playable on the host core, title screen captured on the SNES |
| | Microsoft Flight Simulator 1 | ✅ tested | self-booting disk (`make fs`), not a DOS program |
| Benchmarks | Norton SI, CPUBENCH | ✅ tested | CPU/system info + timing loops |

If you get something interesting running, we'd love to hear about it.

## The SNES is your sound card

snes86's headline trick beyond "it boots DOS": it turns the SNES's SPC-700 audio chip
into an 8-voice General MIDI synthesizer, and exposes a small MIDI card to the guest.

<p align="center">
  <a href="https://github.com/rgsilva/snes86/blob/main/docs/assets/mididemo.mp4">
    <img src="assets/midi.png" width="480" alt="Watch the snes86 MIDI demo">
  </a>
  <br><sub>▶ The demo tune played through the SPC-700 — click to watch (Beethoven's
  "Ode to Joy", sequenced as a CC0 MIDI, ~0.4 MB).</sub>
</p>

- MIDPLAY streams music to the synth. Point it at a converted song:
  `MIDPLAY C:\MIDI\DEMO.SNM`.
- MIDCONV converts a Standard MIDI File (`.MID`, format 0) into the `.SNM` packet
  stream MIDPLAY plays. (The conversion does slow real-number math once, so playback
  can be a fast dumb loop.)
- The public ROM includes a generated demo tune — a public-domain melody sequenced by
  the build as an original CC0 MIDI. Type `PLAY` at `C:\>`.
- Even the PC speaker is wired to the synth, so programs that beep make sound.

Both tools ship with Turbo Pascal source in `C:\MIDI`. See
[INTERNALS.md](INTERNALS.md#the-snes-is-your-sound-card) for how the card and synth
work. Bring your own `.MID` files, convert them, and the SNES plays them.

## FreeDOS on the SNES

`make freedos` builds a third-OS ROM: [FreeDOS](https://www.freedos.org/) 1.3 on the
172 KB BIGMEM machine — 172 KB is FreeDOS's exact floor here (the kernel dies during
init at 108 KB, measured on the host core first).

- **Boot** lands at a FreeCOM `A:\>` prompt; the C: drive is the same free image as
  the MS-DOS ROM, so `DIR C:`, the benchmarks and the MIDI tools are all there.
- **Memory is tight**: FreeCOM stays fully resident (no XMS to swap to), so the free
  arena runs the small tools but not big programs — `MEM` itself doesn't fit, which
  says it all. More RAM is the same SRAM-bank lever as the Windows 1.01 plan
  ([FUTURE.md](FUTURE.md#windows-101--proof-of-concept-done-fit--renderer-next)).
- **It found a real bug**: FreeDOS relocates its kernel init to the top of memory,
  which parked live code exactly across the WRAM→SRAM seam at 108 KB — the first
  guest ever to execute across it, and the reason the fetch path now has a general
  seam bounce (the suite's `t_fdos` regression-guards it).
- **Images**: `freedos/mkfreedos.py` fetches the official FreeDOS 1.3 release
  (GPL — checksum-pinned, cached, never committed) and re-packs the kernel + FreeCOM
  into a 360 KB boot floppy. See [freedos/README.md](../freedos/README.md).

## Linux on the SNES (ELKS)

`make elks` builds a separate ROM that boots [ELKS](https://github.com/ghaerr/elks) —
the Linux-family kernel for real-mode x86 — instead of DOS. It is not a DOS program:
the whole machine changes shape (see
[INTERNALS.md](INTERNALS.md#booting-linux-the-elks-machine)).

- **Boot** takes about two minutes to `login:`; log in as `root`, no password.
- **The machine** is the 172 KB BIGMEM guest. The kernel and every application
  execute in place from cartridge ROM; only data, stacks and the heap live in RAM,
  which leaves >100 KB free for processes at the shell.
- **The console** is ELKS's 80×25 headless console over the BIOS: the SNES shows a
  64-column window, and L/R pan across the full 80 columns, exactly like the DOS
  console. Type with the on-screen keyboard (SELECT), or the controller shortcuts
  (START = Enter, B = Backspace, X = Space, Y = Escape).
- **What runs**: the ELKS shell and the ROMFS userland — `sh`, `uname`, `ls`, `cat`,
  `ps`, `meminfo`, `date`, and friends. There is no writable filesystem yet; it's a
  real Unix, if a spartan one.
- **Images**: the build fetches the unmodified official ELKS v0.9.1 release images
  (GPL — never committed to this repo). A custom-built ELKS (e.g. with a smaller
  kernel heap for more process RAM) can be dropped over `build/elks_rom.bin` /
  `build/elks_romfs.bin` before `make elks`.

## Memory

The default guest has ~108 KB of conventional RAM — enough for MS-DOS plus the
software above. A handful of memory-hungry titles need more. The BIGMEM build
(`make big`) extends the guest to 172 KB using cartridge SRAM, which revives Rogue.
BIGMEM is an experiment for DOS — but it's load-bearing for the ELKS ROM, which is
built on the 172 KB machine.

## Known limitations

- No EGA/VGA — the display is CGA/MDA-class (text modes + CGA graphics 4/5/6).
- Disk is a fixed ROM image (A:) plus writable SRAM (B:) and a hard-disk image (C:);
  there's no real removable media.
- Speed is period-appropriate, roughly IBM PC/XT territory, not instantaneous.
- Copyrighted DOS software is not distributed — you supply your own.

## Help wanted

- Real hardware. Everything here was verified in Mesen. If you flash a ROM to a cart
  (the DOS one or the ELKS one) and boot it on a real SNES/Super Famicom, please
  report what you see — it's the one thing we haven't been able to check.
- Videos and captures welcome. Recordings of DOS software (or the MIDI synth) running
  on snes86 are genuinely useful, and fun. Share them.
