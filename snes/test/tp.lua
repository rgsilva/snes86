-- Pre-load the keyboard ring with the whole TP session, then watch.
local frame = 0
local keys = "turbo\rYwhello.pas\rr"
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then
    -- ring already holds two CRs (date/time); append our session
    local t = 4
    for i = 1, #keys do
      local ch = keys:byte(i)
      if ch == 10 then ch = 13 end
      emu.write16(0x7E0700 + t, 0x1000 + ch, emu.memType.snesMemory)
      t = (t + 2) % 64
    end
    emu.write16(0x7E00DA - 2, t, emu.memType.snesMemory)  -- cKbT at $D8
  end
  if frame == 1200 then shot("tp_menu.png") end
  if frame == 9000 then shot("tp_hello.png") end
  if frame == 9100 then emu.stop(0) end
end, emu.eventType.endFrame)
