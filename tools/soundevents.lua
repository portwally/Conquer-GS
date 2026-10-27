-- Sound events test: which sounds the game starts during play, read from
-- its writes to the sound GLU (an oscillator's control register written
-- with the halt bit clear = that sound starts). A fight on screen must be
-- heard (shots, the explosion), one off screen not; finished production
-- and a placed structure must chime and thud.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local I = dofile("build/gfx/icons.lua")
local names = {"cannon", "rifle", "mgun", "rocket", "boom", "ready", "place"}
local oscsound = {}             -- each sound's oscillators (makesound.py)
for _, n in ipairs(names) do
  local first, voices = V["SOSC_" .. n:upper()], V["SVOX_" .. n:upper()]
  for o = first, first + 2 * voices - 1 do oscsound[o] = n end
end
local adr, log, window = 0, {}, nil
local problems = 0
local function check(ok, msg) if not ok then problems = problems + 1; print("  PROBLEM: " .. msg) end end
tap = mem:install_write_tap(0xC03C, 0xC03F, "snd", function(offset, data)
  if offset == 0xC03E then adr = data & 0xFF
  elseif offset == 0xC03D and adr >= 0xA0 and adr <= 0xBF and data & 1 == 0 and data & 0x10 == 0 then
    local snd = oscsound[adr - 0xA0] or "music"
    if window then log[window][snd] = (log[window][snd] or 0) + 1 end
  end
end)
local function open(name) window = name; log[name] = {} end
local function heard(name)
  local t = {}
  for k, v in pairs(log[name]) do t[#t + 1] = k .. " x" .. v end
  table.sort(t)
  return log[name], (#t > 0 and table.concat(t, ", ") or "nothing")
end

-- on screen: enemy soldier 7 walks up to our tanks by the command center
G.at(700, function() G.seeall(); open("on screen") end)
G.at(705, function()
  G.teleport(7, 9, 18)
  G.sw(V.UTARGET, 0, 2 * 7); G.sw(V.UFLAGS, 0, G.w(V.UFLAGS, 0) | V.F_CHASE)
end)
G.at(1000, function()
  local l, s = heard("on screen")
  print("fight on screen: " .. s)
  check((l.cannon or 0) > 0 and (l.rifle or 0) > 0, "shots on screen heard")
  check((l.boom or 0) > 0, "the soldier's death heard")
  -- off screen: our soldier 3 among the enemies at their base (listening
  -- from a few frames later: until the screen is drawn again, the game
  -- still has the soldier where it was before the jump)
  window = nil
  G.teleport(3, 22, 8)
  G.sw(V.UTARGET, 3, 2 * 5); G.sw(V.UFLAGS, 3, G.w(V.UFLAGS, 3) | V.F_CHASE)
end)
G.at(1005, function() open("off screen") end)
G.at(1400, function()
  local l, s = heard("off screen")
  print("fight off screen: " .. s .. (G.w(V.UFLAGS, 3) & V.F_DEAD ~= 0 and " (our soldier died there)" or ""))
  check((l.cannon or 0) + (l.rifle or 0) + (l.boom or 0) == 0, "nothing heard from off screen")
  open("building")
end)
G.click(1405, I.tank_p[1], I.tank_p[2])                -- a tank (8 s)
G.click(1415, I.pp_p[1], I.pp_p[2])                    -- a power plant (6 s)
G.click(1820, I.pp_p[1], I.pp_p[2])                    -- place it
G.at(1830, function() G.clear(2, 16, 2) end)
G.at(1834, function() local x, y = G.tilexy(2, 16); G.click(1835, x + 8, y + 8) end)
G.at(2000, function()
  local l, s = heard("building")
  print("building: " .. s)
  check((l.ready or 0) == 2, "two chimes: the power plant ready, the tank out")
  check((l.place or 0) == 1, "one thud: the power plant placed")
  print("problems: " .. problems)
end)
G.run(2005, function(f) if f > 700 then mem:write_u16(V.AICREDITS, 0) end end)
