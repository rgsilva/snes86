local frame = 0
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 700 then shot("dos_boot.png") end
  if frame == 2000 then shot("dos_dir.png") end
  if frame == 2100 then emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  if frame >= 800 and frame <= 805 then
    emu.setInput({ start = true }, 0)
  end
end, emu.eventType.inputPolled)
