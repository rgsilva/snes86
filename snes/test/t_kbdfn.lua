-- suite test: t_kbdfn — on-screen keyboard: sticky SHIFT redraws the key
-- labels with the shifted glyphs (and reverts on unlatch AND on the
-- auto-unlatch after an emit), and the new F1-F10 row injects scancode-
-- only INT16 pairs (AH<-3B..44, AL<-0) that the guest consumes.
--
-- Label proof: the kbd tilemaps live at VRAM words $0800 (BG2, even
-- cols) / $0C00 (BG1, odd cols), tile = ascii*2 (mask $3FF: palette
-- bits differ on the selected key).
local frame = 0
local fails = {}
local function vtile(addr)   -- VRAM byte address -> tile index
  return emu.read16(addr, emu.memType.snesVideoRam) & 0x3FF
end
local function labels()
  -- '1' (row0 col1, BG1 $0C00 -> byte $1800), '2' (row0 col4, BG2
  -- $0802 -> byte $1004), 'q' (row1 col1, BG1 $0C20 -> byte $1840)
  return vtile(0x1800), vtile(0x1004), vtile(0x1840)
end
local function expect(name, want1, want2, wantq)
  local a, b, c = labels()
  if a ~= want1 or b ~= want2 or c ~= wantq then
    fails[#fails + 1] = string.format("%s: got %03x/%03x/%03x", name, a, b, c)
  end
end
local function ringhas(w)
  for i = 0, 31 do
    if emu.read16(0x7E0700 + i * 2, emu.memType.snesMemory) == w then return true end
  end
  return false
end
local function bufhas(str)
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r * 160 + c * 2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    if s:find(str, 1, true) then return true end
  end
  return false
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end

-- normal: '1'=$62 '2'=$64 'q'=$E2 / shifted: '!'=$42 '@'=$80 'Q'=$A2
emu.addEventCallback(function()
  frame = frame + 1
  if frame == 1250 and not bufhas("C:\\>") then
    print("RESULT FAIL t_kbdfn (no DOS prompt by 1250)")
    emu.stop(1)
  end
  if frame == 1400 then expect("latch", 0x42, 0x80, 0xA2) shot("t_kbdfn_shift.png") end
  if frame == 1480 then expect("unlatch", 0x62, 0x64, 0xE2) end
  if frame == 1560 then expect("relatch", 0x42, 0x80, 0xA2) end
  if frame == 1650 then
    expect("emit-revert", 0x62, 0x64, 0xE2)
    if not ringhas(0x0221) then fails[#fails + 1] = "no 0221 ('!') in ring" end
  end
  if frame == 1940 then
    local sel = emu.read16(0x7E00E0, emu.memType.snesMemory)
    if sel ~= 54 then fails[#fails + 1] = "kSEL=" .. sel .. " (want 54=F1)" end
  end
  if frame == 2020 then
    if not ringhas(0x3B00) then fails[#fails + 1] = "no 3B00 (F1) in ring" end
    local h = emu.read16(0x7E00D6, emu.memType.snesMemory)
    local t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    if h ~= t then fails[#fails + 1] = "guest left ring head!=tail" end
    shot("t_kbdfn_fkeys.png")
    if #fails == 0 then print("RESULT PASS t_kbdfn")
    else print("RESULT FAIL t_kbdfn (" .. table.concat(fails, "; ") .. ")") end
    emu.stop(0)
  end
end, emu.eventType.endFrame)

emu.addEventCallback(function()
  local function press(f0, btn)
    if frame >= f0 and frame <= f0 + 3 then emu.setInput({ [btn] = true }, 0) end
  end
  press(1300, "select")      -- show the keyboard
  press(1350, "y")           -- shift latch
  press(1430, "y")           -- shift unlatch
  press(1510, "y")           -- latch again
  press(1590, "a")           -- emit '!' -> auto-unlatch reverts labels
  press(1700, "down")        -- '1' -> 'q'
  press(1740, "down")        -- 'q' -> 'a'
  press(1780, "down")        -- 'a' -> 'z'
  press(1820, "down")        -- 'z' -> SPACE
  press(1860, "right")       -- SPACE -> TAB
  press(1900, "right")       -- TAB -> F1
  press(1950, "a")           -- press F1: ring gets 3B00
end, emu.eventType.inputPolled)
