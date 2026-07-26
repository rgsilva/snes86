#!/bin/sh
# tracewin_sa1.sh SKIP [KB] — compare MS-DOS boot steps SKIP..SKIP+800
# between the C core and the SA-1 65816 core. Same mechanism as
# tracewin.sh; the reference machine size must match the SA-1 build's
# GUESTKB (default 300).
SKIP=$1
KB=${2:-300}
MESEN="${MESEN:-/Applications/Mesen.app/Contents/MacOS/Mesen}"
cd "$(dirname "$0")/.."
printf '.DEFINE TRACE\n.DEFINE TRACE_SKIP %s\n.DEFINE TRACE_COUNT 800\n' "$SKIP" > build/trace_meta.asm
rm -f build/msdos_sa1.o build/msdos_sa1.sfc
make -s msdos_sa1 2>&1 | grep -i error
printf '' | ../core-c/build/runpc -m $KB -T $((SKIP+800)) -l $((SKIP+900)) \
  -d build/hd_free.img build/msdos_a.img \
  2>&1 >/dev/null | grep '^T ' | sed 's/^T //' | tail -800 > build/sa1exp.txt
echo "ref lines: $(wc -l < build/sa1exp.txt)"
"$MESEN" --testrunner "$(pwd)/build/msdos_sa1.sfc" "$(pwd)/test/dostrace.lua" 2>/dev/null \
  | grep -E '^[0-9A-F]{4} ' > build/sa1got.txt
python3 -c "
import sys
exp=open('build/sa1exp.txt').read().splitlines()
got=open('build/sa1got.txt').read().splitlines()
names=['AX','CX','DX','BX','SP','BP','SI','DI','ES','CS','SS','DS','IP','FL']
skip=$SKIP
if not got: print('FAIL: NO SNES TRACE'); sys.exit(1)
for i,(e,g) in enumerate(zip(exp,got)):
    if e!=g:
        print('DIVERGE at boot step', skip+i)
        for k in range(max(0,i-3), i):
            print('  ok :',exp[k])
        print('exp:',e); print('got:',g)
        ee,gg=e.split(),g.split()
        print('; '.join(f'{names[j]}: exp={ee[j]} got={gg[j]}' for j in range(14) if ee[j]!=gg[j]))
        sys.exit(1)
print('steps', skip, '-', skip+min(len(exp),len(got)), 'MATCH')"

printf '' > build/trace_meta.asm
rm -f build/msdos_sa1.o build/msdos_sa1.sfc
