#!/bin/sh
# Fetch the ELKS ROM-boot images for `make elks` if not already present.
# Default: the official v0.9.1 release artifacts (kernel XIP + ROMFS,
# GPL - fetched, not committed, like core-c's test vectors). A tuned
# local build (see the sneslinux tree) can simply be copied over these;
# any existing files are left untouched (and so never checksum-verified).
set -e
cd "$(dirname "$0")/.."
mkdir -p build
BASE=https://github.com/ghaerr/elks/releases/download/v0.9.1
# pinned sha256 of the official v0.9.1 artifacts (verified against the
# GitHub release 2026-07-22) so a tampered/truncated download can't boot
ROM_SHA=a6f2d380ef1a4221efcc35f1df087c3a2e787e6191c767fd19e39ef77ca89256
ROMFS_SHA=e2a82873b265199f846ee8b5ba18234a7f3e27b1fc9c42bade3501ef0317d79d

sha256() {
  # macOS ships shasum, most Linux ships sha256sum — take whichever exists
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
  else sha256sum "$1"; fi | cut -d' ' -f1
}

fetch() { # fetch FILE URL SHA256
  [ -f "$1" ] && return 0
  curl -sfL --retry 3 -o "$1" "$2"
  got=$(sha256 "$1")
  if [ "$got" != "$3" ]; then
    rm -f "$1"
    echo "fetch_elks.sh: sha256 mismatch for $1" >&2
    echo "  got  $got" >&2
    echo "  want $3  ($2)" >&2
    exit 1
  fi
}

fetch build/elks_rom.bin   "$BASE/rom-8088.bin"   "$ROM_SHA"
fetch build/elks_romfs.bin "$BASE/romfs-8088.bin" "$ROMFS_SHA"
ls -la build/elks_rom.bin build/elks_romfs.bin
