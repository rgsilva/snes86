local frame = 0
local t = 0
local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
local heard = 0
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 30 then inject("gwbasic\r") end
  if frame == 5000 then inject("BEEP\r") end
  if frame > 5000 and frame < 6500 and frame % 10 == 0 then
    local ok, v = pcall(function() return emu.read(0x0000, emu.memType.spcMemory) end)
    if ok and v == 1 and heard == 0 then heard = 1; print("SPC PLAYING at frame " .. frame) end
  end
  if frame == 6500 then
    print("BEEP heard=" .. heard)
    heard = 0
    inject('PLAY "CDEC"\r')
  end
  if frame > 6500 and frame < 9000 and frame % 10 == 0 then
    local ok, v = pcall(function() return emu.read(0x0000, emu.memType.spcMemory) end)
    if ok and v == 1 and heard == 0 then heard = 1; print("SPC PLAYING (PLAY) at frame " .. frame) end
  end
  if frame == 9000 then print("PLAY heard=" .. heard) end
  if frame == 9400 then
    local ring = ""
    for i = 0, 31 do
      local w = emu.read16(0x7E0700 + i*2, emu.memType.snesMemory)
      ring = ring .. string.format("%04x ", w)
    end
    print("RING " .. ring)
  end
  if frame == 9500 then shot("beep_snes.png") end
  if frame == 9600 then emu.stop(0) end
end, emu.eventType.endFrame)
emu.addEventCallback(function()
  if frame >= 9100 and frame <= 9104 then emu.setInput({ right = true }, 0) end
  if frame >= 9200 and frame <= 9204 then emu.setInput({ up = true }, 0) end
end, emu.eventType.inputPolled)
