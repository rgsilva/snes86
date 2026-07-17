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
  if frame == 30 then inject("gwbasic\r") end
  if frame == 5000 then inject("COLOR 14,1\r") end
  if frame == 6000 then inject("CLS\r") end
  if frame == 7500 then inject('PRINT CHR$(201);STRING$(2') end
  if frame == 7600 then inject('0,205);CHR$(187)\r') end
  if frame == 9500 then inject('PRINT CHR$(186);" SNES86 I') end
  if frame == 9600 then inject('N COLOR ";CHR$(186)\r') end
  if frame == 11500 then inject('PRINT CHR$(200);STRING$(2') end
  if frame == 11600 then inject('0,205);CHR$(188)\r') end
  if frame == 14000 then shot("color_snes.png") end
  if frame == 14100 then emu.stop(0) end
end, emu.eventType.endFrame)
