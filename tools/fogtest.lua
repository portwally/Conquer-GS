-- Fog of war test: what is seen at the start, enemies hidden in the dark
-- (not drawn, no radar dot, a click on one is a move order), then a tank
-- drives into the enemy base and uncovers it. Checks the fog table, the
-- black cells on screen and the radar as it goes; dumps screens to
-- build/mame/f*.bin.
local G = dofile("tools/gs.lua")
local V = G.V
local mem = G.mem
local W, H = V.MAPW, V.MAPH
local problems = 0

local function fog(t) return mem:read_u16(V.FOG + 2 * t) end
local QUEUED = 0x4000
local FQHEAD, FQTAIL = V.FQHEAD, V.FQTAIL
local function seen(t) return fog(t) & V.UNSEEN == 0 end
local DIRS = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}, {1, -1}, {1, 1}, {-1, 1}, {-1, -1}}

local quiet, found = false, 0
local function problem(msg)
  if quiet then found = found + 1; return end
  problems = problems + 1
  if problems <= 20 then print("  PROBLEM f=" .. G.f .. ": " .. msg) end
end

-- every unseen tile holds UNSEEN (+ QUEUED once a unit has seen it and it
-- waits to be uncovered); every seen tile the bits of its unseen
-- neighbors on the map
local function checktable()
  local nseen = 0
  for t = 0, W * H - 1 do
    local v = fog(t)
    if v & V.UNSEEN ~= 0 then
      if v ~= V.UNSEEN and v ~= V.UNSEEN | QUEUED then
        problem(string.format("tile %d unseen but %04X", t, v))
      end
    else
      nseen = nseen + 1
      local c, r, bits = t % W, t // W, 0
      for i, d in ipairs(DIRS) do
        local nc, nr = c + d[1], r + d[2]
        if nc >= 0 and nc < W and nr >= 0 and nr < H and not seen(nr * W + nc) then
          bits = bits | (1 << (i - 1))
        end
      end
      if v & 0xF8FF ~= bits then         -- (bits 8-10: how far looked around from it)
        problem(string.format("tile (%d,%d) edges %02X want %02X", c, r, v & 0xF8FF, bits))
      end
    end
  end
  return nseen
end

-- each of our units sees its circle around its tile (uncovered, or waiting
-- in the queue)
local function checksight()
  local n = G.w(V.NUNITS) // 2
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & V.F_PLAYER ~= 0 and fl & V.F_DEAD == 0 then
      local r = (fl & V.F_BUILDING ~= 0) and 4 or math.max(G.w(V.URANGE, i) + 1, 3)
      local t = G.w(V.UTILE, i)
      local c0, r0 = t % W, t // W
      for dy = -r, r do
        local w = math.floor(math.sqrt(r * r + r - dy * dy))
        local row = r0 + dy
        if row >= 0 and row < H then
          for col = math.max(0, c0 - w), math.min(W - 1, c0 + w) do
            if fog(row * W + col) == V.UNSEEN then
              problem(string.format("unit %d at (%d,%d) does not see (%d,%d)", i, c0, r0, col, row))
            end
          end
        end
      end
    end
  end
end

-- view cells of unseen tiles are black on screen (the cursor aside)
local function checkdark(tag)
  local cx, cy = G.w(V.CAMX), G.w(V.CAMY)
  local lit, dark = 0, 0
  for vy = 0, 11 do for vx = 0, 15 do
    if not seen((cy + vy) * W + cx + vx) then
      dark = dark + 1
      for y = 0, 15 do for x = 0, 7 do
        if mem:read_u8(0xE12000 + (8 + vy * 16 + y) * 160 + vx * 8 + x) ~= 0 then lit = lit + 1 end
      end end
    end
  end end
  print(string.format("%-10s f=%5d view=(%d,%d) unseen cells=%d, lit bytes in them=%d",
    tag, G.f, cx, cy, dark, lit))
  if lit > 0 then problem("lit pixels in unseen cells") end
end

