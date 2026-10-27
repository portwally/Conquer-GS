-- Per-frame timing: records the emulated time at the start of each phase
-- of the main loop, then reports the slowest frames phase by phase.
-- FT_FROM/FT_TO pick the frames to watch; the enemy gets plenty of money
-- as in bench.lua. With FT_STRESS set, the player's army is sent around
-- every 4 seconds as in stress.lua (so it explores too). Each frame also
-- counts tiles uncovered (revtile) and radar pixels redrawn (radpix).
-- FT_NOFOG lifts the fog of war at the start; FT_ALL keeps every unit at
-- full health (as STRESS_ALL in stress.lua), so the unit table fills up.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
local from = tonumber(os.getenv("FT_FROM") or "3900")
local to = tonumber(os.getenv("FT_TO") or "4800")
local phases = {"readmouse", "scroll", "updplace", "input", "updcursor", "units", "pathwork",
                "production", "ai", "checkend", "render", "drawradar", "restorecells", "waitvbl"}
local addr = {}
for line in io.lines("build/symbols.txt") do
  local a, n = line:match(";00/(%x+);([%w_]+);")
  if n then addr[n] = tonumber(a, 16) end
end
local f, taps, cur, frames = 0, {}, nil, {}
local function now() return manager.machine.time:as_double() end
local stress = os.getenv("FT_STRESS") ~= nil
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local targets, nextt = {{60, 150}, {200, 50}, {120, 180}, {40, 40}}, 1
local count = {}
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end       -- still loading
  f = nf
  if f >= 700 then                               -- as in bench.lua
    mem:write_u16(V.AICREDITS, 5000)
    mem:write_u16(V.AIWAIT, 0); mem:write_u16(V.AIMAX, V.MAXUNITS)
  end
  if f == 700 then mem:write_u16(V.RADARALL, 1); mem:write_u16(V.RADARON, 1) end   -- (radar on)
  if f == 700 and os.getenv("FT_NOFOG") then mem:write_u16(V.SEEALL, 1) end
  if f >= 700 and os.getenv("FT_ALL") then         -- as stress.lua STRESS_ALL:
    mem:write_u16(V.UHP + mem:read_u16(V.HQUNIT), 400)     -- nobody dies, so
    mem:write_u16(V.UHP + mem:read_u16(V.BARUNIT), 300)    -- the units fill
    local n = mem:read_u16(V.NUNITS) // 2                  -- every slot
    for i = 0, n - 1 do
      local fl = mem:read_u16(V.UFLAGS + 2 * i)
      if fl & (V.F_DEAD | V.F_BUILDING) == 0 then
        mem:write_u16(V.UHP + 2 * i, mem:read_u16(V.UMAXHP + 2 * i))
      end
    end
  end
  if stress and f >= 1500 and f % 240 == 0 then     -- select all, order a move
    local n = mem:read_u16(V.NUNITS) // 2
    for i = 0, n - 1 do
      local fl = mem:read_u16(V.UFLAGS + 2 * i)
      if fl & V.F_PLAYER ~= 0 and fl & (V.F_DEAD | V.F_BUILDING) == 0 then
        mem:write_u16(V.UFLAGS + 2 * i, fl | V.F_SEL | 0x8000)
      end
    end
    local t = targets[nextt]; nextt = nextt % #targets + 1
    mem:write_u16(V.CX, t[1]); mem:write_u16(V.CY, t[2])
  end
  if stress and f >= 1500 and f % 240 == 4 then btn:set_value(1) end
  if stress and f >= 1500 and f % 240 == 8 then btn:clear_value() end
  if f == from then
    local at = {}
    for _, name in ipairs(phases) do at[addr[name]] = name end
    count[addr.revtile or -1] = "rev"
    count[addr.radpix or -1] = "pix"
    -- one wide tap (single-address taps don't fire on this machine)
    taps[1] = mem:install_read_tap(0x2000, 0x9FFF, "ft", function(o)
      local c = count[o]
      if c and cur then cur[c] = (cur[c] or 0) + 1; return end
      local name = at[o]
      if not name then return end
      if name == "readmouse" then cur = {t = {}} end
      if cur and not cur.t[name] then cur.t[name] = now() end
      if name == "restorecells" and cur then
        cur.cells = mem:read_u16(V.NDIRTY) // 2
        cur.side = 0                                           -- of them in
        for k = 0, cur.cells - 1 do                            -- the sidebar
          if mem:read_u16(V.DIRTYCELL + 2 * k) & 0xFF >= 16 then cur.side = cur.side + 1 end
        end
      end
      if name == "waitvbl" and cur and cur.t.readmouse then
        cur.busy = (cur.t.waitvbl - cur.t.readmouse) * 1000
        cur.cells = cur.cells or 0
        frames[#frames + 1] = cur
        cur = nil
      end
    end)
  end
  if f == to then
    for _, t in ipairs(taps) do t:remove() end
    table.sort(frames, function(a, b) return a.busy > b.busy end)
    local over = 0
    for _, fr in ipairs(frames) do if fr.busy > 16.0 then over = over + 1 end end
    print(string.format("%d frames timed, %d over 16 ms; slowest:", #frames, over))
    for i = 1, math.min(12, #frames) do
      local fr, parts = frames[i], {}
      for j = 1, #phases - 1 do
        local a, b = fr.t[phases[j]], fr.t[phases[j + 1]]
        if a and b then
          local ms = (b - a) * 1000
          if ms >= 0.5 then parts[#parts + 1] = string.format("%s %.1f", phases[j], ms) end
        end
      end
      print(string.format("  %5.1f ms, %3d dirty cells (%d sidebar), %2d tiles uncovered, %2d radar pixels: %s",
        fr.busy, fr.cells, fr.side or 0, fr.rev or 0, fr.pix or 0, table.concat(parts, ", ")))
    end
    local sum = {}
    for _, fr in ipairs(frames) do
      for j = 1, #phases - 1 do
        local a, b = fr.t[phases[j]], fr.t[phases[j + 1]]
        if a and b then sum[phases[j]] = (sum[phases[j]] or 0) + (b - a) * 1000 end
      end
    end
    local avg = {}
    for j = 1, #phases - 1 do
      avg[#avg + 1] = string.format("%s %.2f", phases[j], (sum[phases[j]] or 0) / #frames)
    end
    print("average ms: " .. table.concat(avg, ", "))
    local hist = {}
    for _, fr in ipairs(frames) do
      local b = math.min(fr.cells // 10, 10)
      hist[b] = (hist[b] or 0) + 1
    end
    local hs = {}
    for b = 0, 10 do if hist[b] then hs[#hs + 1] = string.format("%d-%d:%d", b * 10, b * 10 + 9, hist[b]) end end
    print("dirty cells per frame: " .. table.concat(hs, "  "))
    manager.machine:exit()
  end
end)
