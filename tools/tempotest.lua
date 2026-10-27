-- Tempo test (run with MUSIC=1): the battle tune must keep time while
-- the game is busy. Counts how far the tune moves (its steps and frames
-- into the step) against video frames: 10 seconds standing still, 20
-- seconds scrolling the view back and forth (each step redraws the whole
-- view, which takes several frames), 20 seconds with every unit of ours
-- sent across the map. Each must keep at least 97% of the beat.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local problems = 0
local fps, loop
local played, video, last, phase = 0, 0, nil, nil
local function pos() return G.w(V.MSTEP) * fps + G.w(V.MTICK) end
local function begin(name) phase, played, video = name, 0, 0 end
local function report()
  local pct = 100 * played / video
  print(string.format("%-34s %5d video frames, the tune moved %5d: %.1f%%", phase .. ":",
    video, played, pct))
  if pct < 97 then problems = problems + 1 end
end
G.at(700, function()
  if G.w(V.MUSICON) ~= 1 then print("no music: run with MUSIC=1"); problems = 1 end
  fps, loop = G.w(V.MTR + V.MT_FPS), G.w(V.MTR + V.MT_STEPS) * G.w(V.MTR + V.MT_FPS)
  G.mem:write_u16(V.AICREDITS, 0)
  begin("standing still")
end)
G.at(1300, function() report(); begin("scrolling back and forth") end)
-- the mouse at the right edge, then the left, and again
for k = 0, 3 do
  G.at(1300 + k * 300, function() G.mouse(k % 2 == 0 and 319 or 0, 100) end)
end
G.at(2500, function() G.mouse(128, 100); report(); begin("every unit sent across the map") end)
G.at(2510, function()                      -- select ours, order a move
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_PLAYER ~= 0 and fl & (V.F_DEAD | V.F_BUILDING) == 0 then
      G.sw(V.UFLAGS, i, fl | V.F_SEL | 0x8000)
    end
  end
end)
G.click(2512, 230, 30)
G.at(3700, function() report(); print("problems: " .. problems) end)
G.run(3701, function(f)
  if f >= 700 then G.mem:write_u16(V.AICREDITS, 0) end
  if not fps then return end
  local p = pos()
  if last and phase then
    played = played + (p - last) % loop
    video = video + 1
  end
  last = p
end)
