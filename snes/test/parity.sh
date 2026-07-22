#!/bin/sh
# Lockstep parity check: C core vs 65816 core on the same random stream.
# usage: parity.sh [seed] [count]
set -e
cd "$(dirname "$0")/.."
SEED=${1:-1}
COUNT=${2:-1200}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"

python3 test/gen_stream.py "$SEED" "$COUNT" build
( cd ../core-c && make -s x86trace )
../core-c/build/x86trace build/stream.bin "$(cat build/stream.count)" \
    > build/expected.txt

rm -f build/cputest.o build/cputest.sfc   # make can miss same-second updates
make -s cputest
"$MESEN" --testrunner "$(pwd)/build/cputest.sfc" "$(pwd)/test/cputest.lua" \
    > build/mesen_out.txt || true
grep -E '^[0-9A-F]{4} ' build/mesen_out.txt > build/got.txt || true
grep -Ev '^[0-9A-F]{4} ' build/mesen_out.txt | head -5 || true

python3 test/compare.py build/expected.txt build/got.txt build/stream.lst
