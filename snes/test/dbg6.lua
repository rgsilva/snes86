local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if emu.read16(0x7FFFFC, emu.memType.snesMemory) == 0xCAFE then
    local b = {}
    for i = 0, 7 do b[#b+1] = string.format("%02X", emu.read(0x7E2C5C+i, emu.memType.snesMemory)) end
    print("guest@C5C: " .. table.concat(b, " "))
    emu.stop(0)
  end
  if frame > 600 then print("TIMEOUT") emu.stop(1) end
end, emu.eventType.endFrame)
