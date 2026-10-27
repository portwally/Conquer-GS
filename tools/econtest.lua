-- Economy test: watch the harvester work for a while and build a tank
-- (the soldier click is ignored: no barracks). The enemy builds nothing.
-- Prints credits and the harvester's state as they change.
local G = dofile("tools/gs.lua")
local V = G.V
local STATES = {[0] = "idle", "seek", "goto", "mine", "home", "unload"}
local function harv(tag)
  local c, r = G.tile(2)
  print(string.format("%-8s f=%5d game=%5d credits=%5d harvester: %-6s tile=(%2d,%2d) cargo=%3d ore@(8,16)=%2d units=%d queue=%s/%d",
    tag, G.f, G.w(V.FRAME), G.w(V.CREDITS), STATES[G.w(V.USTATE, 2)] or "?", c, r,
    G.w(V.UCARGO, 2), G.mem:read_u8(V.OREAMT + 16 * 32 + 8), G.w(V.NUNITS) // 2,
    G.w(V.QICON + 2) == 0xFFFF and "-" or tostring(G.w(V.QICON + 2) // 22), G.w(V.QSEG + 2)))
end
G.at(700, function() harv("start"); G.dump("e0_start") end)
local I = dofile("build/gfx/icons.lua")
G.click(800, I.tank_p[1], I.tank_p[2])          -- tank icon
G.click(830, I.sold_p[1], I.sold_p[2])          -- soldier icon: no barracks
G.at(1000, function() G.dump("e1_building") end)
G.at(5000, function() harv("end"); G.dump("e3_end") end)
local last
G.run(5005, function(f)
  if f >= 600 then G.mem:write_u16(V.AICREDITS, 0) end
  if f >= 700 and f % 25 == 0 then
    local key = G.w(V.USTATE, 2) .. "/" .. G.w(V.QICON + 2)
    if key ~= last then harv("state"); last = key end
  end
end)
