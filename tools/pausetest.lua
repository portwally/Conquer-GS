-- Space and pause test. Space: no unit selected, selling mode off, a ready
-- structure no longer being placed (still ready). P: the game stops (its
-- frame count, a moving tank, the music) under the pause panel, exactly
-- as unpacked (but under the arrow); RESUME goes on (the panel gone, the
-- music back), so does Space; QUIT MISSION goes back to the mission
-- setup, and a new game starts from there. Run with SHOWOPTIONS=1 (the
-- script lets the first setup screen go itself, and waits for the second
-- one).
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local I = dofile("build/gfx/icons.lua")
local E = {}
for line in io.lines("build/gfx/gfxequ.s") do
  local k, v = line:match("^(%S+)%s+equ%s+(%-?%d+)")
  if k then E[k] = tonumber(v) end
end
local problems = 0
local function check(ok, msg)
  print(string.format("  %-52s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function key(k) manager.machine.natkeyboard:post(k) end
local function selected()
  local n = 0
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    if G.w(V.UFLAGS, i) & V.F_SEL ~= 0 then n = n + 1 end
  end
  return n
end
-- the pause panel on the screen: bytes that differ from its layer (in the
-- win banner's bank at +$8000), but under the arrow
local function paneldiff()
  local cx, cy = G.w(V.CX), G.w(V.CY)
  local n = 0
  for y = E.BANNERY0, E.BANNERY1 - 1 do
    for b = E.BANNERX0 // 2, E.BANNERX1 // 2 - 1 do
      local under = y >= cy - 1 and y < cy + 17 and b * 2 >= cx - 2 and b * 2 < cx + 18
      if not under and mem:read_u8(0xE12000 + y * 160 + b) ~=
         mem:read_u8(V.WINBANK * 0x10000 + 0xA000 + y * 160 + b) then n = n + 1 end
    end
  end
  return n
end

-- the first setup screen goes by itself, the one after QUIT MISSION waits
local quitting, back = false, nil
local raw = 0
optsub = emu.add_machine_frame_notifier(function()
  raw = raw + 1
  if not quitting and mem:read_u16(V.OPTWAIT) == 1 then mem:write_u16(V.OPTWAIT, 0) end
end)

-- Space
G.at(700, function() if G.w(V.MUSICON) == 0 then key("m") end end)   -- music on
G.at(705, function() local x, y = G.unitxy(0); G.click(706, x, y) end)
G.at(720, function()
  print("-- Space")
  check(selected() == 1, "a tank selected")
  key(" ")
end)
G.at(735, function() check(selected() == 0, "Space: none selected") end)
local SELLBTN = {(E.SELLX0 + E.SELLX1) // 2, (E.BTNY0 + E.BTNY1) // 2}
G.click(740, SELLBTN[1], SELLBTN[2])
G.at(755, function() check(G.w(V.CMDMODE) == E.MODE_SELL, "selling mode on"); key(" ") end)
G.at(770, function() check(G.w(V.CMDMODE) == 0, "Space: selling mode off") end)
G.click(775, I.pp_p[1], I.pp_p[2])                       -- a power plant,
G.at(790, function() G.sw(V.QSEG, 0, E.BARSEGS) end)     --   ready at once
G.click(800, I.pp_p[1], I.pp_p[2])                       -- placing it
G.at(812, function() G.mouse(100, 100) end)
G.at(820, function() check(G.w(V.PLACING) == 1, "placing a structure"); key(" ") end)
G.at(835, function()
  check(G.w(V.PLACING) == 0 and G.w(V.QREADY) ~= 0, "Space: not placing, still ready")
end)

-- pause
local frame0, x0, y0
G.at(840, function() local x, y = G.unitxy(0); G.click(841, x, y) end)
G.at(855, function() local x, y = G.tilexy(12, 20); G.click(856, x, y) end)   -- tank 0 off
G.at(880, function()
  print("-- pause")
  check(G.w(V.MUSICON) == 1, "music playing")
  key("p")
end)
G.at(895, function()
  check(G.w(V.PAUSED) == 1, "P: paused")
  check(G.w(V.MUSICON) == 0, "the music stopped")
  frame0, x0, y0 = G.w(V.FRAME), G.w(V.UX, 0), G.w(V.UY, 0)
  G.mouse(30, 40)
end)
G.at(960, function()
  check(G.w(V.FRAME) == frame0, "the game's frame count stands still")
  check(G.w(V.UX, 0) == x0 and G.w(V.UY, 0) == y0, "the tank stands still")
  local d = paneldiff()
  check(d == 0, string.format("the pause panel on the screen (%d bytes differ)", d))
  G.dump("u0_paused")
  G.click(961, (E.PRESX0 + E.PRESX1) // 2, (E.PBTNY0 + E.PBTNY1) // 2)   -- RESUME
end)
G.at(990, function()
  check(G.w(V.PAUSED) == 0, "RESUME: going on")
  check(G.w(V.FRAME) > frame0, "the frame count goes on")
  check(G.w(V.MUSICON) == 1, "the music back")
  check(paneldiff() > 500, "the panel gone")
  key("p")
end)
G.at(1010, function()
  check(G.w(V.PAUSED) == 1, "P again: paused")
  key(" ")
end)
G.at(1030, function()
  check(G.w(V.PAUSED) == 0, "Space: going on")
  key("p")
end)
G.at(1050, function()
  check(G.w(V.PAUSED) == 1, "P again: paused")
  quitting = true
  G.click(1051, (E.PQUITX0 + E.PQUITX1) // 2, (E.PBTNY0 + E.PBTNY1) // 2)   -- QUIT
end)
G.run(1600, function(f)
  if quitting and not back and mem:read_u16(V.OPTWAIT) == 1 then
    back = f
    print("-- QUIT MISSION")
    check(true, string.format("the mission setup again, %d frames later", f - 1051))
    check(G.w(V.PAUSED) == 0, "not paused any more")
    mem:write_u16(V.OPTWAIT, 0)                            -- START
  end
  if back and f == back + 200 then
    check(G.w(V.GAMEGO) == 0xC0DE and G.w(V.GAMEOVER) == 0 and G.w(V.FRAME) < 400,
      "a new game runs")
    print("problems: " .. problems)
  end
  if f == 1599 and not back then check(false, "back to the mission setup"); print("problems: " .. problems) end
end)
