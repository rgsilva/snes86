#!/usr/bin/env python3
"""Fetch Open Watcom v2 for the vi `recompile` pipeline.

Open Watcom is open source (Sybase Open Watcom Public License) but at
149 MB the snapshot has no business inside this repo, so — exactly like
TP3, the ELKS and FreeDOS images — it is FETCHED at build time with a
pinned hash and cached locally (fetch-at-build pattern, see
apps/fetch_tp3.py).

We pin the dated 2026-07-13 release snapshot (the "Current-build" tag
moves) and unpack only what the cross-build needs:

  armo64/   macOS arm64 host binaries (wcc, wlink, wcl, ...)
  h/        target headers
  lib286/   16-bit DOS runtime libraries

Output: apps/cache/watcom/ ready for `make recompile`.
"""
import hashlib
import os
import subprocess
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache")
TARBALL = os.path.join(CACHE, "ow-snapshot.tar.xz")
DEST = os.path.join(CACHE, "watcom")

URL = ("https://github.com/open-watcom/open-watcom-v2/releases/download/"
       "2026-07-13-Build/ow-snapshot.tar.xz")
SHA = "35e9c56ca93234ba0b8b596387815399317ea0548aeac1318f0674dca3921314"

WANT = ["./armo64", "./h", "./lib286", "./license.txt"]


def have():
    return os.path.exists(os.path.join(DEST, "armo64", "wcl")) \
       and os.path.exists(os.path.join(DEST, "h", "stdio.h")) \
       and os.path.exists(os.path.join(DEST, "lib286", "dos", "clibs.lib"))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if have():
        return
    os.makedirs(CACHE, exist_ok=True)
    if not (os.path.exists(TARBALL) and sha256(TARBALL) == SHA):
        print(f"fetching Open Watcom v2 (2026-07-13 snapshot) from {URL} ...")
        urllib.request.urlretrieve(URL, TARBALL)
        got = sha256(TARBALL)
        if got != SHA:
            raise SystemExit(f"ow-snapshot.tar.xz: sha256 mismatch ({got}) "
                             "— refusing")
    os.makedirs(DEST, exist_ok=True)
    subprocess.run(["tar", "xJf", TARBALL, "-C", DEST] + WANT, check=True)
    print("Open Watcom v2 ready in apps/cache/watcom/")


if __name__ == "__main__":
    sys.exit(main())
