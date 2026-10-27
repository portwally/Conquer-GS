-- Scripted AI test (milestone 5): the player does nothing; watch the
-- enemy build and attack until the game ends, then click to restart.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, ended = 0, nil
local firstwave, firsthit, lasthit
local function w(addr, i) return mem:read_u16(addr + 2 * (i or 0)) end
local function hp(i) return (w(V.UHP, i) + 32768) % 65536 - 32768 end
local function dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
-- what the enemy built, by sprite (each new unit counted once: by slot and
-- the frame it was first seen there)
local E = {}
for line in io.lines("build/gfx/gfxequ.s") do
  local k, v = line:match("^(SPR_%S+_E)%s+equ%s+(%d+)")
  if k then E[tonumber(v)] = k:sub(5):lower() end
end
local seen, built = {}, {}
local function census()
  local n = w(V.NUNITS) // 2
  for i = 0, n - 1 do
    local fl = w(V.UFLAGS, i)
    local key = i .. ":" .. w(V.USPR, i)
    if fl & (V.F_AI | V.F_DEAD) == V.F_AI and not seen[key] then
      seen[key] = true
      local name = E[w(V.USPR, i)] or tostring(w(V.USPR, i))
      built[name] = (built[name] or 0) + 1
    elseif fl & V.F_DEAD ~= 0 then
      seen[i .. ":" .. w(V.USPR, i)] = nil
    end
  end
end
local function builtlist()
  local t = {}
  for k, v in pairs(built) do t[#t + 1] = k .. " " .. v end
  table.sort(t)
  return table.concat(t, ", ")
end
local function summary(tag)
  local n = w(V.NUNITS) // 2
  local pl, en, ai, amove = 0, 0, 0, 0
  for i = 0, n - 1 do
    local fl = w(V.UFLAGS, i)
    if fl & V.F_DEAD == 0 and fl & V.F_BUILDING == 0 then
      if fl & V.F_PLAYER ~= 0 then pl = pl + 1 else en = en + 1 end
      if fl & V.F_AI ~= 0 then ai = ai + 1 end
      if fl & V.F_AMOVE ~= 0 then amove = amove + 1 end
    end
  end
  print(string.format("%-8s f=%5d game=%5d slots=%2d player=%d enemy=%d (built %d, attacking %d) wave=%d aicredits=%4d building=%s HQ hp=%d barracks hp=%d over=%d",
    tag, f, w(V.FRAME), n, pl, en, ai, amove, w(V.WAVESIZE), w(V.AICREDITS),
    w(V.AIBUILD) == 0xFFFF and "-" or tostring(w(V.AIBUILD)),
    hp(w(V.HQUNIT) // 2), hp(w(V.BARUNIT) // 2), w(V.GAMEOVER)))
end
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end       -- still loading
  f = nf
  if f >= 700 and f % 600 == 0 then summary("tick") end
  if f > 700 and not ended then census() end
  if f > 700 and not firstwave then                -- the pace
    local n = w(V.NUNITS) // 2
    for i = 0, n - 1 do
      if w(V.UFLAGS, i) & (V.F_AMOVE | V.F_DEAD) == V.F_AMOVE then
        firstwave = w(V.FRAME)
        print(string.format("first wave leaves at game frame %d (%.0f s)", firstwave, firstwave / 60))
        break
      end
    end
  end
  -- (two frames in a row: a frame can end in the middle of the screen
  -- copy, when a read here sees the wrong memory bank)
  local hit = hp(w(V.HQUNIT) // 2) < 400
  if f > 700 and not firsthit and hit and lasthit then
    firsthit = w(V.FRAME)
    print(string.format("command center first hit at game frame %d (%.0f s)", firsthit, firsthit / 60))
  end
  lasthit = hit
  if f == 3000 then dump("a0_wave") end
  if not ended and f > 700 and w(V.GAMEOVER) ~= 0 then
    ended = f
    summary("ENDED")
    print(string.format("game over at game frame %d (%.0f s)", w(V.FRAME), w(V.FRAME) / 60))
    print("enemy built: " .. builtlist())
  end
  if ended and f == ended + 120 then dump("a1_end") end
  if ended and f == ended + 130 then btn:set_value(1) end
  if ended and f == ended + 135 then btn:clear_value() end
  if ended and f == ended + 300 then summary("restart"); dump("a2_restart") end
  if (ended and f == ended + 305) or f == 30000 then
    if not ended then summary("timeout") end
    manager.machine:exit()
  end
end)
