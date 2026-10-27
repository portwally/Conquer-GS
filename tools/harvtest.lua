-- Harvester test. Harvesters have 400 hit points. The enemy's harvester
-- (not one of the units it built: no attack waves for it) mines and
-- unloads at its refinery's door, and the enemy gets its share (AISHARE)
-- for each scoop; killed, its refinery makes a new one (free) in AIHARVT
-- frames, by the refinery's door, and none while the refinery is gone.
-- With no ore left our harvester waits (H_WAIT) and goes back to work
-- once ore grows back (every GROWMASK+1 frames, GROWSCOOPS a tile).
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function units() return G.w(V.NUNITS) // 2 end
local function eharvs()                        -- the enemy's live harvesters
  local out = {}
  for i = 0, units() - 1 do
    if G.w(V.UFLAGS, i) & (V.F_HARV | V.F_PLAYER | V.F_DEAD) == V.F_HARV then out[#out + 1] = i end
  end
  return out
end
local function kill(i)
  G.sw(V.UHP, i, 0); G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) | V.F_DEAD | 0x8000)
end
local function near(t, u, d)
  return math.abs(t % 32 - u % 32) <= d and math.abs(t // 32 - u // 32) <= d
end
local function refdoor()                       -- (as doorof)
  local r = G.w(V.REFUNIT) // 2
  return G.w(V.UCARGO, r) + G.w(V.USTATE, r) * 32
end
local OURS = 2                                 -- our harvester (unit 2)

-- the start
local oretiles = {}                            -- (all still there)
G.at(700, function()
  print("-- the start")
  for t = 0, 32 * 24 - 1 do
    if mem:read_u8(V.OREAMT + t) ~= 0 then oretiles[#oretiles + 1] = t end
  end
  check(#oretiles * 2 == G.w(V.NORETL), string.format("%d ore tiles", #oretiles))
  local e = eharvs()
  check(G.w(V.UMAXHP, OURS) == 400, "our harvester: 400 hit points")
  check(#e == 1 and G.w(V.UMAXHP, e[1]) == 400, "the enemy has a harvester, 400 hit points")
  check(e[1] and G.w(V.UFLAGS, e[1]) & V.F_AI == 0, "not one of the units it built")
end)

-- its loads: credits up by its share, at its refinery's door
local lastcr, shares, others, atdoor = nil, 0, 0, false
local function income(f)
  local cr = G.w(V.AICREDITS)
  if lastcr and cr > lastcr then
    if cr - lastcr == G.w(V.AISHARE) then shares = shares + 1 else others = others + 1 end
  end
  lastcr = cr
  for _, i in ipairs(eharvs()) do
    if G.w(V.USTATE, i) == V.H_UNLOAD and G.w(V.UTILE, i) == refdoor() then atdoor = true end
  end
end
G.at(2300, function()
  print("-- its loads")
  check(atdoor, "its harvester unloads at its refinery's door")
  check(shares >= 20 and others == 0,
    string.format("credits up by its share (%d) a scoop: %d times, %d other", G.w(V.AISHARE),
      shares, others))
end)

-- killed: a new one in AIHARVT frames (nothing else built meanwhile)
local killedat, newat, newtile, busy
G.at(2900, function()
  print("-- its harvester killed")
  busy = G.w(V.AIBUILD) ~= 0xFFFF
  kill(eharvs()[1])
  killedat = G.w(V.FRAME)
end)
G.at(2905, function()
  check(not busy, "(the enemy was building nothing)")
  check(G.w(V.AIBUILD) == V.TMPL_HARVE, "its refinery makes a new one")
end)
local function watchnew()
  if killedat and not newat and #eharvs() == 1 then
    newat = G.w(V.FRAME) - killedat
    newtile = G.w(V.UTILE, eharvs()[1])
  end
end
G.at(5000, function()
  check(newat and math.abs(newat - V.AIHARVT) <= 10,
    string.format("there in %s frames (AIHARVT %d)", tostring(newat), V.AIHARVT))
  check(newtile and near(newtile, refdoor(), 2), "by its refinery's door")
  local e = eharvs()[1]
  check(e and G.w(V.UFLAGS, e) & V.F_AI == 0, "again not one of its units")
  G.sw(V.AIWAIT, 0, 0)                                    -- a wave now
end)
G.at(5100, function()
  local e = eharvs()[1]
  local sent = 0
  for i = 0, units() - 1 do
    if G.w(V.UFLAGS, i) & (V.F_AMOVE | V.F_DEAD) == V.F_AMOVE then sent = sent + 1 end
  end
  check(sent > 0 and e and G.w(V.UFLAGS, e) & V.F_AMOVE == 0,
    string.format("a wave of %d left without it", sent))
end)

-- our harvester: no ore, it waits; ore grows back, it works again
local waited, back, grewat
G.at(5200, function()
  print("-- no ore")
  G.sw(V.NORETL, 0, 0)                                     -- (no growing yet)
  for t = 0, 32 * 24 - 1 do mem:write_u8(V.OREAMT + t, 0) end
end)
local function watchours(f)
  local st = G.w(V.USTATE, OURS)
  if f > 5200 and not waited and st == V.H_WAIT then
    waited = f
    print("  our harvester waits (frame " .. f .. ")")
  end
  if grewat and not back and st ~= V.H_WAIT and st ~= V.H_IDLE then back = f end
end
G.at(6600, function()
  check(waited ~= nil, "our harvester waits")
  check(G.w(V.USTATE, OURS) == V.H_WAIT, "still waiting (it looks again now and then)")
  G.sw(V.NORETL, 0, #oretiles * 2)                         -- growing again
end)
local ORE = {8, 16}                                        -- a tile of ours
G.run(10500, function(f)
  if f < 700 then return end
  if f < 5000 then G.sw(V.AIWAIT, 0, 30000) end            -- no waves (but one)
  if f >= 5100 then G.sw(V.AIWAIT, 0, 30000) end
  if f >= 2300 then G.sw(V.AICREDITS, 0, 0) end           -- builds nothing more
  if f < 2300 then income(f) end
  watchnew()
  watchours(f)
  if f > 6600 and not grewat and mem:read_u8(V.OREAMT + ORE[2] * 32 + ORE[1]) ~= 0 then
    grewat = f
    print(string.format("  ore back at (%d,%d): %d scoops (frame %d, game frame %d)", ORE[1], ORE[2],
      mem:read_u8(V.OREAMT + ORE[2] * 32 + ORE[1]), f, G.w(V.FRAME)))
  end
  if f == 9200 then
    print("-- ore grows back")
    check(grewat ~= nil, "ore grew back")
    check(back ~= nil and back - grewat <= V.HARVWAIT + 30,
      string.format("our harvester back at work %s frames later", back and tostring(back - grewat) or "-"))
    print("-- without its refinery")
    for _, i in ipairs(eharvs()) do kill(i) end
    kill(G.w(V.REFUNIT) // 2)
  end
  if f == 10400 then
    check(#eharvs() == 0 and G.w(V.AIBUILD) ~= V.TMPL_HARVE, "no new harvester")
    print("problems: " .. problems)
  end
end)
