-- suite test: t_pico -- the Pico keyboard (dosboot.asm pk_*) against a
-- model of the SNOS Pico W adapter on controller port 2.
--
-- The model is the firmware in two layers. The port (pico/port.c +
-- snoslink.pio): each $4016 write is LATCH, each $4017 read is one clock
-- and returns DATA1 inverted; 512 clocks are a frame; the frame shifted
-- out is the one staged at the adapter's last restart (the end of an
-- exchange, or the vblank auto-joypad burst); every bit released until a
-- valid frame arrives and again after two seconds without one; a burst
-- of any other length is dropped and the staged frame kept. A burst
-- begins at a read with two $4016 writes before it (pk_xfer's LATCH-low
-- lead-in, then the first bit); the lead-in's length is checked on the
-- first few. The link
-- (pico/link.c, pico/kbd.c): sequence, cumulative ack, SYN, checksum,
-- resend until acknowledged, keys as channel $11 records.
--
-- Phases: boot with nothing plugged in; a joypad in port 2; plug the
-- adapter in and type; the key map;
-- a burst bigger than the FIFO; lost and corrupt frames; an adapter
-- restart (as a firmware that answers one exchange sooner); a console
-- reset with keys still queued in the adapter.
local FR = 64
local frame = 0
local fails = {}
local function check(ok, msg)
  if not ok then fails[#fails + 1] = msg; print("t_pico: FAIL " .. msg) end
end
local function rd(a) return emu.read(a, emu.memType.snesMemory) end
local function rd16(a) return emu.read16(a, emu.memType.snesMemory) end
local pkUP, pkST, pkFH, pkFT = 0x7E0200, 0x7E0208, 0x7E020A, 0x7E020C

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
local function count_rows(str)
  local n = 0
  for _, s in ipairs(rows()) do if s == str then n = n + 1 end end
  return n
end
local function prompt_last()
  local last = ""
  for _, s in ipairs(rows()) do if s ~= "" then last = s end end
  return last == "C:\\>"
end

-- ---------------------------------------------------------------- link
local function sum_of(f)
  local s = 0
  for i = 0, FR - 1 do if i ~= 3 then s = (s + f[i]) & 0xFF end end
  return s
end
local function copy(f)
  local g = {}
  for i = 0, FR - 1 do g[i] = f[i] end
  return g
end

local link
local function link_init()
  link = { q = {}, syn = true, peer_syn_seen = false, rx_resync = true,
           base = 0, tx_seq = 0, cursor = 0, rx_next = 0, window = 1,
           frames = {}, resends = 0, bad_sum = 0 }
end
local function link_push(data)            -- one CH_KBD chunk
  if #link.q == 32 then return false end
  link.q[#link.q + 1] = { data = data, pos = 1 }
  return true
end
local function link_on_rx(f)
  local res = { valid = false, reset = false, records = {} }
  if f[3] ~= sum_of(f) then link.bad_sum = link.bad_sum + 1; return res end
  res.valid = true
  local acked = (f[1] - link.base + 1) & 0xFF
  local flying = (link.tx_seq - link.base) & 0xFF
  if link.rx_resync then link.rx_resync = false; link.rx_next = f[0] end
  if acked ~= 0 and acked <= flying then
    link.base = (f[1] + 1) & 0xFF
    link.syn = false
    if ((link.cursor - link.base) & 0xFF) > ((link.tx_seq - link.base) & 0xFF) then
      link.cursor = link.base
    end
  end
  if (f[2] & 2) ~= 0 then
    if not link.peer_syn_seen then
      link.peer_syn_seen = true
      link.rx_next = f[0]
      link.q = {}
      link.tx_seq = link.base
      link.cursor = link.base
      link.window = 1
      res.reset = true
    end
  else
    link.peer_syn_seen = false
  end
  if (f[2] & 1) ~= 0 and f[0] == link.rx_next then
    local o = 4
    while o + 2 <= FR do
      local ch, n = f[o], f[o + 1]
      if ch == 0xFF or o + 2 + n > FR then break end
      local d = {}
      for i = 0, n - 1 do d[#d + 1] = f[o + 2 + i] end
      res.records[#res.records + 1] = { ch = ch, data = d }
      o = o + 2 + n
    end
    link.rx_next = (link.rx_next + 1) & 0xFF
  end
  return res
end
local function link_next_out()
  local flying = (link.tx_seq - link.base) & 0xFF
  local w = link.syn and 1 or link.window
  if link.cursor == link.tx_seq and flying > 0 and (flying >= w or #link.q == 0) then
    link.cursor = link.base
  end
  if link.cursor ~= link.tx_seq then
    local g = link.frames[link.cursor % 8]
    link.cursor = (link.cursor + 1) & 0xFF
    link.resends = link.resends + 1
    g[1] = (link.rx_next - 1) & 0xFF
    g[3] = sum_of(g)
    return copy(g)
  end
  local f = {}
  f[0], f[1], f[2], f[3] = link.tx_seq, (link.rx_next - 1) & 0xFF, 0, 0
  local o = 4
  while #link.q > 0 and o + 2 < FR do
    local c = link.q[1]
    local n = #c.data - c.pos + 1
    if n > FR - o - 2 then n = FR - o - 2 end
    f[o], f[o + 1] = 0x11, n
    for i = 0, n - 1 do f[o + 2 + i] = c.data:byte(c.pos + i) end
    o = o + 2 + n
    c.pos = c.pos + n
    if c.pos > #c.data then table.remove(link.q, 1) end
    f[2] = f[2] | 1
  end
  for i = o, FR - 1 do f[i] = 0xFF end
  if link.syn then f[2] = f[2] | 2 end
  f[3] = sum_of(f)
  if (f[2] & 1) ~= 0 then
    link.frames[link.tx_seq % 8] = copy(f)
    link.tx_seq = (link.tx_seq + 1) & 0xFF
    link.cursor = link.tx_seq
  end
  return f
end

-- ---------------------------------------------------------------- port
local port = { plugged = false, idle = true, nbits = 0, writes = 0, latch = 0,
               rx = {}, latched = nil, queue = {}, tx_sent = true,
               last_valid = -1000, exchanges = 0, clocks = 0, torn = 0,
               nmi_since = 1, no_vblank = 0, resets = 0, ctrl = {},
               drop_rx = 0, corrupt_tx = 0, refused = 0, prev = nil, short = 0,
               odd = 0, bursts = 0, quiet_min = nil, span_max = 0,
               end_line_max = 0, console = nil }
local function idle_frame()
  local f = {}
  for i = 0, FR - 1 do f[i] = 0xFF end
  return f
end
local function restart(whole)             -- port.c restart()
  if whole then port.tx_sent = true end
  if port.idle then
    port.latched = idle_frame(); port.tx_sent = true
  elseif port.tx_sent and #port.queue > 0 then
    port.latched = table.remove(port.queue, 1); port.tx_sent = false
  end
end
-- main() queues the link's first frame before the port is up, and it
-- stays in front of every reply: the answer to one exchange leaves on
-- the second exchange after it. `prompt` models a firmware without that.
local function pico_boot(prompt)
  link_init()
  port.idle, port.nbits, port.queue, port.tx_sent = true, 0, {}, true
  port.last_valid = -1000
  local first = link_next_out()
  if not prompt then port.queue[1] = first end
  restart(false)
end
local function pico_main(f)               -- main.c, once per received frame
  if port.drop_rx > 0 then
    port.drop_rx = port.drop_rx - 1
    f[10] = f[10] ~ 0x40                  -- line noise: the checksum fails
  end
  port.console = copy(f)
  -- a clean, in-sequence data frame the console did not acknowledge
  local p = port.prev
  if p and f[3] == sum_of(f) and ((f[1] + 1) & 0xFF) == p.seq then port.refused = port.refused + 1 end
  local t = port.tx
  port.prev = (t[2] & 1) ~= 0 and t[3] == sum_of(t) and { seq = t[0] } or nil
  local res = link_on_rx(f)
  if res.valid then port.last_valid = frame; port.idle = false end
  if res.reset then port.resets = port.resets + 1 end
  for _, r in ipairs(res.records) do
    if r.ch == 0 then port.ctrl[#port.ctrl + 1] = r.data end
  end
  local out = link_next_out()
  if port.corrupt_tx > 0 then
    port.corrupt_tx = port.corrupt_tx - 1
    out[20] = out[20] ~ 0x04
  end
  if #port.queue == 2 then table.remove(port.queue, 1) end
  port.queue[#port.queue + 1] = out
end
local function clock() return emu.getState()["masterClock"] end

emu.addMemoryCallback(function(addr, value)
  port.latch = value & 1
  port.writes = port.writes + 1
  if port.plugged and port.bursts < 40 and
     (port.writes >= 2 or port.nbits == 0 or port.nbits == 24) then
    port.t_low, port.t_w = port.t_w, clock()   -- LATCH low, then the first bit
  end
end, emu.callbackType.write, 0x4016)

emu.addMemoryCallback(function(addr, value)
  local writes = port.writes
  port.writes = 0
  port.clocks = port.clocks + 1
  if port.pad then                        -- a joypad instead: 16 buttons, then
    if writes >= 2 then port.padbit = 0 end   -- the line stays low (reads 1)
    local b = port.padbit
    port.padbit = b + 1
    return (value & 0xFE) | ((b >= 16 or port.pad[b + 1]) and 1 or 0)
  end
  if not port.plugged then return end
  if writes == 0 then return (value & 0xFE) | 1 end   -- not a frame's clock
  if writes >= 2 then                     -- silence, then a new burst
    if port.nbits ~= 0 then
      port.short = port.short + 1
      if port.nbits ~= 24 then port.odd = port.odd + 1 end
      port.nbits = 0
      restart(false)
    end
    port.bursts = port.bursts + 1
    port.t_first = nil
    if port.bursts < 40 and port.t_low then
      port.t_first = clock()
      local quiet = port.t_first - port.t_low
      if not port.quiet_min or quiet < port.quiet_min then port.quiet_min = quiet end
    end
  end
  local n = port.nbits
  if n == 0 then
    port.tx = port.latched
    for i = 0, FR - 1 do port.rx[i] = 0 end
  end
  local byte = n >> 3
  port.rx[byte] = ((port.rx[byte] << 1) | port.latch) & 0xFF
  local bit = (port.tx[byte] >> (7 - (n & 7))) & 1
  port.nbits = n + 1
  if port.nbits == FR * 8 then
    port.nbits = 0
    port.exchanges = port.exchanges + 1
    if port.nmi_since == 0 then port.no_vblank = port.no_vblank + 1 end
    port.nmi_since = 0
    if port.t_first then
      local st = emu.getState()
      local span = st["masterClock"] - port.t_first
      if span > port.span_max then port.span_max = span end
      local line = st["ppu.scanline"]
      if line > port.end_line_max then port.end_line_max = line end
    end
    restart(true)
    pico_main(copy(port.rx))
  end
  return (value & 0xFE) | (1 - bit)       -- the CPU reads the line inverted
end, emu.callbackType.read, 0x4017)

emu.addEventCallback(function()
  port.nmi_since = port.nmi_since + 1
  if not port.plugged then return end
  if port.nbits ~= 0 then                 -- a short burst, long over
    port.short = port.short + 1
    if port.nbits ~= 24 then port.torn = port.torn + 1 end
    port.nbits = 0
  end
  if frame - port.last_valid > 120 then port.idle = true end
  restart(false)                          -- the auto-joypad burst's gap
end, emu.eventType.nmi)

-- ------------------------------------------------- what kb_push queued
local keys, scans = {}, {}
local lo = {}
emu.addMemoryCallback(function(addr, value)
  if (addr & 1) == 0 then lo[addr] = value
  else keys[#keys + 1] = (value << 8) | (lo[addr - 1] or 0) end
end, emu.callbackType.write, 0x0700, 0x073F)
emu.addMemoryCallback(function(addr, value)
  if (addr & 1) == 0 then scans[#scans + 1] = value end
end, emu.callbackType.write, 0x0600, 0x061F)
local function hexlist(t, from)
  local s = {}
  for i = from, #t do s[#s + 1] = string.format("%04X", t[i]) end
  return table.concat(s, " ")
end

-- ----------------------------------------------------------- the script
local function typeline(s) link_push(s); link_push("\n") end
local steps, si, st_frame = {}, 1, 0
local function step(name, timeout, start, done)
  steps[#steps + 1] = { name = name, timeout = timeout, start = start, done = done }
end
local mark = {}

step("boot, nothing in port 2", 2000, nil, function()
  return frame > 1100 and prompt_last()
end)
step("a joypad in port 2", 1100, function()
  mark.boot_frames = frame
  mark.keys0 = #keys
  check(rd16(pkUP) == 0, "link up with nothing plugged in")
  check(rd16(pkFH) == 0, "keys accepted with nothing plugged in")
  local ex = port.clocks / 512
  check(ex >= 2 and ex <= 2 * frame / 240 + 2,
    string.format("%.1f probes in %d frames with no adapter, want a pair every 240", ex, frame))
  port.pad = { true, false, false, true }   -- B and Start held
end, function()
  -- then every button at once: 64 zero bytes, which checksum
  if frame - st_frame == 500 then for i = 1, 16 do port.pad[i] = true end end
  return frame - st_frame >= 1000
end)
step("absent", 1, function()
  check(rd16(pkUP) == 0, "a joypad in port 2 was taken for the adapter")
  check(rd16(pkFH) == 0 and #keys == mark.keys0, "a joypad in port 2 typed keys")
  port.pad = nil
  port.plugged = true
  pico_boot()
  mark.plug = frame
end, function() return true end)
step("adapter found", 400, nil, function() return rd16(pkUP) == 1 and (rd(pkST) & 4) ~= 0 end)
step("handshake", 30, function()
  mark.found = frame - mark.plug
end, function() return frame - st_frame >= 20 end)
step("type a command", 400, function()
  check(port.resets == 1, port.resets .. " SYN resets at the adapter, want 1")
  check(#port.ctrl == 1 and #port.ctrl[1] == 3 and port.ctrl[1][1] == 0x0D and
        port.ctrl[1][3] == 1, "the adapter did not get exactly one LINKWIN=1 record")
  check(port.console[2] == 0 and port.console[4] == 0xFF,
    "the console still sends its SYN frame after the ack")
  check(#keys == mark.keys0, "keys typed by the handshake")
  mark.t_type = frame
  typeline("echo Hi_There!")
end, function() return count_rows("Hi_There!") == 1 and prompt_last() end)
step("key map", 400, function()
  mark.latency = frame - mark.t_type
  check(count_rows("C:\\>echo Hi_There!") == 1, "the command line was not echoed as typed")
  mark.k = #keys + 1
  mark.s = #scans + 1
  -- Backspace and the shifted row inside a command, then keys DOS takes
  -- no text from: the arrows and Esc (which cancels the line).
  typeline("echo aZ09 !@#$%^&*()_+-=[]{};':\",./?~`\\X\bq")
  for _, k in ipairs({ "\x1C", "\x1D", "\x1E", "\x1F", "\t", "\x03" }) do link_push(k) end
end, function() return #keys - mark.k + 1 >= 43 + 6 and frame - st_frame > 120 and prompt_last() end)
step("burst", 3000, function()
  check(count_rows("aZ09 !@#$%^&*()_+-=[]{};':\",./?~`\\q") == 1, "shifted/backspace line wrong on screen")
  local got = hexlist(keys, mark.k)
  local want = "1265 2E63 2368 186F 3920 1E61 2C5A 0B30 0A39 3920 0221 0340 0423 0524 0625 075E"
    .. " 0826 092A 0A28 0B29 0C5F 0D2B 0C2D 0D3D 1A5B 1B5D 1A7B 1B7D 273B 2827 273A 2822"
    .. " 332C 342E 352F 353F 297E 2960 2B5C 2D58 0E08 1071 1C0D 4800 5000 4B00 4D00 0F09 2E03"
  check(got == want, "key words\n got  " .. got .. "\n want " .. want)
  -- 'e' plain, 'Z' wrapped in Shift, Ctrl-C wrapped in Ctrl
  local sc = {}
  for i = mark.s, #scans do sc[#sc + 1] = string.format("%02X", scans[i] & 0xFF) end
  local s = table.concat(sc, " ")
  check(s:sub(1, 5) == "12 92", "INT 9 queue for 'e': " .. s:sub(1, 11))
  check(s:find("2A 2C AC AA", 1, true) ~= nil, "INT 9 queue lacks Shift around Z")
  check(s:sub(-11) == "1D 2E AE 9D", "INT 9 queue for Ctrl-C: " .. s:sub(-11))
  -- four commands at once: more keys than the FIFO holds
  mark.fifo_max = 0
  mark.ex = port.exchanges
  mark.burst_at = frame
  for i = 1, 4 do typeline("echo burst " .. i .. " 0123456789abcdefghijklmnopqrstuvwxyz0123456789") end
end, function()
  local d = (rd16(pkFH) - rd16(pkFT)) & 0x7F
  if d > mark.fifo_max then mark.fifo_max = d end
  return count_rows("burst 4 0123456789abcdefghijklmnopqrstuvwxyz0123456789") == 1 and prompt_last()
end)
step("lost and corrupt frames", 1500, function()
  for i = 1, 4 do
    check(count_rows("burst " .. i .. " 0123456789abcdefghijklmnopqrstuvwxyz0123456789") == 1,
      "burst line " .. i .. " wrong")
  end
  check(mark.fifo_max > 64, "the burst never filled the FIFO (peak " .. mark.fifo_max .. ")")
  -- a full FIFO stops the polling instead of refusing frames
  mark.burst_rate = (port.exchanges - mark.ex) / (frame - mark.burst_at)
  check(mark.burst_rate < 0.2, string.format("%.2f exchanges a frame while the FIFO was full",
    mark.burst_rate))
  mark.k = #keys
  port.corrupt_tx = 3                     -- three frames the console must ignore
  typeline("echo fault one")
  mark.phase = 0
end, function()
  if mark.phase == 0 and count_rows("fault one") == 1 and prompt_last() then
    mark.phase = 1
    port.drop_rx = 3                      -- three acks the adapter never sees
    typeline("echo fault two")
  end
  return mark.phase == 1 and count_rows("fault two") == 1 and prompt_last()
end)
step("adapter restart", 1500, function()
  check(#keys - mark.k == 30, (#keys - mark.k) .. " keys from 30 typed across lost frames")
  mark.k = #keys
  pico_boot(true)                         -- replugged: sequence 0, SYN, idle
  typeline("echo again")
end, function() return count_rows("again") == 1 and prompt_last() end)
step("console reset", 3000, function()
  check(#keys - mark.k == 11, (#keys - mark.k) .. " keys from 11 typed after the adapter restart")
  mark.resets = port.resets
  for i = 1, 30 do link_push("stale") end -- typed as the console goes down:
  mark.phase = 0                          -- some arrive, some are in flight,
end, function()                           -- some still queued in the adapter
  if mark.phase == 0 and frame - st_frame >= 3 then
    mark.phase = 1
    emu.reset()
    mark.reset_at = frame
    mark.k = #keys
  end
  return mark.phase == 1 and frame - mark.reset_at > 1100 and prompt_last() and rd16(pkUP) == 1
end)
step("after the reset", 600, function()
  check(port.resets == mark.resets + 1, "the adapter saw no SYN from the reset console")
  check(count_rows("C:\\>") >= 1, "no clean prompt after the reset")
  local stale = 0
  for i = mark.k + 1, #keys do if keys[i] == 0x1F73 then stale = stale + 1 end end
  check(stale == 0, stale .. " keys typed before the reset arrived after it")
  typeline("echo back")
end, function() return count_rows("back") == 1 and prompt_last() end)

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
    check(port.torn == 0, port.torn .. " exchanges cut short by a vblank")
    check(port.odd == 0, port.odd .. " bursts that were neither a frame nor a 3-byte peek")
    check(port.short > 0, "the console never peeked")
    check(port.refused == 0, port.refused .. " frames the console had to refuse")
    check(port.no_vblank == 0, port.no_vblank .. " exchanges with no vblank since the last")
    check(port.quiet_min and port.quiet_min >= 6443,
      "quiet lead-in " .. tostring(port.quiet_min) .. " master cycles, want >= 6443 (300 us)")
    check(port.end_line_max < 200, "an exchange ended on line " .. port.end_line_max)
    local info = string.format("found in %d frames, key to output %d frames, exchange %d mc,"
      .. " quiet %d mc, fifo peak %d, %d exchanges, %d peeks", mark.found or -1,
      mark.latency or -1, port.span_max, port.quiet_min or -1, mark.fifo_max or -1,
      port.exchanges, port.short)
    if #fails == 0 then print("RESULT PASS t_pico (" .. info .. ")")
    else print("RESULT FAIL t_pico (" .. fails[1] .. "; " .. info .. ")") end
    emu.stop(0)
  end
end, emu.eventType.endFrame)
