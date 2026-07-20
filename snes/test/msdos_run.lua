-- Drive one C: app under MS-DOS: boot -> wait for C:\> -> type CMD -> dump.
-- CMD is read from the env var MSDOS_CMD (default "VER").
local CMD = "VER"   -- edit this per app (os.getenv is sandboxed in Mesen)
local frame, t, injF, phase = 0, 0, 0, 0
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
local function dumpText(tag)
  print("=== " .. tag .. " (frame " .. frame .. ") ===")
  for r = 0, 24 do
    local s = ""
    for c = 0, 79 do
      local ch = emu.read(0x7E1000 + r*160 + c*2, emu.memType.snesMemory)
      if ch < 32 or ch > 126 then ch = 32 end
      s = s .. string.char(ch)
    end
    s = s:gsub("%s+$", "")
    if #s > 0 then print(string.format("%2d| %s", r, s)) end
  end
end
emu.addEventCallback(function()
  frame = frame + 1
  if phase == 0 and frame > 900 and bufhas("C:\\>") then
    inject(CMD .. "\r"); injF = frame; phase = 1
    print("INJECT '" .. CMD .. "' at frame " .. frame)
  elseif phase == 1 and frame == injF + 600 then
    dumpText(CMD .. " @+600")
  elseif phase == 1 and frame == injF + 1100 then
    dumpText(CMD .. " @+1100")
    emu.stop(0)
  end
end, emu.eventType.endFrame)
