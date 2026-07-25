# Small-C — provenance and license

Third-party software, redistributed under the terms below. First tenant of
`apps/` (see `../README.md` for the admission rule).

## What this is

A complete C toolchain that compiles and runs **inside** the emulated PC, on
the stock 108 KB machine: `CC HELLO` at the prompt of a writable drive
produces and runs `HELLO.EXE`, with the tools on read-only `C:\CC`.

| file | what | version |
|---|---|---|
| `SCC.EXE` (`CC.EXE` here) | Small-C compiler (C → 8086 assembly) | 2.2 rev 117, J. E. Hendrix, 1988 |
| `ASM.EXE` | Small Assembler (assembly → OMF `.OBJ`) | 1.2 rev 14, J. E. Hendrix, 1988 |
| `LINK.EXE` | Microsoft Object Linker (`.OBJ` → `.EXE`) | V2.00, 1982 |
| `lib/*.OBJ` | Small-C runtime, 69 loose modules | with CC 2.2 |
| `STDIO.H` | the standard header | with CC 2.2 |
| `CC.BAT`, `CLIB.RSP` | our driver + link response file | ours, CC0 |
| `samples/HELLO.C`, `samples/SIEVE.C` | sample programs | ours, CC0 |

All binaries are **stock** — nothing was patched. The 108 KB fit and the
read-only-C: operation are purely command-line and environment matters
(see "Mechanics" below).

This directory is also the complete Small-C kit for rebuilding
`apps/java/javac.exe` (`make -C apps/java javac-dos`): CC.EXE +
ASM.EXE + `lib/*.OBJ` are exactly the pieces that build needs, so the
rebuild runs from a clean checkout with no external kit. The rebuilt
`javac.exe` is byte-identical to the committed one.

## Provenance & hashes

- **Small-C, Small Assembler, runtime** — the DosWorld collected archive of
  Hendrix's original releases, <https://github.com/DosWorld/smallc> (`C/`,
  `ASM/`), including full source for every piece. The source tree is >1 MB
  and not vendored here; the upstream repo is the reference. `SHA256SUMS`
  pins every committed kit file (`shasum -c SHA256SUMS` verifies).
  - `CC.EXE`  sha256 `f8cbe4529617463c6f5a563ee1808182bace90e687f15675dbc7a6ce9d843d7e`
  - `ASM.EXE` sha256 `9ef22876ade03d3d4cc86b6e4988318fd70612c553d44f581d01e382e608144f`
- **LINK.EXE** — Microsoft's linker from the MIT-licensed MS-DOS 2.0 source
  release, <https://github.com/microsoft/MS-DOS>; byte-identical to
  `../../msdos/LINK.EXE`, which the boot toolchain already uses.
  - `LINK.EXE` sha256 `fe52892da7bd6832cb88a959cccd230f307e30c7c83a225b2e638f4ea25d76be`

## Licenses

**Small-C / Small Assembler / runtime** — Public Domain, per Hendrix's
*Notice of Public Domain Status*:

> The source code for the Small-C Compiler and runtime libraries (CP/M & DOS),
> Small-Mac Assembler (CP/M), Small-Assembler (DOS), Small-Tools programs and
> Small-Windows library to which I hold copyrights are hereby available for
> royalty free use in private or commercial endeavors. The only obligation
> being that the users retain the original copyright notices and credit all
> prior authors (Ron Cain, James Hendrix, etc.) in derivative versions.

Notices retained: Small-C is © 1982–1988 J. E. Hendrix, descended from Ron
Cain's Small-C (Dr. Dobb's Journal, 1980).

**LINK.EXE** — MIT License, © Microsoft Corporation; `../../msdos/MSDOS-LICENSE`.

## Mechanics of the 108 KB fit

Three period details, no binary patches:

1. **`ASM -S200 -NM`** — the assembler's default 1000-symbol table
   over-allocates the arena at 108 KB (exit code 1, truncated object).
   200 symbols is ample for small programs; `-NM` skips the macro pass,
   which Small-C output never uses.
2. **Tools are found via `PATH`** (`C:\CC` is on it) because DOS 2.x cannot
   execute a program by explicit path — that arrived in DOS 3.0. Running
   via PATH also keeps the current drive on the user's writable disk, so
   every output lands next to the source.
3. **`#include` searches only the current directory**, so `CC.BAT` copies
   `STDIO.H` to the work disk first; `LINK` spills `VM.TMP` there when
   memory is tight. Both are normal 1982 behavior on a two-drive machine.
