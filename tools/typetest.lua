-- Unit types test: a barracks and a war factory (built at once), then a
-- buggy and a rocket soldier from the sidebar; check their stats, the buggy's speed against a tank's, then
-- single fights in open ground checking the damage of each weapon against
-- each kind of armor. Dumps a screen to build/mame/t1_fight.bin.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local E = {}
for line in io.lines("build/gfx/gfxequ.s") do
  local k, v = line:match("^(%S+)%s+equ%s+(%-?%d+)")
  if k then E[k] = tonumber(v) end
end
local I = dofile("build/gfx/icons.lua")
local problems = 0
local function check(ok, msg)
  if not ok then problems = problems + 1; print("  PROBLEM f=" .. G.f .. ": " .. msg) end
end
local W = V.MAPW
local function free(c, r)
  return c > 0 and r > 0 and c < W - 1 and r < V.MAPH - 1 and
    mem:read_u8(V.PASSW + r * W + c) == 0 and mem:read_u16(V.OCC + 2 * (r * W + c)) == 0
end
local function find(spr)
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    if G.w(V.USPR, i) == spr and G.w(V.UFLAGS, i) & V.F_DEAD == 0 then return i end
  end
end
local function stats(tag, i)
  print(string.format("  %-15s unit %2d hp=%d range=%d damage=%d rate=%d speed=%d class=%d",
    tag, i, G.w(V.UMAXHP, i), G.w(V.URANGE, i), G.w(V.UDMG, i), G.w(V.URATE, i),
    G.w(V.USPD, i), G.w(V.UCLASS, i)))
end
local BAR = {2, 21}
local buggy, rocket

G.at(700, function() G.seeall() end)
G.quickbuild(705, I.bar_p, BAR[1], BAR[2], 2)            -- a barracks, then
G.quickbuild(760, I.fact_p, 5, 16, 2)                    --   a war factory
G.click(815, I.buggy_p[1], I.buggy_p[2])                -- a buggy
G.at(1130, function()
  buggy = find(E.SPR_BUGGY_P)
  check(buggy, "buggy built")
  if buggy then
    stats("buggy", buggy)
    check(G.w(V.UMAXHP, buggy) == 90 and G.w(V.URANGE, buggy) == 2 and G.w(V.USPD, buggy) == 0
      and G.w(V.UCLASS, buggy) == 1 + 1 * 4, "buggy stats")
  end
end)

-- speed: the buggy and then a tank, put at the start of 7 open tiles in a
-- row on screen, drive to the end; game frames per tile (the buggy moves
-- every frame, the tank every other one: 8 and 16)
local watch, changes, lasttile
local function openrow()
  for r = 13, 22 do for c = 1, 9 do
    local ok = true
    for k = 0, 6 do ok = ok and free(c + k, r) end
    if ok then return c, r end
  end end
