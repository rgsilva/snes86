# msdos/bin — MS-DOS 2.0 utilities (ships as C:\DOS)

Original Microsoft binaries from the MIT-licensed MS-DOS source release,
fetched from https://github.com/microsoft/MS-DOS (`v2.0/bin/`), same
provenance as our `LINK.EXE`/`MASM.EXE`/`MSDOS.SYS`/`COMMAND.COM`
(license: `msdos/MSDOS-LICENSE`).

| file | sha256 | verified on snes86 |
|---|---|---|
| CHKDSK.COM | 75be6db096873aed6525e71dcacfe81a56ba038699600d5f203bb40d6a308201 | ✅ reports disk + free memory |
| DEBUG.COM | cbb171acca2a5581d926b6782aebeaad49111ecd359e64cf6f2e5dd0a000b4ca | ✅ dump/quit |
| EDLIN.COM | 799767e5bc6727fd3fb1b0c54a2099c5c53d46dcab5b7b5012b688f3c718b444 | ✅ runs; needs a writable drive (B: — C: is cartridge ROM) |
| FIND.EXE | d57bab73ba6a77be1aa8d2d3f1fd7d1d6ce6d459b2ab067d26cf63228e940198 | ✅ |
| MORE.COM | 56830889fef22d56ef5938df0394bf30a8416cc06225b8dc35adc74bb13416b7 | ✅ via `<` redirection (DOS 2.0 pipes want a writable temp file; C: is ROM) |
| SORT.EXE | f2135e16cd1ebff6233b4d01fcb7f73b311a1f5524ddca21056248b29fa015b8 | ✅ via `<` redirection |

Note: MODE.COM is not here — it was an IBM PC-DOS utility, absent from
Microsoft's OEM release, so the 40/80-column suite leg (`t_m40`) runs on
the apps fixture, which carries the PC-DOS copy locally.
