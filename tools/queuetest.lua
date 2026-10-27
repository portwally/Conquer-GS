-- Build queue test: structures, infantry (barracks), vehicles (war
-- factory) and harvesters (command center) each build one at a time, all
-- four at once. With a barracks and a war factory: a soldier, a tank, a
-- harvester and a power plant all in progress together; a rocket soldier
-- and a buggy wait (their queues are busy); the three units come out by
-- their own buildings.
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
G.run(1510, function(f)
  if f >= 700 then G.sw(V.AICREDITS, 0, 0); G.sw(V.AIWAIT, 0, 30000); watch() end
end)
G.at(1505, function() print("problems: " .. problems) end)
