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
  if frame == 30 then inject("mode 40\r") end
  if frame == 3000 then inject("dir a:\r") end
  if frame == 6000 then shot("m40_snes.png") end
  if frame == 6100 then inject("mode 80\rdir a:\r") end
  if frame == 10000 then shot("m80_snes.png") end
  if frame == 10100 then emu.stop(0) end
end, emu.eventType.endFrame)
