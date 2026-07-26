# VI — a real vi on the SNES

This is **levee**, David L Parsons' vi clone from 1982 (see
[ORIGIN.md](ORIGIN.md)), cross-compiled for MS-DOS 2.0 with Open
Watcom and given a BIOS INT 10h screen layer — this machine has no
ANSI.SYS and never will. It is a genuine modal vi: `hjkl` and arrow
keys, `i`/`a`/`o` insert, `dd`/`x`/`p`, `u` undo, `/pattern` search,
`:s//`, counts, macros, `:w`, `:q`, `:n`, wildcards.

    C:\> VI B:NOTE.TXT         edit a file on the writable drive
    C:\> VI *.TXT              wildcards work (:n = next file)

`C:\VI` is on the PATH, so `VI` works from anywhere.

Files are written with DOS CRLF line endings. The edit buffer is 16 KB
(bigger files open read-only with `[overflow]`); C: is read-only, so
write to `B:` — battery-backed cartridge SRAM. Undo of small changes
lives in memory; big deletions spill to a temp file, which lands on
the current drive unless you `SET TMP=B:\` first (on the SNES, do).

What's missing: `:!` and `:r !cmd` (no subshell on a 108 KB machine),
tags across files, and anything your muscle memory borrowed from vim.

No `vi.exe` is committed — `make stage` (and so every image build)
builds it from source: `fetch_watcom.py` fetches a pinned Open Watcom
v2 snapshot into `apps/cache/watcom/` (~151 MB download, one-time,
cached; only the host bin dir + headers + 16-bit libs are unpacked)
and cross-compiles the vendored levee source with `snescall.c`. Works
on macOS arm64 and Linux x64 alike — the Watcom host bin dir is picked
per-OS at build time. `make recompile` forces the rebuild.
