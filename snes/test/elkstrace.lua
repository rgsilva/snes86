-- ELKS lockstep trace dump: records live in VBUF adapter RAM at $7E2000,
-- sentinels at $7E4FF8 (count) / $7E4FFA ($CAFE magic) — out of guest reach.
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  local magic = emu.read16(0x7E4FFA, emu.memType.snesMemory)
  if magic == 0xCAFE then
    local count = emu.read16(0x7E4FF8, emu.memType.snesMemory)
    for i = 0, count - 1 do
      local base = 0x7E2000 + i * 28
      local parts = {}
      for j = 0, 13 do
        parts[#parts + 1] = string.format("%04X", emu.read16(base + j * 2, emu.memType.snesMemory))
      end
      print(table.concat(parts, " "))
    end
    emu.stop(0)
    return
  end
  if frame > 30000 then print("TIMEOUT") emu.stop(1) end
end, emu.eventType.endFrame)
