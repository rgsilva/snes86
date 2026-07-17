local function dp16(a) return emu.read16(0x7E0000+a, emu.memType.snesMemory) end
local function dp8(a) return emu.read(0x7E0000+a, emu.memType.snesMemory) end
local frame = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 120 then
    -- after ~step56 region: dump bES, mPTR, mPTR2, guest 0x500, boot bytes at 0x7D7B
    print(string.format("bES=%02X:%04X mPTR=%02X:%04X mPTR2=%02X:%04X",
      dp8(26), dp16(24), dp8(64), dp16(62), dp8(81), dp16(79)))
    local m = {}
    for i = 0, 15 do m[#m+1] = string.format("%02X", emu.read(0x7E2500+i, emu.memType.snesMemory)) end
    print("guest@500: " .. table.concat(m, " "))
    local b = {}
    for i = 0, 11 do b[#b+1] = string.format("%02X", emu.read(0x7E2000+0x7D70+i, emu.memType.snesMemory)) end
    print("boot@7D70: " .. table.concat(b, " "))
    emu.stop(0)
  end
end, emu.eventType.endFrame)
