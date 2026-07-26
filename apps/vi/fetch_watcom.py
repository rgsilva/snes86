#!/usr/bin/env python3
"""Fetch Open Watcom v2 for the vi build (stage compiles vi.exe).

Open Watcom is open source (Sybase Open Watcom Public License) but at
~151 MB the snapshot has no business inside this repo, so — exactly
like TP3, the ELKS and FreeDOS images — it is FETCHED at build time
with a pinned hash and cached locally (fetch-at-build pattern, see
apps/fetch_tp3.py).

We pin the dated 2026-07-13 release snapshot (the "Current-build" tag
moves). The release's only per-host artifacts are self-extracting
installers (~128 MB each, no plain archive inside), so the multi-host
ow-snapshot.tar.xz is the smallest artifact we can actually unpack —
one URL, one sha256, every host. We unpack only what the cross-build
needs on THIS host:

  <hostbin>/  host compiler binaries (wcc, wlink, wcl, ...):
              armo64 = macOS arm64, bino64 = macOS x64,
              binl64 = Linux x64,   arml64 = Linux arm64
  h/          target headers
  lib286/     16-bit DOS runtime libraries

Output: apps/cache/watcom/ ready for the vi Makefile (which asks
`fetch_watcom.py --bindir` for the host bin dir instead of hardcoding
one).
"""
import hashlib
import os
import platform
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

HOSTDIRS = {
    ("Darwin", "arm64"): "armo64",
    ("Darwin", "x86_64"): "bino64",
    ("Linux", "x86_64"): "binl64",
    ("Linux", "aarch64"): "arml64",
}


def hostdir():
    key = (platform.system(), platform.machine())
    try:
        return HOSTDIRS[key]
    except KeyError:
        raise SystemExit(f"fetch_watcom.py: unsupported host {key} — "
                         f"known: {sorted(HOSTDIRS)}")


def have():
    return os.path.exists(os.path.join(DEST, hostdir(), "wcl")) \
       and os.path.exists(os.path.join(DEST, "h", "stdio.h")) \
       and os.path.exists(os.path.join(DEST, "lib286", "dos", "clibs.lib"))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--bindir":
        # resolve-only mode for the Makefile: never fetches
        print(os.path.abspath(os.path.join(DEST, hostdir())))
        return
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
    want = ["./" + hostdir(), "./h", "./lib286", "./license.txt"]
    subprocess.run(["tar", "xJf", TARBALL, "-C", DEST] + want, check=True)
    print(f"Open Watcom v2 ({hostdir()}) ready in apps/cache/watcom/")


if __name__ == "__main__":
    sys.exit(main())
