local frame = 0
local t = 0
local sent = false
local samples = {}
local nz = 0
local changes = 0
local last = -1
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
emu.addEventCallback(function()
  frame = frame + 1
  if not sent and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("midplay\r")
    sent = true
  end
  if sent and frame % 20 == 0 then
    local m = emu.read(0, emu.memType.spcMemory)
    if m ~= 0 then nz = nz + 1 end
    if m ~= last then changes = changes + 1; last = m end
    if #samples < 40 then samples[#samples+1] = string.format("%02X", m) end
  end
  if sent and frame % 1500 == 0 then
    print(string.format("f=%d voicemask nz=%d changes=%d [%s]",
      frame, nz, changes, table.concat(samples, " ")))
    samples = {}
  end
  if frame == 12000 then
    print((nz > 20 and changes > 10) and "RESULT PASS t_midi" or "RESULT FAIL t_midi")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
