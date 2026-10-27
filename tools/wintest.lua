-- Win test: remove the enemy's units, weaken its barracks, send a tank
-- across the world to destroy it; then click to play again.
local G = dofile("tools/gs.lua")
local V = G.V
local ended, restarted
local function show(tag)
  local bar = G.w(V.BARUNIT) // 2
  local c, r = G.tile(0)
  print(string.format("%-10s f=%5d tank0 tile=(%d,%d) target=%04X barracks hp=%d flags=%04X over=%d",
    tag, G.f, c, r, G.w(V.UTARGET, 0), G.s16(G.w(V.UHP, bar)), G.w(V.UFLAGS, bar), G.w(V.GAMEOVER)))
end
G.at(700, function()
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_PLAYER == 0 and fl & V.F_BUILDING == 0 then
      G.sw(V.UFLAGS, i, fl | V.F_DEAD | 0x8000)
      G.mem:write_u16(V.OCC + 2 * G.w(V.UTILE, i), 0)
    end
  end
  G.sw(V.UHP, G.w(V.BARUNIT) // 2, 40)
  G.seeall()                                          -- no fog
  show("prepared")
end)
G.at(705, function() local x, y = G.unitxy(0); G.click(706, x, y) end)      -- tank 0
G.at(720, function() G.look(16, 0) end)
G.at(730, function() local x, y = G.unitxy(G.w(V.BARUNIT) // 2); G.click(731, x, y) end)
G.at(745, function() show("ordered") end)
G.run(9000, function(f)
  if f > 700 then G.mem:write_u16(V.AICREDITS, 0) end
  if f > 745 and f % 600 == 0 and not ended then show("progress") end
  if not ended and f > 745 and G.w(V.GAMEOVER) ~= 0 then
    ended = f; show("ENDED")
    G.at(f + 60, function() G.dump("w1_win") end)
    G.click(f + 70, 160, 100)
  end
  if ended and f > ended + 80 and not restarted and G.w(V.GAMEOVER) == 0 then
    restarted = f
    show("restarted")
    print(string.format("  a new game %d frames after the click", f - ended - 73))
    G.at(f + 40, function() G.dump("w2_restart") end)
    G.at(f + 45, function() manager.machine:exit() end)
  end
  if ended and f == ended + 700 and not restarted then
    show("NOT RESTARTED"); manager.machine:exit()
  end
end)
