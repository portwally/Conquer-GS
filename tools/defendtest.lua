-- Defense test: a player who does the least sensible thing - builds two
-- turrets by the command center and a tank, then keeps building tanks
-- when there is money - against the enemy AI. Prints the state every 30
-- seconds of game time until the game ends or 8 minutes pass.
local G = dofile("tools/gs.lua")
local V = G.V
local I = dofile("build/gfx/icons.lua")
local function hp(i) return G.s16(G.w(V.UHP, i)) end
local function report(tag)
  local n, pl, en, amove = G.w(V.NUNITS) // 2, 0, 0, 0
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_DEAD == 0 and fl & V.F_BUILDING == 0 then
      if fl & V.F_PLAYER ~= 0 then pl = pl + 1 else en = en + 1 end
      if fl & V.F_AMOVE ~= 0 then amove = amove + 1 end
    end
  end
  print(string.format("%-8s game %4.0f s: credits=%4d player units=%2d enemy=%2d (attacking %d) wave=%d HQ hp=%d over=%d",
    tag, G.w(V.FRAME) / 60, G.w(V.CREDITS), pl, en, amove, G.w(V.WAVESIZE), hp(G.w(V.HQUNIT) // 2), G.w(V.GAMEOVER)))
end
local spots = {{7, 17}, {7, 19}}              -- turrets, top-left tiles
local turrets = 0
local function placexy(spot) return G.tilexy(spot[1], spot[2]) end
G.at(700, function() report("start") end)
G.click(705, I.turret_p[1], I.turret_p[2])
G.click(712, I.tank_p[1], I.tank_p[2])
local ended
G.run(60 * 60 * 8 + 700, function(f)
  if ended or f < 700 then return end      -- (before 660 the game is loading)
  if f % 1800 == 0 then report("") end
  -- a finished turret: place it at the next spot, then order another
  if f % 20 == 0 and G.w(V.QREADY) ~= 0 and G.w(V.PLACING) == 0 and turrets < #spots then
    G.click(f + 1, I.turret_p[1], I.turret_p[2])
    local spot = spots[turrets + 1]
    G.at(f + 10, function() G.clear(spot[1], spot[2], 1) end)
    G.at(f + 12, function() local x, y = placexy(spot); G.click(f + 13, x, y) end)
    G.at(f + 30, function()
      if G.w(V.QREADY) == 0 then
        turrets = turrets + 1
        if turrets < #spots then G.click(f + 31, I.turret_p[1], I.turret_p[2]) end
      end
    end)
  end
  -- unit queue idle and money for a tank: another tank
  if f % 60 == 30 and G.w(V.QICON + 2) == 0xFFFF and G.w(V.CREDITS) >= 800 then
    G.click(f + 1, I.tank_p[1], I.tank_p[2])
  end
  if G.w(V.GAMEOVER) ~= 0 then
    ended = f
    report(G.w(V.GAMEOVER) == 1 and "WON" or "LOST")
    manager.machine:exit()
  end
  if f == 60 * 60 * 8 + 699 then report("8 min") end
end)
