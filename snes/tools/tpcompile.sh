#!/bin/sh
# Compile a Turbo Pascal .PAS to a standalone .COM on the host, by driving
# TP3's IDE under runpc (TP3 has no command-line compiler). Produces
# disks/<name>.com, which mkadisk.py ships alongside the .PAS.
#
# usage: tpcompile.sh NAME  (NAME.pas must exist in disks/, uppercased <=8 chars)
#
# The keystrokes: WNAME<CR> sets the work file, O C Q selects Com-file
# output and exits Options, C compiles. Nothing may follow C — TP polls the
# keyboard during compilation and any pending key triggers "Abort? (Y/N)".
set -e
cd "$(dirname "$0")/.."
NAME=$1
[ -f "../disks/$NAME.pas" ] || { echo "../disks/$NAME.pas not found"; exit 1; }

python3 tools/mk_tpc_img.py "$NAME"
printf '\r\rturbo\rYW%s\rOCQC' "$NAME" | \
    ../core-c/build/runpc -m 112 -l 500000000 -w build/tpc.img >/dev/null 2>&1
python3 tools/mk_tpc_img.py --extract "$NAME"
