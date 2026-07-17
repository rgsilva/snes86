local frame = 0
local keys = "dir\rdir bench\r"
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
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
  if frame == 1600 then shot("reorg.png") end
  if frame == 1700 then emu.stop(0) end
end, emu.eventType.endFrame)
