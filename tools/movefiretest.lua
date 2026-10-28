-- Fire on the move: our tank, sent along the road past an enemy tank,
-- shoots at it on the way without stopping, and still gets where it was
-- sent; one that stands still shoots as before.
local G = dofile("tools/gs.lua")
local V = G.V
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local ENEMY = 5                                          -- an enemy tank
local hp0, shotwalking, stops = nil, 0, 0
G.at(700, function()
  G.seeall()
  G.teleport(ENEMY, 10, 17)                              -- by the road
  G.sw(V.UHP, ENEMY, 2000)                               -- (lasts the test)
  hp0 = 2000
  local x, y = G.unitxy(0)
  G.click(701, x, y)                                     -- our tank 0
end)
G.at(720, function() local x, y = G.tilexy(15, 19); G.click(721, x, y) end)
local last, arrived
G.run(1500, function(f)
  if f < 700 then return end
  G.sw(V.AIWAIT, 0, 30000); G.sw(V.AICREDITS, 0, 0)
  G.sw(V.UTARGET, ENEMY, 0xFFFF)                         -- (it does not shoot)
  G.sw(V.URELOAD, ENEMY, 100)
  if f > 730 and not arrived then
    local hp = G.s16(G.w(V.UHP, ENEMY))
    local moving = G.w(V.UNEXT, 0) ~= 0xFFFF
    if last and hp < last then
      if moving then shotwalking = shotwalking + 1 else stops = stops + 1 end
    end
    last = hp
    if G.w(V.UTILE, 0) == 19 * 32 + 15 then arrived = f end
  end
  if f == 1490 then
    print(string.format("  hits while walking %d, standing %d; arrived at frame %s", shotwalking,
      stops, tostring(arrived)))
    check(shotwalking >= 2, "it shot the enemy tank while walking")
    check(arrived ~= nil, "and got where it was sent")
    print("problems: " .. problems)
  end
end)
