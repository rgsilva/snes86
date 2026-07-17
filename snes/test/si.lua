local frame = 0
local t = 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7FE000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
local done = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1200 then inject("si\r") end
  if done == 0 and frame > 1200 and frame % 50 == 0 and bufhas("Performance Index") then
    done = frame + 200
    print("SIDONE frame=" .. frame)
  end
  if done > 0 and frame == done then shot("si_snes.png"); emu.stop(0) end
  if frame == 60000 then print("TIMEOUT"); shot("si_snes.png"); emu.stop(0) end
end, emu.eventType.endFrame)
