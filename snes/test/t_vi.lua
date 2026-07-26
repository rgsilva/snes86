-- suite test: t_vi — a real vi (levee 4.0b, BIOS INT10 screen layer)
-- edits a file on B:, the battery-backed SRAM drive: launch from
-- C:\VI, insert a line, Esc, :wq, then CLS + TYPE the file back at
-- the DOS prompt. Tolerates a stale B: (writes fresh content each
-- run, no .srm deletion needed). Run with --timeout=600.
local frame = 0
local t = 0
local stage = 0
local waitf = 0
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
local function shot(name)
  local png = emu.takeScreenshot()
  local hex = png:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
  print("SHOT " .. name .. " " .. hex)
end
emu.addEventCallback(function()
  frame = frame + 1
  if stage == 0 and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("cd vi\rvi b:vi.txt\r")
    stage = 1
  elseif stage == 1 and frame % 10 == 0 and bufhas("New file") then
    inject("ihello from vi on the SNES")     -- 26 keys, ring is 32
    stage = 2
  elseif stage == 2 and frame % 10 == 0 and bufhas("hello from vi on the SNES") then
    shot("vi_snes.png")
    inject("\027:wq\r")
    waitf = frame + 300                      -- let levee write + exit
    stage = 3
  elseif stage == 3 and frame >= waitf then
    inject("cls\rtype b:vi.txt\r")           -- cls: only TYPE's output left
    stage = 4
  elseif stage == 4 and frame % 10 == 0
         and not bufhas("New file")          -- edit screen really gone
         and bufhas("hello from vi on the SNES") then
    print("RESULT PASS t_vi")
    emu.stop(0)
  end
  if frame == 20000 then
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
    print("RESULT FAIL t_vi (timeout)"); emu.stop(0)
  end
end, emu.eventType.endFrame)
