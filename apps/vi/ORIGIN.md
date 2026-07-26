# VI — provenance

`levee/` is third-party source: **levee 4.0b ("mandatory happiness")**,
David L Parsons' tiny vi clone, first written in 1979-82 and maintained
at <https://github.com/Orc/levee>.

* Upstream commit: `a1d98bdf654e03c95aee4cc4cee1ce64dccaed74`
  ("more mandatory happiness in configure.inc")
* Fetched: 2026-07-26, via `git clone https://github.com/Orc/levee`

## License

BSD-style, redistribution of source and binary permitted — the full
text is in [`levee/COPYRIGHT`](levee/COPYRIGHT). Its conditions: keep
the copyright notice, and acknowledge that the software was developed
by **David L Parsons (orc@pell.portland.or.us)** in documentation and
related materials — which this file and the in-source headers do. His
name may not be used to endorse derived products.

## What was taken, what was changed

The editor core is vendored pristine: the 15 `.c` files levee's
Makefile.in builds (minus the per-OS `*call.c` backends), the three
headers, `COPYRIGHT`, `README`, `VERSION`, and the docs (`lv.doc`,
`lv.1`).

Two files carry a two-line patch, marked with `snes86:` comments:
`extern.h` and `find.c` named a function parameter `errno`, which is a
macro in Open Watcom's `<errno.h>` (it mangled the prototype into a
function-pointer type). Renamed to `err`. Everything else is untouched
— upstream's own `doscall.c` was NOT used: it is bit-rotted (Microsoft
C 5.x isms, `externs.h`, an incompatible glob API) and needs ANSI.SYS,
which this machine will never have.

Our additions, all new code, same license terms as levee:

* `config.h` — what `configure.sh --dos` would have generated, tuned
  for MS-DOS 2.0 on the 108 KB machine (16 KB edit buffer).
* `snescall.c` — the snes86 backend: BIOS INT 10h screen (no ANSI.SYS),
  INT 16h keyboard, DOS 2.0-only INT 21h file i/o, FindFirst/FindNext
  wildcards. The glob helpers are adapted from levee's `wincall.c`.
* `Makefile`, `fetch_watcom.py` — Open Watcom v2 cross-build
  (fetch-at-build, pinned sha256, never committed).

## Toolchain

Built with **Open Watcom v2** (open source, Sybase Open Watcom Public
License), 2026-07-13 release snapshot, pinned by sha256 in
`fetch_watcom.py`; 16-bit DOS target, small memory model
(`wcl -bcl=dos -ms -0 -os`). No `vi.exe` is committed — every image
build compiles it from this source (`make stage`); the per-OS Watcom
host bin dir (macOS arm64 / Linux x64) is resolved at build time.

## Vendored file hashes (sha256)

```
7942bed45aaa9db17fe6403101110d89db9c257e10849cbecfe3f10e12fdefc3  levee/blockio.c
17aec9382a3e446bd172db8ae81293fc75ea6845513d23605851f86f7b844d2a  levee/display.c
87b99b4947b1ff72355bf833c9b522cdcffa9a45a71268d54db97a33be2748af  levee/editcor.c
07ad43fded906f1d2ede769eca80e6cec59dd23c4e83a262d4c8fb27bbc7595c  levee/exec.c
950e1e9292c35efc912e9bd8c7b0f8f50298a0c6d14ef55d14ae5f6d07130946  levee/find.c
97e326ce519f59cad1696cd3983d9a627c63fb12745f08221473bebb2afba85e  levee/globals.c
88456e554a30675be9af7a9d5bae7b6df8913c2431291808df0fa94c039be775  levee/home.c
dd327704d93582e79fd892d5e22745e0be9a9be1928a94ff2eb4355c5d75b43b  levee/insert.c
2a0925ea41e32f60c8cfb673ecc431e96238724560fd1a0c14b36d4824bb6f3b  levee/main.c
289005293ef0369dc82af974227a58e72a61081cadd28ed173ee5ec2694c25b0  levee/misc.c
36c68e3d797c17e8fd518d38dafccbdd673de354df205f14567295f746dcdb66  levee/modify.c
9ebde8bd29133fdf0cb0370eba7d7f2c79cdfab888a9cf58d499f8d0fb1fec30  levee/move.c
6be098bfcb0b2c48555099a790df3035129d50fa2094bfc85353074e1a0fd5d7  levee/tag.c
e0720ad0d55b1dd84604ed9934ffd8883fcff41438a3d12715792c6c94f8eb4b  levee/ucsd.c
f4aabe27ce908ac56dab7adbdaa5cd15336a5d3cd9d5b11dfeb47d85055587d9  levee/undo.c
3a49a9068278176c4aa6f4cc1a7fba47ac8a8db6a744f0338bdc7d2091fdaa0b  levee/extern.h
37ce31d488444ce3d80523bbb25de1df2cededb957720b3a0c882b9b1cb12772  levee/grep.h
7efa5c14335dcd32ffe84177b77282bc315b72ccd0662465e53a95a15b6ad42d  levee/levee.h
e5c2282e21672db9276007f1225a8d1fab90b39061a088c397993875fdc543c8  levee/COPYRIGHT
b0e198d49b327156a1911ec45473372004fc106a4c53ab718d89f9970864b790  levee/VERSION
```

(`extern.h` and `find.c` hashes are post-patch; the pristine originals
are commit `a1d98bd` upstream.)
