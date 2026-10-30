-- Sell and repair test: build a power plant and a turret, damage them and
-- repair them (checking hit points against credits paid, the wrench, the
-- pressed button and the cursors), sell both, then try a repair without
-- enough money. Dumps screens to build/mame/r*.bin.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local E = {}                                   -- equates from the generator
for line in io.lines("build/gfx/gfxequ.s") do
  local k, v = line:match("^(%S+)%s+equ%s+(%-?%d+)")
  if k then E[k] = tonumber(v) end
end
local problems = 0
local function check(ok, msg)
  if not ok then problems = problems + 1; print("  PROBLEM f=" .. G.f .. ": " .. msg) end
end
local I = dofile("build/gfx/icons.lua")
local icon = {pp = I.pp_p, turret = I.turret_p}
local SELLBTN = {(E.SELLX0 + E.SELLX1) // 2, (E.BTNY0 + E.BTNY1) // 2}
local REPBTN = {(E.REPX0 + E.REPX1) // 2, (E.BTNY0 + E.BTNY1) // 2}
local PP, TUR = {2, 16}, {7, 20}
local pp, tur
local function placexy(spot, size)
  local x, y = G.tilexy(spot[1], spot[2])
  return x + (size - 1) * 8, y + (size - 1) * 8
end
local function find(spot)
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    if G.w(V.UFLAGS, i) & V.F_PLAYER ~= 0 and G.w(V.UTILE, i) == spot[2] * 32 + spot[1] then return i end
  end
end
local function credits() return G.w(V.CREDITS) end
local function hp(i) return G.s16(G.w(V.UHP, i)) end
local function report(tag)
  print(string.format("%-14s f=%5d credits=%5d mode=%d power %d/%d  pp hp=%s%s  turret hp=%s%s", tag, G.f,
    credits(), G.w(V.CMDMODE), G.w(V.PWRUSED), G.w(V.PWRMADE),
    pp and hp(pp) or "-", pp and (G.w(V.UFLAGS, pp) & V.F_REPAIR ~= 0 and " repairing" or "") or "",
    tur and hp(tur) or "-", tur and (G.w(V.UFLAGS, tur) & V.F_REPAIR ~= 0 and " repairing" or "") or ""))
end
-- bytes of a button on screen that differ from the sidebar layer
local function pressed(off, w)
  local d = 0
  for y = 0, E.BTNH - 1 do for x = 0, w - 1 do
    local a = off + y * 160 + x
    if mem:read_u8(0xE12000 + a) ~= mem:read_u8(V.UIBANK * 0x10000 + 0x2000 + a) then d = d + 1 end
  end end
  return d
end
local function cursor(tag, x, y, want)
  G.at(G.f + 1, function() G.mouse(x, y) end)
  G.at(G.f + 4, function()
    local c = G.w(V.CSHAPE)
    print(string.format("  cursor over %-14s %d (want %d)", tag, c, want))
    check(c == want, "cursor over " .. tag)
  end)
end
local function passable(c, r) return mem:read_u8(V.PASSW + r * 32 + c) == 0 end

G.at(700, function()
  G.sw(V.USTATE, 2, 0); G.sw(V.UGOAL, 2, 0xFFFF)     -- harvester idle: credits stay put
  report("start")
end)
G.click(705, icon.pp[1], icon.pp[2])                       -- build a power plant
G.click(1090, icon.pp[1], icon.pp[2])                      -- place it
G.at(1102, function() G.clear(PP[1], PP[2], 2) end)
G.at(1104, function() G.mouse(placexy(PP, 2)) end)
G.at(1109, function() G.click(1110, placexy(PP, 2)) end)
G.click(1170, icon.turret[1], icon.turret[2])              -- build a turret
G.click(1700, icon.turret[1], icon.turret[2])              -- place it
G.at(1706, function() G.clear(TUR[1], TUR[2], 1) end)
G.at(1709, function() G.click(1710, placexy(TUR, 1)) end)
G.at(1760, function()
  pp, tur = find(PP), find(TUR)
  print("  power plant is unit " .. tostring(pp) .. ", turret unit " .. tostring(tur))
  check(pp and tur, "both built")
  check(G.w(V.UCOST, pp) == 150 and G.w(V.UCOST, tur) == 300, "sell prices 150 / 300")
  G.sw(V.UHP, pp, 100); G.sw(V.UHP, tur, 50)                -- damage them
  G.sw(V.UFLAGS, pp, G.w(V.UFLAGS, pp) | 0x8000); G.sw(V.UFLAGS, tur, G.w(V.UFLAGS, tur) | 0x8000)
  report("built, damaged")
end)

-- repair
G.at(1770, function() G.click(1771, REPBTN[1], REPBTN[2]) end)
G.at(1785, function() G.mouse(100, 100) end)
G.at(1790, function()
  local d = pressed(E.REPOFF, E.REPW)
  print(string.format("  mode=%d, REPAIR button bytes changed: %d", G.w(V.CMDMODE), d))
  check(G.w(V.CMDMODE) == E.MODE_REPAIR and d > 20, "repair mode on, button pressed")
end)
G.at(1796, function() local x, y = G.unitxy(pp); cursor("power plant", x, y, E.SPR_REPAIR) end)
G.at(1802, function() local x, y = G.unitxy(G.w(V.HQUNIT) // 2); cursor("whole HQ", x, y, E.SPR_NO) end)
G.at(1808, function() local x, y = G.unitxy(0); cursor("a tank", x, y, E.SPR_NO) end)
local c0, h0, blinks, wrenchdump = 0, 0, 0, false
G.at(1814, function() local x, y = G.unitxy(pp); G.click(1815, x, y) end)
G.at(1830, function()
  c0, h0 = credits(), hp(pp)
  check(G.w(V.UFLAGS, pp) & V.F_REPAIR ~= 0, "power plant repairing")
  report("repairing")
end)
G.at(1990, function()
  local paid, gained = c0 - credits(), hp(pp) - h0
  print(string.format("  after 160 frames: paid %d credits, gained %d hp", paid, gained))
  check(paid > 0 and paid % E.REPAIRCOST == 0 and gained == paid // E.REPAIRCOST * E.REPAIRHP,
    "hp gained matches credits paid")
  local x, y = G.unitxy(tur); G.click(1991, x, y)          -- the turret too
end)
G.at(2010, function() report("both repairing") end)
G.at(2400, function()
  report("repaired")
  check(hp(pp) == 200 and hp(tur) == 200, "both whole")
  check(G.w(V.UFLAGS, pp) & (V.F_REPAIR | V.F_BLINK) == 0 and G.w(V.UFLAGS, tur) & (V.F_REPAIR | V.F_BLINK) == 0,
    "repair stopped")
  print("  wrench shown on " .. blinks .. " checks")
  check(blinks > 0, "wrench blinked")
  G.click(2401, REPBTN[1], REPBTN[2])                       -- repair mode off
end)
G.at(2415, function() G.mouse(100, 100) end)
G.at(2420, function()
  local d = pressed(E.REPOFF, E.REPW)
  print(string.format("  mode=%d, REPAIR button bytes changed: %d", G.w(V.CMDMODE), d))
  check(G.w(V.CMDMODE) == 0 and d == 0, "repair mode off, button back")
end)

-- sell
local before, used, made
G.at(2425, function() G.click(2426, SELLBTN[1], SELLBTN[2]) end)
G.at(2440, function()
  check(G.w(V.CMDMODE) == E.MODE_SELL, "sell mode on")
  local x, y = G.unitxy(G.w(V.HQUNIT) // 2); cursor("HQ", x, y, E.SPR_NO)
end)
G.at(2446, function() local x, y = G.unitxy(tur); cursor("turret", x, y, E.SPR_SELL) end)
G.at(2452, function()
  before, used = credits(), G.w(V.PWRUSED)
  local x, y = G.unitxy(tur); G.click(2453, x, y)
end)
G.at(2470, function()
  report("turret sold")
  check(credits() == before + 300, "300 back for the turret")
  check(G.w(V.UFLAGS, tur) & V.F_DEAD ~= 0, "turret gone")
  check(passable(TUR[1], TUR[2]), "its tile open")
  check(G.w(V.PWRUSED) == used - 40, "40 less power used")
  local fx = 0
  for i = 0, 7 do if G.w(V.FXTIME, i) ~= 0 then fx = fx + 1 end end
  check(fx == 0, "no explosion")
  before, made = credits(), G.w(V.PWRMADE)
  local x, y = G.unitxy(pp); G.click(2471, x, y)
end)
G.at(2490, function()
  report("pp sold")
  check(credits() == before + 150, "150 back for the power plant")
  check(G.w(V.UFLAGS, pp) & V.F_DEAD ~= 0, "power plant gone")
  check(passable(PP[1], PP[2]) and passable(PP[1] + 1, PP[2]) and passable(PP[1], PP[2] + 1)
        and passable(PP[1] + 1, PP[2] + 1), "its tiles open")
  check(G.w(V.PWRMADE) == made - 100, "100 less power made")
  G.dump("r2_sold")
  local x, y = G.tilexy(10, 14); G.click(2491, x, y)       -- empty ground: done
end)
G.at(2505, function() check(G.w(V.CMDMODE) == 0, "sell mode off after a click on the ground") end)

-- repair without the money for it
local hq
G.at(2510, function()
  hq = G.w(V.HQUNIT) // 2
  G.sw(V.CREDITS, 0, 4); G.sw(V.UHP, hq, 300)
  G.click(2511, REPBTN[1], REPBTN[2])
end)
G.at(2525, function() local x, y = G.unitxy(hq); G.click(2526, x, y) end)
G.at(2600, function()
  print(string.format("  poor repair: credits=%d hq hp=%d flags=%04X", credits(), hp(hq), G.w(V.UFLAGS, hq)))
  check(credits() == 1 and hp(hq) == 304 and G.w(V.UFLAGS, hq) & V.F_REPAIR == 0, "one step, then stopped")
  print("problems: " .. problems)
end)
G.run(2605, function(f)
  if f > 700 then mem:write_u16(V.AICREDITS, 0) end                -- a quiet enemy
  if f > 1830 and f < 2400 and pp and G.w(V.UFLAGS, pp) & V.F_BLINK ~= 0 then
    blinks = blinks + 1
    if not wrenchdump then wrenchdump = true; G.at(f + 2, function() G.dump("r1_wrench") end) end
  end
end)
