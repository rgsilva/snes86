local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 100 == 0 and frame <= 400 then
    print(string.format("f=%d cNMI=%04X cTickA=%04X cTickL=%04X joyN=%04X",
      frame, dp16(0xC0), dp16(0xD0), dp16(0xD2), dp16(0xCE)))
  end
  if frame > 420 then emu.stop(0) end
end, emu.eventType.endFrame)
