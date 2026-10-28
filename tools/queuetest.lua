-- Build queue test: structures, infantry (barracks), vehicles (war
-- factory) and harvesters (command center) each build one at a time, all
-- four at once. With a barracks and a war factory: a soldier, a tank, a
-- harvester and a power plant all in progress together; a rocket soldier
-- and a buggy wait (their queues are busy); the three units come out by
-- their own buildings. More of one kind queue up behind it; an
-- Option-click takes one back (or stops a structure), the money back.
local G = dofile("tools/gs.lua")
local V = G.V
local I = dofile("build/gfx/icons.lua")
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function q(n) return G.w(V.QICON + 2 * n) end      -- icon in queue n
local function ours(spr)                                 -- our live units of a kind
  local n = 0
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING) == V.F_PLAYER and G.w(V.USPR, i) == spr then
      n = n + 1
    end
  end
  return n
end
local function icon(name) return I[name].n * V.ICONSZ end
-- where each new unit of ours first stood
local known, firsttile = {}, {}
local function watch()
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, i)
    local live = fl & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING) == V.F_PLAYER
    if live and not known[i] then
      known[i] = true
      if G.f > 825 then firsttile[G.w(V.USPR, i)] = G.w(V.UTILE, i) end
    end
    if not live then known[i] = nil end
  end
end
local function near(t, c, r) return t and math.abs(t % 32 - c) <= 2 and math.abs(t // 32 - r) <= 2 end

G.at(700, function()
  check(V.QTAB == V.NQUEUES * 2, string.format("%d queues", V.NQUEUES))
  G.sw(V.CREDITS, 0, 9000)
end)
G.quickbuild(705, I.bar_p, 2, 21, 2)                     -- a barracks, then
G.quickbuild(760, I.fact_p, 5, 16, 2)                    --   a war factory
local before = {}
G.at(825, function()
  for _, k in ipairs({'SOLD_P', 'TANK_P', 'HARV_P', 'ROCK_P', 'BUGGY_P'}) do
    before[k] = ours(V['SPR_' .. k])
  end
end)
G.click(830, I.sold_p[1], I.sold_p[2])
G.click(840, I.tank_p[1], I.tank_p[2])
G.click(850, I.harv_p[1], I.harv_p[2])
G.click(860, I.pp_p[1], I.pp_p[2])
G.click(870, I.rock_p[1], I.rock_p[2])                   -- (busy: ignored)
G.click(880, I.buggy_p[1], I.buggy_p[2])                 -- (busy: ignored)
G.at(900, function()
  print("-- all at once")
  check(q(0) == icon('pp_p'), "structures: a power plant")
  check(q(1) == icon('sold_p'), "infantry: a soldier (not the rocket soldier)")
  check(q(2) == icon('tank_p'), "vehicles: a tank (not the buggy)")
  check(q(3) == icon('harv_p'), "harvesters: a harvester")
end)
local segs
G.at(1000, function()
  segs = {G.w(V.QSEG, 0), G.w(V.QSEG, 2), G.w(V.QSEG, 3)}
  check(G.w(V.QSEG, 0) > 0 and G.w(V.QSEG, 2) > 0 and G.w(V.QSEG, 3) > 0,
    string.format("their bars fill together (%d, %d, %d of %d)", segs[1], segs[2], segs[3], V.BARSEGS))
end)
G.at(1500, function()
  print("-- out")
  local ex = G.w(V.EXITTILE)
  check(ours(V.SPR_SOLD_P) == before.SOLD_P + 1 and near(firsttile[V.SPR_SOLD_P], 2, 23),
    "a soldier came out, by the barracks")
  check(ours(V.SPR_TANK_P) == before.TANK_P + 1 and near(firsttile[V.SPR_TANK_P], 5, 18),
    "a tank came out, by the war factory")
  check(ours(V.SPR_HARV_P) == before.HARV_P + 1 and near(firsttile[V.SPR_HARV_P], ex % 32, ex // 32),
    "a harvester came out, by the command center")
  check(ours(V.SPR_ROCK_P) == before.ROCK_P and ours(V.SPR_BUGGY_P) == before.BUGGY_P,
    "no rocket soldier, no buggy")
  check(q(1) == 0xFFFF and q(2) == 0xFFFF and q(3) == 0xFFFF, "the unit queues idle again")
  check(q(0) == icon('pp_p') and G.w(V.QREADY) ~= 0, "the power plant ready to place")
end)

-- more of one kind: three soldiers queued, one taken back (Option-click)
local cr0, sold0
local function sold() return G.w(V.QICON + 2) end
G.at(1520, function()
  print("-- queued")
  for i = 0, G.w(V.NUNITS) // 2 - 1 do                  -- (no income now)
    if G.w(V.UFLAGS, i) & V.F_HARV ~= 0 then
      G.sw(V.USTATE, i, V.H_IDLE); G.sw(V.UCARGO, i, 0); G.sw(V.UGOAL, i, 0xFFFF)
    end
  end
  G.sw(V.CREDITS, 0, 5000); cr0 = 5000; sold0 = ours(V.SPR_SOLD_P)
end)
G.click(1525, I.sold_p[1], I.sold_p[2])
G.click(1535, I.sold_p[1], I.sold_p[2])
G.click(1545, I.sold_p[1], I.sold_p[2])
G.at(1560, function()
  check(sold() == icon('sold_p') and G.w(V.QMORE, 1) == 2 and G.w(V.CREDITS) == cr0 - 300,
    string.format("three soldiers: two more queued (%d), 300 paid", G.w(V.QMORE, 1)))
  G.dump("q1_badge")
  G.sw(V.OPTHELD, 0, 1)
end)
G.click(1565, I.sold_p[1], I.sold_p[2])                 -- Option-click
G.at(1580, function()
  G.sw(V.OPTHELD, 0, 0)
  check(G.w(V.QMORE, 1) == 1 and G.w(V.CREDITS) == cr0 - 200, "Option-click: one fewer, 100 back")
end)
G.at(1900, function()
  check(ours(V.SPR_SOLD_P) == sold0 + 2 and sold() == 0xFFFF,
    string.format("two soldiers came out, one after the other (%d)", ours(V.SPR_SOLD_P) - sold0))
end)
-- a structure: cancelled while it builds, and once it is ready
G.at(1905, function() G.sw(V.CREDITS, 0, 5000); G.sw(V.QICON, 0, 0xFFFF); G.sw(V.QREADY, 0, 0) end)
G.click(1910, I.radar_p[1], I.radar_p[2])
G.at(1930, function() check(G.w(V.QICON) == icon('radar_p') and G.w(V.CREDITS) == 4200, "a radar center being built") ; G.sw(V.OPTHELD, 0, 1) end)
G.click(1935, I.radar_p[1], I.radar_p[2])
G.at(1950, function()
  G.sw(V.OPTHELD, 0, 0)
  check(G.w(V.QICON) == 0xFFFF and G.w(V.CREDITS) == 5000, "Option-click: stopped, its 800 back")
end)
G.run(1990, function(f)
  if f >= 700 then G.sw(V.AICREDITS, 0, 0); G.sw(V.AIWAIT, 0, 30000); watch() end
end)
G.at(1985, function() print("problems: " .. problems) end)
