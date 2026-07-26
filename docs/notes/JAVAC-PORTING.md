# JAVAC — design notes and the Small-C port war story

`javac.c` is a single-pass Java-subset compiler that emits class files
(format version 49.0) for the subset JAVA.COM interprets. One source,
two binaries:

- **`javac.exe`** (a build product — not committed; every image build
  recreates it) — the DOS binary that ships in `C:\JAVA`. Built by the
  1988 Small-C 2.2 toolchain running on MS-DOS 2.0 inside our own
  emulator (`tools/mkjavac_dos.sh`, deterministic —
  re-running rebuilds it byte-identically). Compiles every sample at
  `-m 108` (108 KB of guest RAM).
- **`make javac-dev`** — the same compiler built with clang for the
  host. Its output is **byte-identical** to `javac.exe`'s for all five
  samples: the compiler keeps every int in −32768..32767 and carries
  32-bit Java literals as four byte-limbs precisely so a 16-bit and a
  64-bit host compute the same bytecode.

Verified end to end: all five samples compile on the guest, run on
JAVA.COM (Sieve: the right 1899 primes), and the same class files pass
a modern desktop JVM's verifier (version 49.0 predates StackMapTable,
so no stack frames are needed, yet JDKs still load it).

## What it compiles

Exactly the subset JAVA.COM runs: one public class, `static` methods,
32-bit `int`, `boolean[]`/`int[]` arrays, `String` literals, `+`
concatenation (desugared to the same StringBuilder chain javac emits),
`System.out.println/print`, `System.in.read()`, `if/else`, `while`,
`for`, `break`, `continue`, `&&`/`||`, comparisons, `+ - *`. No `/` or
`%` (the interpreter has no `idiv`), no long/float, no objects/fields,
no exceptions. Anything else is a clean error with a line number,
never a silent miscompile.

Design: whole source in memory, a declaration pre-scan for forward
method references, then one recursive-descent pass straight to stack
bytecode with classic backpatch chains for control flow and a
deduplicated in-memory constant-pool builder. No AST.

## The Small-C dialect (historical — no longer a constraint)

Ricardo has since dropped the self-hosting goal (`javac.c` will not be
compiled ON the SNES), so the dialect below documents how `javac.exe`
was built; it is not a rule for future edits. If you change javac.c,
also check the Small-C build still compiles it (`make apps` rebuilds
`javac.exe` via `tools/mkjavac_dos.sh` and byte-compares its output
against the clang build's).

The 1988 Small-C 2.2 (Hendrix, rev 117) rules, each found the hard way:

- **No return type on a function definition.** `foo(a) int a; { }`,
  never `int foo(a)`. (Global *variables* keep their type.)
- **No `#include` mid-file** — desyncs the parser after real code.
- **No string-literal subscripts** (`"abc"[i]`): copy through a helper.
- **One pointer per declaration**: `char *a; char *b;`.
- **No forward prototypes** — implicit-int forward references only.
- **`main(argc, argv) int argc, *argv;` + CLIB `getarg()`** — cc
  *accepts* `char *argv[]` and then silently emits main's body as
  file-scope garbage (statements become fake function definitions;
  the damage only surfaces later as assembler "Phase Error"s).
- **No local arrays** — another silent miscompile; buffers are globals.
- **`fputc`, not `putc`** — CLIB has no PUTC module.
- Plus the baseline: no structs (parallel arrays), no
  `unsigned`/`long`/`void`, no initialisers, `/* */` comments only,
  identifiers unique in 8 chars, ints assumed 16-bit.

Binary file I/O uses CLIB's raw `read()`/`write()` (CSYSLIB), not
`fgetc`/`fputc` — those cook CR/LF and `^Z` and would wreck a class
file.

## The three toolchain walls (and how the build dodges them)

1. **LINK V2.00 "Too many segments or classes."** cc opens a fresh
   `CODE`/`DATA` segment pair around *every function* — 87 segments
   for JAVAC — overflowing the 1982 linker's fixed table.
   → `tools/mergeseg.py` coalesces the generated .ASM into one CODE +
   one DATA segment before assembling (same-name PUBLIC segments would
   have been combined by the linker anyway).

2. **`asm -S3000` writes a corrupt object.** The Small Assembler is
   itself a 16-bit Small-C program; a 3000-symbol table overflows its
   own 64 KB data segment and the OBJ comes out as ~24 KB of junk
   LNAMES records with no code. JAVAC has only ~600 labels — the
   *default* table (1500) is plenty. No `-S` flag, no corruption.

3. **The 360 KB floppy wall.** cc's 113 KB .ASM plus the toolchain
   plus DOS cannot share one floppy; the overflow silently truncates
   the .ASM mid-write (35 SEGMENTs, 34 ENDS — hours of confusion).
   → the build puts the toolchain on a read-only *hard disk* image
   (`runpc -d`, the same fixed-disk support the SNES build uses) and
   keeps only the work files on the writable A: floppy.

`tools/mkjavac_dos.sh` runs the whole pipeline (cc → mergeseg → asm →
link, two runpc sessions) and is what produced the committed binary.

## Provenance

Compiler and drivers: this repo (`javac.c`, `ccmain.c`, `scmain.c`).
Toolchain: public-domain Small-C 2.2 kit (Hendrix) — CC.EXE, Small
Assembler, exploded CLIB objects — committed in `apps/cc/` (see its
ORIGIN.md; `KIT=` still points the build at an external kit).
Linker: Microsoft LINK V2.00, already in `msdos/`. Host: our own
`runpc` on our own MS-DOS 2.0 build.
