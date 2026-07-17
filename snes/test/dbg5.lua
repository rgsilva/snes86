local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
local function dp8(a) return emu.read(0x7E0000+a, emu.memType.snesMemory) end
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if emu.read16(0x7FFFFC, emu.memType.snesMemory) == 0xCAFE then
    print(string.format("mPTR=%02X:%04X mPTR2=%02X:%04X cT0=%04X cT1=%04X",
      dp8(64), dp16(62), dp8(81), dp16(79), dp16(0xDA), dp16(0xDC)))
    local m = {}
    for i = 0, 15 do m[#m+1] = string.format("%02X", emu.read(0x7E2500+i, emu.memType.snesMemory)) end
    print("guest@500: " .. table.concat(m, " "))
    emu.stop(0)
  end
  if frame > 600 then print("TIMEOUT") emu.stop(1) end
end, emu.eventType.endFrame)
