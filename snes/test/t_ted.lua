-- suite test: t_ted — TED (our controller-first editor) edits a file on
-- B:, the battery-backed SRAM drive: launch, type (measuring keystroke
-- latency), cursor with arrow scancodes, menu-save, quit, and TYPE the
-- file back at the DOS prompt. Run with --timeout=300.
local frame = 0
local t = 0
local stage = 0
local waitf = 0
local t0 = 0
local lat = -1
local gok = true
local function injectw(w)
  emu.write16(0x7E0700 + t, w, emu.memType.snesMemory)
  t = (t + 2) % 64
  emu.write16(0x7E00D8, t, emu.memType.snesMemory)
end
local function inject(keys)
  for i = 1, #keys do injectw(0x1000 + keys:byte(i)) end
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
local function cell(r, c)
  return emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
end
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if stage == 0 and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("ted b:note.txt\r")
    stage = 1
  elseif stage == 1 and frame % 5 == 0 and bufhas("Y=menu") then
    t0 = frame                       -- TED is up; measure one keystroke
    injectw(0x1000 + string.byte("H"))
    stage = 2
  elseif stage == 2 and cell(0, 0) == string.byte("H") then
    lat = frame - t0
    inject("ello from TED!")
    stage = 3
  elseif stage == 3 and frame % 20 == 0 and cell(0, 14) == string.byte("!") then
    injectw(0x4B00) injectw(0x4B00) injectw(0x4B00) injectw(0x4B00)
    injectw(0x1000 + string.byte("X"))
    stage = 4
  elseif stage == 4 and frame % 20 == 0 and cell(0, 11) == string.byte("X") then
    shot("ted_snes.png")
    inject("\027S")                  -- menu, Save hotkey
    stage = 5
  elseif stage == 5 and frame % 20 == 0 and bufhas("saved b:note.txt") then
    inject("\027Q")                  -- menu, Quit
    waitf = frame + 240
    stage = 6
  elseif stage == 6 and frame == waitf then
    inject("type b:note.txt\r")
    stage = 7
  elseif stage == 7 and frame % 20 == 0 and bufhas("Hello from XTED!") then
    print(string.format("t_ted latency=%d frames", lat))
    print("RESULT PASS t_ted")
    emu.stop(0)
  end
  if frame == 12000 then
    print("timeout stage=" .. stage)
    for r = 0, 24 do
      local x = ""
      for c = 0, 50 do
        local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
        if ch < 32 or ch > 126 then ch = 32 end
        x = x .. string.char(ch)
      end
      if x:match("%S") then print(string.format("%02d|%s", r, x)) end
    end
    print("RESULT FAIL t_ted (timeout)"); emu.stop(0)
  end
end, emu.eventType.endFrame)
