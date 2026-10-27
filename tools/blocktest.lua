-- Blocked units test. 1: a new buggy comes out of the war factory's door
-- (5,18; the barracks and the factory built at once first) boxed in by
-- parked units (two tanks, two soldiers) and walls (the
-- command center's pad, the factory); ordered east, the idle ones must
-- make way and it must get there. 2: a tank in a
-- pocket whose neighbors cannot move (held in place by the script) must
-- keep its order instead of giving up, and get through once they can.
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
local function tile(c, r) return r * W + c end
local function at(i) local c, r = G.tile(i); return string.format("(%d,%d)", c, r) end
local function around(tag)
  print(string.format("-- %s f=%d (unit numbers, # walls)", tag, G.f))
  for r = 16, 22 do
    local row = ""
    for c = 2, 14 do
      local o = mem:read_u16(V.OCC + 2 * tile(c, r))
      local p = mem:read_u8(V.PASSW + tile(c, r))
      row = row .. (o ~= 0 and string.format("%3d", o // 2 - 1) or (p ~= 0 and "  #" or "  ."))
    end
    print(string.format("  row %2d:%s", r, row))
  end
end
local function order(i, c, r, f)                -- select unit i alone, move it
  G.at(f, function() local x, y = G.unitxy(i); G.click(f + 1, x, y) end)
  G.at(f + 14, function() local x, y = G.tilexy(c, r); G.click(f + 15, x, y) end)
end
local function near(i, c, r)
  local uc, ur = G.tile(i)
  return math.abs(uc - c) <= 1 and math.abs(ur - r) <= 1
end

-- 1: out of the exit (as soon as the buggy is there)
local buggy, t0, t1, s3, s4
local held = {}
local function part2(f0)
  -- a pocket at the exit: the dock is walled off for the test, and the
  -- neighbors east, south and south-east are held (F_STATIC: cannot move)
  G.at(f0, function()
    G.teleport(0, 5, 20)
    G.teleport(1, 6, 20); G.teleport(3, 5, 21); G.teleport(4, 6, 21)
    held = {1, 3, 4}
    for _, i in ipairs(held) do G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) | V.F_STATIC) end
    mem:write_u8(V.PASSW + tile(5, 19), 1)
    around("pocket")
  end)
  order(0, 9, 18, f0 + 10)
  G.at(f0 + 280, function()
    local g = G.w(V.UGOAL, 0)
    print(string.format("  after 250 frames boxed in: tank0 at %s, goal %04X", at(0), g))
    check(g ~= 0xFFFF, "still wants to go")
    check(near(0, 5, 20), "still in the pocket")
    for _, i in ipairs(held) do G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) & ~V.F_STATIC) end
    mem:write_u8(V.PASSW + tile(5, 19), 0)
  end)
  G.at(f0 + 780, function()
    around("released")
    print("  tank0 at " .. at(0))
    check(near(0, 9, 18), "tank got through")
    G.dump("k1_through")
    print("problems: " .. problems)
    manager.machine:exit()
  end)
end
G.at(700, function() G.sw(V.USTATE, 2, 0); G.sw(V.UGOAL, 2, 0xFFFF) end)   -- (the
G.quickbuild(705, I.bar_p, 1, 16, 2)            -- harvester stays put) a barracks,
G.quickbuild(760, I.fact_p, 5, 16, 2)           --   then the war factory
G.at(815, function()                            -- park them around its door
  G.teleport(0, 6, 18); G.teleport(1, 5, 19); G.teleport(3, 6, 19); G.teleport(4, 4, 17)
end)
G.click(820, I.buggy_p[1], I.buggy_p[2])
local state, ordered = "wait", nil
G.run(4000, function(f)
  if f > 700 then mem:write_u16(V.AICREDITS, 0) end
  if state == "wait" and f > 900 then
    local n = G.w(V.NUNITS) // 2
    for i = 0, n - 1 do if G.w(V.USPR, i) == E.SPR_BUGGY_P then buggy = i end end
    if buggy then
      state = "part1"
      around("buggy (unit " .. buggy .. ") at the war factory's door")
      check(near(buggy, 5, 18), "it came out by the door")
      t0, t1, s3, s4 = G.w(V.UTILE, 0), G.w(V.UTILE, 1), G.w(V.UTILE, 3), G.w(V.UTILE, 4)
      ordered = f + 5
      order(buggy, 13, 20, ordered)
    end
  elseif state == "part1" and f > ordered + 20 then
    if near(buggy, 13, 20) or f > ordered + 400 then
      state = "part2"
      around("after the order")
      print(string.format("  buggy at %s after %d frames", at(buggy), f - ordered))
      check(near(buggy, 13, 20), "buggy got out and arrived")
      local moved = (G.w(V.UTILE, 0) ~= t0 and 1 or 0) + (G.w(V.UTILE, 1) ~= t1 and 1 or 0)
        + (G.w(V.UTILE, 3) ~= s3 and 1 or 0)
        + (G.w(V.UTILE, 4) ~= s4 and 1 or 0)
      print("  parked units that made way: " .. moved)
      check(moved > 0, "a parked unit made way")
      part2(f + 20)
    end
  end
  if f == 3999 then check(false, "did not finish"); print("problems: " .. problems) end
end)
