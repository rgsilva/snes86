# freeware/

Third-party DOS software that is **not ours** but is **freely redistributable**,
staged onto the public ROM's C: drive the same way `homebrew/` tools are:
`freeware/<tool>/build/` → `C:\<TOOL>`, populated by that tool's `make stage`
(wired into `snes/Makefile`'s staging target).

The taxonomy, for orientation:

- **`homebrew/`** — software *we* wrote, with source.
- **`freeware/`** — third-party, PD/MIT, redistributable, provenance-documented (here).
- **`disks/`** — copyrighted bring-your-own media, never committed.
- **`freedos/`**, ELKS — GPL guests, *fetched* at build time, never committed.
- **Turbo Pascal 3** — abandonware, not redistributable; fetched at build time
  (`homebrew/fetch_tp3.py`), never committed. It does not belong here.

## The admission rule

A package comes in only with an `ORIGIN.md` documenting: where each file came
from (source URL), its license with the evidence (the actual PD notice or MIT
grant), and a sha256 for every binary. PD or MIT-class redistribution rights,
documented — or it stays out. When in doubt, it stays out.

## Tenants

- **`cc/`** — the Small-C toolchain (public-domain compiler + assembler, the
  MIT MS-DOS linker, runtime, samples) → `C:\CC`. Compiles and runs C
  entirely inside the emulated machine at the stock 108 KB.
