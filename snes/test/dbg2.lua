local frame = 0
local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then
    print(string.format(
      "magic=%04X kind=%04X lfA=%04X lfB=%04X lfR=%04X lfCF=%04X fSTATIC=%04X tmp2=%04X snap0_FL=%04X",
      emu.read16(0x7FFFFC, emu.memType.snesMemory),
      dp16(0x26), dp16(0x28), dp16(0x2A), dp16(0x2C), dp16(0x2E), dp16(0x24),
      dp16(0x40), emu.read16(0x7F001A, emu.memType.snesMemory)))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
