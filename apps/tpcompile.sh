#!/bin/sh
# Compile a apps Turbo Pascal .PAS to a standalone .COM by driving
# TP3's IDE inside runpc, our own emulated MS-DOS 2.0 (TP3 has no
# command-line compiler). TP3 itself is fetched, not committed — see
# fetch_tp3.py. The scratch boot floppy is cloned from msdos/msdos.img,
# so the whole pipeline runs from a clean checkout.
#
# usage: tpcompile.sh <tool> <name>     compiles apps/<tool>/<name>.pas
#                                       into apps/<tool>/<name>.com
#
# The keystrokes: Y answers "Include error messages", W<NAME> sets the
# work file, O C Q selects Com-file output and exits Options, C compiles.
# Nothing may follow C — TP polls the keyboard during compilation and any
# pending key triggers "Abort? (Y/N)".
set -e
cd "$(dirname "$0")"
TOOL=$1
NAME=$2
[ -f "$TOOL/$NAME.pas" ] || { echo "apps/$TOOL/$NAME.pas not found"; exit 1; }
UPPER=$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')

# the compile runs inside runpc — build it if this is a fresh checkout
[ -x ../core-c/build/runpc ] || make -s -C ../core-c runpc

python3 fetch_tp3.py
python3 mk_tpc_img.py build "$TOOL/$NAME.pas"
printf 'turbo\rYW%s\rOCQC' "$UPPER" | \
    ../core-c/build/runpc -m 108 -l 800000000 -w cache/tpc.img >/dev/null 2>&1
python3 mk_tpc_img.py --extract "$UPPER.COM" "$TOOL/$NAME.com"
