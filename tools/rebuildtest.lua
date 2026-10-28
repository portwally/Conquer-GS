-- Enemy rebuilding: destroyed, its power plant comes back on the same
-- spot (once the spot is clear of units, and it has the money), after its
-- build time; so does its barracks (3x3, on its concrete pad); the
-- remembered slots follow the new buildings.
local G = dofile("tools/gs.lua")
local V = G.V
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local TANK = 0
local function alive(i) return G.w(V.UFLAGS, i) & V.F_DEAD == 0 end
local function shoot(f, unitvar)             -- our tank kills a building
  G.at(f, function()
    local b = G.w(unitvar) // 2
    G.sw(V.UHP, b, 1)
    local x, y = G.unitxy(TANK); G.click(f + 1, x, y)
  end)
  G.at(f + 15, function()
    local b = G.w(unitvar) // 2
    local x, y = G.unitxy(b); G.click(f + 16, x, y)
  end)
end
local function standing(unitvar, tmpl)
  local b = G.w(unitvar) // 2
  return alive(b) and G.w(V.USPR, b) == tmpl and G.w(V.UFLAGS, b) & V.F_BUILDING ~= 0
end
local pptl, bartl
G.at(700, function()
  G.seeall(); G.look(16, 0)
  G.sw(V.UHP, TANK, 3000)
  G.teleport(TANK, 27, 10)
  pptl, bartl = G.w(V.UCARGO, G.w(V.PPUNIT) // 2), G.w(V.UCARGO, G.w(V.BARUNIT) // 2)
end)
shoot(720, V.PPUNIT)
G.at(800, function()
  print("-- its power plant")
  check(not standing(V.PPUNIT, V.TMPL_PPE), "destroyed")
  G.teleport(TANK, pptl % 32, pptl // 32)                  -- on its spot
end)
G.at(1100, function()
  check(G.w(V.AIBUILD) ~= V.TMPL_PPE, "not rebuilt while our tank stands on the spot")
  G.teleport(TANK, 27, 10)
end)
local started
G.at(1140, function()
  started = G.w(V.FRAME)
  check(G.w(V.AIBUILD) == V.TMPL_PPE, "spot clear: rebuilding it")
end)
G.at(3060, function()
  check(standing(V.PPUNIT, V.TMPL_PPE) and G.w(V.UCARGO, G.w(V.PPUNIT) // 2) == pptl,
    string.format("back on the same spot, in %d frames (half speed: no power plant)", G.w(V.FRAME) - started))
  check(G.mem:read_u8(V.OVERLAY + pptl) ~= 0 and G.mem:read_u8(V.PASSW + pptl) ~= 0,
    "drawn on the map, a wall")
  G.teleport(TANK, 25, 6)
end)
shoot(3070, V.BARUNIT)
G.at(3150, function()
  print("-- its barracks")
  check(not standing(V.BARUNIT, V.TMPL_BARE), "destroyed")
end)
G.at(4500, function()
  local b = G.w(V.BARUNIT) // 2
  check(standing(V.BARUNIT, V.TMPL_BARE) and G.w(V.UCARGO, b) == bartl and
        G.w(V.UTILE, b) == bartl + 33, "back on its pad (standing on the middle tile)")
  local n = 0
  for r = 0, 2 do for c = 0, 2 do
    if G.mem:read_u8(V.OVERLAY + bartl + r * 32 + c) ~= 0 then n = n + 1 end
  end end
  check(n == 9, string.format("its 9 pieces on the map (%d)", n))
  G.look(16, 0); G.at(4505, function() G.dump("rb_end") end)
  print("problems: " .. problems)
end)
G.run(4515, function(f)
  if f >= 700 then
    G.sw(V.AIWAIT, 0, 30000); G.sw(V.AIMAX, 0, 0)          -- no units, no waves
    G.sw(V.AICREDITS, 0, 5000)
    G.sw(V.UHP, TANK, 3000)
  end
end)
