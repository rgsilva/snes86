-- suite test: t_cga6 — CGA6TST.COM renders the mode-6 (640x200) card
-- through the M10p6 hires-BG2 renderer. Asserts cMODE/cGFX/cWID, planar
-- stripe data in all three VRAM char bands ($5000/$7000/$2C00), the mono
-- CGRAM palette, the 1bpp glyph blitter, and a clean gfx_exit + a SHOT.
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
    inject("cd bench\rcga6tst\r")
    sent = true
  end
  if sent and armed == 0 and emu.read16(0x7E07AE, emu.memType.snesMemory) == 1 then
    armed = frame + 150            -- gfx entered; wait for a full repaint
  end
  if armed > 0 and frame == armed then
    local mode = emu.read16(0x7E078E, emu.memType.snesMemory)   -- cMODE
    local wid  = emu.read16(0x7E078C, emu.memType.snesMemory)   -- cWID
    -- stripes ($AA) land as plane0=AA/plane1=00 in every char band:
    local b1 = emu.readWord(0xA000, emu.memType.snesVideoRam)   -- row 0  @$5000
    local b2 = emu.readWord(0xE000, emu.memType.snesVideoRam)   -- row 16 @$7000
    local b3 = emu.readWord(0x5800, emu.memType.snesVideoRam)   -- row 24 @$2C00
    -- the solid white band (scanlines 96-111) fills tile row 12:
    local wb = emu.readWord(0xD000, emu.memType.snesVideoRam)   -- row 12 @$6800
    local c0 = emu.readWord(0,  emu.memType.snesCgRam)          -- black (backdrop)
    local c1 = emu.readWord(34, emu.memType.snesCgRam)          -- white (CGA group)
    -- glyph blitter: 'L' at row 1 col 0 -> fb byte (10>>1)*80 = 400;
    -- a control cell at col 40 keeps the AA stripes
    local go = emu.read(0x7E1000 + 400, emu.memType.snesMemory)
    local gb = emu.read(0x7E1000 + 440, emu.memType.snesMemory)
    gok = (mode == 6) and (wid == 80) and
          (b1 == 0x00AA) and (b2 == 0x00AA) and (b3 == 0x00AA) and
          (wb == 0x00FF) and
          (c0 == 0x0000) and (c1 == 0x7FFF) and
          (go ~= 0xAA) and (go ~= 0) and (gb == 0xAA)
    shot("cga6_snes.png")
    print(string.format("t_cga6 m=%d w=%d b=%04X,%04X,%04X wb=%04X cg=%04X,%04X g=%02X,%02X",
                        mode, wid, b1, b2, b3, wb, c0, c1, go, gb))
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("x")                    -- key -> CGA6TST restores mode 3, exits
    exitchk = frame + 200
  end
  if exitchk > 0 and frame == exitchk then
    local tok = emu.read16(0x7E07AE, emu.memType.snesMemory) == 0
                and bufhas("C:\\bench>") -- gfx_exit + prompt back in text
    local ok = gok and tok
    print((ok and "RESULT PASS" or "RESULT FAIL") .. " t_cga6" ..
          (tok and "" or " (gfx_exit failed)"))
    emu.stop(0)
  end
  if frame == 3000 then print("RESULT FAIL t_cga6 (timeout)"); emu.stop(0) end
end, emu.eventType.endFrame)
