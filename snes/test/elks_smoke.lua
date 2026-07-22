-- sneslinux boot smoke test: dump the VBUF text grid periodically until
-- the ELKS login prompt shows up (or we give up). VBUF text at $7E1000,
-- 2 bytes/char (char,attr), 160 bytes/row.
local frame = 0
local function screenText()
  local rows = {}
  for r = 0, 24 do
    local line = {}
    for c = 0, 79 do
      local ch = emu.read(0x1000 + r * 160 + c * 2, emu.memType.snesWorkRam)
      if ch >= 32 and ch < 127 then line[#line + 1] = string.char(ch)
      else line[#line + 1] = " " end
    end
    rows[r] = table.concat(line):gsub("%s+$", "")
  end
  return rows
end
local function dumpText(tag)
  print("=== " .. tag .. " (frame " .. frame .. ") ===")
  local rows = screenText()
  for r = 0, 24 do
    if #rows[r] > 0 then print(string.format("%2d| %s", r, rows[r])) end
  end
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 600 == 0 then
    local rows = screenText()
    local all = table.concat(rows, "\n")
    if all:find("login:") then
      dumpText("LOGIN REACHED")
      emu.stop(0)
    elseif frame >= 12000 then
      dumpText("TIMEOUT")
      emu.stop(1)
    elseif frame % 1800 == 0 then
      dumpText("progress")
    end
  end
end, emu.eventType.endFrame)
