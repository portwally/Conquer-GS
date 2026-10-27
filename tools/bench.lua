-- Battle benchmark: the enemy gets plenty of money, so the map fills up
-- and waves attack; the command center can't fall, so it never ends.
-- Prints the frame rate every 300 frames.
-- With PROFILE=<frame>, counts bank-0 memory reads per routine for 300
-- frames from that frame on (uses build/symbols.txt).
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
local f, lastgame = 0, 0
local profile_at = tonumber(os.getenv("PROFILE") or "")
local stop_at = tonumber(os.getenv("BENCH_END") or "6000")
local counts, tap, e1tap, e1writes = {}, nil, nil, 0
local function w(addr, i) return mem:read_u16(addr + 2 * (i or 0)) end

local function census()
  local n = w(V.NUNITS) // 2
  local alive, moving = 0, 0
  for i = 0, n - 1 do
    local fl = w(V.UFLAGS, i)
    if fl & V.F_DEAD == 0 and fl & V.F_BUILDING == 0 then
      alive = alive + 1
      if mem:read_u16(V.UNEXT + 2 * i) ~= 0xFFFF then moving = moving + 1 end  -- unext
    end
  end
  return alive, moving
end

local function report_profile()
  local syms = {}
  for line in io.lines("build/symbols.txt") do
    local addr, name = line:match(";00/(%x+);([%w_]+);")
    if addr and not name:match("^ozunid") and not name:match("^_") then
      syms[#syms + 1] = {tonumber(addr, 16), name}
    end
  end
  table.sort(syms, function(a, b) return a[1] < b[1] end)
  local per, total = {}, 0
  for addr, c in pairs(counts) do
    local name = "?"
    for i = #syms, 1, -1 do
      if syms[i][1] <= addr then name = syms[i][2]; break end
    end
    per[name] = (per[name] or 0) + c
    total = total + c
  end
  local list = {}
  for name, c in pairs(per) do list[#list + 1] = {name, c} end
  table.sort(list, function(a, b) return a[2] > b[2] end)
  print(string.format("profile: %d bank-0 reads, %d writes to $E1 over 300 frames", total, e1writes))
  for i = 1, math.min(22, #list) do
    print(string.format("  %-14s %5.1f%%", list[i][1], 100 * list[i][2] / total))
  end
end

sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end       -- still loading
  f = nf
  if f >= 700 then
    mem:write_u16(V.AICREDITS, 5000)
    mem:write_u16(V.AIWAIT, 0); mem:write_u16(V.AIMAX, V.MAXUNITS)   -- no pauses or cap
    mem:write_u16(V.UHP + w(V.HQUNIT), 400)   -- the game must not end
  end
  if f % 300 == 0 and f >= 900 then
    local game = w(V.FRAME)
    local alive, moving = census()
    print(string.format("f=%5d fps=%4.1f units=%2d moving=%2d over=%d", f,
      (game - lastgame) % 65536 / 5, alive, moving, w(V.GAMEOVER)))
    lastgame = game
  elseif f == 600 then lastgame = w(V.FRAME) end
  if profile_at and f == profile_at then
    tap = mem:install_read_tap(0x002000, 0x009FFF, "prof", function(offset, data, mask)
      counts[offset] = (counts[offset] or 0) + 1
    end)
    e1tap = mem:install_write_tap(0xE12000, 0xE19FFF, "e1", function(offset, data, mask)
      e1writes = e1writes + 1
    end)
  end
  if profile_at and f == profile_at + 300 then
    tap:remove(); e1tap:remove()
    report_profile()
  end
  if f == stop_at then manager.machine:exit() end
end)
