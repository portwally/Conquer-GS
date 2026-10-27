-- Scripted battle test: a soldier walks around the command center's pad,
-- box select, then the selected units cross the world to attack an
-- enemy tank. Prints the unit table; dumps screens to build/mame/b*.bin.
local G = dofile("tools/gs.lua")
local V = G.V
local trail = {}
G.at(700, function() G.units("start"); G.dump("b0_start"); G.seeall() end)   -- no fog
-- 1. pathfinding: soldier 3 at (5,21) walks to (3,17), around the pad
G.at(705, function() local x, y = G.unitxy(3); G.click(706, x, y) end)
G.at(720, function() local x, y = G.tilexy(3, 17); G.click(721, x, y) end)
G.at(1100, function()
  print("soldier trail: " .. table.concat(trail, " ")); G.units("after detour") end)
-- 2. box select around soldier 4 (6,21) and tank 1 (6,20)
G.at(1110, function()
  local x0, y0 = G.tilexy(6, 20); local x1, y1 = G.tilexy(6, 21)
  G.at(1111, function() G.mouse(x0 - 12, y0 - 12) end)
  G.at(1114, function() btn_press() end)
  G.at(1120, function() G.mouse(x0, y0) end)
  G.at(1125, function() G.mouse(x1 + 10, y1 + 10) end)
  G.at(1130, function() G.dump("b1_box") end)
  G.at(1135, function() btn_release() end)
end)
G.at(1145, function() G.units("box selected") end)
-- 3. attack enemy tank 5: look at it, click it
G.at(1150, function() G.look(16, 0) end)
G.at(1160, function() local x, y = G.unitxy(5); G.click(1161, x, y) end)
G.at(1175, function() G.look(0, 12) end)
G.at(2400, function() G.look(14, 4); G.units("battle") end)
G.at(2410, function() G.dump("b3_battle") end)
G.at(3600, function() G.units("after battle"); G.dump("b4_after") end)
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
function btn_press() btn:set_value(1) end
function btn_release() btn:clear_value() end
G.run(3605, function(f)
  if f >= 600 then G.mem:write_u16(V.AICREDITS, 0) end   -- no enemy production
  if f >= 730 and f < 1100 then
    local c, r = G.tile(3)
    local t = c .. "," .. r
    if trail[#trail] ~= t then trail[#trail + 1] = t end
  end
end)
