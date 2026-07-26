# VI — a real vi on the SNES

This is **levee**, David L Parsons' vi clone from 1982 (see
[ORIGIN.md](ORIGIN.md)), cross-compiled for MS-DOS 2.0 with Open
Watcom and given a BIOS INT 10h screen layer — this machine has no
ANSI.SYS and never will. It is a genuine modal vi: `hjkl` and arrow
keys, `i`/`a`/`o` insert, `dd`/`x`/`p`, `u` undo, `/pattern` search,
`:s//`, counts, macros, `:w`, `:q`, `:n`, wildcards.

    C:\> CD VI
    C:\VI> VI B:NOTE.TXT       edit a file on the writable drive
    C:\VI> VI *.TXT            wildcards work (:n = next file)

Files are written with DOS CRLF line endings. The edit buffer is 16 KB
(bigger files open read-only with `[overflow]`); C: is read-only, so
write to `B:` — battery-backed cartridge SRAM. Undo of small changes
lives in memory; big deletions spill to a temp file, which lands on
the current drive unless you `SET TMP=B:\` first (on the SNES, do).

What's missing: `:!` and `:r !cmd` (no subshell on a 108 KB machine),
tags across files, and anything your muscle memory borrowed from vim.

`make recompile` rebuilds `vi.exe` from source: it fetches a pinned
Open Watcom v2 snapshot into `apps/cache/watcom/` (149 MB, one-time)
and cross-compiles the vendored levee source with `snescall.c`.
