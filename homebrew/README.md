# homebrew/ — the DOS software we wrote

One folder per tool. Each folder holds the tool's Turbo Pascal source,
its committed `.COM` binary, any generators it owns, and a Makefile with
two targets:

- `make stage` — populate `<tool>/build/` with **exactly** what ships on
  the C: drive as `C:\<TOOL>` (binaries and generated data only — no
  sources: the image can't compile Pascal, so it doesn't ship Pascal).
  The packer (`snes/tools/mkhd_free.py`) walks every `*/build/` by
  convention; adding a tool here needs no packer changes.
- `make recompile` — rebuild the `.COM` from source by driving Turbo
  Pascal 3's IDE inside `runpc`, our own emulated MS-DOS 2.0. TP3 is
  **fetched, not committed** (`fetch_tp3.py`: pinned archive.org image,
  sha256-verified per file, cached in `cache/`; a local
  `disks/tp301.img` is preferred when present). Borland/Embarcadero
  retain all rights to TP3 — we treat it exactly like the ELKS and
  FreeDOS images: fetch at build time, never redistribute.

The shared machinery lives here at the top: `tpcompile.sh` (the compile
driver: `sh tpcompile.sh <tool> <name>`), `mk_tpc_img.py` (builds the
scratch boot floppy from `msdos/msdos.img`), `fatimg.py` (FAT12
plumbing), `fetch_tp3.py`, and `vdbg.pas` — a scratch harness that runs
`inline()` machine-code blocks in the TP3 IDE with text output, the fast
loop for developing inline asm (`python3 mk_tpc_img.py build vdbg.pas`
is not needed; copy your experiment into `vdbg.pas` and run
`sh tpcompile.sh . vdbg` — or drive the IDE directly with the `R`un
keystroke as described below).

## Turbo Pascal 3 lessons (paid for; do not re-learn)

- **Sources must be CRLF.** LF-only source "compiles" to a broken
  program with no error. Keep every `.pas`/`.inc` CRLF; when patching
  from Python, use `\r\n` strings and assert every replacement.
- **TP3 keeps SS ≠ DS.** Locals are `SS:[BP+x]` — invisible to
  DS-relative `inline()` machine code, and `[bp]` stores go to the
  stack segment. Inline-loop state lives in *globals*; memory writes go
  through `ES:DI` after `push ds / pop es`. DOS-call pointers to locals
  need `Seg(x)`, not `DSeg`.
- **Parameters need named string types** (`type Str80 = string[80]`),
  bare `string` params don't compile.
- **Typed constants are CS-relative** — never reference them from
  `inline()`.
- **No 32-bit integers.** File offsets and Java ints alike are word
  pairs; VIEW reads files strictly forward so it never needs a 32-bit
  seek.
- TP3 compiles `x*3` to a real 8086 `MUL` (~120 cycles); write
  `x+x+x`. At snes86 speed every instruction in a per-pixel loop is
  about a minute of total runtime — see `view/mkviewasm.py` for the
  generated-machine-code approach when Pascal isn't fast enough.

## The tools

| dir | ships as | what |
|---|---|---|
| `view/` | `C:\VIEW` | BMP/PCX viewer, 640×200 halftone / 320×200 colour, slideshows |
| `ted/` | `C:\TED` | controller-first text editor (on the DOS PATH) |
| `java/` | `C:\JAVA` | Java class-file interpreter + JAVAC (our on-machine Java compiler) + sample `.JAV` sources and `.CLA` bytecode |
| `midi/` | `C:\MIDI` | MIDPLAY/MIDCONV + the generated CC0 demo tune |
| `sokoban/` | `C:\SOKOBAN` | our CGA game |
| `bench/` | `C:\BENCH` | SIEVE/HELLO + the CGA test cards |

Sample data policy: `java/samples/` keeps the `.java` sources and the
`javac --release 8` bytecode committed together (`mkjava.sh` rebuilds
them when a JDK is around), and the image ships only the bytecode —
the rule everywhere is *ship source only if the machine itself could
build it*. When the Small-C milestone lands, `C:\CC` ships C sources,
because there the rule passes.
