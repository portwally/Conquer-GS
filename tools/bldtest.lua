-- New buildings test. Ours: we start with a command center only; the war
-- factory needs a barracks, vehicles the war factory; the radar is off
-- (its picture says so, a click on it does nothing) until a radar center
-- stands; a refinery comes with a harvester at its dock, a second place to
-- unload; a guard tower stands like a turret; tanks roll out of the war
-- factory, and once that is sold, none can be built; with too little
-- power the radar goes off again. Theirs: infantry comes out of its barracks,
-- vehicles out of its war factory; without the factory, no more vehicles;
-- without its refinery, no income; without its power plant, half speed.
-- Dumps screens to build/mame/n*.bin.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local I = dofile("build/gfx/icons.lua")
local E = {}                                   -- equates from the generator
for line in io.lines("build/gfx/gfxequ.s") do
  local k, v = line:match("^(%S+)%s+equ%s+(%-?%d+)")
  if k then E[k] = tonumber(v) end
end
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function tile(c, r) return r * 32 + c end
local function near(t, c, r, d)                -- tile t within d of (c, r)?
  return math.abs(t % 32 - c) <= d and math.abs(t // 32 - r) <= d
end
local function placexy(c, r, size)             -- mouse for a structure's top left
  local x, y = G.tilexy(c, r)
  return x + (size - 1) * 8, y + (size - 1) * 8
end
local function units() return G.w(V.NUNITS) // 2 end
local function alive(i) return G.w(V.UFLAGS, i) & V.F_DEAD == 0 end
local function find(test)                      -- live units for which test(i)
  local out = {}
  for i = 0, units() - 1 do if alive(i) and test(i) then out[#out + 1] = i end end
  return out
end
-- the radar on the screen: the offline picture (from the sprite bank)?
local function radaroff()
  local base = V.SPRBANK * 0x10000 + V.RADOFFADDR
  for row = 0, V.RADH - 1 do
    for b = 0, V.RADW // 2 - 1 do
      if mem:read_u8(0xE12000 + (V.RADY + row) * 160 + V.RADX // 2 + b) ~=
         mem:read_u8(base + row * (V.RADW // 2) + b) then return false end
    end
  end
  return true
end
local function build(f, name) G.click(f, I[name][1], I[name][2]) end
local function place(f, name, c, r, size)      -- (when it is ready)
  G.click(f, I[name][1], I[name][2])
  G.at(f + 10, function() G.clear(c, r, size) end)
  G.at(f + 12, function() G.click(f + 13, placexy(c, r, size)) end)
end

-- ours, on Green Valley: command center at (2..4, 18..20); the structures
-- are built at once (the script fills their progress bars)
local PP, BAR, FACT = {2, 21}, {5, 21}, {5, 16}
local RADAR, REF, TOWER = {2, 16}, {8, 19}, {4, 16}
local function one(tmpl) return find(function(i) return G.w(V.USPR, i) == tmpl and
  G.w(V.UFLAGS, i) & V.F_BUILDING ~= 0 end)[1] end
G.at(700, function()
  G.sw(V.CREDITS, 0, 9000)
  G.sw(V.USTATE, 2, 0); G.sw(V.UGOAL, 2, 0xFFFF)          -- (harvester parked)
  print("-- the start: a command center only")
  check(G.w(V.RADARON) == 0 and radaroff(), "the radar is off, and says so")
  check(G.w(V.ICONOK, I.fact_p.n) == 0, "the war factory greyed out (no barracks)")
  check(G.w(V.ICONOK, I.tank_p.n) == 0, "the tank greyed out (no war factory)")
end)
build(705, 'fact_p')
G.at(720, function() check(G.w(V.QICON) == 0xFFFF, "a click on the war factory does nothing") end)
G.click(725, E.RADX + 40, E.RADY + 6)                     -- the radar: nothing
G.at(745, function()
  check(G.w(V.CAMX) == 0 and G.w(V.CAMY) == 12, "a click on the radar does not move the view")
end)
G.quickbuild(750, I.pp_p, PP[1], PP[2], 2)
G.quickbuild(800, I.bar_p, BAR[1], BAR[2], 2)
G.at(850, function()
  print("-- barracks")
  check(one(E.TMPL_BARP) ~= nil, "it stands")
  check(G.w(V.ICONOK, I.fact_p.n) == 1, "the war factory can be built now")
end)
G.quickbuild(860, I.fact_p, FACT[1], FACT[2], 2)
G.at(910, function()
  print("-- war factory")
  check(one(E.TMPL_FACTP) ~= nil, "it stands")
  check(G.w(V.ICONOK, I.tank_p.n) == 1 and G.w(V.ICONOK, I.harv_p.n) == 1,
    "tanks and harvesters can be built now")
end)
G.quickbuild(920, I.radar_p, RADAR[1], RADAR[2], 2)
G.at(975, function()
  print("-- radar center")
  check(one(E.TMPL_RADARP) ~= nil, "it stands")
  check(G.w(V.RADARON) == 1 and not radaroff(), "the radar is on")
  check(G.w(V.PWRUSED) == 100 and G.w(V.PWRMADE) == 200, "power 100/200")
  G.dump("n1_radar")
end)
G.click(980, E.RADX + 40, E.RADY + 6)                     -- now it works
G.at(1000, function() check(G.w(V.CAMY) < 12, "a click on it moves the view") ; G.look(0, 12) end)

local harvs0
G.at(1005, function() harvs0 = #find(function(i) return G.w(V.UFLAGS, i) & V.F_HARV ~= 0 end) end)
G.quickbuild(1010, I.ref_p, REF[1], REF[2], 2)
G.at(1065, function()
  print("-- refinery")
  local dock = tile(REF[1], REF[2] + 2)
  check(one(E.TMPL_REFP) ~= nil, "it stands")
  check(G.w(V.NDOCKS) == 4 and G.w(V.DOCKS) == G.w(V.DOCK) and G.w(V.DOCKS + 2) == dock,
    "two docks: the command center's and below the refinery")
  local h = find(function(i) return G.w(V.UFLAGS, i) & V.F_HARV ~= 0 end)
  check(#h == harvs0 + 1, "a harvester came with it")
  check(near(G.w(V.UTILE, h[#h]), REF[1], REF[2] + 2, 2), "next to its dock")
  check(G.w(V.PWRUSED) == 130, "power 130/200")
end)
-- the new harvester fills up and unloads at the refinery (nearer)
local unloaded

local tanks0
G.at(1070, function() tanks0 = #find(function(i) return G.w(V.USPR, i) == V.SPR_TANK_P end) end)
build(1075, 'tank_p')                                     -- (8 s)
G.quickbuild(1090, I.tower_p, TOWER[1], TOWER[2], 1)
G.at(1145, function()
  print("-- guard tower")
  local t = find(function(i) return G.w(V.USPR, i) == V.SPR_TOWER_P end)
  check(#t == 1 and G.w(V.UTILE, t[1]) == tile(TOWER[1], TOWER[2]), "it stands where placed")
  check(#t == 1 and G.w(V.UFLAGS, t[1]) & V.F_STATIC ~= 0 and G.w(V.URANGE, t[1]) == 3,
    "a static unit with range 3")
  check(mem:read_u8(V.PASSW + tile(TOWER[1], TOWER[2])) ~= 0, "its tile is a wall")
  check(G.w(V.PWRUSED) == 140 and G.w(V.LOWPOWER) == 0, "power 140/200")
end)
G.at(1570, function()
  print("-- tank")
  local t = find(function(i) return G.w(V.USPR, i) == V.SPR_TANK_P end)
  check(#t == tanks0 + 1, "a tank was built")
  local newest = t[#t]
  check(newest and near(G.w(V.UTILE, newest), 5, 18, 2),
    string.format("next to the war factory's door (at %d,%d)", newest and G.w(V.UTILE, newest) % 32 or -1,
      newest and G.w(V.UTILE, newest) // 32 or -1))
end)
-- sell: the power plant (power low, the radar off), the war factory (no
-- more vehicles), the barracks (no war factory; power enough again)
local SELLBTN = {(E.SELLX0 + E.SELLX1) // 2, (E.BTNY0 + E.BTNY1) // 2}
local pp, fact, bar
G.at(1580, function()
  pp, fact, bar = one(E.TMPL_PPP), one(E.TMPL_FACTP), one(E.TMPL_BARP)
  G.click(1581, SELLBTN[1], SELLBTN[2])
end)
G.at(1595, function() local x, y = G.unitxy(pp); G.click(1596, x, y) end)
G.at(1620, function()
  print("-- power plant sold")
  check(not alive(pp), "it is gone")
  check(G.w(V.PWRUSED) == 140 and G.w(V.PWRMADE) == 100 and G.w(V.LOWPOWER) == 1,
    "power 140/100: low")
  check(G.w(V.RADARON) == 0, "the radar is off again (too little power)")
end)
G.at(1630, function() check(radaroff(), "and says so"); G.dump("n2_base") end)
G.at(1635, function() local x, y = G.unitxy(fact); G.click(1636, x, y) end)
G.at(1660, function()
  print("-- war factory sold")
  check(not alive(fact), "it is gone")
  check(G.w(V.ICONOK, I.tank_p.n) == 0 and G.w(V.ICONOK, I.buggy_p.n) == 0 and
        G.w(V.ICONOK, I.harv_p.n) == 0, "tank, buggy and harvester greyed out")
end)
G.at(1665, function() local x, y = G.unitxy(bar); G.click(1666, x, y) end)
G.at(1690, function()
  print("-- barracks sold")
  check(not alive(bar), "it is gone")
  check(G.w(V.ICONOK, I.fact_p.n) == 0, "the war factory greyed out again")
  check(G.w(V.PWRUSED) == 80 and G.w(V.RADARON) == 1, "power 80/100: the radar on again")
  G.click(1691, 100, 100)                                 -- (sell mode off)
end)
build(1710, 'tank_p')
G.at(1730, function() check(G.w(V.QICON + 2) == 0xFFFF, "a click on the tank icon does nothing") end)

-- the harvesters: one unloads at the refinery
G.at(1740, function()
  local h = find(function(i) return G.w(V.UFLAGS, i) & V.F_HARV ~= 0 end)
  for _, i in ipairs(h) do G.sw(V.UCARGO, i, 475) end     -- nearly full: home soon
end)

-- theirs: watch where its new units appear
local seen, firsts = {}, {}
local function watch()
  for i = 0, units() - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_AI ~= 0 and fl & V.F_DEAD == 0 and not seen[i] then
      seen[i] = true
      firsts[#firsts + 1] = {spr = G.w(V.USPR, i), t = G.w(V.UTILE, i), f = G.f}
    end
    if fl & V.F_DEAD ~= 0 then seen[i] = nil end
  end
end
local function count(sprs, from)
  local n = 0
  for _, u in ipairs(firsts) do
    if u.f >= from then for _, s in ipairs(sprs) do if u.spr == s then n = n + 1 end end end
  end
  return n
end
local VEH = {V.SPR_TANK_E, V.SPR_BUGGY_E}
local INF = {V.SPR_SOLD_E, V.SPR_ROCK_E}
local function kill(unitvar)                    -- an enemy building dies
  local i = G.w(unitvar) // 2
  G.sw(V.UHP, i, 0); G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) | V.F_DEAD | 0x8000)
end
G.at(3300, function()
  print("-- the enemy")
  local wrongv, wrongi = 0, 0
  for _, u in ipairs(firsts) do
    for _, s in ipairs(VEH) do if u.spr == s and not near(u.t, 29, 5, 2) then wrongv = wrongv + 1 end end
    for _, s in ipairs(INF) do if u.spr == s and not near(u.t, 26, 6, 2) then wrongi = wrongi + 1 end end
  end
  print(string.format("  built %d vehicles, %d infantry", count(VEH, 0), count(INF, 0)))
  check(count(VEH, 0) > 0 and wrongv == 0, "vehicles came out of its war factory")
  check(count(INF, 0) > 0 and wrongi == 0, "infantry out of its barracks")
  kill(V.FACTUNIT)
end)
local credits0
G.at(5000, function()
  check(count(VEH, 3400) == 0 and count(INF, 3400) > 0, "without the factory: infantry only")
  credits0 = G.w(V.AICREDITS)
end)
G.at(5100, function()
  check(G.w(V.AICREDITS) > credits0, "income with its refinery")
  kill(V.REFUNIT)
  credits0 = G.w(V.AICREDITS)
end)
G.at(5300, function()
  check(G.w(V.AICREDITS) <= credits0, "none without it")
  G.sw(V.AICREDITS, 0, 5000)                               -- (enough to go on)
end)
-- build speed: game frames for aitimer to go down by 20, with and without
-- its power plant
local t0, a0, fast
G.at(5310, function() t0 = nil end)
local function timing()
  local f = G.w(V.FRAME)
  if G.w(V.AIBUILD) == 0xFFFF or G.w(V.AITIMER) < 30 then t0 = nil; return end
  if not t0 then t0, a0 = f, G.w(V.AITIMER); return end
  if a0 - G.w(V.AITIMER) >= 20 then
    local frames = f - t0
    t0 = nil
    return frames
  end
end
local slow
G.run(7000, function(f)
  if f >= 700 then
    G.sw(V.AIWAIT, 0, 30000)                               -- no attack waves
    G.sw(V.AIMAX, 0, V.MAXUNITS)
    if f < 5300 then G.sw(V.AICREDITS, 0, math.max(G.w(V.AICREDITS), 3000)) end
    watch()
  end
  if f >= 1750 and not unloaded then                       -- at the refinery?
    for _, i in ipairs(find(function(i) return G.w(V.UFLAGS, i) & V.F_HARV ~= 0 end)) do
      if G.w(V.USTATE, i) == V.H_UNLOAD and G.w(V.UTILE, i) == tile(REF[1], REF[2] + 2) then
        unloaded = f
        print("  a harvester unloads at the refinery's dock (frame " .. f .. ")")
      end
    end
  end
  if f == 4500 then check(unloaded ~= nil, "a harvester unloaded at the refinery") end
  if f > 5310 and f < 6000 and not fast then fast = timing() end
  if f == 6000 then kill(V.PPUNIT); t0 = nil end
  if f > 6000 and not slow then slow = timing() end
  if f == 6990 then
    print(string.format("  aitimer down by 20: in %s frames with its power plant, %s without",
      tostring(fast), tostring(slow)))
    check(fast and slow and fast <= 22 and slow >= 38, "half speed without its power plant")
    print("problems: " .. problems)
  end
end)
