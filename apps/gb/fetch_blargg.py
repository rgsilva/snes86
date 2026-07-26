#!/usr/bin/env python3
"""Fetch one of Blargg's cpu_instrs test ROMs for the gb-host suite leg.

Blargg's Game Boy test ROMs are freely distributed (no formal license
text has ever accompanied them), but this repo ships nothing it does
not have clear rights to — so, exactly like the ELKS/FreeDOS images and
Turbo Pascal, the ROM is FETCHED at test time with a pinned sha256,
cached in apps/cache/, and never committed.

Output: apps/cache/blargg06.gb — "06-ld r,r", the broad register-move
leg of the suite GB.COM passes 11/11 of; it prints its name and then
"Passed" over the serial port (GB.COM -t wires that to the console).
"""
import hashlib
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, "..", "cache")
OUT = os.path.join(CACHE, "blargg06.gb")

# retrio/gb-test-roms @ c240dd7 (cpu_instrs/individual/06-ld r,r.gb)
URL = ("https://github.com/retrio/gb-test-roms/raw/"
       "c240dd7d700e5c0b00a7bbba52b53e4ee67b5f15/"
       "cpu_instrs/individual/06-ld%20r%2Cr.gb")
SHA = "17ada54b0b9c1a33cd5429fce5b765e42392189ca36da96312222ffe309e7ed1"


def sha256(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


def main():
    if os.path.exists(OUT) and sha256(OUT) == SHA:
        return 0
    os.makedirs(CACHE, exist_ok=True)
    print(f"fetching Blargg 06-ld r,r -> {os.path.relpath(OUT, HERE)}")
    data = urllib.request.urlopen(URL, timeout=60).read()
    if hashlib.sha256(data).hexdigest() != SHA:
        print("fetch_blargg.py: sha256 mismatch — refusing", file=sys.stderr)
        return 1
    with open(OUT, "wb") as f:
        f.write(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
