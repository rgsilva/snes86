-- FS boot debug: trap INT13 error paths + count successful sector reads
local frame = 0
local errs = 0
local secs = 0
local function w(a) return emu.read16(0x7E0000 + a, emu.memType.snesMemory) end
emu.addMemoryCallback(function()
  errs = errs + 1
  if errs <= 5 then
    print(string.format("INT13 ERR f=%d AX=%04X CX=%04X DX=%04X ES=%04X",
      frame, w(0), w(2), w(4), w(0x10)))
  end
end, emu.callbackType.exec, 0x8099B9, 0x8099BD, emu.cpuType.snes, emu.memType.snesMemory)
emu.addMemoryCallback(function()
  secs = secs + 1
end, emu.callbackType.exec, 0x809A72, 0x809A73, emu.cpuType.snes, emu.memType.snesMemory)
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 1500 == 0 then
    print(string.format("f=%d int13err=%d secreads=%d cGFX=%d s3D8=%02X",
      frame, errs, secs, w(0x07AE), w(0x07B0)))
  end
  if frame == 9000 then emu.stop(0) end
end, emu.eventType.endFrame)
