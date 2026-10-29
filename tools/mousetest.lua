-- Mouse test: the emulator's mouse moved steadily (right and down, then
-- left and up) must move the arrow every frame - no frame standing still,
-- none jumping more than twice the average (the game smooths the uneven
-- way the movement arrives) - and once the mouse stops, the arrow must
-- stop a few frames later with all of the movement applied: none still
-- to come (mhist, mhisty), less than a pixel kept for the next (macc).
-- Then shaking fast right and left, up to 90 a frame - more than the
-- mouse's 7 bits hold: MAME wraps it, the game must undo that - the
-- arrow never against the hand's way, never up or down.
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
-- fast: shaking right and left, the speed rising to 90 a frame and
-- falling smoothly - more than the mouse's 7 bits hold, which MAME wraps
-- (the game must undo that): the arrow must never jump against the
-- hand's way (beyond the smoothing's lag), nor up or down
local SPEEDS = {}
for k = 0, 59 do SPEEDS[k] = math.floor(90 * math.sin(2 * math.pi * k / 12) + 0.5) end
local fy0, wrong, prev, worst = 0, 0, nil, 0
G.at(900, function() G.mouse(160, 100) end)
G.at(910, function() fy0 = G.w(V.CY) end)
for k = 0, 59 do
  G.at(911 + k, function() mx = mx + SPEEDS[k]; ax:set_value(mx) end)
end
G.run(1030, function(f)
  if f > 913 and f < 972 then
    local x = G.w(V.CX)
    if prev and x > 0 and x < 319 and prev > 0 and prev < 319 then
      local v = SPEEDS[f - 913] + SPEEDS[f - 914]   -- (the hand, 2 frames back)
      local d = x - prev
      if (v > 60 and d < -8) or (v < -60 and d > 8) then
        wrong = wrong + 1; worst = math.max(worst, math.abs(d))
      end
    end
    prev = x
  end
end)
G.at(990, function()
  print("-- fast, shaking right and left")
  check(wrong == 0, string.format("never against the hand (%d frames, %d at most)", wrong, worst))
  check(G.w(V.CY) == fy0, "nor up or down")
end)
G.at(1000, function()
  local left = 0                            -- (movement still to come;
  for k = 0, 5 do left = left + math.abs(G.s16(G.w(V.MHIST, k))) end   -- under
  local part = math.max(G.w(V.MACC, 0), G.w(V.MACC, 1))   -- a pixel kept for later)
  check(left == 0 and part < 4,
    string.format("all the movement applied (%d to come, %d/4 pixel kept)", left, part))
  print("problems: " .. problems)
end)
