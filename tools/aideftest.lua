-- The enemy defends (Green Valley): no attack waves, money to build an
-- army at home; then one of our tanks shoots its refinery. Within a
-- second it sends help after the tank - its nearest armed units at home,
-- 2 to 6 of them, together at least twice the tank's hit points - and not
-- the rest; the tank is destroyed or driven off. Dumps d1_defend.
local G = dofile("tools/gs.lua")
local V = G.V
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local TANK = 0
local ref, home0
local function after(t)
  local n, hp = 0, 0
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & (V.F_PLAYER | V.F_DEAD) == 0 and G.w(V.UTARGET, i) == 2 * t then
      n = n + 1; hp = hp + G.w(V.UMAXHP, i)
    end
  end
  return n, hp
end
local function home()
  local n = 0
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING | V.F_STATIC | V.F_HARV | V.F_AMOVE) == 0
       and G.w(V.URANGE, i) > 0 then n = n + 1 end
  end
  return n
end
G.run(4400, function(f)
  if f >= 700 and f < 3600 then
    G.sw(V.AIWAIT, 0, 30000)                     -- no waves: an army at home
    if G.w(V.AICREDITS) < 2000 then G.sw(V.AICREDITS, 0, 2000) end
  end
  if f == 700 then G.seeall() end
  if f == 3000 then
    ref = G.w(V.REFUNIT) // 2
    home0 = home()
    print(string.format("-- %d armed units at home", home0))
    check(home0 >= 4, "it has an army at home")
    local t = G.w(V.UCARGO, ref)                 -- next to its refinery
    local c, r = t % V.MAPW + 3, t // V.MAPW
    G.clear(c, r, 1); G.teleport(TANK, c, r)
    G.sw(V.UHP, TANK, 2000)
    G.sw(V.UTARGET, TANK, 2 * ref)
    G.sw(V.UFLAGS, TANK, G.w(V.UFLAGS, TANK) | V.F_CHASE)
    G.look(c - 8, r - 6)
  end
  if f == 3100 then
    local n, hp = after(TANK)
    print(string.format("-- %d sent after our tank, %d hit points (the tank's %d)", n, hp, G.w(V.UMAXHP, TANK)))
    check(n >= 2 and n <= 6, "it sends 2 to 6 units after it")
    check(hp >= 2 * G.w(V.UMAXHP, TANK) or n == 6, "together at least twice its hit points")
    check(home() - n >= 0 and n < home0, "not everybody")
  end
  if f == 3300 then G.dump("d1_defend") end
  if f == 4399 then
    check(G.w(V.UFLAGS, TANK) & V.F_DEAD ~= 0 or G.s16(G.w(V.UHP, TANK)) < 2000,
      "the tank is hit: " .. G.s16(G.w(V.UHP, TANK)))
    print("problems: " .. problems)
  end
end)
