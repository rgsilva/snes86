local frame = 0
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1250 then shot("dos_copy.png") end
  if frame == 2000 then shot("dos_chkdsk.png") end
  if frame == 2700 then shot("dos_dirb.png") end
  if frame == 2800 then emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  if frame >= 700 and frame <= 705 then emu.setInput({ select = true }, 0) end
  if frame >= 1300 and frame <= 1305 then emu.setInput({ y = true }, 0) end
  if frame >= 2050 and frame <= 2055 then emu.setInput({ start = true }, 0) end
end, emu.eventType.inputPolled)
