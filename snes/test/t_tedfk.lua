-- suite test: t_tedfk — TED's keyboard-only F-key bindings. The
-- INT16 ring at $7E0700 is fed scancode-only words (ascii 0, AH =
-- 3B..44), exactly what the on-screen keyboard's F-row produces:
-- F6 goto + F5 search position an edit, F7 undoes a probe, F2 saves,
-- F1 pages the help, F10 opens the menu, F4/F3 open the save-as/load
-- prompts. Ctrl fallbacks are the ted-host-keys leg's job on runpc
-- (F-keys can't ride runpc stdin). Saves to B:FK.TXT; suite runs
-- delete stale .srm before the TED legs. Run with --timeout=300.
local frame = 0
local t = 0
local stage = 0
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
emu.addEventCallback(function()
  frame = frame + 1
  if stage == 0 and frame > 400 and frame % 10 == 0 and bufhas("C:\\>") then
    t = emu.read16(0x7E00D8, emu.memType.snesMemory)
    inject("ted b:fk.txt\r")
    stage = 1
  elseif stage == 1 and frame % 5 == 0 and bufhas("F1=help") then
    inject("alpha\rbeta")               -- two lines, cursor ends on 2
    injectw(0x4000) inject("1\r")       -- F6: goto line 1
    injectw(0x3F00) inject("pha\r")     -- F5: search -> line 1 col 3
    inject("X")                         -- probe: "alXpha", col now 4
    injectw(0x4100)                     -- F7: undo text -> "alpha" (the
                                        -- column stays where X left it)
    inject("Z")                         -- marker at col 4: "alpZha"
    injectw(0x3C00)                     -- F2: save
    stage = 2
  elseif stage == 2 and frame % 10 == 0 and bufhas("saved b:fk.txt")
      and bufhas("alpZha") then
    injectw(0x3B00)                     -- F1: help page 1
    stage = 3
  elseif stage == 3 and frame % 10 == 0 and bufhas("F2=save") then
    inject(" ")                         -- any key -> page 2
    stage = 4
  elseif stage == 4 and frame % 10 == 0 and bufhas("^S=save") then
    inject(" ")                         -- any key -> back to editing
    stage = 5
  elseif stage == 5 and frame % 10 == 0 and bufhas("F1=help") then
    injectw(0x4400)                     -- F10: menu
    stage = 6
  elseif stage == 6 and frame % 10 == 0 and bufhas("[Save]") then
    inject("\027") injectw(0x3E00)      -- Esc; F4: save-as prompt
    stage = 7
  elseif stage == 7 and frame % 10 == 0 and bufhas("Save as:") then
    inject("\027") injectw(0x3D00)      -- Esc; F3: load prompt
    stage = 8
  elseif stage == 8 and frame % 10 == 0 and bufhas("Load:") then
    inject("\027\017\r")                -- Esc; ^Q (17) quits to DOS
    stage = 9
  elseif stage == 9 and frame % 10 == 0 and bufhas("C:\\>")
      and not bufhas("F1=help") then
    inject("type b:fk.txt\r")
    stage = 10
  elseif stage == 10 and frame % 10 == 0 and bufhas("alpZha")
      and bufhas("beta") then
    print("RESULT PASS t_tedfk")
    emu.stop(0)
  end
  if frame == 12000 then
    print("timeout stage=" .. stage)
    for r = 0, 24 do
      local x = ""
      for c = 0, 63 do
        local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
        if ch < 32 or ch > 126 then ch = 32 end
        x = x .. string.char(ch)
      end
      if x:match("%S") then print(string.format("%02d|%s", r, x)) end
    end
    print("RESULT FAIL t_tedfk (timeout)"); emu.stop(0)
  end
end, emu.eventType.endFrame)
