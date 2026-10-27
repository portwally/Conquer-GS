-- Art check: screen dumps of the start (our base), the enemy base with the
-- fog lifted, and a fight there with hits and explosions, for
-- tools/shr2png.py: build/mame/art_base.bin, art_enemy.bin, art_fight.bin.
local G = dofile("tools/gs.lua")
local V = G.V
G.at(700, function() G.dump("art_base") end)
G.at(702, function() G.seeall(); G.radar(); G.look(16, 0) end)
G.at(790, function() G.dump("art_enemy") end)
G.at(792, function()                     -- our tanks and soldiers drop in
  G.teleport(0, 21, 8); G.teleport(1, 22, 9)
  G.teleport(3, 20, 7); G.teleport(4, 21, 7)
end)
G.at(900, function() G.dump("art_fight") end)
G.run(902, function(f) if f >= 600 then G.mem:write_u16(V.AICREDITS, 0) end end)
