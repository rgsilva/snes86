local frame = 0
local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 5 == 0 and frame <= 30 then
    local ok, err = pcall(function()
      print(string.format(
        "f=%d gIP=%04X halt=%04X stepCNT=%04X snap=%04X bCS=%04X kind=%04X magic=%04X mem3000=%04X",
        frame, dp16(0x20), dp16(0x22), dp16(0x44), dp16(0x42), dp16(0x1A),
        dp16(0x26), emu.read16(0x7FFFFC, emu.memType.snesMemory),
        emu.read16(0x7E3000, emu.memType.snesMemory)))
    end)
    if not ok then print("ERR " .. tostring(err)) end
  end
  if frame > 40 then emu.stop(0) end
end, emu.eventType.endFrame)
