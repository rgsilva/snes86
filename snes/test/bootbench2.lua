local frame = 0
local found = 0
emu.addEventCallback(function()
  frame = frame + 1
  if found == 0 and frame % 5 == 0 then
    -- find "A>" : 'A' on BG2 (even col), '>' on BG1 (odd col), same cell
    for k = 0, 895 do
      local w2 = emu.readWord(k*2, emu.memType.snesVideoRam)
      if w2 % 1024 == 130 then           -- tile 65*2 = 'A'
        local w1 = emu.readWord(0x800 + k*2, emu.memType.snesVideoRam)
        if w1 % 1024 == 124 then         -- tile 62*2 = '>'
          found = 1
          print("APROMPT frame=" .. frame)
          emu.stop(0)
          break
        end
      end
    end
  end
  if frame == 3000 then print("APROMPT timeout"); emu.stop(0) end
end, emu.eventType.endFrame)
