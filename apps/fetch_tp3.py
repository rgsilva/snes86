#!/usr/bin/env python3
"""Fetch Turbo Pascal 3.01A for the apps `recompile` pipeline.

TP3 is NOT redistributable by us: Borland released it as "Antique
Software" freeware around 2000, but that was a download grant, not a
redistribution license, and Borland/Embarcadero retain all rights. So —
exactly like the ELKS and FreeDOS images — it is FETCHED at build time
with a pinned hash, cached locally, and never committed to this repo.

Sources, in order of preference:
  1. disks/tp301.img       (a developer's local copy, if present)
  2. archive.org           (pinned image, sha256-verified)

Output: apps/cache/TURBO.COM + TURBO.MSG, each verified against the
pinned per-file sha256 (version 3.01A), so every rebuild everywhere uses
byte-identical compiler binaries and codegen never drifts.
"""
import hashlib
import os
import sys
import urllib.request

import fatimg

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "cache")
LOCAL = os.path.join(HERE, "..", "disks", "tp301.img")

URL = "https://archive.org/download/turbo-pascal-3.01a/tpascal.img"
IMG_SHA = "2bb934fc361472895f424fab41ee79f03d0408977200a50a7ef9547ec21be7b8"
WANT = {
    "TURBO.COM": "e91124755d428dab5c75862fac40c34bb2e96c7864cb68834df7d3f45bc87e86",
    "TURBO.MSG": "fa28165089320cb8b76f42db03fb85d17da2b3abe099f9a255fb052037c81742",
}


def have():
    for nm, sha in WANT.items():
        p = os.path.join(CACHE, nm)
        if not os.path.exists(p):
            return False
        if hashlib.sha256(open(p, "rb").read()).hexdigest() != sha:
            return False
    return True


def stash(files):
    os.makedirs(CACHE, exist_ok=True)
    for nm, sha in WANT.items():
        data = files[nm]
        got = hashlib.sha256(data).hexdigest()
        if got != sha:
            raise SystemExit(f"{nm}: sha256 mismatch ({got}) — refusing")
        open(os.path.join(CACHE, nm), "wb").write(data)
    print("TP3 3.01A ready in apps/cache/ (TURBO.COM + TURBO.MSG)")


def main():
    if have():
        return
    if os.path.exists(LOCAL):
        stash(fatimg.read_img(LOCAL))
        return
    print(f"fetching Turbo Pascal 3.01A from {URL} ...")
    data = urllib.request.urlopen(URL, timeout=120).read()
    got = hashlib.sha256(data).hexdigest()
    if got != IMG_SHA:
        raise SystemExit(f"tpascal.img: sha256 mismatch ({got}) — refusing")
    tmp = os.path.join(CACHE, "tpascal.img")
    os.makedirs(CACHE, exist_ok=True)
    open(tmp, "wb").write(data)
    stash(fatimg.read_img(tmp))


if __name__ == "__main__":
    sys.exit(main())
