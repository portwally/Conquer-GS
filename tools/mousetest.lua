-- Mouse test: the emulator's mouse moved steadily (right and down, then
-- left and up) must move the arrow every frame - no frame standing still,
-- none jumping more than twice the average (the game smooths the uneven
-- way the movement arrives) - and once the mouse stops, the arrow must
-- stop a few frames later with all of the movement applied: none still
-- to come (mhist, mhisty), less than a pixel kept for the next (macc).
local G = dofile("tools/gs.lua")
local V = G.V
local problems = 0
local function check(ok, msg)
  print(string.format("  %-56s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local ax = manager.machine.ioport.ports[":macadb:MOUSE1"].fields["Mouse X"]
local ay = manager.machine.ioport.ports[":macadb:MOUSE2"].fields["Mouse Y"]
local mx, my, sx, sy, ex, ey = 0, 0, 0, 0, 0, 0
local log = {}
local function leg(f0, f1, dx, dy, name)
  G.at(f0, function() log = {}; sx, sy = G.w(V.CX), G.w(V.CY) end)
  for f = f0 + 1, f1 do
    G.at(f, function()
      mx, my = mx + dx, my + dy
      ax:set_value(mx); ay:set_value(my)
      log[#log + 1] = {G.w(V.CX), G.w(V.CY)}
    end)
  end
  G.at(f1 + 20, function()
    print("-- " .. name)
    local still, big, n, tot = 0, 0, 0, 0
    for i = 12, #log do                     -- (once under way)
      local d = math.abs(log[i][1] - log[i - 1][1]) + math.abs(log[i][2] - log[i - 1][2])
      if d == 0 then still = still + 1 end
      n, tot = n + 1, tot + d
      log[i].d = d
    end
    local avg = tot / n
    for i = 12, #log do if log[i].d > 2 * avg + 1 then big = big + 1 end end
    check(still == 0, string.format("the arrow moves every frame (%d frames still)", still))
    check(big == 0, string.format("no jumps (%d of %d frames over twice %.1f)", big, n, avg))
    ex, ey = G.w(V.CX), G.w(V.CY)
    local later = {G.w(V.CX), G.w(V.CY)}
    G.at(f1 + 40, function()
      check(G.w(V.CX) == later[1] and G.w(V.CY) == later[2], "then it stops")
    end)
  end)
end
G.at(700, function() G.mouse(60, 40) end)
leg(710, 760, 3, 2, "right and down")
leg(800, 850, -3, -2, "left and up")
G.at(900, function()
  local left = 0                            -- (movement still to come;
  for k = 0, 5 do left = left + math.abs(G.s16(G.w(V.MHIST, k))) end   -- under
  local part = math.max(G.w(V.MACC, 0), G.w(V.MACC, 1))   -- a pixel kept for later)
  check(left == 0 and part < 4,
    string.format("all the movement applied (%d to come, %d/4 pixel kept)", left, part))
  check(G.w(V.CX) > 0 and G.w(V.CX) < 319 and G.w(V.CY) > 0 and G.w(V.CY) < 199,
    string.format("(not held at an edge: %d,%d)", G.w(V.CX), G.w(V.CY)))
  print("problems: " .. problems)
end)
G.run(901)
