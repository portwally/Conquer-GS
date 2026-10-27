-- Profile: the stress.lua battle (unlimited enemy money, nobody dies, the
-- player's army sent around every 4 seconds, so the unit table fills),
-- then counts bank-0 program reads per routine for 300 frames from
-- PROFILE_AT (default 14000) and prints the busiest routines. Reads
-- stand in for time: each instruction fetch is a read.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local at = tonumber(os.getenv("PROFILE_AT") or "14000")
local f, counts, tap, frames0 = 0, {}, nil, 0
local targets, nextt = {{60, 150}, {200, 50}, {120, 180}, {40, 40}}, 1
local function w(a, i) return mem:read_u16(a + 2 * (i or 0)) end
local syms = {}
for line in io.lines("build/symbols.txt") do
  local addr, name = line:match(";00/(%x+);([%w_]+);")
  if addr and not name:match("^ozunid") and not name:match("^_") then
    syms[#syms + 1] = {tonumber(addr, 16), name}
  end
end
table.sort(syms, function(a, b) return a[1] < b[1] end)
local function routine(a)
  local lo, hi = 1, #syms
  if a < syms[1][1] then return "?" end
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if syms[mid][1] <= a then lo = mid else hi = mid - 1 end
  end
  return syms[lo][2]
end
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end
  f = nf
  if f == 700 then mem:write_u16(V.RADARALL, 1); mem:write_u16(V.RADARON, 1) end   -- (radar on)
  if f >= 700 then
    mem:write_u16(V.AICREDITS, 5000); mem:write_u16(V.AIWAIT, 0); mem:write_u16(V.AIMAX, V.MAXUNITS)
    mem:write_u16(V.UHP + w(V.HQUNIT), 400); mem:write_u16(V.UHP + w(V.BARUNIT), 300)
    local n = w(V.NUNITS) // 2
    for i = 0, n - 1 do
      local fl = w(V.UFLAGS, i)
      if fl & (V.F_DEAD | V.F_BUILDING) == 0 then mem:write_u16(V.UHP + 2 * i, w(V.UMAXHP, i)) end
    end
  end
  if f >= 1500 and f % 240 == 0 then
    local n = w(V.NUNITS) // 2
    for i = 0, n - 1 do
      local fl = w(V.UFLAGS, i)
      if fl & V.F_PLAYER ~= 0 and fl & (V.F_DEAD | V.F_BUILDING) == 0 then
        mem:write_u16(V.UFLAGS + 2 * i, fl | V.F_SEL | 0x8000)
      end
    end
    local t = targets[nextt]; nextt = nextt % #targets + 1
    mem:write_u16(V.CX, t[1]); mem:write_u16(V.CY, t[2])
  end
  if f >= 1500 and f % 240 == 4 then btn:set_value(1) end
  if f >= 1500 and f % 240 == 8 then btn:clear_value() end
  if f == at then
    frames0 = w(V.FRAME)
    tap = mem:install_read_tap(0x2000, 0x8FFF, "prof", function(o) counts[o] = (counts[o] or 0) + 1 end)
  end
  if f == at + 300 then
    tap:remove()
    local per, total = {}, 0
    for a, c in pairs(counts) do local r = routine(a); per[r] = (per[r] or 0) + c; total = total + c end
    local list = {}
    for r, c in pairs(per) do list[#list + 1] = {r, c} end
    table.sort(list, function(a, b) return a[2] > b[2] end)
    local n, alive = w(V.NUNITS) // 2, 0
    for i = 0, n - 1 do if w(V.UFLAGS, i) & V.F_DEAD == 0 then alive = alive + 1 end end
    print(string.format("%d units alive, %d game frames in 300 video frames; reads per routine:",
      alive, w(V.FRAME) - frames0))
    for k = 1, math.min(22, #list) do
      print(string.format("  %-14s %5.1f%%", list[k][1], 100 * list[k][2] / total))
    end
    manager.machine:exit()
  end
end)
