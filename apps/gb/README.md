# GB — a Game Boy inside DOS inside a SNES

`GB.COM` is a Game Boy (DMG) emulator as a 15 KB MS-DOS `.COM`: pure
8086 assembly (`cpu 8086` enforced — it runs on the machine this repo
emulates), CGA output, real cartridge ROMs. It was born in this repo
(as "gbdos"), was split out into its own project, and now ships here
again as an app.

**Provenance**: copied from the owner's standalone repo
[rgsilva/gb8086](https://github.com/rgsilva/gb8086) (also reachable as
`gameboy8086`) at commit `e86c6f6fcbd25bb7eafb3d1300d1921bdb9ce87b`
(MIT). `gb.asm`, `mksm83.py` and the homebrew cart sources
(`smoke.asm`, `gfx.asm`, `joy.asm`) are verbatim copies; the Makefile,
`fetch_blargg.py` and this README are this repo's packaging. Upstream
remains the emulator's home — sync from there, don't fork the core
here.

## Use

`make stage` fills `build/`, which becomes `C:\GB` on the images:
`GB.COM` plus three homebrew test carts (all MIT, built from the
sources here):

```
C:\> CD GB
C:\GB> GB SMOKE.GB          serial hello + ALU sanity, exits cleanly
C:\GB> GB GFX.GB            BG renderer test pattern (hangs by design)
C:\GB> GB JOY.GB            shows the joypad byte - press things
C:\GB> GB -t SMOKE.GB       text mode: serial output to the console
```

Flags: `-t` text mode (Blargg-style serial to console), `-o` also log
serial to `GBOUT.TXT`, `-b` run a real boot ROM first (`DMGBOOT.BIN` in
the cwd — Bootix, CC0; not shipped, see upstream `test/fetch-roms.sh`),
`-rN` render every N frames (default 6), `-sN` dump the CGA framebuffer
to `GBSHOT.RAW` at frame N and exit, `-f` warp busy-waits (capture use
only). Keys: arrows = d-pad, A/X = A, B/Z = B, Backspace/Space =
Select, Enter = Start, ESC quits.

Cartridges: 32 KB, no-MBC only (Tetris, Dr. Mario, Alleyway, homebrew).
Game ROMs are copyrighted — bring your own via `user/` → `C:\USER` or a
`B:` disk; they never ship in this repo. `C:` is read-only, so run from
a writable drive if you want `-o`/`-sN` output files.

## Build

No `gb.com` is committed — `make stage` (and so every image build)
assembles it from source: `mksm83.py` generates the 512 SM83 opcode
handlers (`hostbuild/sm83.inc`), then `nasm -f bin` assembles `gb.asm`
(deterministic). That makes **nasm a required build prerequisite** of
the images.

The homebrew `.gb` test carts ARE committed: rebuilding them needs
RGBDS (`rgbasm`/`rgblink`/`rgbfix`), which stays a canary/dev-only
dependency — `make recompile` rebuilds carts + `gb.com`, and the
`make apps` canary skips the cart rebuild where RGBDS is absent.

macOS: `brew install nasm` (add `rgbds` to touch the carts).

## Test

The suite (`make test`, gb-host leg) runs `SMOKE.GB` from `C:\GB` and
asserts its serial output, then fetches Blargg's cpu_instrs
"06-ld r,r" ROM (`fetch_blargg.py`, pinned sha256, cached in
`apps/cache/`, never committed) and runs it to its `Passed` marker
under runpc. Upstream passes all 11 cpu_instrs ROMs; one ROM here is
the suite-time compromise — the full run lives upstream
(`test/blargg.sh`, which drives this repo's runpc when checked out
side by side).
