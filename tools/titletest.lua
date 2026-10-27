-- Title test: the title picture must show (exactly as
-- build/gfx/title_expected.bin: the picture with CLICK TO START), stay up
-- until a click, and the options screen must follow; the game starts when
-- they are done with (here: OPTWAIT cleared, as tools/clock.lua does;
-- tools/optionstest.lua tests that screen). Counts raw video frames (it
-- does not skip the title as tools/clock.lua does).
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local want = io.open("build/gfx/title_expected.bin", "rb"):read("a")
local f, shown, matched, clicked, options, problems = 0, nil, nil, nil, nil, 0
local function differ()
  local n = 0
  for i = 0, 32767, 1 do
    if mem:read_u8(0xE12000 + i) ~= want:byte(i + 1) then n = n + 1 end
  end
  return n
end
local function dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  local up = mem:read_u8(0xE0C029) & 0x80 ~= 0
  if not shown and up and mem:read_u16(V.TITLEWAIT) == 1 then
    shown = f; print("title on screen at frame " .. f)
  end
  if shown and not matched and f % 10 == 0 then
    if differ() == 0 then
      matched = f
      print("title with CLICK TO START, exactly as expected, at frame " .. f)
      dump("t0_title")
    end
  end
  -- it waits: still there 300 frames later, then a click
  if matched and f == matched + 300 then
    local d = differ()
    print(string.format("frame %d: still the title (%d bytes differ), game %s", f, d,
      mem:read_u16(V.GAMEGO) == 0xC0DE and "RUNNING" or "not started"))
    if d ~= 0 or mem:read_u16(V.GAMEGO) == 0xC0DE then problems = problems + 1 end
    btn:set_value(1)
  end
  if matched and f == matched + 306 then btn:clear_value(); clicked = f end
  if clicked and not options and mem:read_u16(V.OPTWAIT) == 1 then
    options = f
    print(string.format("options screen %d frames after the click", f - clicked))
  end
  if options and f == options + 10 then mem:write_u16(V.OPTWAIT, 0) end
  if clicked and mem:read_u16(V.GAMEGO) == 0xC0DE then
    print(string.format("game running %d frames after the options", f - options - 10))
    if not options then problems = problems + 1 end
    clicked = nil
    started = f
  end
  if started and f == started + 40 then dump("t1_game"); print("problems: " .. problems); manager.machine:exit() end
  if f == 3000 then
    print(string.format("gave up at frame 3000: shown=%s matched=%s (%d bytes differ)",
      tostring(shown), tostring(matched), differ()))
    print("problems: " .. (problems + 1))
    manager.machine:exit()
  end
end)
