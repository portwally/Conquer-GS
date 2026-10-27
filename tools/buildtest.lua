-- Building test: build and place a power plant (after a refused spot on
-- water), a barracks and a turret next to the command center, train a
-- soldier at the barracks; then an enemy tank destroys the power plant.
local G = dofile("tools/gs.lua")
local V = G.V
local I = dofile("build/gfx/icons.lua")
local icon = {pp = I.pp_p, bar = I.bar_p, sold = I.sold_p, turret = I.turret_p}
local function passable(c, r) return G.mem:read_u8(V.PASSW + r * 32 + c) == 0 end
local function report(tag)
  print(string.format("%-14s f=%5d credits=%4d power %d/%d low=%d placing=%d ok=%d  queues: s=%s ready=%d  u=%s",
    tag, G.f, G.w(V.CREDITS), G.w(V.PWRUSED), G.w(V.PWRMADE), G.w(V.LOWPOWER), G.w(V.PLACING),
    G.w(V.PLACEOK) & 1, G.w(V.QICON) == 0xFFFF and "-" or tostring(G.w(V.QICON) // 22),
    G.w(V.QREADY), G.w(V.QICON + 2) == 0xFFFF and "-" or tostring(G.w(V.QICON + 2) // 22)))
end
local function structures(tag)
  local n = G.w(V.NUNITS) // 2
  print("-- " .. tag)
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_PLAYER ~= 0 and (fl & V.F_STATIC ~= 0 or i >= 13) then
      local c, r = G.tile(i)
      print(string.format("  unit %2d tile=(%2d,%2d) hp=%3d power=%4d flags=%04X %s", i, c, r,
        G.s16(G.w(V.UHP, i)), G.s16(G.w(V.UPOWER, i)), fl, fl & V.F_DEAD ~= 0 and "DEAD" or ""))
    end
  end
end
-- placement spots (top-left tiles) near the command center at (2..4, 18..20)
-- (not at (5..6, 16..17): that is where the war factory goes in other tests)
local PP, BAR, TUR, WATER = {2, 16}, {2, 21}, {7, 20}, {13, 12}
local function pptiles(tag)
  print(string.format("  %s: tiles (%d,%d) to (%d,%d) passable:", tag, PP[1], PP[2], PP[1] + 1, PP[2] + 1),
    passable(PP[1], PP[2]), passable(PP[1] + 1, PP[2]), passable(PP[1], PP[2] + 1), passable(PP[1] + 1, PP[2] + 1))
end
local function placexy(spot, size)    -- mouse for a structure's top left
  local x, y = G.tilexy(spot[1], spot[2])
  return x + (size - 1) * 8, y + (size - 1) * 8
end
G.at(700, function()                                     -- harvester parked: it
  G.sw(V.USTATE, 2, 0); G.sw(V.UGOAL, 2, 0xFFFF)           -- would drive across
  report("start")                                          -- the building spots
end)
G.click(705, icon.pp[1], icon.pp[2])                      -- build power plant
G.at(1080, function() report("pp ready"); G.dump("p0_ready") end)
G.click(1090, icon.pp[1], icon.pp[2])                     -- start placing
G.at(1105, function() G.mouse(G.tilexy(WATER[1], WATER[2])) end)
G.at(1112, function() report("on water"); G.dump("p1_red") end)
G.at(1114, function() G.click(1115, G.tilexy(WATER[1], WATER[2])) end)
G.at(1130, function() report("after click") end)
G.at(1133, function() G.clear(PP[1], PP[2], 2) end)
G.at(1135, function() G.mouse(placexy(PP, 2)) end)
G.at(1142, function() report("good spot"); G.dump("p2_green") end)
G.at(1144, function() G.click(1145, placexy(PP, 2)) end)
G.at(1160, function()
  report("pp placed"); pptiles("placed")
end)
G.click(1170, icon.bar[1], icon.bar[2])                   -- build barracks
G.click(1680, icon.bar[1], icon.bar[2])                   -- place it
G.at(1690, function() G.clear(BAR[1], BAR[2], 2) end)
G.at(1694, function() G.click(1695, placexy(BAR, 2)) end)
G.at(1720, function() report("bar placed") end)
G.click(1730, icon.sold[1], icon.sold[2])                 -- soldier: now possible
G.click(1745, icon.turret[1], icon.turret[2])             -- build turret
G.click(2260, icon.turret[1], icon.turret[2])             -- place it
G.at(2270, function() G.clear(TUR[1], TUR[2], 1) end)
G.at(2274, function() G.click(2275, placexy(TUR, 1)) end)
G.at(2320, function() report("base built"); structures("structures"); G.dump("p3_base") end)
local pp
G.at(2330, function()                                     -- enemy tank 5 vs power plant
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    if G.w(V.UFLAGS, i) & (V.F_BUILDING | V.F_PLAYER) == (V.F_BUILDING | V.F_PLAYER)
       and G.w(V.UTILE, i) == PP[2] * 32 + PP[1] then pp = i end
  end
  G.sw(V.UHP, pp, 10)
  G.sw(V.UTARGET, 5, 2 * pp)
  G.sw(V.UFLAGS, 5, G.w(V.UFLAGS, 5) | V.F_CHASE)
  print("  power plant is unit " .. pp .. "; enemy tank 5 sent at it")
end)
G.at(5400, function()
  report("pp attacked"); structures("structures"); pptiles("razed")
  G.dump("p4_razed")
end)
G.run(5405, function(f) if f >= 600 then G.mem:write_u16(V.AICREDITS, 0) end end)
