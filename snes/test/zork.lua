local frame = 0
local t = 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then inject("c:\rzork1\r") end
  if frame == 6000 then inject("open mailbox\r") end
  if frame == 11000 then inject("read leaflet\r") end
  if frame == 15900 then
    local r0 = ""
    for i = 0, 39 do
      local c = emu.read(0x7E1000 + i*2, emu.memType.snesMemory)
      if c < 32 or c > 126 then c = 46 end
      r0 = r0 .. string.char(c)
    end
    print("PROBE row0=[" .. r0 .. "] crow=" .. emu.read16(0x7E00C6, emu.memType.snesMemory))
  end
  if frame == 16000 then shot("zork_snes.png") end
  if frame == 16100 then emu.stop(0) end
end, emu.eventType.endFrame)
