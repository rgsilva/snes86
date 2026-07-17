local frame = 0
local t = 0
local tstart, tend = 0, 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function findchar(ch)  -- scan console buffer for a char code
  for r = 0, 24 do
    for c = 0, 79 do
      if emu.read(0x7FE000 + r*160 + c*2, emu.memType.snesMemory) == ch then return true end
    end
  end
  return false
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1200 then inject("cd bench\r") end
  if frame == 1600 then inject("cpubench\r") end
  if tstart == 0 and frame > 1700 and findchar(91) then tstart = frame end   -- '['
  if tstart > 0 and tend == 0 and frame % 5 == 0 and findchar(93) then       -- ']'
    tend = frame
    print("BASELINE loop_frames=" .. (tend - tstart) .. " (start=" .. tstart .. " end=" .. tend .. ")")
    emu.stop(0)
  end
  if frame == 40000 then print("timeout tstart=" .. tstart); emu.stop(0) end
end, emu.eventType.endFrame)
