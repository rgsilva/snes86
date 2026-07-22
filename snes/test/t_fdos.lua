-- FreeDOS regression: boot build/freedos.sfc to the FreeCOM prompt.
-- Success = the AUTOEXEC banner painted, which proves kernel + FreeCOM +
-- C: (the AUTOEXEC runs after the shell is up). Needs Mesen --timeout.
local frame = 0
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x1000 + r*160 + c*2, emu.memType.snesWorkRam)
      if ch >= 32 and ch < 127 then s = s .. string.char(ch) else s = s .. " " end
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 ~= 0 then return end
  if bufhas("FreeDOS on a SNES") then
    print("RESULT PASS t_fdos")
    emu.stop(0)
  elseif frame >= 30000 then
    print("RESULT FAIL t_fdos (no FreeCOM prompt by frame 30000)")
    emu.stop(1)
  end
end, emu.eventType.endFrame)
