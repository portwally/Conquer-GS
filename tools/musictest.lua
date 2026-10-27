-- Title music test: waits at the title (it does not skip it as
-- tools/clock.lua does) until CLICK TO START is up and the music runs,
-- lets it play 32 seconds (over two loops), then clicks: the options
-- screen comes (the music plays on) and is done with (OPTWAIT cleared);
-- the game must start and the music stop; a second later it asks for a
-- sound effect,
-- which must still play (the music had the chip). Prints the times for
-- tools/musiccheck.py; run with -wavwrite <file>.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, started, clicked, problems = 0, nil, nil, 0
local function now() return manager.machine.time:as_double() end
sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  -- the music has started once its step counter moves (mtick wraps)
  if not started and mem:read_u16(V.TITLEWAIT) == 1 and mem:read_u16(V.MSTEP) == 2 then
    started = f
    print(string.format("music playing at %.4f s (step 2)", now()))
  end
  if started and f == started + 32 * 60 then
    print(string.format("click at %.4f s, still at the title: %s", now(),
      mem:read_u16(V.TITLEWAIT) == 1 and "yes" or "NO"))
    if mem:read_u16(V.TITLEWAIT) ~= 1 then problems = problems + 1 end
    btn:set_value(1)
  end
  if started and f == started + 32 * 60 + 6 then btn:clear_value(); clicked = f end
  if clicked and mem:read_u16(V.OPTWAIT) == 1 then
    print(string.format("options at %.4f s", now()))
    mem:write_u16(V.OPTWAIT, 0)
  end
  if clicked and mem:read_u16(V.GAMEGO) == 0xC0DE then
    print(string.format("game running at %.4f s", now()))
    clicked = nil
    ended = f
  end
  if ended and f == ended + 60 then
    mem:write_u16(V.AICREDITS, 0)
    mem:write_u16(V.SNDREQ, V.SND_PLACE)
    print(string.format("play place at %.4f s", now()))
  end
  if ended and f == ended + 120 then
    print(string.format("end at %.4f s", now()))
    print("problems: " .. problems)
    manager.machine:exit()
  end
  if f == 6000 then print("gave up at frame 6000"); print("problems: " .. (problems + 1)); manager.machine:exit() end
end)
