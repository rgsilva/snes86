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
