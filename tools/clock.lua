-- Test clock shared by the MAME scripts: counts video frames, but holds at
-- START - 1 until the game runs (its GAMEGO marker), so the game starts at
-- about frame START however long loading takes and the scripts' frame
-- numbers keep their meaning. It also skips the title picture (clears
-- TITLEWAIT) unless SHOWTITLE is set, and the options screen whenever it
-- comes up (clears OPTWAIT) unless SHOWOPTIONS is set, having chosen
-- DIFFICULTY (0 easy, 1 normal, 2 hard: the default, how the enemy played
-- before there was a choice), MAP (0 or 1, default 0) and the music off
-- (MUSIC=1 keeps it on).
-- Usage:  local tick = dofile("tools/clock.lua")
--         in the frame notifier: local nf = tick(); if nf == f then return end; f = nf
local START = 660
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local V = dofile("tools/vars.lua")
local skiptitle = os.getenv("SHOWTITLE") == nil
local skipopts = os.getenv("SHOWOPTIONS") == nil
local diff = tonumber(os.getenv("DIFFICULTY") or "2")
local mapno = tonumber(os.getenv("MAP") or "0")
local musicoff = os.getenv("MUSIC") and 0 or 1
local f, started = 0, false
return function()
  if skipopts then
    if not started then
      mem:write_u16(V.DIFF, diff)
      mem:write_u16(V.MAPNO, mapno)
      mem:write_u16(V.MUSICOFF, musicoff)
    end
    mem:write_u16(V.OPTWAIT, 0)
  end
  if not started then
    if skiptitle then mem:write_u16(V.TITLEWAIT, 0) end
    if mem:read_u16(V.GAMEGO) == 0xC0DE then
      started = true
      if f < START - 1 then f = f + 1 else f = START end
      return f
    end
    if f >= START - 1 then return f end        -- loading: wait
  end
  f = f + 1
  return f
end
