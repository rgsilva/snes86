# The FreeDOS boot floppy

`make freedos` (in `snes/`) boots [FreeDOS](https://www.freedos.org/) 1.3 on the
172 KB BIGMEM machine. This folder builds its A: disk.

`mkfreedos.py` downloads the official **FreeDOS 1.3 Floppy Edition** release
(GPL — fetched at build time and cached in `freedos/cache/`, never committed,
the same policy as the ELKS images; source at
[github.com/FDOS](https://github.com/FDOS)), verifies its sha256, extracts the
8086 `KERNEL.SYS`, FreeCOM (`COMMAND.COM`) and `MEM.EXE` from the 720 KB boot
disk, and assembles a minimal **360 KB** boot floppy matching snes86's A:
geometry (40×2×9). The FreeDOS boot sector reads its geometry from the BPB, so
the original sector-0 code boots the smaller layout once the BPB is re-patched.

The floppy carries only the kernel, the shell, `MEM`, and a trimmed
`FDCONFIG.SYS`/`AUTOEXEC.BAT` (`BUFFERS=15`, `FILES=20` — every kilobyte
counts at 172 KB). The C: drive is the same free image as the public MS-DOS
build, so the MIDI player, SOKOBAN and the benchmarks are all there.

Why BIGMEM: measured on `runpc`, the FD 1.3 kernel dies during init at 108 KB
and reaches FreeCOM at exactly 172 KB. There is no non-BIGMEM FreeDOS build.
