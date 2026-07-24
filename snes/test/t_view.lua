-- t_view — VIEW.COM (TP3, on the C:) renders the generated CARD.BMP
-- test card in CGA mode 6. End-to-end over DOS file I/O, the Turbo
-- Pascal runtime, INT 10h mode set and the M10p6 hires renderer.
-- MANUAL test: a full paint takes ~10 emulated minutes (near-realtime
-- in Mesen), so the suite covers VIEW with a runpc host leg instead.
-- Run:  Mesen --testrunner --timeout=2400 build/msdos.sfc test/t_view.lua
local frame = 0
local t = 0
local sent = false
local ingfx = 0
local lastsum = -1
local stable = 0
local gok = false
local exitchk = 0
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
      local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function toprow()
  -- the card is 160 rows letterboxed at y=20; row 20 (fb offset 800,
  -- its checkerboard corners are white) is painted LAST (bottom-up BMP)
  for i = 0, 79 do
    if emu.read(0x7E1000 + 800 + i, emu.memType.snesMemory) > 0 then return true end
  end
  return false
end
emu.addEventCallback(function()
  frame = frame + 1
  if not sent and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("cd view\rview card.bmp\r")
    sent = true
  end
  if sent and ingfx == 0 and emu.read16(0x7E07AE, emu.memType.snesMemory) == 1 then
    ingfx = frame
  end
  if ingfx > 0 and stable == 0 and exitchk == 0 and frame > ingfx + 200 and (frame % 60) == 0 then
    if toprow() then stable = frame + 120 end
  end
  if stable > 0 and exitchk == 0 and frame == stable then
    do
        local mode = emu.read16(0x7E078E, emu.memType.snesMemory)
        -- the card's top rows (y=20+: checkerboard) must have reached
        -- both the fb and the band-1 VRAM chars by now
        local v = emu.readWord(0xA000 + 2*512*2, emu.memType.snesVideoRam)
        gok = (mode == 6) and (v ~= 0)
        local png = emu.takeScreenshot()
        local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
        print("SHOT view_snes.png " .. hex)
        print(string.format("t_view m=%d vram2=%04X", mode, v))
        t = emu.read16(0x7E00D8, emu.memType.snesMemory)
        inject("x")                    -- key -> VIEW restores mode 3, exits
        exitchk = frame + 300
    end
  end
  if exitchk > 0 and frame == exitchk then
    local tok = emu.read16(0x7E07AE, emu.memType.snesMemory) == 0
                and bufhas("C:\\>")
    local ok = gok and tok
    print((ok and "RESULT PASS" or "RESULT FAIL") .. " t_view" ..
          (tok and "" or " (exit failed)"))
    emu.stop(0)
  end
  if frame == 120000 then print("RESULT FAIL t_view (timeout)"); emu.stop(0) end
end, emu.eventType.endFrame)
