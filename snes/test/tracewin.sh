#!/bin/sh
# tracewin.sh SKIP — compare boot steps SKIP..SKIP+800 between cores
SKIP=$1
printf '.DEFINE TRACE\n.DEFINE TRACE_SKIP %s\n.DEFINE TRACE_COUNT 800\n' "$SKIP" > build/trace_meta.asm
rm -f build/dosboot.o
make -s dos 2>&1 | grep -i error
printf '\r\r' | ../core-c/build/runpc -m 96 -T $((SKIP+800)) -l $((SKIP+900)) ../disks/pcdos200-disk1.img 2>&1 >/dev/null | grep '^T ' | sed 's/^T //' | tail -800 > build/dosexp.txt
echo "ref lines: $(wc -l < build/dosexp.txt)"
/Applications/Mesen.app/Contents/MacOS/Mesen --testrunner "$(pwd)/build/dosboot.sfc" "$(pwd)/test/dostrace.lua" 2>/dev/null | grep -E '^[0-9A-F]{4} ' > build/dosgot.txt
python3 -c "
import sys
exp=open('build/dosexp.txt').read().splitlines()
got=open('build/dosgot.txt').read().splitlines()
names=['AX','CX','DX','BX','SP','BP','SI','DI','ES','CS','SS','DS','IP','FL']
skip=$SKIP
for i,(e,g) in enumerate(zip(exp,got)):
    if e!=g:
        print('DIVERGE at boot step', skip+i)
        if i: print('before:',exp[i-1])
        print('exp:',e); print('got:',g)
        ee,gg=e.split(),g.split()
        print('; '.join(f'{names[j]}: exp={ee[j]} got={gg[j]}' for j in range(14) if ee[j]!=gg[j]))
        sys.exit(1)
print('steps', skip, '-', skip+min(len(exp),len(got)), 'MATCH')"

# leave a clean (non-trace) build behind so `make dos` artifacts are never stale
printf '' > build/trace_meta.asm
rm -f build/dosboot.o build/dosboot.sfc
