local frame = 0
local keys = "mp\r"
local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then
    local t = 0
    for i = 1, #keys do
      emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
      t = (t + 2) % 64
    end
    emu.write16(0x7E00D8, t, emu.memType.snesMemory)
  end
  if frame == 2600 then
    -- guest ES (gES at DP $10), its cached base bES (DP $18, 3 bytes)
    print(string.format("gES=%04X bES=%02X:%04X  gDS=%04X bDS=%02X:%04X",
      dp16(0x10), emu.read(0x7E001A, emu.memType.snesMemory), dp16(0x18),
      dp16(0x16), emu.read(0x7E0023, emu.memType.snesMemory), dp16(0x21)))
    -- shadow buffer first 16 bytes at $7F:E000
    local s = {}
    for i = 0, 15 do s[#s+1] = string.format("%02X", emu.read(0x7E1000+i, emu.memType.snesMemory)) end
    print("shadow@E000: " .. table.concat(s, " "))
    -- PPU: is screen on? read $2100 shadow not possible; check BG map cell
    print(string.format("kVIS=%04X kPAN=%04X scanROW=%04X cROW=%04X",
      dp16(0xE6), dp16(0xC6+0x1E), dp16(0xE8), dp16(0xC6)))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
