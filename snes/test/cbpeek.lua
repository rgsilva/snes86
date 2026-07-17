local frame = 0
local t = 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1200 then inject("cd bench\r") end
  if frame == 1600 then inject("cpubench\r") end
  if frame == 3500 then
    for r = 0, 24 do
      local s = ""
      for c = 0, 40 do
        local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
        if ch < 32 or ch > 126 then ch = 32 end
        s = s .. string.char(ch)
      end
      if s:match("%S") then print("R" .. r .. " [" .. s .. "]") end
    end
    emu.stop(0)
  end
end, emu.eventType.endFrame)
