-- HOW TO PLAY: from the mission setup, the instruction pages (CONQUER.HELP)
-- one after the other - NEXT, NEXT, BACK, NEXT, DONE back to the setup;
-- again, and Esc back; then START starts a game. Dumps each page
-- (build/mame/h1_page0.bin ...). Runs on its own (no SHOWOPTIONS needed).
local V = dofile("tools/vars.lua")
local O = dofile("build/gfx/options.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local f, problems, t0, phase = 0, 0, nil, "title"
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local function dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
local function area(act)
  for _, a in ipairs(O.areas) do
    if a.act == act then return (a.x0 + a.x1) // 2, (a.y0 + a.y1) // 2 end
  end
end
local steps = {}
local function at(n, fn) steps[n] = fn end
local function click(n, x, y)
  at(n, function() mem:write_u16(V.CX, x); mem:write_u16(V.CY, y) end)
  steps[n + 3] = function() btn:set_value(1) end
  steps[n + 9] = function() btn:clear_value() end
end
local hx, hy = area(64)
local BACK, NEXT = {50, V.HELPBTNY + 6}, {266, V.HELPBTNY + 6}
local function plan(s)
  click(s + 20, hx, hy)                                   -- HOW TO PLAY
  at(s + 60, function() print("-- the pages"); check(mem:read_u16(V.HPAGE) == 0, "page 1"); dump("h1_page0") end)
  click(s + 70, NEXT[1], NEXT[2])
  at(s + 110, function() check(mem:read_u16(V.HPAGE) == 1, "NEXT: page 2"); dump("h1_page1") end)
  click(s + 120, NEXT[1], NEXT[2])
  at(s + 160, function() check(mem:read_u16(V.HPAGE) == 2, "NEXT: page 3"); dump("h1_page2") end)
  click(s + 170, BACK[1], BACK[2])
  at(s + 210, function() check(mem:read_u16(V.HPAGE) == 1, "BACK: page 2") end)
  click(s + 220, NEXT[1], NEXT[2])
  click(s + 260, NEXT[1], NEXT[2])                        -- DONE
  at(s + 330, function()
    check(mem:read_u16(V.OPTWAIT) == 1 and mem:read_u16(V.GAMEGO) ~= 0xC0DE, "DONE: the setup again")
    dump("h1_setup")
  end)
  click(s + 340, hx, hy)                                  -- again, then Esc
  at(s + 390, function() manager.machine.natkeyboard:post("\27") end)
  at(s + 440, function() check(mem:read_u16(V.OPTWAIT) == 1, "Esc: the setup again") end)
  click(s + 450, area(32))                                -- START (the first
  click(s + 470, area(32))                                --   click only lets go)
  at(s + 700, function()
    check(mem:read_u16(V.GAMEGO) == 0xC0DE and mem:read_u16(V.OPTWAIT) == 0, "START: a game")
    print("problems: " .. problems)
    manager.machine:exit()
  end)
end
sub = emu.add_machine_frame_notifier(function()
  f = f + 1
  local rd = mem:read_u8(0xC013) >= 0x80
  if rd then mem:write_u8(0xC002, 0) end
  if phase == "title" then
    mem:write_u16(V.TITLEWAIT, 0)
    if mem:read_u16(V.OPTWAIT) == 1 then phase = "opts"; plan(f); print("setup at frame " .. f) end
  end
  if steps[f] then steps[f](); steps[f] = nil end
  if rd then mem:write_u8(0xC003, 0) end
  if f > 9000 then print("timed out; problems: " .. problems + 1); manager.machine:exit() end
end)
