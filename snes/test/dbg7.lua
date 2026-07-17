local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 300 or frame == 450 then
    local b = {}
    for i = 0, 15 do b[#b+1] = string.format("%02X", emu.read(0x7E2000+0x700+0xE0+i, emu.memType.snesMemory)) end
    print(string.format("f=%d code@70:E0: %s", frame, table.concat(b, " ")))
    print(string.format("  ticksL=%04X bda440=%02X bda6C=%04X",
      dp16(0xD2),
      emu.read(0x7E2440, emu.memType.snesMemory),
      emu.read16(0x7E246C, emu.memType.snesMemory)))
  end
  if frame > 500 then emu.stop(0) end
end, emu.eventType.endFrame)
