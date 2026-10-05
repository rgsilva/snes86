-- suite test: t_zoom -- the 32-column view (dosboot.asm view_*).
-- L+R switches views: the default text colour, the scanner's fat tiles,
-- the pan following a resting cursor and its wider range, a glyph from
-- the fat font's upper half, and that half surviving a trip through CGA
-- graphics, whose tilemap borrows its VRAM.
local frame = 0
local fails = {}
local function check(ok, msg)
  if not ok then fails[#fails + 1] = msg; print("t_zoom: FAIL " .. msg) end
end
local function rd(a) return emu.read(a, emu.memType.snesMemory) end
local function rd16(a) return emu.read16(a, emu.memType.snesMemory) end
local cROW, cCOL, kPAN, vZ, cGFX = 0x7E00C6, 0x7E00C8, 0x7E00F6, 0x7E0220, 0x7E07AE
local function vram(word) return emu.readWord(word * 2, emu.memType.snesVideoRam) end
local function cgram(i) return emu.readWord(i * 2, emu.memType.snesCgRam) end
local function fat2sum()
  local s = 0
  for w = 0x2800, 0x2FFF do s = (s * 31 + vram(w)) % 2147483647 end
  return s
end
local function on_bg2(col, tile)          -- a BG2 map row with `tile` at `col`
  for r = 0, 27 do
    if vram(r * 32 + col) & 0x3FF == tile then return r end
  end
end
local function rows()
  local t = {}
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = rd(0x7E1000 + r * 160 + c * 2)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    t[#t + 1] = (s:gsub("%s+$", ""))
  end
  return t
end
local function last_row()
  local last = ""
  for _, s in ipairs(rows()) do if s ~= "" then last = s end end
  return last
end
local function inject(s)
  local tl = rd16(0x7E00D8)
  for i = 1, #s do
    emu.write16(0x7E0700 + tl, 0x1000 + s:byte(i), emu.memType.snesMemory)
    tl = (tl + 2) % 64
  end
  emu.write16(0x7E00D8, tl, emu.memType.snesMemory)
end
local function shot(name)
  local png = emu.takeScreenshot()
  print("SHOT " .. name .. " " .. png:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local pad, pad_until = nil, 0
local function press(buttons) pad = buttons; pad_until = frame + 4 end
emu.addEventCallback(function()
  if pad and frame < pad_until then emu.setInput(pad, 0) end
end, emu.eventType.inputPolled)

local steps, si, st_frame = {}, 1, 0
local function step(name, timeout, start, done)
  steps[#steps + 1] = { name = name, timeout = timeout, start = start, done = done }
end
local mark = {}
local function after(n) return function() return frame - st_frame >= n end end

step("boot", 2000, nil, function() return frame > 1100 and last_row() == "C:\\>" end)
step("to the 32-column view", 60, function()
  check(rd16(vZ) == 0 and cgram(2) == 0x03E0, "the ROM did not boot in the 64-column view, green")
  mark.fat = fat2sum()
  local ink = 0
  for w = 0, 15 do ink = ink | vram(0x2800 + (0xC4 - 0x80) * 16 + w) end
  check(ink ~= 0, "no fat glyph for the box-drawing dash")
  press({ l = true, r = true })
end, after(40))
step("fat tiles", 600, function()
  check(rd16(vZ) == 1, "L+R did not switch views")
  check(cgram(2) == 0x7FFF, string.format("default colour %04X in the 32-column view", cgram(2)))
  local row = on_bg2(0, 0x200 + 2 * 0x43)
  check(row, "the prompt is not drawn with the fat C")
  check(row and vram(0x400 + row * 32) == 0x2000, "BG1 is not transparent under fat text")
  -- a box-drawing dash at column 10, three rows below the prompt
  emu.write16(0x7E1000 + (rd16(cROW) + 3) * 160 + 20, 0x07C4, emu.memType.snesMemory)
  inject("rem 34567890123456789012345678")           -- to column 34
  mark.phase = 0
end, function()
  if mark.phase == 0 and rd16(cCOL) == 34 then
    mark.phase = 1
    mark.at = frame
  elseif mark.phase == 1 and frame - mark.at == 30 then
    check(rd16(kPAN) == 8, "pan " .. rd16(kPAN) .. " with the cursor at column 34, want 8")
    inject("90123456789012345")                        -- to column 51
    mark.phase = 2
  elseif mark.phase == 2 and rd16(cCOL) == 51 then
    mark.phase = 3
    mark.at = frame
  end
  return mark.phase == 3 and frame - mark.at == 30
end)
step("follow and pan", 200, function()
  check(rd16(kPAN) == 24, "pan " .. rd16(kPAN) .. " with the cursor at column 51, want 24")
  shot("zoom_typing.png")
  mark.phase = 0
end, function()
  local e = frame - st_frame
  if e == 10 then press({ l = true }) end
  if e == 20 then check(rd16(kPAN) == 16, "L from 24 gave " .. rd16(kPAN)) end
  if e >= 30 and e < 110 and e % 10 == 0 then press({ r = true }) end
  if e == 120 then check(rd16(kPAN) == 48, "R stops at " .. rd16(kPAN) .. ", want 48") end
  if e == 125 then inject("\3") end             -- Ctrl-C: DOS abandons the line
  return e >= 170
end)
step("box glyph, pan home", 30, function()
  check(rd16(kPAN) == 0, "pan " .. rd16(kPAN) .. " after the cursor went home")
  check(on_bg2(10, 0x200 + 2 * 0xC4), "the box-drawing dash is not drawn from the fat font's upper half")
  inject("cd bench\rcgatest\r")
end, function() return true end)
step("into graphics", 900, nil, function() return rd16(cGFX) == 1 and frame - st_frame > 150 end)
step("back to text", 600, function()
  check(fat2sum() ~= mark.fat, "the graphics tilemap is not where the fat glyphs were")
  inject("x")
end, function() return rd16(cGFX) == 0 and last_row() == "C:\\bench>" end)
step("glyphs back", 40, function()
  check(fat2sum() == mark.fat, "the fat font's upper half did not come back after graphics")
  check(cgram(2) == 0x7FFF, "the default colour did not survive graphics")
  shot("zoom_32.png")
  press({ l = true, r = true })
end, after(30))
step("64 columns again", 30, function()
  check(rd16(vZ) == 0 and cgram(2) == 0x03E0, "L+R did not switch back")
  check(rd16(kPAN) == 0, "pan not reset on the way back")
end, after(28))

emu.addEventCallback(function()
  frame = frame + 1
  local s = steps[si]
  if s == nil then return end
  if st_frame == 0 then
    st_frame = frame
    if s.start then s.start() end
  end
  if s.done() then
    si = si + 1
    st_frame = 0
  elseif frame - st_frame > s.timeout then
    check(false, "timeout in '" .. s.name .. "'")
    for _, r in ipairs(rows()) do if r ~= "" then print("  | " .. r) end end
    si = #steps + 1
  end
  if si > #steps then
    check(on_bg2(0, 2 * 0x43), "64-column tiles did not come back")
    if #fails == 0 then print("RESULT PASS t_zoom")
    else print("RESULT FAIL t_zoom (" .. fails[1] .. ")") end
    emu.stop(0)
  end
end, emu.eventType.endFrame)
