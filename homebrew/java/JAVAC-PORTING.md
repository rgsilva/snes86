# JAVAC — status, design, and the Small-C port

`javac.c` is a single-pass Java-subset compiler that emits class files
(format version 49.0) for the subset JAVA.COM interprets. It is written
in a **polyglot C dialect** so the same source builds two ways:

- **`make javac-dev`** — clang, the host reference compiler. **Working
  and verified.** Every sample compiles, and the output runs on a
  modern desktop JVM (JDK 26 loads version-49 class files) *and* on
  JAVA.COM under emulated MS-DOS on the SNES. So the compiler is proven
  correct end to end today: `HELLO/FIB/SIEVE/CONCAT/GUESS` all produce
  bytecode that runs, and SIEVE reports the right 1899 primes on both.

- **`make javac-dos`** — the Small-C toolchain, for a binary that runs
  on the guest itself. **cc and asm succeed; the final link is the one
  open step** (see below).

## What it compiles

Exactly the subset JAVA.COM runs: one public class, `static` methods,
32-bit `int` (kept as hi/lo halves so the arithmetic is identical on a
16-bit and a 32-bit host), `boolean[]`/`int[]` arrays, `String`
literals, `+` concatenation (desugared to the same `StringBuilder`
chain javac emits), `System.out.println/print`, `System.in.read()`,
`if/else`, `while`, `for`, `break`, `continue`, `&&`/`||`, comparisons,
`+ - *`. No `/` or `%` (the interpreter has no `idiv`), no long/float,
no objects/fields, no exceptions. Anything else is a clean error with a
line number, never a silent miscompile.

Design: whole source in memory, a declaration pre-scan for forward
method references, then one recursive-descent pass straight to stack
bytecode with classic backpatch chains for control flow and an
in-memory constant-pool builder (deduplicated). No AST. Emits class
version 49.0 deliberately — it predates `StackMapTable`, so no stack
frames are needed, yet modern JVMs still load it.

## The polyglot dialect (what the 1988 Small-C accepts)

The Small-C compiler (Hendrix rev 117, the public-domain kit) is far
narrower than clang. Every rule below was found by compiling under it
and reading the errors; clang tolerates all of them under `-std=c89
-w`. If you extend `javac.c`, keep to:

- **No return type on a function definition.** `foo(a) int a; { }`,
  never `int foo(a) ...`. A leading `int`/`char` on a definition is a
  hard "missing token". (Global *variables* keep their type: `int x;`.)
- **No `#include` mid-file.** The kit reads it, but placed after code it
  desyncs the parser. `scmain.c` inlines the three values it needs
  (`NULL`, `LF`, `stderr`) instead; the I/O functions resolve at link.
- **No subscripting a string literal.** `"abc"[i]` is "can't
  subscript"; copy the literal through `scopy()` first.
- **One pointer per declaration.** `char *a; char *b;`, not
  `char *a, *b;`.
- **No forward function prototypes** (`stmt();` at file scope becomes a
  *definition* and collides). Rely on implicit-int forward references.
- Also assumed throughout: no structs (parallel arrays), no
  `unsigned`/`long`/`void` in our code, no local initialisers, no
  compound assignment beyond what is hand-expanded, `/* */` comments
  only, identifiers unique in 8 characters.

Binary file I/O on DOS uses the kit's raw `read()`/`write()` (not
`fgetc`/`fputc`, which cook CR/LF and `^Z` and would wreck a class
file). `argv[1..]` arrive fine on DOS 2.0 — cc and asm take arguments
the same way; only `argv[0]` needs the DOS-3 Get-PSP call, which JAVAC
does not use.

## The open step: the 1982 linker

With the fetched Small-C kit, `cc javac -m` compiles `JAVAC.C` cleanly
and `asm javac` assembles it. The last stage, Microsoft LINK V2.00
(1982, the one already in `msdos/`), fails with **"Too many segments or
classes."**

Root cause, traced through the OMF: cc emits a separate `CODE`/`DATA`
segment pair per function — 87 segments for JAVAC — which alone
overflows LINK's table. Coalescing the assembly into one `CODE` and one
`DATA` segment (`tools/mergeseg.py`) fixes the segment count, but then
the assembler, driven to a symbol table large enough for the whole
program (`-S3000`), writes a bloated `LNAMES` record (~990 empty name
entries) that overflows LINK's *name* table instead. `-S1000` keeps the
name table small but is too few symbols for JAVAC (undefined-symbol
errors). No single `-S` threads both needles with this LINK.

Paths to finish it (not yet done):
- A newer linker (the kit's `ylink`, or any OMF linker without LINK
  V2.00's fixed tables) — needs its own DOS-2.0 verification.
- Splitting JAVAC into a handful of segments (not 1, not 87) so both
  the segment count and the per-segment symbol table stay under LINK's
  limits.
- Trimming the linked library to only the objects JAVAC references, so
  the cumulative name/segment count across all objects stays low.

Until then, `make javac-dev` is the working compiler; its output is
what ships as the samples, and it is proven on the SNES via JAVA.COM.

## Reproducing

`tools/mkjavac_dos.sh` documents the exact floppy-staged build under
`runpc` (cc on its own floppy for output room, segment-merge, asm,
link) and the point at which it stops. The Small-C kit itself is not
committed; the script notes where to fetch it.
