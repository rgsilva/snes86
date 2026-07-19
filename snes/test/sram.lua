local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then
    -- read what the SNES CPU sees at each SRAM bank $70..$7D : 0000
    local s = ""
    for b = 0x70, 0x7D do
      local v = emu.read16(b*0x10000, emu.memType.snesMemory)
      s = s .. string.format("$%02X=%04X ", b, v)
    end
    print("SNES-visible: " .. s)
    print("count $04 = " .. emu.read(4, emu.memType.snesWorkRam))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
