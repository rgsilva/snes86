#!/bin/sh
# Run the M1 console ROM in Mesen2's headless testrunner and extract the
# screenshots the Lua script hex-dumps to stdout.
cd "$(dirname "$0")/.."
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
"$MESEN" --testrunner "$(pwd)/build/console.sfc" "$(pwd)/test/console.lua" |
python3 -c '
import sys
for line in sys.stdin:
    if line.startswith("SHOT "):
        _, name, hexdata = line.split(None, 2)
        open("test/" + name, "wb").write(bytes.fromhex(hexdata.strip()))
        print("wrote test/" + name)
    else:
        print(line, end="")
'
