-- Name tag test: the mouse rests on one of our tanks, our command center,
-- an enemy tank (fog lifted, view moved there) and a build icon; each time
-- the right tag must show below the arrow, exactly as unpacked (in the
-- sprite bank), and go away when the mouse moves to open ground.
local G = dofile("tools/gs.lua")
local V = G.V
local L = dofile("build/gfx/labels.lua")
local I = dofile("build/gfx/icons.lua")
local problems = 0
local function tagname(n)
  for k, v in pairs(L) do if v.n == n then return k end end
  return n == 0xFFFF and "none" or tostring(n)
end
-- the shown tag on the screen, byte by byte as in the sprite bank
local function onscreen()
  local n = G.w(V.LBLNUM)
  if n == 0xFFFF then return false end
  local t = L[tagname(n)]
  local x, y = G.w(V.LBLX), G.w(V.LBLY)
  for row = 0, V.LABELH - 1 do
    for b = 0, t.w - 1 do
      local want = G.mem:read_u8(V.SPRBANK * 0x10000 + V.LABELADDR + t.off + row * t.w + b)
      if G.mem:read_u8(0xE12000 + (y + row) * 160 + x // 2 + b) ~= want then return false end
    end
  end
  return true
end
local function expect(tag, name)
  local n = G.w(V.LBLNUM)
  local ok = tagname(n) == name and onscreen()
  print(string.format("%-22s tag %-8s on screen: %s", tag, tagname(n), ok and "yes" or "NO"))
  if not ok then problems = problems + 1 end
end
local function gone(tag)
  local ok = G.w(V.LBLNUM) == 0xFFFF
  print(string.format("%-22s %s", tag, ok and "no tag" or "TAG STILL THERE"))
  if not ok then problems = problems + 1 end
end
local function rest(f, x, y) G.at(f, function() G.mouse(x, y) end) end
-- our tank 0, standing still
G.at(700, function()
  G.sw(V.USTATE, 2, 0); G.sw(V.UGOAL, 2, 0xFFFF)          -- (harvester parked)
  local x, y = G.unitxy(0); G.mouse(x, y)
end)
G.at(730, function() expect("our tank:", "tank_p"); G.dump("l0_tank") end)
G.at(732, function() G.mouse(G.tilexy(12, 21)) end)       -- open ground
G.at(760, function() gone("open ground:") end)
G.at(762, function() G.mouse(G.tilexy(3, 19)) end)        -- command center
G.at(790, function() expect("our command center:", "hq_p") end)
G.at(792, function() G.mouse(I.tank_p[1], I.tank_p[2]) end)
G.at(820, function() expect("tank icon:", "icon" .. I.tank_p.n); G.dump("l1_icon") end)
G.at(822, function() G.seeall(); G.look(16, 0) end)
G.at(880, function()                                      -- an enemy tank
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    if G.w(V.UFLAGS, i) & (V.F_PLAYER | V.F_DEAD) == 0 and G.w(V.USPR, i) == V.SPR_TANK_E then
      local x, y = G.unitxy(i); G.mouse(x, y); break
    end
  end
end)
G.at(910, function() expect("enemy tank:", "tank_e"); G.dump("l2_enemy") end)
G.at(912, function() G.mouse(G.tilexy(18, 10)) end)
G.at(940, function() gone("open ground again:") end)
G.at(945, function() print("problems: " .. problems) end)
G.run(946, function(f) if f >= 600 then G.mem:write_u16(V.AICREDITS, 0) end end)
