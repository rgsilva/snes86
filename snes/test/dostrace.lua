local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  local magic = emu.read16(0x7FFFFC, emu.memType.snesMemory)
  if magic == 0xCAFE then
    local count = emu.read16(0x7FFFFA, emu.memType.snesMemory)
    for i = 0, count - 1 do
      local base = 0x7FA000 + i * 28
      local parts = {}
      for j = 0, 13 do
        parts[#parts + 1] = string.format("%04X", emu.read16(base + j * 2, emu.memType.snesMemory))
      end
      print(table.concat(parts, " "))
    end
    emu.stop(0)
    return
  end
  if frame > 3600 then print("TIMEOUT") emu.stop(1) end
end, emu.eventType.endFrame)
