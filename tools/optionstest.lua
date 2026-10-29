-- Options screen test (counts raw video frames; skips the title): the
-- options screen must look exactly like build/gfx/options_expected.bin
-- (but under the arrow), the title tune playing; clicking HARD and the map
-- (the next one) must show as in options_expected2.bin; the arrows must go
-- back and forth through the maps, round from the first to the last; then
-- with the second map again, clicking music OFF must stop the tune and
-- press that button (options_expected3.bin); START must begin a game on
-- that map at that difficulty, without music. Then the game is ended: a click must
-- bring the options back with the same choices, and RETURN must start the
-- next game.
local V = dofile("tools/vars.lua")
local O = dofile("build/gfx/options.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local function load(name) local fh = io.open(name, "rb"); local d = fh:read("a"); fh:close(); return d end
local want1 = load("build/gfx/options_expected.bin")
local want2 = load("build/gfx/options_expected2.bin")
local want3 = load("build/gfx/options_expected3.bin")
local f, problems, phase, t0 = 0, 0, "title", 0

-- screen bytes that differ from want, leaving out the arrow's square
local function differ(want)
  local cx, cy = mem:read_u16(V.CX), mem:read_u16(V.CY)
  local ax, ay = math.min(cx, 304) // 2, math.min(cy, 184)
  local n = 0
  for y = 0, 199 do
    for x = 0, 159 do
      if not (y >= ay and y < ay + 16 and x >= ax and x < ax + 8) and
         mem:read_u8(0xE12000 + y * 160 + x) ~= want:byte(y * 160 + x + 1) then n = n + 1 end
    end
  end
  return n
end
local function dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
local function area(act, press, nth)          -- (the nth with that action)
  local n = 0
  for _, a in ipairs(O.areas) do
    if a.act == act and (press == nil or a.press == press) then
      n = n + 1
      if n == (nth or 1) then return (a.x0 + a.x1) // 2, (a.y0 + a.y1) // 2 end
    end
  end
end
local function mapno(tag, want)
  local m = mem:read_u16(V.MAPNO)
  print(string.format("%-34s map %d %s", tag, m, m == want and "as expected" or "WRONG (want " .. want .. ")"))
  if m ~= want then problems = problems + 1 end
end
local clicks = {}
local function click(at, x, y)
  clicks[at] = function() mem:write_u16(V.CX, x); mem:write_u16(V.CY, y) end
  clicks[at + 3] = function() btn:set_value(1) end
  clicks[at + 9] = function() btn:clear_value() end
end
local function check(tag, want)
  local d = differ(want)
  print(string.format("%-34s %s (%d bytes differ)", tag, d == 0 and "as expected" or "WRONG", d))
  if d ~= 0 then problems = problems + 1 end
end

sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  if clicks[f] then clicks[f](); clicks[f] = nil end
  if phase == "title" then
    mem:write_u16(V.TITLEWAIT, 0)
    if mem:read_u16(V.OPTWAIT) == 1 then
      phase, t0 = "options", f
      print("options screen at frame " .. f)
      click(t0 + 12, area(2))                  -- HARD
      click(t0 + 30, area(17, 0))              -- the map: the next one
      click(t0 + 52, area(16))                 -- the left arrow: back
      click(t0 + 70, area(16))                 -- and round to the last
      click(t0 + 92, area(17, 0, 3))           -- the right arrow: round to
      click(t0 + 110, area(17, 0, 3))          --   the first, the second
      click(t0 + 130, area(50))                -- music: volume 2
      click(t0 + 152, area(57))                -- effects: volume 1
      click(t0 + 175, area(48))                -- music OFF
      click(t0 + 197, area(32))                -- START
    end
  elseif phase == "options" then
    if f == t0 + 10 then
      check("at first (NORMAL, GREEN VALLEY):", want1); dump("o0_options")
      local on = mem:read_u16(V.MUSICON) == 1
      print("  the title tune playing: " .. (on and "yes" or "NO"))
      if not on then problems = problems + 1 end
    end
    if f == t0 + 48 then check("HARD and RIVER CROSSING pressed:", want2); dump("o1_chosen") end
    if f == t0 + 66 then mapno("left arrow:", 0) end
    if f == t0 + 88 then mapno("left arrow again:", 3); dump("o1_last") end
    if f == t0 + 106 then mapno("right arrow:", 0) end
    if f == t0 + 126 then mapno("right arrow again:", 1) end
    if f == t0 + 148 then
      local ok = mem:read_u16(V.MUSVOL) == 2 and mem:read_u16(V.MUSICOFF) == 0 and
                 mem:read_u16(V.MUSICON) == 1
      print("  music volume 2, playing: " .. (ok and "yes" or "NO"))
      if not ok then problems = problems + 1 end
    end
    if f == t0 + 170 then
      local ok = mem:read_u16(V.SFXVOL) == 1
      print("  effects volume 1: " .. (ok and "yes" or "NO"))
      if not ok then problems = problems + 1 end
    end
    if f == t0 + 193 then
      check("music OFF pressed (effects at 1):", want3)
      local off = mem:read_u16(V.MUSICON) == 0 and mem:read_u16(V.MUSICOFF) == 1
      print("  the tune stopped: " .. (off and "yes" or "NO"))
      if not off then problems = problems + 1 end
    end
    if mem:read_u16(V.GAMEGO) == 0xC0DE then
      local dock, aimax = mem:read_u16(V.DOCK), mem:read_u16(V.AIMAX)
      local ok = dock == 18 * 32 + 25 and aimax == 8 and mem:read_u16(V.DIFF) == 2
      print(string.format("game started %d frames after START: dock tile %d, enemy at most %d units: %s",
        f - (t0 + 200), dock, aimax, ok and "RIVER CROSSING at HARD" or "WRONG"))
      local quiet = mem:read_u16(V.MUSICON) == 0
      print("  no battle tune (music off): " .. (quiet and "yes" or "NO"))
      if not quiet then problems = problems + 1 end
      phase, t0 = "game", f
      if not ok then problems = problems + 1 end
    end
  elseif phase == "game" then
    if f == t0 + 60 then dump("o2_game") end
    if f == t0 + 70 then                       -- the game ends (a win)
      mem:write_u16(V.GAMEOVER, 1); mem:write_u16(V.NEWBANNER, 1)
    end
    if f == t0 + 100 then click(f + 1, 160, 100) end
    if f > t0 + 100 and mem:read_u16(V.OPTWAIT) == 1 then
      phase, t0 = "again", f
      print("options again after the end, at frame " .. f)
    end
    if f == t0 + 400 then print("no options screen after the end"); problems = problems + 1; phase = "done" end
  elseif phase == "again" then
    if f == t0 + 10 then check("the same choices:", want3) end
    if f == t0 + 12 then
      local ok = pcall(function() manager.machine.natkeyboard:post("\r") end)
      print("RETURN pressed" .. (ok and "" or " (could not post it)"))
    end
    if f > t0 + 12 and mem:read_u16(V.OPTWAIT) == 0 then
      phase, t0 = "next", f
      print(string.format("RETURN started the next game (dock tile %d)", mem:read_u16(V.DOCK)))
    end
    if f == t0 + 200 then print("RETURN did not start the game"); problems = problems + 1; phase = "done" end
  elseif phase == "next" then
    if f == t0 + 60 then
      local running = mem:read_u16(V.GAMEOVER) == 0 and mem:read_u16(V.DOCK) == 18 * 32 + 25
      print("next game runs on the same map: " .. (running and "yes" or "NO"))
      if not running then problems = problems + 1 end
      phase = "done"
    end
  end
  if phase == "done" or f == 6000 then
    if f == 6000 then print("gave up in phase " .. phase); problems = problems + 1 end
    print("problems: " .. problems)
    manager.machine:exit()
  end
end)
