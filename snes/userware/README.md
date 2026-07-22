# userware — bring your own DOS software

Drop your own DOS `.COM` / `.EXE` (and any data files they need) into this
directory, then rebuild the ROM:

```sh
cd snes && make dosboot
```

They appear on the release C: drive under `C:\USER`, which is on the PATH, so
you can run them from anywhere at the `C:\>` prompt.

This directory is intentionally empty in the public release — the base ROM
ships only free software (see `snes/tools/mkhd_free.py`). Anything you add here
is yours; it is git-ignored so it never lands in the repo.