end
local function speedtest(f0, unit, tag, want)
  local c, r
  G.at(f0 - 2, function() c, r = openrow(); G.teleport(unit(), c, r) end)
  G.at(f0, function() local x, y = G.unitxy(unit()); G.click(f0 + 1, x, y) end)
  G.at(f0 + 15, function()
    local x, y = G.tilexy(c + 6, r); G.click(f0 + 16, x, y)
    watch, changes, lasttile = unit(), {}, G.w(V.UTILE, unit())
  end)
  G.at(f0 + 140, function()
    -- (a sample may fall in the middle of the unit's update: each change
    -- is seen within a frame, so take the average)
    local avg = (changes[#changes] - changes[1]) / (#changes - 1)
    print(string.format("  %-6s %d tiles, %.1f game frames a tile (want %d)", tag, #changes, avg, want))
    check(#changes >= 4 and math.abs(avg - want) <= 0.5, tag .. " speed")
    watch = nil
  end)
end
speedtest(1140, function() return buggy end, "buggy", 8)
G.click(1245, I.rock_p[1], I.rock_p[2])                 -- a rocket soldier
speedtest(1300, function() return 1 end, "tank", 16)
G.at(1600, function()
  rocket = find(E.SPR_ROCK_P)
  check(rocket, "rocket soldier built")
  if rocket then
    stats("rocket soldier", rocket)
    check(G.w(V.UMAXHP, rocket) == 30 and G.w(V.URANGE, rocket) == 4 and G.w(V.USPD, rocket) == 3
      and G.w(V.UCLASS, rocket) == 0 + 2 * 4, "rocket soldier stats")
  end
end)

-- fights: shooter and target next to each other far from everyone, or
-- the shooter near the enemy barracks; the target's first loss of hit
-- points is one shot
local used = {}
local function spot()
  for r = 9, 15 do for c = 8, 22 do
    local ok = free(c, r) and free(c + 1, r)
    for _, u in ipairs(used) do
      if math.abs(u[1] - c) + math.abs(u[2] - r) < 8 then ok = false end
    end
    if ok then used[#used + 1] = {c, r}; return c, r end
  end end
end
local function fight(f0, tag, shooter, target, want, near)
  local hp0, done
  G.at(f0, function()
    local s, t = shooter(), target()
    G.sw(V.UHP, s, G.w(V.UMAXHP, s))                -- (whole again, and nobody
    local n = G.w(V.NUNITS) // 2                     --  still after it)
    for i = 0, n - 1 do
      if G.w(V.UTARGET, i) == 2 * s then
        G.sw(V.UTARGET, i, 0xFFFF); G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) & ~V.F_CHASE)
      end
    end
    if near then
      local tc, tr = G.tile(t)
      local best
      for r = tr - 4, tr + 4 do for c = tc - 4, tc + 4 do
        if free(c, r) and math.abs(c - tc) + math.abs(r - tr) >= 3 and not best then best = {c, r} end
      end end
      G.teleport(s, best[1], best[2])
    else
      local c, r = spot()
      G.teleport(s, c, r); G.teleport(t, c + 1, r)
      G.sw(V.UTARGET, t, 0xFFFF)
    end
    G.sw(V.UTARGET, s, 2 * t); G.sw(V.URELOAD, s, 0)
    G.sw(V.UFLAGS, s, G.w(V.UFLAGS, s) | V.F_CHASE)
    hp0 = G.s16(G.w(V.UHP, t))
  end)
  for k = 1, 120 do
    G.at(f0 + k, function()
      local t = target()
      local hp = G.s16(G.w(V.UHP, t))
      if not done and hp ~= hp0 then
        done = true
        print(string.format("  %-28s hit for %3d (want %d)", tag, hp0 - hp, want))
        check(hp0 - hp == want, tag)
        local s = shooter()                          -- done: the shooter
        G.sw(V.UTARGET, s, 0xFFFF)                   -- goes home before it
        G.sw(V.UFLAGS, s, G.w(V.UFLAGS, s) & ~V.F_CHASE)   -- gets shot
        G.sw(V.UTARGET, t, 0xFFFF)
        for r = 21, 14, -1 do for c = 9, 14 do
          if s and free(c, r) then G.teleport(s, c, r); s = nil end
        end end
      end
      if k == 120 and not done then check(false, tag .. ": no hit") end
    end)
  end
end
local function unit(i) return function() return i end end
fight(1650, "buggy vs soldier", function() return buggy end, unit(7), 10)
fight(1800, "buggy vs tank", function() return buggy end, unit(5), 2)
fight(1950, "rocket soldier vs tank", function() return rocket end, unit(6), 30)
fight(2100, "rocket soldier vs soldier", function() return rocket end, unit(8), 5)
fight(2250, "tank vs soldier", unit(1), unit(9), 15)
fight(2400, "rocket soldier vs barracks", function() return rocket end,
  function() return G.w(V.BARUNIT) // 2 end, 22, true)
G.at(2402, function() G.look(16, 0) end)
G.at(2430, function() G.dump("t1_fight"); G.units("fights") end)
G.at(2560, function() print("problems: " .. problems) end)
G.run(2565, function(f)
  if f > 700 then mem:write_u16(V.AICREDITS, 0) end      -- no new enemies
  if watch then
    local t = G.w(V.UTILE, watch)
    if t ~= lasttile then lasttile = t; changes[#changes + 1] = G.w(V.FRAME) end
  end
end)
