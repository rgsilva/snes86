-- suite test: t_sa1mem — the SA-1 ROM really has a 300 KB machine.
--
-- Two independent proofs, both driven through the guest with DEBUG:
--   1. SIZE: dump the BIOS memory-size word at 0040:0013. 300 KB is
--      012C, so the screen must show "2C 01". That word is what INT 12h
--      returns and what DOS builds its arena top from.
--   2. ROUND TRIP ABOVE THE OLD 172 KB LINE: write a pattern at
--      4000:0000 = linear 0x40000 = 256 KB — 84 KB past the top of the
--      172 KB cartridge-SRAM machine — and read it back. The naive SNES pointer for
--      that address is $82:5000, which is a system-area mirror; only the
--      BW-RAM fold turns it into real memory, so the leg ALSO reads the
--      bytes straight out of SA-1 BW-RAM at the folded address $42:5000
--      to prove they reached the cart.
--
-- The on-screen keyboard ring holds 32 keys, so every injected line is
-- kept under that and the leg waits for the guest to answer before
-- typing the next one (DEBUG.COM's own load is the slow step).
local M = emu.memType.snesMemory
local frame, state, mark = 0, 0, 0
local fails = {}
local PAT = { 0x53, 0x41, 0x31, 0x42, 0x57, 0x52 }   -- "SA1BWR"

local t
local function inject(keys)
  if not t then t = emu.read16(0x7E00D8, M) end
  for i = 1, #keys do
    emu.write16(0x7E0700 + t, 0x1000 + keys:byte(i), M)
    t = (t + 2) % 64
  end
  emu.write16(0x7E00D8, t, M)
end
local function row(r)
  local s = ""
  for c = 0, 79 do
    local ch = emu.read(0x7E1000 + r*160 + c*2, M)
    if ch < 32 or ch > 126 then ch = 32 end
    s = s .. string.char(ch)
  end
  return s
end
local function bufhas(str)
  for r = 0, 24 do if row(r):find(str, 1, true) then return true end end
  return false
end
local function debugprompt()          -- a row that starts with DEBUG's '-'
  for r = 0, 24 do
    if emu.read(0x7E1000 + r*160, M) == 0x2D then return true end
  end
  return false
end
local function finish()
  local bw = ""
  for i = 0, #PAT-1 do
    local b = emu.read(0x425000 + i, M)
    bw = bw .. string.format("%02X ", b)
    if b ~= PAT[i+1] then
      fails[#fails+1] = string.format("BW-RAM $42:%04X=%02X want %02X", 0x5000+i, b, PAT[i+1])
    end
  end
  print("t_sa1mem: BW-RAM $42:5000 = " .. bw .. "(guest 4000:0000 = 256 KB)")
  if #fails == 0 then print("RESULT PASS t_sa1mem (300 KB reported, round trip at 256 KB)")
  else print("RESULT FAIL t_sa1mem (" .. table.concat(fails, "; ") .. ")") end
  emu.stop(0)
end

emu.addEventCallback(function()
  frame = frame + 1
  if frame == 6000 then
    fails[#fails+1] = "timeout in state " .. state
    finish()
    return
  end

  if state == 0 then                       -- wait for the DOS prompt
    if frame > 1100 and frame % 10 == 0 and bufhas("C:\\>") then
      inject("debug\r"); state, mark = 1, frame
    end
  elseif state == 1 then                   -- wait for DEBUG to load
    if frame > mark + 30 and debugprompt() then
      inject("d 40:13 l 2\r"); state, mark = 2, frame
    end
  elseif state == 2 then                   -- INT 12h / BDA memory size
    if bufhas("2C 01") or frame > mark + 900 then
      if not bufhas("2C 01") then
        fails[#fails+1] = "0040:0013 is not 2C 01 (300 KB)"
      end
      inject("e 4000:0 53 41 31 42 57 52\r"); state, mark = 3, frame
    end
  elseif state == 3 then                   -- 'e' is silent: give it time
    if frame > mark + 500 then
      inject("d 4000:0 l 6\r"); state, mark = 4, frame
    end
  elseif state == 4 then                   -- guest reads its own write back
    if bufhas("53 41 31 42 57 52") or frame > mark + 900 then
      if not bufhas("53 41 31 42 57 52") then
        fails[#fails+1] = "no read-back at 4000:0000 (256 KB)"
      end
      finish()
    end
  end
end, emu.eventType.endFrame)
