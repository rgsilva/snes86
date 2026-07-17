local frame = 0
local found = 0
emu.addEventCallback(function()
  frame = frame + 1
  if found == 0 and frame % 5 == 0 then
    for r = 0, 24 do
      local c1 = emu.read(0x7E1000 + r*160, emu.memType.snesMemory)
      local c2 = emu.read(0x7E1000 + r*160 + 2, emu.memType.snesMemory)
      if c1 == 65 and c2 == 62 then   -- "A>"
        found = 1
        print("APROMPT frame=" .. frame)
        emu.stop(0)
        break
      end
    end
  end
  if frame == 3000 then print("APROMPT timeout"); emu.stop(0) end
end, emu.eventType.endFrame)
