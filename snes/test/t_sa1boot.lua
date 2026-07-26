-- suite test: t_sa1boot — the SA-1 ROM (300 KB machine: 108 KB WRAM +
-- 192 KB BW-RAM) boots MS-DOS to the C:\> prompt with the SPC idle.
-- Same shape as t_boot, on build/msdos_sa1.sfc; the boot is slower than
-- the 108 KB machine (reset zeroes three BW-RAM banks and SYSINIT
-- relocates to the top of 300 KB), hence the wider frame budget.
local frame = 0
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end

local spc_ok = nil
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1100 then spc_ok = (emu.read(0, emu.memType.spcMemory) == 0) end
  if frame % 10 == 0 and frame > 1100 and bufhas("C:\\>") then
    -- the banner must name the SA-1 machine, or we booted the wrong ROM
    local sa1 = bufhas("300KB guest RAM (SA-1)")
    local ok = spc_ok and sa1
    print((ok and "RESULT PASS" or "RESULT FAIL") ..
          " t_sa1boot (prompt at frame " .. frame ..
          ", banner=" .. tostring(sa1) .. ", spc idle=" .. tostring(spc_ok) .. ")")
    emu.stop(0)
  end
  if frame == 4000 then print("RESULT FAIL t_sa1boot (no prompt)"); emu.stop(0) end
end, emu.eventType.endFrame)
