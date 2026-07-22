#!/bin/sh
# elkstrace.sh SKIP — lockstep-compare ELKS ROM boot steps SKIP..SKIP+340
# between the C core (runpc -rom/-entry) and the 65816 core (TRACE build).
SKIP=$1
printf '.DEFINE TRACE\n.DEFINE TRACE_SKIP %s\n.DEFINE TRACE_SKIPL %s\n.DEFINE TRACE_SKIPH %s\n.DEFINE TRACE_COUNT 340\n' "$SKIP" $((SKIP % 65536)) $((SKIP / 65536)) > build/trace_meta.asm
rm -f build/elks.o
make -s elks 2>&1 | grep -i error
printf '' | ../core-c/build/runpc -m 172 -T $((SKIP+340)) -l $((SKIP+440)) \
  -rom build/elks_rom.bin@e000 -rom build/elks_romfs.bin@8000 -entry e000:0014 \
  2>&1 >/dev/null | grep '^T ' | sed 's/^T //' | tail -340 > build/elksexp.txt
echo "ref lines: $(wc -l < build/elksexp.txt)"
/Applications/Mesen.app/Contents/MacOS/Mesen --testrunner --timeout=1500 "$(pwd)/build/elks.sfc" "$(pwd)/test/elkstrace.lua" 2>/dev/null | grep -E '^[0-9A-F]{4} ' > build/elksgot.txt
python3 -c "
import sys
exp=open('build/elksexp.txt').read().splitlines()
got=open('build/elksgot.txt').read().splitlines()
names=['AX','CX','DX','BX','SP','BP','SI','DI','ES','CS','SS','DS','IP','FL']
skip=$SKIP
if not got: print('NO SNES TRACE'); sys.exit(2)
for i,(e,g) in enumerate(zip(exp,got)):
    if e!=g:
        print('DIVERGE at boot step', skip+i)
        if i: print('before:',exp[i-1])
        print('exp:',e); print('got:',g)
        ee,gg=e.split(),g.split()
        print('; '.join(f'{names[j]}: exp={ee[j]} got={gg[j]}' for j in range(14) if ee[j]!=gg[j]))
        sys.exit(1)
print('steps', skip, '-', skip+min(len(exp),len(got)), 'MATCH')"
printf '' > build/trace_meta.asm
rm -f build/elks.o build/elks.sfc