-- enemies on unseen tiles are not drawn; enemies in view on seen tiles are
local function checkhidden(tag)
  local n, hidden, shown = G.w(V.NUNITS) // 2, 0, 0
  local vx, vy = G.w(V.VIEWX), G.s16(G.w(V.VIEWY))
  for i = 0, n - 1 do
    local fl = G.w(V.UFLAGS, i)
    if fl & (V.F_PLAYER | V.F_DEAD) == 0 then
      local x, y = G.w(V.UX, i), G.w(V.UY, i)
      local t = ((y + 8) // 16) * W + (x + 8) // 16
      local sx, sy = x - vx, y - vy
      local inview = sx >= 0 and sx <= 240 and sy >= 8 and sy <= 184
      local ox = G.w(V.UOX, i)
      if not seen(t) then
        hidden = hidden + 1
        if ox ~= V.OFFVIEW then problem("unit " .. i .. " drawn in the dark") end
      elseif inview then
        shown = shown + 1
        if ox == V.OFFVIEW then problem("unit " .. i .. " seen but not drawn") end
      end
    end
  end
  print(string.format("%-10s f=%5d enemies hidden=%d, in view and drawn=%d", tag, G.f, hidden, shown))
end

-- the radar: terrain where seen (black elsewhere), the dots recorded, the
-- view frame - checked whenever no redraw is pending
local URX, URY = V.URX, V.URY
local radarchecks, radarbad = 0, 0
local function checkradar()
  local img = {}
  for py = 0, 35 do for px = 0, 47 do
    local x, y = 264 + px, 20 + py
    local t = (py * 2 // 3) * W + px * 2 // 3
    local b = mem:read_u8(0x03A000 + y * 160 + (x >> 1))     -- the terrain kept aside
    local p = (x & 1 == 0) and (b >> 4) or (b & 15)
    img[y * 512 + x] = seen(t) and p or 0
  end end
  for i = 0, V.MAXUNITS - 1 do
    local x = mem:read_u16(URX + 2 * i)
    if x ~= 0xFFFF then
      local y = mem:read_u16(URY + 2 * i)
      local big = y & 0x8000 ~= 0; y = y & 0x7FFF
      local c = (G.w(V.UFLAGS, i) & 1 ~= 0) and 13 or 14
      for dy = 0, big and 1 or 0 do for dx = 0, big and 1 or 0 do img[(y + dy) * 512 + x + dx] = c end end
    end
  end
  local x0, y0 = 264 + G.w(V.CAMX) * 3 // 2, 20 + G.w(V.CAMY) * 3 // 2
  local x1, y1 = x0 + 23, y0 + 17
  for x = x0, x1 do img[y0 * 512 + x] = 12; img[y1 * 512 + x] = 12 end
  for y = y0, y1 do img[y * 512 + x0] = 12; img[y * 512 + x1] = 12 end
  local bad = 0
  for y = 20, 55 do for x = 264, 311 do
    local b = mem:read_u8(0x022000 + y * 160 + (x >> 1))
    local p = (x & 1 == 0) and (b >> 4) or (b & 15)
    if p ~= img[y * 512 + x] then bad = bad + 1 end
  end end
  radarchecks = radarchecks + 1
  if bad > 0 then radarbad = radarbad + 1; problem(bad .. " radar pixels wrong") end
end

G.at(700, function()
  print(string.format("start      f=%5d seen tiles=%d", G.f, checktable()))
  checksight()
  checkdark("start")
end)
G.at(705, function() local x, y = G.unitxy(0); G.click(706, x, y) end)       -- select tank 0
G.at(720, function() G.look(16, 0); G.mouse(300, 190) end)                   -- the enemy base
G.at(740, function()
  checkdark("enemy base")
  checkhidden("enemy base")
  G.dump("f1_dark")
end)
G.at(745, function() local x, y = G.unitxy(5); G.click(746, x, y) end)       -- on a hidden tank
G.at(770, function()
  print(string.format("clicked    f=%5d tank0 target=%04X goal=%04X (a move order, not an attack)",
    G.f, G.w(V.UTARGET, 0), G.w(V.UGOAL, 0)))
  if G.w(V.UTARGET, 0) ~= 0xFFFF then problem("attacked a hidden unit") end
  G.mouse(300, 190)
end)
G.at(2400, function()
  print(string.format("arrived    f=%5d tank0 tile=(%d,%d) seen tiles=%d, waiting=%d", G.f,
    G.w(V.UTILE, 0) % W, G.w(V.UTILE, 0) // W, checktable(),
    (mem:read_u16(FQTAIL) - mem:read_u16(FQHEAD)) % 2048 // 2))
  checksight()
  checkdark("arrived")
  checkhidden("arrived")
  G.dump("f2_found")
  G.units("arrived")
end)
G.at(661, G.radar)                                        -- (radar on)
G.run(2405, function(f)
  if f > 700 then mem:write_u16(V.AICREDITS, 0) end                   -- no new enemies
  -- (a frame can end in the middle of uncovering a tile: if the table looks
  -- wrong, look again on the next frame)
  if f > 780 and f % 50 == 0 then
    quiet, found = true, 0; checktable(); checksight(); quiet = false
    if found > 0 then G.at(f + 1, function() checktable(); checksight() end) end
  end
  if f > 780 and f % 7 == 0 and G.w(V.RADTIME) ~= 0xFFFF and G.w(V.RADIDX) >= G.w(V.RADCHG) then
    quiet, found = true, 0; checkradar(); quiet = false     -- (look again if
    if found > 0 then                                       --  caught midway)
      radarbad = radarbad - 1
      G.at(f + 1, function()
        if G.w(V.RADTIME) ~= 0xFFFF and G.w(V.RADIDX) >= G.w(V.RADCHG) then checkradar() end
      end)
    end
  end
  if f > 780 and f % 100 == 0 then
    checkdark("travel")
    -- (a tile uncovered during this frame's drawing shows its units on
    -- the next one, which may take more than one video frame: if one
    -- looks missing, look again a little later)
    quiet, found = true, 0; checkhidden("travel"); quiet = false
    if found > 0 then G.at(f + 4, function() checkhidden("again") end) end
  end
  if f == 2404 then
    print(string.format("radar checked %d times, wrong %d times; problems: %d", radarchecks, radarbad, problems))
  end
end)
