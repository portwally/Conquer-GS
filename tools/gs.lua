-- Helpers for the MAME test scripts. Usage:
--   local G = dofile("tools/gs.lua")
--   G.at(f, function() ... end)       run something at MAME frame f
--   G.click(f, x, y)                  click at screen x, y (frames f..f+7)
--   G.look(col, row)                  put world tile col, row at the view's
--                                     top left (redrawn on the next frame)
--   G.tilexy(col, row)                screen x, y of the middle of a tile
--   G.unitxy(i)                       screen x, y of the middle of unit i
--   G.seeall()                        lift the fog of war
--   G.seen(t)                         has world tile t been seen?
--   G.radar()                         the radar on without a radar center
--   G.quickbuild(f, icon, c, r, size) build and place a structure at once
--   G.run(last)                       start; exit MAME after frame `last`
-- G.V holds the addresses (tools/vars.lua), G.f the current frame.
local G = {}
local V = dofile("tools/vars.lua")
G.V = V
local mem = manager.machine.devices[":maincpu"].spaces["program"]
G.mem = mem
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local steps = {}
G.f = 0

function G.w(addr, i) return mem:read_u16(addr + 2 * (i or 0)) end
function G.sw(addr, i, v) mem:write_u16(addr + 2 * i, v) end
function G.s16(v) return (v + 32768) % 65536 - 32768 end
function G.at(f, fn)
  local old = steps[f]
  steps[f] = old and function() old(); fn() end or fn
end
function G.mouse(x, y) mem:write_u16(V.CX, x); mem:write_u16(V.CY, y) end
function G.click(f, x, y)
  G.at(f, function() G.mouse(x, y) end)
  G.at(f + 3, function() btn:set_value(1) end)
  G.at(f + 7, function() btn:clear_value() end)
end
function G.look(col, row)            -- (the game moves the view on its
  mem:write_u16(V.LOOKY, row)           --  next frame, at a safe point)
  mem:write_u16(V.LOOKX, col)
end
-- G.teleport(i, col, row): put unit i on that tile at once, standing still
function G.teleport(i, col, row)
  local function freeocc(t) if t ~= 0xFFFF then mem:write_u16(V.OCC + 2 * t, 0) end end
  freeocc(G.w(V.UTILE, i)); freeocc(G.w(V.UNEXT, i))
  local t = row * V.MAPW + col
  G.sw(V.UTILE, i, t); G.sw(V.UNEXT, i, 0xFFFF); G.sw(V.UGOAL, i, 0xFFFF)
  G.sw(V.UX, i, col * 16); G.sw(V.UY, i, row * 16)
  G.sw(V.UPATHLEN, i, 0); G.sw(V.UPATHPOS, i, 0)
  G.sw(V.UFLAGS, i, G.w(V.UFLAGS, i) | 0x8000)
  mem:write_u16(V.OCC + 2 * t, 2 * i + 2)
end
-- G.clear(col, row, size): move any unit standing on that size x size
-- spot (top left col, row) to a free tile nearby, e.g. before placing a
-- structure there (parked units step aside for others, so they wander)
function G.clear(c0, r0, size)
  local function inspot(c, r) return c >= c0 and c < c0 + size and r >= r0 and r < r0 + size end
  for r = r0, r0 + size - 1 do for c = c0, c0 + size - 1 do
    local o = mem:read_u16(V.OCC + 2 * (r * V.MAPW + c))
    if o ~= 0 then
      local done = false
      for d = 2, 6 do for rr = r0 - d, r0 + size - 1 + d do for cc = c0 - d, c0 + size - 1 + d do
        local t = rr * V.MAPW + cc
        if not done and rr > 0 and cc > 0 and rr < V.MAPH - 1 and cc < V.MAPW - 1
           and not inspot(cc, rr) and mem:read_u8(V.PASSW + t) == 0
           and mem:read_u16(V.OCC + 2 * t) == 0 and mem:read_u8(V.OREAMT + t) == 0 then
          G.teleport(o // 2 - 1, cc, rr); done = true
        end
      end end end
    end
  end end
end
function G.seeall() mem:write_u16(V.SEEALL, 1) end     -- no fog from the next frame
-- G.quickbuild(f, icon, col, row, size): from frame f, build the structure
-- of sidebar icon {x, y} at once (the script fills its progress bar) and
-- place it with its top left at col, row. Done 50 frames later.
function G.quickbuild(f, icon, col, row, size)
  G.click(f, icon[1], icon[2])
  G.at(f + 12, function() G.sw(V.QSEG, 0, V.BARSEGS) end)
  G.click(f + 20, icon[1], icon[2])
  G.at(f + 30, function() G.clear(col, row, size) end)
  G.at(f + 32, function()
    local x, y = G.tilexy(col, row); G.click(f + 33, x + (size - 1) * 8, y + (size - 1) * 8)
  end)
end
-- G.radar(): the radar works without a radar center (from the next frame)
function G.radar() mem:write_u16(V.RADARALL, 1); mem:write_u16(V.RADARON, 1) end
function G.seen(t) return mem:read_u16(V.FOG + 2 * t) & V.UNSEEN == 0 end
function G.tilexy(col, row)
  return (col - G.w(V.CAMX)) * 16 + 8, (row - G.w(V.CAMY)) * 16 + 16
end
function G.unitxy(i)
  return G.w(V.UX, i) - G.w(V.VIEWX) + 8, G.w(V.UY, i) - G.w(V.VIEWY) + 8
end
function G.tile(i) local t = G.w(V.UTILE, i); return t % 32, t // 32 end
function G.dump(name)
  local fh = io.open("build/mame/" .. name .. ".bin", "wb")
  for a = 0xE12000, 0xE19FFF do fh:write(string.char(mem:read_u8(a))) end
  fh:close()
end
function G.units(tag)
  local n = G.w(V.NUNITS) // 2
  print(string.format("-- %s (frame %d, game frame %d)", tag, G.f, G.w(V.FRAME)))
  for i = 0, n - 1 do
    local c, r = G.tile(i)
    local t = G.w(V.UTARGET, i)
    print(string.format("  unit %2d tile=(%2d,%2d) hp=%4d flags=%04X target=%s", i, c, r,
      G.s16(G.w(V.UHP, i)), G.w(V.UFLAGS, i), t == 0xFFFF and "-" or tostring(t // 2)))
  end
end
-- The screen copy runs with bank 0 reads and writes switched to bank 1, and
-- a frame can end in the middle of it. Switch back to main memory while the
-- test looks at the game, then restore the switches.
local function mainmem(fn)
  local rd = mem:read_u8(0xC013) >= 0x80
  local wr = mem:read_u8(0xC014) >= 0x80
  if rd then mem:write_u8(0xC002, 0) end
  if wr then mem:write_u8(0xC004, 0) end
  fn()
  if rd then mem:write_u8(0xC003, 0) end
  if wr then mem:write_u8(0xC005, 0) end
end
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
function G.run(last, everyframe)
  sub = emu.add_machine_frame_notifier(function()
    local nf = tick()
    if nf == G.f then return end           -- still loading
    G.f = nf
    mainmem(function()
      if everyframe then everyframe(G.f) end
      if steps[G.f] then steps[G.f]() end
    end)
    if G.f == last then manager.machine:exit() end
  end)
end
return G
