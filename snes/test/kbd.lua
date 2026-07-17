local frame = 0
local seq = {
  {f=700, b="select"},
  {f=760,b="down"},{f=772,b="down"},{f=784,b="down"},
  {f=796,b="right"},{f=808,b="right"},{f=820,b="right"},
  {f=832,b="a"},
  {f=844,b="up"},{f=856,b="up"},{f=868,b="left"},
  {f=880,b="a"},
  {f=892,b="right"},
  {f=904,b="a"},
  {f=916,b="start"},
}
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 750 then shot("kbd_open.png") end
  if frame == 1150 then shot("kbd_ver.png") end
  if frame == 1250 then emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  for _, s in ipairs(seq) do
    if frame >= s.f and frame < s.f + 4 then
      local t = {}
      t[s.b] = true
      emu.setInput(t, 0)
    end
  end
end, emu.eventType.inputPolled)
