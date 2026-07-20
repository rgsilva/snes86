#!/bin/bash
set -e
cd "$(dirname "$0")"
D=$(pwd)
./jwasm -c -Fo=io.obj io.asm || { echo "JWASM FAILED"; exit 1; }
python3 ../snes/tools/mkscratch.py "$D/build.img" "$D/LINK.EXE" "$D/EXE2BIN.EXE" "$D/io.obj" "$D/SYSINIT.OBJ" "$D/SYSIMES.OBJ" >/dev/null
printf '\r\rLINK IO+SYSINIT+SYSIMES,IO,,;\rEXE2BIN IO.EXE IO.SYS\r60\r' | ../core-c/build/runpc -w -m 256 build.img -l 130000000 >/dev/null 2>&1
python3 -c "import sys; sys.path.insert(0,'../snes/tools'); import mkscratch; b=mkscratch.read_img('build.img')['IO.SYS']; open('IO.SYS','wb').write(b); print('IO.SYS',len(b),'bytes')"
python3 mkmsdos.py | tail -1
