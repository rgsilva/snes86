local frame, t, phase, lastact = 0, 0, 0, 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function rowstr(r)
  local s = ""
  for c = 0, 79 do
    local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
    if ch < 32 or ch > 126 then ch = 32 end
    s = s .. string.char(ch)
  end
  return s
end
local function bufhas(str)
  for r = 0, 24 do
    if rowstr(r):find(str, 1, true) then return true end
  end
  return false
end
local function dumpText(tag)
  print("=== " .. tag .. " (frame " .. frame .. ") ===")
  for r = 0, 24 do
    local s = rowstr(r):gsub("%s+$", "")
    if #s > 0 then print(string.format("%2d| %s", r, s)) end
  end
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame % 120 ~= 0 then return end
  if phase == 0 and bufhas("login:") then
    phase = 1; lastact = frame; inject("root\r")
  elseif phase == 1 and bufhas("#") then
    phase = 2; lastact = frame
    print("shell prompt at frame " .. frame)
    inject("uname -snrm\r")
  elseif phase == 2 and frame - lastact >= 1800 then
    phase = 3; lastact = frame
    inject("meminfo\r")
  elseif phase == 3 and frame - lastact >= 3600 then
    dumpText("TROPHY")
    local png = emu.takeScreenshot()
    local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
    print("SHOT elks_trophy.png " .. hex)
    emu.stop(0)
  elseif phase == 1 and frame - lastact >= 9000 then
    dumpText("NO SHELL (login exec starved?)"); emu.stop(1)
  end
  if frame >= 40000 then dumpText("TIMEOUT") emu.stop(1) end
end, emu.eventType.endFrame)
