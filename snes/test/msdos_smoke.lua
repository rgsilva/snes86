-- MS-DOS variant boot smoke test: read the VBUF text grid and print it.
-- VBUF text at $7E1000, 2 bytes/char (char,attr), 160 bytes/row.
local frame = 0
local function dumpText(tag)
  print("=== " .. tag .. " (frame " .. frame .. ") ===")
  for r = 0, 24 do
    local line = {}
    for c = 0, 79 do
      local ch = emu.read(0x1000 + r * 160 + c * 2, emu.memType.snesWorkRam)
      if ch >= 32 and ch < 127 then line[#line + 1] = string.char(ch)
      else line[#line + 1] = " " end
    end
    local s = table.concat(line):gsub("%s+$", "")
    if #s > 0 then print(string.format("%2d| %s", r, s)) end
  end
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1400 then dumpText("boot") end
  if frame == 1450 then emu.stop(0) end
end, emu.eventType.endFrame)
