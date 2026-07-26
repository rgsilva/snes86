# The FreeDOS boot floppy

`make freedos` (in `snes/`) boots [FreeDOS](https://www.freedos.org/) 1.3 on the
300 KB SA-1 machine. This folder builds its A: disk.

`mkfreedos.py` downloads the official **FreeDOS 1.3 Floppy Edition** release
(GPL — fetched at build time and cached in `freedos/cache/`, never committed,
the same policy as the ELKS images; source at
[github.com/FDOS](https://github.com/FDOS)), verifies its sha256, extracts the
8086 `KERNEL.SYS`, FreeCOM (`COMMAND.COM`) and `MEM.EXE` from the 720 KB boot
disk, and assembles a minimal **360 KB** boot floppy matching snes86's A:
geometry (40×2×9). The FreeDOS boot sector reads its geometry from the BPB, so
the original sector-0 code boots the smaller layout once the BPB is re-patched.

The floppy carries only the kernel, the shell, `MEM`, and a trimmed
`FDCONFIG.SYS`/`AUTOEXEC.BAT` (`BUFFERS=15`, `FILES=20` — the settings date
from the days when FreeDOS had 172 KB to live in, and there is no reason to
loosen them). The C: drive is the same free image as the public MS-DOS build,
so the MIDI player, SOKOBAN and the benchmarks are all there.

Why the big machine: measured on `runpc`, the FD 1.3 kernel dies during init
at 108 KB and reaches FreeCOM at exactly 172 KB, so it cannot run on the
public ROM's machine. It rides the SA-1 board (the same one `make msdos_sa1`
uses), which gives it 300 KB and — unlike the old 172 KB cart-SRAM machine,
where the SRAM *was* the extra guest RAM — a working `B:` drive as well. That
older machine is gone: `make elks` moved onto the SA-1 board too, and with no
users left the second memory layer was deleted.
