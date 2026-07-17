local frame = 0
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 500 then shot("kbh2_snes.png") end
  if frame == 510 then emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  if frame >= 200 and frame <= 205 then emu.setInput({ select = true }, 0) end
  if frame >= 300 and frame <= 305 then emu.setInput({ right = true }, 0) end
end, emu.eventType.inputPolled)
