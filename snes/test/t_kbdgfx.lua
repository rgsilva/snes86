-- suite test: t_kbdgfx — the on-screen keyboard stays legible in CGA
-- graphics modes.
--
-- Regression guard for the palette-group collision that made the raised
-- keyboard invisible in every graphics-mode guest: pal_apply used to
-- repaint CGRAM 0-3 from the CGA palette registers, and CGRAM 1/2 are
-- exactly the keyboard's normal-key (bg, fg) pair — in mode 6 both
-- became the mono foreground, so the labels vanished into their own
-- background and only the highlight (pair 7, CGRAM 29/30) survived.
--
-- Asserts, in mode 6 (640x200 mono) and mode 4 (320x200 4-color), with
-- the keyboard raised:
--   * CGRAM: pair 0 is still black/green and pair 7 still yellow, and
--     the CGA foreground lives in its own group (CGRAM 17+), i.e. the
--     bitmap palette and the keyboard palette cannot alias.
--   * pixels: the keyboard strip really contains green label pixels —
--     hundreds of them — so labels are drawn AND contrast their key
--     background. (With the bug this count is exactly 0.)
local frame = 0
local t = 0
local stage = 0
local at = 0
local fails = {}
local log = {}

local KVIS  = 0x7E00E4
local CGFX  = 0x7E07AE
local CMODE = 0x7E078E

local function inject(keys)
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), emu.memType.snesMemory)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function send(keys)
  t = emu.read16(0x7E00D8, emu.memType.snesMemory)
  inject(keys)
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

-- The on-screen keyboard occupies scanlines 184-223. Mesen's SNES frame
-- buffer is 512x478 (hires width, every scanline doubled), so scanline s
-- is buffer rows 2s and 2s+1.
local function strip_greens()
  local b = emu.getScreenBuffer()
  local green, distinct, n = 0, {}, 0
  for s = 188, 220 do
    local base = (2*s) * 512
    for x = 0, 511 do
      local p = b[base + x + 1]
      local r = (p >> 16) & 0xFF
      local g = (p >> 8) & 0xFF
      local bl = p & 0xFF
      if g > 0x80 and r < 0x60 and bl < 0x60 then green = green + 1 end
      local k = p & 0xFFFFFF
      if not distinct[k] then distinct[k] = true; n = n + 1 end
    end
  end
  return green, n
end

local function check(name, want4)
  local cg1  = emu.readWord(2,  emu.memType.snesCgRam)   -- key bg (pair 0)
  local cg2  = emu.readWord(4,  emu.memType.snesCgRam)   -- key fg (pair 0)
  local cg29 = emu.readWord(58, emu.memType.snesCgRam)   -- highlight bg
  local cga1 = emu.readWord(34, emu.memType.snesCgRam)   -- CGA pixel value 1
  local vis  = emu.read16(KVIS,  emu.memType.snesMemory)
  local gfx  = emu.read16(CGFX,  emu.memType.snesMemory)
  local mode = emu.read16(CMODE, emu.memType.snesMemory)
  local green, distinct = strip_greens()
  log[#log+1] = string.format(
    "%s mode=%d gfx=%d vis=%d pair0=%04X/%04X hl=%04X cga1=%04X green=%d colors=%d",
    name, mode, gfx, vis, cg1, cg2, cg29, cga1, green, distinct)
  local function want(cond, why)
    if not cond then fails[#fails+1] = name .. ":" .. why end
  end
  want(gfx == 1, "not-in-graphics")
  want(mode == want4, "wrong-mode")
  want(vis == 1, "keyboard-not-raised")
  want(cg1 == 0x0000 and cg2 == 0x03E0, "pair0-clobbered")
  want(cg29 == 0x03FF, "highlight-clobbered")
  want(cga1 ~= cg2, "cga-fg-aliases-key-fg")
  want(green > 400, "labels-invisible")
end

emu.addEventCallback(function()
  frame = frame + 1

  if stage == 0 then                       -- boot -> mode 6
    if frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
      send("cd bench\rcga6tst\r")
      stage = 1
    end
  elseif stage == 1 then                   -- wait for the bitmap
    if emu.read16(CGFX, emu.memType.snesMemory) == 1 then
      at = frame + 150; stage = 2
    end
  elseif stage == 2 then                   -- keyboard up (Select), settle
    if frame == at then at = frame + 60; stage = 3 end
  elseif stage == 3 then
    if frame == at then check("mode6", 6); send("x"); at = frame + 200; stage = 4 end
  elseif stage == 4 then                   -- back to text, then mode 4
    if frame == at then
      if not bufhas("C:\\bench>") then fails[#fails+1] = "mode6:no-gfx-exit" end
      send("cgatest\r"); stage = 5
    end
  elseif stage == 5 then
    if emu.read16(CGFX, emu.memType.snesMemory) == 1 then
      at = frame + 150; stage = 6
    end
  elseif stage == 6 then
    if frame == at then check("mode4", 4); send("x"); at = frame + 200; stage = 7 end
  elseif stage == 7 then
    if frame == at then
      if not bufhas("C:\\bench>") then fails[#fails+1] = "mode4:no-gfx-exit" end
      for _, l in ipairs(log) do print("t_kbdgfx " .. l) end
      if #fails == 0 then
        print("RESULT PASS t_kbdgfx")
      else
        print("RESULT FAIL t_kbdgfx (" .. table.concat(fails, " ") .. ")")
      end
      emu.stop(0)
    end
  end

  if frame == 3400 then
    for _, l in ipairs(log) do print("t_kbdgfx " .. l) end
    print("RESULT FAIL t_kbdgfx (timeout stage=" .. stage .. ")")
    emu.stop(0)
  end
end, emu.eventType.endFrame)

-- Select raises the on-screen keyboard, once, as soon as the mode-6
-- bitmap is up; it stays up for the mode-4 half of the run too.
emu.addEventCallback(function()
  if stage == 2 and at > 0 and frame >= at - 40 and frame <= at - 35 then
    emu.setInput({ select = true }, 0)
  end
end, emu.eventType.inputPolled)
