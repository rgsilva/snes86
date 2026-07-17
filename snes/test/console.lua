-- Mesen2 testrunner script for the M1 console ROM.
-- io is sandboxed away, so screenshots are hex-dumped to stdout;
-- test/run_test.sh decodes them back into PNG files.

local frame = 0

local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame == 150 then shot("m1_banner.png") end
  if frame == 700 then shot("m1_dir.png") end
  if frame == 720 then emu.stop(0) end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  if frame >= 200 and frame <= 205 then
    emu.setInput({ start = true }, 0)
  end
end, emu.eventType.inputPolled)
