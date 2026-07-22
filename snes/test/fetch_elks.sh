#!/bin/sh
# Fetch the ELKS ROM-boot images for `make elks` if not already present.
# Default: the official v0.9.1 release artifacts (kernel XIP + ROMFS,
# GPL - fetched, not committed, like core-c's test vectors). A tuned
# local build (see the sneslinux tree) can simply be copied over these;
# any existing files are left untouched.
set -e
cd "$(dirname "$0")/.."
mkdir -p build
BASE=https://github.com/ghaerr/elks/releases/download/v0.9.1
[ -f build/elks_rom.bin ]   || curl -sL -o build/elks_rom.bin   "$BASE/rom-8088.bin"
[ -f build/elks_romfs.bin ] || curl -sL -o build/elks_romfs.bin "$BASE/romfs-8088.bin"
ls -la build/elks_rom.bin build/elks_romfs.bin
