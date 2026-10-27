-- Scrolling test (milestone 8): hold the mouse at the right edge of the
-- screen, then click the radar on the enemy base, then send a tank
-- there across the world. Prints the view and timing as it goes.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, steps, last = 0, {}, nil
local function w(addr, i) return mem:read_u16(addr + 2 * (i or 0)) end
local function at(x, y) mem:write_u16(V.CX, x); mem:write_u16(V.CY, y) end
local function dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
local function view(tag)
  print(string.format("%-14s f=%5d game=%5d view=(%d,%d)", tag, f, w(V.FRAME), w(V.CAMX), w(V.CAMY)))
end
local function tank(tag)
  local t = w(V.UTILE, 0)
  print(string.format("%-14s f=%5d tank0 tile=(%d,%d) goal=%04X job=%04X hp=%d target=%04X", tag, f,
    t % 32, t // 32, w(V.UGOAL, 0), w(V.JOBUNIT), (w(V.UHP, 0) + 32768) % 65536 - 32768,
    w(V.UTARGET, 0)))
end
local function click(x, y, t)
  steps[t] = function() at(x, y) end
  steps[t + 3] = function() btn:set_value(1) end
  steps[t + 7] = function() btn:clear_value() end
end
steps[700] = function() view("start"); dump("s0_start") end
steps[705] = function() at(319, 100) end                  -- right edge
for t = 710, 830, 20 do steps[t] = function() view("scrolling") end end
steps[840] = function() at(160, 100); view("stopped"); dump("s1_right") end
click(264 + 40, 20 + 6, 850)                              -- radar: enemy base
steps[870] = function() view("radar jump"); dump("s2_radar") end
-- select tank 0: jump back home first
click(264 + 4, 20 + 30, 880)
steps[900] = function() view("home again")
  local sx = w(V.UX, 0) - w(V.VIEWX); local sy = w(V.UY, 0) - w(V.VIEWY)
  steps[905] = function() at(sx + 8, sy + 8) end
end
steps[908] = function() btn:set_value(1) end
steps[912] = function() btn:clear_value() end
click(264 + 40, 20 + 6, 920)                              -- view the enemy base
steps[940] = function() at(100, 120) end                  -- and click near it
steps[943] = function() btn:set_value(1) end
steps[947] = function() btn:clear_value(); tank("ordered") end
for t = 1000, 3000, 250 do steps[t] = function() tank("travel") end end
steps[3005] = function() dump("s3_arrived"); manager.machine:exit() end
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end       -- still loading
  f = nf
  if f >= 600 then mem:write_u16(V.AICREDITS, 0) end
  if f == 700 then mem:write_u16(V.RADARALL, 1); mem:write_u16(V.RADARON, 1) end   -- (radar on)
  if steps[f] then steps[f]() end
end)
