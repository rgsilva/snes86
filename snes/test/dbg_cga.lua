-- debug: dump all CGA-path state ~20 frames after cGFX goes 1
local frame = 0
local t = 0
local sent = false
local armed = 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function w(a) return emu.read16(0x7E0000 + a, emu.memType.snesMemory) end
local function vram(a) return emu.readWord(a, emu.memType.snesVideoRam) end
local function hexrow(base, n, rd)
  local s = ""
  for i = 0, n - 1 do s = s .. string.format("%04X ", rd(base + i * 2)) end
  return s
end
emu.addEventCallback(function()
  frame = frame + 1
  if not sent and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("cgatest\r")
    sent = true
  end
  if sent and armed == 0 and w(0x07AE) == 1 then armed = frame + 20 end
  if armed > 0 and frame == armed then
    print("vars: s3D8=" .. string.format("%04X", w(0x07B0)) ..
          " s3D9=" .. string.format("%04X", w(0x07B2)) ..
          " cPALD=" .. w(0x07B4) .. " gROW=" .. w(0x07B6) ..
          " gSTG=" .. w(0x07B8) .. " cMODE=" .. w(0x078E) ..
          " cWID=" .. w(0x078C))
    local fb = ""
    for i = 0, 15 do fb = fb .. string.format("%02X ", emu.read(0x7E1000 + i, emu.memType.snesMemory)) end
    print("fb even: " .. fb)
    fb = ""
    for i = 0, 15 do fb = fb .. string.format("%02X ", emu.read(0x7E3000 + i, emu.memType.snesMemory)) end
    print("fb odd:  " .. fb)
    local st = ""
    for i = 0, 15 do st = st .. string.format("%02X ", emu.read(0x7E0C00 + i, emu.memType.snesMemory)) end
    print("staging: " .. st)
    print("map A  : " .. hexrow(0x5000, 8, vram))     -- tilemap $2800 words
    print("map r1 : " .. hexrow(0x5000 + 64, 8, vram))
    print("tile0  : " .. hexrow(0xA000, 8, vram))     -- tile 0 planar
    print("tile10 : " .. hexrow(0xA0A0, 8, vram))
    print("cgram  : " .. hexrow(0, 8, function(a) return emu.readWord(a, emu.memType.snesCgRam) end))
    local h6 = ""
    for i = 0, 7 do h6 = h6 .. string.format("%02X ", emu.read(0x7E0500 + i, emu.memType.snesMemory)) end
    local h7 = ""
    for i = 0, 7 do h7 = h7 .. string.format("%02X ", emu.read(0x7E0510 + i, emu.memType.snesMemory)) end
    print("hdma6: " .. h6 .. " hdma7: " .. h7)
    emu.stop(0)
  end
  if frame == 3000 then print("timeout"); emu.stop(0) end
end, emu.eventType.endFrame)
