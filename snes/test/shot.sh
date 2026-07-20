#!/bin/zsh
# shot.sh ROM CMD INJ SHOTFRAME OUT.png ALARM
# Boots ROM in Mesen (headless), optionally types CMD at frame INJ, captures the
# framebuffer at frame SHOTFRAME as docs/assets/OUT. os is sandboxed in Mesen's Lua
# so params are baked into a generated lua per run.
here=${0:A:h}                       # snes/test
cd "$here/.."                       # snes/
rom=$1; cmd=$2; inj=$3; shot=$4; out=$5; alarm=$6
cat > test/shot.lua <<LUA
local CMD, INJ, SHOT = "$cmd", $inj, $shot
local frame, t = 0, 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
emu.addEventCallback(function()
  frame = frame + 1
  if CMD ~= "" and frame == INJ then inject(CMD .. "\r") end
  if frame == SHOT then
    local png = emu.takeScreenshot()
    print("SHOT " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
LUA
perl -e 'alarm shift; exec @ARGV' "$alarm" /Applications/Mesen.app/Contents/MacOS/Mesen \
     --testrunner "$rom" test/shot.lua 2>/dev/null \
  | grep "^SHOT " | head -1 | cut -d' ' -f2 \
  | python3 -c "import sys;d=sys.stdin.read().strip();open('../docs/assets/$out','wb').write(bytes.fromhex(d)) if len(d)>100 else print('  !! no shot: $out')"
[ -f "../docs/assets/$out" ] && echo "  wrote docs/assets/$out ($(wc -c < ../docs/assets/$out | tr -d ' ') bytes)"
