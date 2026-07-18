local frame = 0
local t = 0
local phase = 0
local pf = 0
local ox, oy = -1, -1
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function injectscan(sc)          -- scancode-only entry (arrows)
  emu.write16(0x7E0700 + t, sc * 256, emu.memType.snesMemory)
  t = (t + 2) % 64
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
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
local function findOO()
  for r = 2, 24 do
    for c = 0, 78 do
      if emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory) == 79 and
         emu.read(0x7E1000 + r*160 + (c+1)*2, emu.memType.snesMemory) == 79 then
        return c, r
      end
    end
  end
  return -1, -1
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if phase == 0 and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("cd games\rsnipes\r")
    phase = 1
  end
  if phase == 1 and frame % 20 == 0 and bufhas("skill") then
    inject("a\r")
    phase = 2
  end
  if phase == 2 and frame % 20 == 0 and bufhas("Men Left") then
    phase = 3
    pf = frame + 25000
  end
  if phase == 3 and frame == pf then
    ox, oy = findOO()
    print(string.format("player at %d,%d", ox, oy))
    injectscan(0x4D)                   -- right arrow x3
    injectscan(0x4D)
    injectscan(0x4D)
    phase = 4
    pf = frame + 2000
  end
  if phase == 4 and frame == pf then
    local nx, ny = findOO()
    print(string.format("player now %d,%d (was %d,%d) moved=%s",
      nx, ny, ox, oy, tostring(nx ~= ox or ny ~= oy)))
    shot("snipes_snes.png")
    emu.stop(0)
  end
  if frame == 40000 then print("timeout phase=" .. phase); emu.stop(0) end
end, emu.eventType.endFrame)
