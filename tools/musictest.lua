-- Music test: waits at the title (it does not skip it as tools/clock.lua
-- does) until CLICK TO START is up and the title tune runs, lets it play
-- 32 seconds (over two loops), then clicks: the options screen comes (the
-- tune plays on) and is done with (OPTWAIT cleared). In the game the
-- battle tune must play: 45 seconds of it (over one loop), then the M key
-- turns it off; a sound effect must still play; M again turns it back on.
-- Prints the times for tools/musiccheck.py; run with -wavwrite <file>.
-- It also writes what the game tells the music's oscillators (0-9:
-- frequency, volume, control) in the game, frame by frame, to
-- build/mame/musicwrites.txt, for musiccheck.py to compare with the score.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, started, clicked, game, problems = 0, nil, nil, nil, 0
local function now() return manager.machine.time:as_double() end
local function key(k) manager.machine.natkeyboard:post(k) end
local writes, adr = io.open("build/mame/musicwrites.txt", "w"), 0
tap = mem:install_write_tap(0xC03C, 0xC03F, "music", function(offset, data)
  if offset == 0xC03E then adr = data & 0xFF
  elseif offset == 0xC03D and game and (adr & 0x1F) < 10 and adr < 0xC0 and
         (adr < 0x60 or adr >= 0xA0) then
    if writes then writes:write(string.format("%d %d %d\n", f - game, adr, data & 0xFF)) end
  end
end)
local function expect(ok, msg) if not ok then problems = problems + 1; print("  PROBLEM: " .. msg) end end
sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  -- the tune has started once its step counter moves (mtick wraps)
  if not started and mem:read_u16(V.TITLEWAIT) == 1 and mem:read_u16(V.MSTEP) == 2 then
    started = f
    print(string.format("music playing at %.4f s (step 2)", now()))
  end
  if started and f == started + 32 * 60 then
    print(string.format("click at %.4f s, still at the title: %s", now(),
      mem:read_u16(V.TITLEWAIT) == 1 and "yes" or "NO"))
    expect(mem:read_u16(V.TITLEWAIT) == 1, "still at the title")
    btn:set_value(1)
  end
  if started and f == started + 32 * 60 + 6 then btn:clear_value(); clicked = f end
  if clicked and mem:read_u16(V.OPTWAIT) == 1 then
    print(string.format("options at %.4f s", now()))
    mem:write_u16(V.OPTWAIT, 0)
  end
  if clicked and mem:read_u16(V.GAMEGO) == 0xC0DE then
    print(string.format("game running at %.4f s", now()))
    expect(mem:read_u16(V.MUSICON) == 1, "the battle tune on")
    clicked = nil
    game = f
  end
  if game then
    if f > game then mem:write_u16(V.AICREDITS, 0) end     -- (a quiet enemy)
    if f == game + 45 * 60 then
      writes:close(); writes = nil
      key("m"); print(string.format("M pressed at %.4f s", now()))
    end
    if f == game + 45 * 60 + 10 then
      expect(mem:read_u16(V.MUSICON) == 0 and mem:read_u16(V.MUSICOFF) == 1, "M turns the music off")
    end
    if f == game + 47 * 60 then
      mem:write_u16(V.SNDREQ, V.SND_PLACE)
      print(string.format("play place at %.4f s", now()))
    end
    if f == game + 48 * 60 then
      key("m"); print(string.format("M again at %.4f s", now()))
    end
    if f == game + 48 * 60 + 10 then
      expect(mem:read_u16(V.MUSICON) == 1 and mem:read_u16(V.MUSICOFF) == 0, "M turns it on again")
    end
    if f == game + 52 * 60 then
      print(string.format("end at %.4f s", now()))
      print("problems: " .. problems)
      manager.machine:exit()
    end
  end
  if f == 9000 then print("gave up at frame 9000"); print("problems: " .. (problems + 1)); manager.machine:exit() end
end)
