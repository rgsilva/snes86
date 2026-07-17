local frame = 0
local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 150 == 0 and frame <= 1200 then
    print(string.format("f=%d CS:IP=%04X:%04X SP=%04X AX=%04X HALT=%d qh=%04X qt=%04X",
      frame, dp16(18), dp16(36), dp16(8), dp16(0), dp16(38), dp16(0xC2), dp16(0xC4)))
  end
  if frame > 1200 then emu.stop(0) end
end, emu.eventType.endFrame)
