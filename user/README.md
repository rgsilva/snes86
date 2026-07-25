# user/ — bring your own DOS software

Drop your own DOS `.COM` / `.EXE` (and any data files they need) into this
directory, then rebuild the ROM:

```sh
cd snes && make msdos
```

They land on the C: drive under `C:\USER`. It is not on the PATH, so at the
`C:\>` prompt do `CD USER` first (or run `\USER\YOURAPP`).

This directory is intentionally empty in the public release — the base ROM
ships only free software (see `snes/tools/mkhd_free.py`). Anything you add
here is yours; it is git-ignored so it never lands in the repo.
