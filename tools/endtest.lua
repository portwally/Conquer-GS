-- The end-of-game panel's numbers: units built, units lost, enemy units
-- and buildings destroyed, credits from ore, the time played. Builds a
-- harvester, has our tank destroy a guard tower, loses a soldier, then
-- loses the command center; dumps the panel (build/mame/end_lose.bin).
local G = dofile("tools/gs.lua")
local V = G.V
local I = dofile("build/gfx/icons.lua")
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local TOWER = 11                                          -- (22,6)
G.at(700, function()
  G.seeall()
  G.sw(V.CREDITS, 0, 3000)
  G.teleport(0, 21, 9)                                    -- our tank by it
  G.sw(V.UHP, 0, 3000)
  G.sw(V.UHP, TOWER, 1)
  G.teleport(3, 23, 9)                                    -- a soldier in
  G.sw(V.UHP, 3, 1)                                       --   harm's way
end)
G.click(705, I.harv_p[1], I.harv_p[2])                    -- a harvester
G.at(720, function() G.look(14, 2) end)
G.at(730, function() local x, y = G.unitxy(0); G.click(731, x, y) end)
G.at(745, function() local x, y = G.unitxy(TOWER); G.click(746, x, y) end)
G.at(1500, function()
  print("-- counted")
  check(G.w(V.SBUILT) == 1, "units built: 1 (" .. G.w(V.SBUILT) .. ")")
  check(G.w(V.SLOST) >= 1, "units lost: " .. G.w(V.SLOST))
  check(G.w(V.SKILLS) >= 1, "enemies destroyed: " .. G.w(V.SKILLS))
  check(G.w(V.SMINED) > 0, "ore mined: " .. G.w(V.SMINED))
  check(math.abs(G.w(V.SSECS) - G.w(V.FRAME) // 60) <= 1,
    string.format("time: %d s (game frame %d)", G.w(V.SSECS), G.w(V.FRAME)))
  local hq = G.w(V.HQUNIT) // 2                           -- the end
  G.sw(V.UHP, hq, 0); G.sw(V.UFLAGS, hq, G.w(V.UFLAGS, hq) | V.F_DEAD)
end)
G.at(1560, function()
  check(G.w(V.GAMEOVER) == 2, "the mission failed")
  G.mouse(300, 190)
end)
G.at(1580, function() G.dump("end_lose"); print("problems: " .. problems) end)
G.run(1585, function(f)
  if f >= 700 then G.sw(V.AIWAIT, 0, 30000); G.sw(V.AICREDITS, 0, 0) end
end)
