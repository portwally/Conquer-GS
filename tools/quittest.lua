-- QUIT test (run with SHOWOPTIONS=1): on the mission setup a click on
-- QUIT must hand the machine back to ProDOS - Super Hi-Res off, the text
-- screen on, and ProDOS's program selector (Bitsy Bye on the game disk)
-- showing there. Then CONQUER.SYSTEM chosen there must start the game
-- again, as far as the mission setup.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local O = dofile("build/gfx/options.lua")
local problems = 0
local function check(ok, msg)
  print(string.format("  %-58s %s", msg, ok and "ok" or "PROBLEM"))
  if not ok then problems = problems + 1 end
end
local QUIT
for _, a in ipairs(O.areas) do
  if a.act == 88 then QUIT = {(a.x0 + a.x1) // 2, (a.y0 + a.y1) // 2} end
end
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local function textscreen()              -- the 40-column text page, as text
  local base = {0x400, 0x480, 0x500, 0x580, 0x600, 0x680, 0x700, 0x780}
  local out = {}
  for row = 0, 23 do
    local a = base[row % 8 + 1] + (row // 8) * 40
    local l = {}
    for c = 0, 39 do
      local b = mem:read_u8(a + c) & 0x7F
      if b < 32 then b = b + 64 end
      l[#l + 1] = string.char(b)
    end
    out[#out + 1] = table.concat(l)
  end
  return table.concat(out, "\n")
end
local raw, at, again = 0, nil, nil
sub = emu.add_machine_frame_notifier(function()
  raw = raw + 1
  local rd = mem:read_u8(0xC013) >= 0x80
  if rd then mem:write_u8(0xC002, 0) end
  mem:write_u16(V.TITLEWAIT, 0)
  if not at and mem:read_u16(V.OPTWAIT) == 1 then
    print("-- the mission setup: QUIT")
    check(QUIT ~= nil, "a QUIT button")
    at = raw + 20
  end
  if at and raw == at then G.mouse(QUIT[1], QUIT[2]) end
  if at and raw == at + 4 then btn:set_value(1) end
  if at and raw == at + 8 then btn:clear_value() end
  if at and raw == at + 400 then
    local t = textscreen()
    check(mem:read_u8(0xC029) & 0x80 == 0, "Super Hi-Res off")
    check(mem:read_u8(0xC01A) >= 0x80, "the text screen on")
    check(t:find("PRODOS") ~= nil or t:find("BYE") ~= nil or t:find("SYSTEM") ~= nil,
      "ProDOS's program selector on it")
    print(t)
    print("-- CONQUER.SYSTEM again")
    mem:write_u16(V.OPTWAIT, 0)
    manager.machine.natkeyboard:post_coded("{DOWN}")
  end
  if at and raw == at + 440 then manager.machine.natkeyboard:post("\r") end
  if at and raw > at + 440 and mem:read_u16(V.OPTWAIT) == 1 and not again then
    again = raw
    check(true, string.format("the mission setup again (%d frames)", raw - at - 440))
    print("problems: " .. problems)
    manager.machine:exit()
  end
  if at and raw == at + 4000 then
    check(false, "the mission setup again")
    print(textscreen())
    print("problems: " .. problems)
    manager.machine:exit()
  end
  if rd and raw ~= (at or 0) + 400 then mem:write_u8(0xC003, 0) end
end)
