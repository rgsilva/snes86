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
  if frame == 1200 then inject("rogue\r") end
  if frame == 5000 then inject("SNES\r") end
  if frame == 12000 then inject(" ") end
  if frame == 20000 then inject("j") end
  if frame == 24000 then shot("rogue_snes.png") end
  if frame == 24100 then emu.stop(0) end
end, emu.eventType.endFrame)
