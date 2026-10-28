-- Rally points: a click on our barracks (or war factory), then on open
-- ground, sets where its new units go; they walk there after coming out.
-- A click on a unit in between, and the rally point is not set.
local G = dofile("tools/gs.lua")
local V = G.V
local I = dofile("build/gfx/icons.lua")
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function bld(tmpl)
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & (V.F_BUILDING | V.F_DEAD) == V.F_BUILDING and G.w(V.USPR, i) == tmpl then return i end
  end
end
local function newest(spr)                    -- our live units of a kind
  local out = {}
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    if G.w(V.UFLAGS, i) & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING) == V.F_PLAYER and
       G.w(V.USPR, i) == spr then out[#out + 1] = i end
  end
  return out
end
local function near(t, c, r, d) return math.abs(t % 32 - c) <= d and math.abs(t // 32 - r) <= d end
G.at(700, function() G.sw(V.CREDITS, 0, 9000) end)
G.quickbuild(705, I.bar_p, 2, 21, 2)
G.quickbuild(760, I.fact_p, 5, 16, 2)
local bar, fact, sold0, tank0
G.at(820, function()
  bar, fact = bld(V.TMPL_BARP), bld(V.TMPL_FACTP)
  sold0, tank0 = #newest(V.SPR_SOLD_P), #newest(V.SPR_TANK_P)
  print("-- rally points")
  check(G.w(V.UDOCK, bar) == 0xFFFF and G.w(V.UDOCK, fact) == 0xFFFF, "none at first")
  local x, y = G.unitxy(bar); G.click(821, x, y)            -- the barracks
end)
G.at(835, function()
  check(G.w(V.RALLYB) == bar * 2, "the barracks chosen")
  local x, y = G.tilexy(12, 21); G.click(836, x, y)         -- its rally point
end)
G.at(850, function()
  check(G.w(V.UDOCK, bar) == 21 * 32 + 12 and G.w(V.RALLYB) == 0xFFFF, "its rally point set")
  local x, y = G.unitxy(fact); G.click(851, x, y)           -- the war factory,
end)
G.at(865, function() local x, y = G.unitxy(0); G.click(866, x, y) end)   -- then a unit:
G.at(880, function()
  check(G.w(V.RALLYB) == 0xFFFF and G.w(V.UDOCK, fact) == 0xFFFF, "a unit clicked: no rally point")
  local x, y = G.unitxy(fact); G.click(881, x, y)
end)
G.at(895, function() local x, y = G.tilexy(13, 17); G.click(896, x, y) end)
G.at(910, function()
  check(G.w(V.UDOCK, fact) == 17 * 32 + 13, "the war factory's set")
end)
G.click(915, I.sold_p[1], I.sold_p[2])
G.click(925, I.sold_p[1], I.sold_p[2])
G.click(935, I.tank_p[1], I.tank_p[2])
G.at(1900, function()
  print("-- new units")
  local s, t = newest(V.SPR_SOLD_P), newest(V.SPR_TANK_P)
  check(#s == sold0 + 2 and near(G.w(V.UTILE, s[#s]), 12, 21, 2) and near(G.w(V.UTILE, s[#s - 1]), 12, 21, 2),
    "two soldiers walked to the barracks' rally point")
  check(#t == tank0 + 1 and near(G.w(V.UTILE, t[#t]), 13, 17, 2), "the tank to the war factory's")
  print("problems: " .. problems)
end)
G.run(1910, function(f) if f >= 700 then G.sw(V.AICREDITS, 0, 0); G.sw(V.AIWAIT, 0, 30000) end end)
