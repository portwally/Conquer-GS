-- Stress test: the enemy gets plenty of money and fills the map; every 4
-- seconds all of the player's units are selected and sent across the map
-- (alternating targets), so many units plan routes and move at once.
-- Bases and the player's units are kept at full health so it never ends;
-- with STRESS_ALL set, enemy units too, so all the unit slots fill up.
-- Prints the frame rate every 300 frames and the worst stretch.
-- STRESS_NOFOG lifts the fog of war at the start.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, last, worst, low = 0, 0, 99, 0
local stop = tonumber(os.getenv("STRESS_END") or "9000")
local everyone = os.getenv("STRESS_ALL") ~= nil   -- enemy units immortal too: the map fills up
local function w(addr, i) return mem:read_u16(addr + 2 * (i or 0)) end
local targets = {{60, 150}, {200, 50}, {120, 180}, {40, 40}}
local nextt = 1
local function census()
  local n, pl, en, mv = w(V.NUNITS) // 2, 0, 0, 0
  for i = 0, n - 1 do
    local fl = w(V.UFLAGS, i)
    if fl & V.F_DEAD == 0 and fl & V.F_BUILDING == 0 then
      if fl & V.F_PLAYER ~= 0 then pl = pl + 1 else en = en + 1 end
      if mem:read_u16(V.UNEXT + 2 * i) ~= 0xFFFF then mv = mv + 1 end
    end
  end
  return pl, en, mv
end
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end       -- still loading
  f = nf
  if f >= 700 then                               -- unlimited money, no pauses
    mem:write_u16(V.AICREDITS, 5000)               -- between waves, no cap
    mem:write_u16(V.AIWAIT, 0); mem:write_u16(V.AIMAX, V.MAXUNITS)
  end
  if f == 700 then mem:write_u16(V.RADARALL, 1); mem:write_u16(V.RADARON, 1) end   -- (radar on)
  if f == 700 and os.getenv("STRESS_NOFOG") then mem:write_u16(V.SEEALL, 1) end
  if f >= 700 then                               -- nobody wins: keep the
    mem:write_u16(V.UHP + w(V.HQUNIT), 400)        -- bases and the player's
    mem:write_u16(V.UHP + w(V.BARUNIT), 300)       -- units at full health
    local n = w(V.NUNITS) // 2
    for i = 0, n - 1 do
      local fl = w(V.UFLAGS, i)
      if (fl & V.F_PLAYER ~= 0 or everyone) and fl & (V.F_DEAD | V.F_BUILDING) == 0 then
        mem:write_u16(V.UHP + 2 * i, w(V.UMAXHP, i))
      end
    end
  end
  if f >= 1500 and f % 240 == 0 then            -- select all, order a move
    local n = w(V.NUNITS) // 2
    for i = 0, n - 1 do
      local fl = w(V.UFLAGS, i)
      if fl & V.F_PLAYER ~= 0 and fl & (V.F_DEAD | V.F_BUILDING) == 0 then
        mem:write_u16(V.UFLAGS + 2 * i, fl | V.F_SEL | 0x8000)
      end
    end
    local t = targets[nextt]; nextt = nextt % #targets + 1
    mem:write_u16(V.CX, t[1]); mem:write_u16(V.CY, t[2])
  end
  if f >= 1500 and f % 240 == 4 then btn:set_value(1) end
  if f >= 1500 and f % 240 == 8 then btn:clear_value() end
  if f == 900 then last = w(V.FRAME) end
  if f > 900 and f % 300 == 0 then
    local g = w(V.FRAME)
    local fps = (g - last) % 65536 / 5
    last = g
    local pl, en, mv = census()
    print(string.format("f=%5d fps=%4.1f player=%2d enemy=%2d moving=%2d", f, fps, pl, en, mv))
    if fps < worst then worst = fps end
  end
  if f == stop then
    print(string.format("worst 5-second stretch: %.1f fps", worst))
    manager.machine:exit()
  end
end)
