# CC — a C compiler on the SNES

This is a real 1980s C toolchain running *inside* the emulated PC, on
the stock 108 KB machine: **Small-C 2.2** and the **Small Assembler**
(J. E. Hendrix, 1988, public domain) plus the **Microsoft Object Linker
V2.00** (1982, MIT — the same binary that links our IO.SYS). Nothing
was patched; these are the stock binaries, provenance and hashes in
[ORIGIN.md](ORIGIN.md).

The tools live on read-only `C:\CC` (found via PATH — DOS 2.x can't
execute by explicit path), and everything you compile lives on your
writable drive: sources, intermediates, the finished `.EXE`. On the
SNES that drive is `B:` — battery-backed cartridge SRAM. You can play
with it as such:

    C:\> B:
    B:\> COPY C:\CC\HELLO.C
    B:\> CC HELLO
    ...about ten minutes of authentic 1982 compiling...
    Built HELLO.EXE - run it by name
    B:\> HELLO
    Hello from Small-C inside snes86!

Ten minutes is not a bug: the pipeline is three real programs — `SCC`
(C → assembly), `ASM` (assembly → object), `LINK` (object + the 69
runtime modules → `.EXE`) — each loaded and run in turn, exactly the
cadence a 1982 floppy developer lived with. On the desktop reference
core (`runpc`) the same cycle takes seconds; here is a real session
from it (the desktop work disk is `A:`; on the SNES it's `B:`):

```
A:\>copy c:\cc\hello.c
        1 File(s) copied
A:\>cc hello

   Microsoft Object Linker V2.00
(C) Copyright 1982 by Microsoft Inc.

Object Modules [.OBJ]: PROG+C:\CC\ABS+C:\CC\ATOI+C:\CC\ATOIB+C:\CC\AUXBUF+
Object Modules [.OBJ]: C:\CC\AVAIL+C:\CC\BSEEK+C:\CC\BTELL+C:\CC\CALL+ ...
Run File [PROG.EXE]: PROG.EXE
Built hello.EXE - run it by name

A:\>hello
Hello from Small-C inside snes86!
```

## What's in the box

- `CC.BAT` — the driver you actually type: `scc` → `asm -S200 -NM` →
  `link @clib.rsp`, with the renames and cleanup handled. (It also
  copies `STDIO.H` onto your work disk first: Small-C's `#include`
  searches only the current directory — 1988 rules.)
- `SCC.EXE`, `ASM.EXE`, `LINK.EXE`, `lib/*.OBJ`, `STDIO.H`, `CLIB.RSP`.
- `samples/HELLO.C` and `samples/SIEVE.C` — shipped **with source** on
  `C:\CC`, the first files in this repo allowed to, because the machine
  itself can build them (the house rule: ship source only if the image
  can compile it). `SIEVE` prints `1899 primes (expect 1899)` when your
  ten minutes pay off.

Notes from the field: `LINK` may drop a `VM.TMP` on your work drive
mid-link — normal 1982 memory-spill behavior, cleaned up by `CC.BAT`.
The dialect is genuine Small-C: `int`/`char`, pointers, one-dimensional
arrays, no structs — see
[docs/notes/javac-porting.md](../../docs/notes/javac-porting.md) for
what it's like to write something big in it (this kit built our Java
compiler).

This toolchain is exercised on every `make test` run (the `cc-host`
leg compiles and runs both samples in-machine); see
[TESTING.md](../../TESTING.md).
