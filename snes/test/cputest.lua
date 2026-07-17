-- Dump the 65816 core's per-instruction register snapshots for the
-- lockstep parity check. Records: 14 words each at $7F:0000+, count at
-- $7F:FFFA, magic $CAFE at $7F:FFFC when the run completes.
-- $0BAD magic = the core hit an unimplemented opcode (id at $7F:FFFE).

local frame = 0

emu.addEventCallback(function()
  frame = frame + 1
  local magic = emu.read16(0x7FFFFC, emu.memType.snesMemory)
  if magic == 0x0BAD then
    print(string.format("BADOP %02X",
      emu.read(0x7FFFFE, emu.memType.snesMemory)))
    emu.stop(2)
    return
  end
  if magic == 0xCAFE then
    local count = emu.read16(0x7FFFFA, emu.memType.snesMemory)
    for i = 0, count - 1 do
      local base = 0x7F0000 + i * 28
      local parts = {}
      for j = 0, 13 do
        parts[#parts + 1] =
          string.format("%04X", emu.read16(base + j * 2, emu.memType.snesMemory))
      end
      print(table.concat(parts, " "))
    end
    emu.stop(0)
    return
  end
  if frame > 7200 then
    print("TIMEOUT")
    emu.stop(1)
  end
end, emu.eventType.endFrame)
