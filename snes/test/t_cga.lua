-- suite test: t_cga — CGATEST.COM renders the mode-4 test card.
-- Asserts cGFX, planar tile data in VRAM (AA/55 interleave bands) and
-- the CGRAM palette (pal 1 + blue bg via INT10 AH=0B), plus a SHOT.
local frame = 0
local t = 0
local sent = false
local armed = 0
local exitchk = 0
local gok = false
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
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(c) return string.format("%02x", c:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if not sent and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("cd bench\rcgatest\r")
    sent = true
  end
  if sent and armed == 0 and emu.read16(0x7E07AE, emu.memType.snesMemory) == 1 then
    armed = frame + 150            -- gfx entered; wait for a full repaint
  end
  if armed > 0 and frame == armed then
    local v0 = emu.readWord(0xA0A0, emu.memType.snesVideoRam)   -- tile 10 line 0
    local v1 = emu.readWord(0xA0A2, emu.memType.snesVideoRam)   -- tile 10 line 1
    -- CGA colors live in CGRAM group 4 (pixel value v -> CGRAM 16+v);
    -- value 0 is transparent on a 2bpp BG, so it comes from the backdrop.
    local c0 = emu.readWord(0,  emu.memType.snesCgRam)          -- bg blue
    local c1 = emu.readWord(34, emu.memType.snesCgRam)          -- cyan
    local c2 = emu.readWord(36, emu.memType.snesCgRam)          -- magenta
    local c3 = emu.readWord(38, emu.memType.snesCgRam)          -- light gray
    -- glyph blitter: "OK" at row 22 col 1; fb even-line-2 of the 'O'
    -- cell = (22*4+1)*80 + 1*2 = 7122; a control cell keeps the AA fill
    local go = emu.read(0x7E1000 + 7122, emu.memType.snesMemory)
    local gb = emu.read(0x7E1000 + 7122 + 8, emu.memType.snesMemory)
    gok = (v0 == 0xFF00) and (v1 == 0x00FF) and
          (c0 == 0x5400) and (c1 == 0x56A0) and
          (c2 == 0x5415) and (c3 == 0x56B5) and
          (go ~= 0xAA) and (go ~= 0) and (gb == 0xAA)
    shot("cga_snes.png")
    print(string.format("t_cga v0=%04X v1=%04X cg=%04X,%04X,%04X,%04X",
                        v0, v1, c0, c1, c2, c3))
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("x")                    -- key -> CGATEST restores mode 3, exits
    exitchk = frame + 200
  end
  if exitchk > 0 and frame == exitchk then
    local tok = emu.read16(0x7E07AE, emu.memType.snesMemory) == 0
                and bufhas("C:\\bench>") -- gfx_exit + prompt back in text
    local ok = gok and tok
    print((ok and "RESULT PASS" or "RESULT FAIL") .. " t_cga" ..
          (tok and "" or " (gfx_exit failed)"))
    emu.stop(0)
  end
  if frame == 3000 then print("RESULT FAIL t_cga (timeout)"); emu.stop(0) end
end, emu.eventType.endFrame)
