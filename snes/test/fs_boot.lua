-- FS1 booter smoke: let it boot, grab a screenshot + gfx state
local frame = 0
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 5500 then
    print("cGFX=" .. emu.read16(0x7E07AE, emu.memType.snesMemory) ..
          " s3D8=" .. string.format("%02X", emu.read16(0x7E07B0, emu.memType.snesMemory)) ..
          " mode=" .. emu.read16(0x7E078E, emu.memType.snesMemory))
    shot("fs1_snes.png")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
