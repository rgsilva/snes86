# freeware/

Third-party DOS software that is **not ours** but is **freely redistributable**, staged onto the public ROM's C: drive the same way `homebrew/` tools are: `freeware/<tool>/build/` → `C:\<TOOL>`, populated by that tool's `make stage` (wired into `snes/Makefile`'s staging target).

A package comes in only with an `ORIGIN.md` documenting: where each file came from (source URL), its license with the evidence (the actual PD notice or MIT grant), and a sha256 for every binary. PD or MIT-class redistribution rights, documented — or it stays out. When in doubt, it stays out.

## C compiler

We provide the Small-C toolchain (public-domain compiler + assembler, the MIT MS-DOS linker, runtime, samples) → `C:\CC`. Compiles and runs C entirely inside the emulated machine at the stock 108 KB. You can use it like this:

```
C:\> B:
B:\> COPY C:\CC\HELLO.C
B:\> CC HELLO
...about ten minutes of authentic 1982 compiling...
Built HELLO.EXE - run it by name
B:\> HELLO
Hello from Small-C inside snes86!
```

Your work drive is `B:` — battery-backed cartridge SRAM, so your programs
survive power-off like a game save. The pipeline is three real programs
(`SCC` → `ASM` → `LINK`) driven by `CC.BAT`; ten minutes is the authentic
1982 cadence, not a bug. Two samples ship **with source** in `C:\CC` —
`HELLO.C` and `SIEVE.C` (the latter prints `1899 primes (expect 1899)`
when your patience pays off) — the first source files in this repo
allowed on the image, because the machine itself can build them.

On the desktop reference core the same cycle takes seconds:

```
A:\>cc hello

   Microsoft Object Linker V2.00
(C) Copyright 1982 by Microsoft Inc.

Object Modules [.OBJ]: PROG+C:\CC\ABS+C:\CC\ATOI+ ...
Run File [PROG.EXE]: PROG.EXE
Built hello.EXE - run it by name

A:\>hello
Hello from Small-C inside snes86!
```

<!-- TODO: Mesen screenshot of the CC HELLO build+run on B: — lands with
     the queued B:-workflow verification run -->

The full story — what's in the box, the Small-C dialect, LINK's `VM.TMP`
spills, and how this kit built our Java compiler — is in
[cc/README.md](cc/README.md); provenance and hashes in
[cc/ORIGIN.md](cc/ORIGIN.md).
