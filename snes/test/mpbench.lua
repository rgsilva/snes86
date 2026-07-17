local frame = 0
local t = 0
local injected = 0
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
  if frame == 1200 then inject("mp\r"); injected = frame end
  if injected > 0 and frame % 20 == 0 and bufhas("Multiplan:") then
    print("MPDONE frames=" .. (frame - injected))
    emu.stop(0)
  end
  if frame == 20000 then print("TIMEOUT"); emu.stop(0) end
end, emu.eventType.endFrame)
