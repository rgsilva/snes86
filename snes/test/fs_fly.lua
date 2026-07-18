-- FS1 full flight: answer both prompts via the INT9 scancode queue,
-- then screenshot the demo flight.
local frame = 0
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
local function key(sc)                 -- queue make+break of scancode
  local h = emu.read16(0x7E07BC, emu.memType.snesMemory)  -- s9H
  emu.write16(0x7E0600 + h, sc, emu.memType.snesMemory)
  h = (h + 2) % 32
  emu.write16(0x7E0600 + h, sc + 0x80, emu.memType.snesMemory)
  h = (h + 2) % 32
  emu.write16(0x7E07BC, h, emu.memType.snesMemory)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 5200 then key(0x1E) end  -- 'A': color display
  if frame == 7000 then key(0x1E) end  -- 'A': demo mode
  if frame % 1500 == 0 then
    print(string.format("f=%d s3D8=%02X s9H=%d s9T=%d",
      frame, emu.read16(0x7E07B0, emu.memType.snesMemory),
      emu.read16(0x7E07BC, emu.memType.snesMemory),
      emu.read16(0x7E07BE, emu.memType.snesMemory)))
  end
  if frame == 10000 then
    shot("fs1_fly_snes.png")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
