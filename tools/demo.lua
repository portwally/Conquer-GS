-- Demo for a video: from the title to a battle on Green Valley at NORMAL,
-- played the way a person would (the arrow glides from one thing to the
-- next): the title; the mission setup (a look at every map); a power
-- plant, a barracks and a war factory built and placed; soldiers, rocket
-- soldiers and tanks built side by side (their own queues) while the
-- harvester brings in ore; the infantry and the tanks boxed and sent to
-- a rally point by the road, then the whole army boxed and marched on the
-- enemy's base, the view following it; the battle. Exits when done. E.g.
--   ./run.sh -video none -sound none -nothrottle -aviwrite demo.avi \
--     -autoboot_script tools/demo.lua
-- writes build/mame/snap/demo.avi (see docs/BUILDING.md). DEMODEBUG=1
-- prints how the battle goes.
local G = dofile("tools/gs.lua")
local V, mem = G.V, G.mem
local O = dofile("build/gfx/options.lua")
local I = dofile("build/gfx/icons.lua")
local btn = manager.machine.ioport.ports[":macadb:MOUSE0"].fields["Mouse Button 0"]
local DEBUG = os.getenv("DEMODEBUG")

-- the arrow: where the script has put it, and a glide under way
local cur = {x = 160, y = 100}
local raw = 0
local glide
local tending, busy = false, false               -- (see tend)
local tend
local function frame()
  coroutine.yield()
  if tending and not busy and raw % 30 == 0 then tend() end
end
local function wait(n) for _ = 1, n do frame() end end
local function waitfor(cond, limit)
  for _ = 1, limit or 3600 do
    if cond() then return true end
    frame()
  end
  return false
end
local function moveto(x, y, n)                   -- glide there in n frames
  glide = {x0 = cur.x, y0 = cur.y, x1 = x, y1 = y, t = 0, n = n or 24}
  waitfor(function() return glide == nil end)
end
local function movep(n, x, y) moveto(x, y, n) end -- (n first: movep(n, tile(c, r)))
local function click()
  btn:set_value(1); wait(5); btn:clear_value(); wait(4)
end
local function drag(x, y, n)                     -- press, glide, let go
  btn:set_value(1); wait(3); moveto(x, y, n); wait(3); btn:clear_value(); wait(4)
end
local function area(act, nth)                    -- options screen button
  local k = 0
  for _, a in ipairs(O.areas) do
    if a.act == act then
      k = k + 1
      if k == (nth or 1) then return (a.x0 + a.x1) // 2, (a.y0 + a.y1) // 2 end
    end
  end
end
local function icon(name) return I[name][1], I[name][2] end
local function tile(c, r) return G.tilexy(c, r) end
local function ours(...)                         -- our live units of these
  local want = {}                                --   kinds (sprites; not
  for _, s in ipairs({...}) do want[s] = true end --   buildings: theirs is
  local out = {}                                 --   a template)
  for i = 0, G.w(V.NUNITS) // 2 - 1 do
    if G.w(V.UFLAGS, i) & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING) == V.F_PLAYER and
       want[G.w(V.USPR, i)] then
      out[#out + 1] = i
    end
  end
  return out
end
local function infantry() return ours(V.SPR_SOLD_P, V.SPR_ROCK_P) end
local function tanks() return ours(V.SPR_TANK_P) end
local function army() return ours(V.SPR_TANK_P, V.SPR_SOLD_P, V.SPR_ROCK_P) end
local function lead()                            -- the unit furthest on its
  local best, bi = -math.huge, nil               --   way (north-east)
  for _, i in ipairs(army()) do
    local c, r = G.tile(i)
    if c - r > best then best, bi = c - r, i end
  end
  return bi
end

-- the view follows the army: a tile at a time towards the lead unit
local follow = false
local function view()
  local i = lead()
  if not i then return end
  local c, r = G.tile(i)
  local tx = math.max(0, math.min(V.MAPW - 16, c - 6))
  local ty = math.max(0, math.min(V.MAPH - 12, r - 6))
  local cx, cy = G.w(V.CAMX), G.w(V.CAMY)
  if tx ~= cx or ty ~= cy then
    G.look(cx + (tx > cx and 1 or tx < cx and -1 or 0), cy + (ty > cy and 1 or ty < cy and -1 or 0))
  end
end

-- a click on tile c, r (an order for the units selected), with the view
-- moved first if the tile is not in it (and held still meanwhile)
local function order(c, r, n)
  local was = follow
  follow = false
  local cx, cy = G.w(V.CAMX), G.w(V.CAMY)
  if c < cx + 1 or c > cx + 14 or r < cy + 1 or r > cy + 10 then
    G.look(math.max(0, math.min(V.MAPW - 16, c - 8)), math.max(0, math.min(V.MAPH - 12, r - 6)))
    wait(15)
  end
  movep(n or 30, tile(c, r))
  wait(6)
  click()
  follow = was
end

-- a box around units (screen pixels, 10 more each way), once our
-- harvester is not in it (else it would be sent along)
local function boxof(list)
  local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
  for _, i in ipairs(list) do
    local x, y = G.unitxy(i)
    x0, y0, x1, y1 = math.min(x0, x), math.min(y0, y), math.max(x1, x), math.max(y1, y)
  end
  return math.max(1, x0 - 10), math.max(10, y0 - 10), math.min(254, x1 + 10), math.min(198, y1 + 10)
end
local function boxselect(list)
  if #list == 0 then return end
  waitfor(function()
    local x0, y0, x1, y1 = boxof(list)
    for _, h in ipairs(ours(V.SPR_HARV_P)) do
      local x, y = G.unitxy(h)
      if x >= x0 - 8 and x <= x1 + 8 and y >= y0 - 8 and y <= y1 + 8 then return false end
    end
    return true
  end, 900)
  local x0, y0, x1, y1 = boxof(list)
  moveto(x0, y0, 26)
  wait(6)
  drag(x1, y1, 24)
  wait(10)
end

-- build: click an icon (when its queue takes it)
local function build(name)
  moveto(icon(name))
  wait(6)
  click()
end
-- place a finished structure with its top left at c, r
local function place(name, c, r)
  waitfor(function() return G.w(V.QREADY) ~= 0 end, 1500)
  busy = true
  wait(10)
  moveto(icon(name))
  wait(6)
  click()
  local px, py = tile(c, r)
  movep(28, px + 8, py + 8)
  wait(14)
  G.clear(c, r, 2)
  click()
  wait(4)
  if G.w(V.QREADY) ~= 0 then                     -- (not placed: stop placing)
    print(name .. " NOT placed")
    manager.machine.natkeyboard:post(" ")
    wait(10)
  end
  busy = false
end
-- tend: keep the barracks and the war factory busy (soldiers and rocket
-- soldiers by turns, tanks) while there is money
local rockets = false
tend = function()
  busy = true
  local cr = G.w(V.CREDITS)
  local inf = rockets and 'rock_p' or 'sold_p'
  if G.w(V.QICON + 2) == 0xFFFF and G.w(V.ICONOK, I[inf].n) == 1 and cr >= 300 then
    build(inf)
    rockets = not rockets
  elseif G.w(V.QICON + 4) == 0xFFFF and G.w(V.ICONOK, I.tank_p.n) == 1 and cr >= 800 then
    build('tank_p')
  end
  busy = false
end

-- the nearest enemy unit (not a building) seen, to unit i
local function nearestenemy(i)
  local c0, r0 = G.tile(i)
  local best, bj = math.huge, nil
  for j = 0, G.w(V.NUNITS) // 2 - 1 do
    local fl = G.w(V.UFLAGS, j)
    if fl & (V.F_PLAYER | V.F_DEAD | V.F_BUILDING) == 0 and G.seen(G.w(V.UTILE, j)) then
      local c, r = G.tile(j)
      local d = math.max(math.abs(c - c0), math.abs(r - r0))
      if d < best then best, bj = d, j end
    end
  end
  return bj, best
end

local function demo()
  -- the title (once it shows: Super Hi-Res on): a few seconds, a click
  waitfor(function() return mem:read_u16(V.TITLEWAIT) ~= 0 and mem:read_u8(0xC029) >= 0x80 end, 9000)
  wait(240)
  click()
  print("title clicked at frame " .. raw)
  -- the mission setup: every map's preview, NORMAL, START
  waitfor(function() return mem:read_u16(V.OPTWAIT) == 1 end, 600)
  wait(50)
  movep(28, area(1))                             -- NORMAL
  click()
  wait(20)
  local rx, ry = area(17, 3)                     -- the map: the next one
  moveto(rx, ry, 24)
  for _ = 1, 4 do wait(40); click() end          --   (round to Green Valley)
  wait(30)
  movep(30, area(32))                            -- START
  wait(10)
  click()
  print("START at frame " .. raw)

  -- the base: a power plant, a barracks, a war factory
  waitfor(function() return mem:read_u16(V.GAMEGO) == 0xC0DE end, 600)
  wait(70)
  build('pp_p')
  movep(30, tile(9, 14))
  place('pp_p', 2, 16)
  build('bar_p')
  movep(30, tile(10, 20))
  place('bar_p', 2, 21)
  build('fact_p')
  tending = true                                 -- soldiers meanwhile
  movep(30, tile(11, 15))
  place('fact_p', 5, 16)
  print("base built at frame " .. raw)
  -- an army: built side by side for a while
  movep(40, tile(12, 21))
  local t0 = raw
  waitfor(function() return raw - t0 >= 2700 end, 2800)
  tending = false
  wait(60)
  print(string.format("army: %d tanks, %d infantry at frame %d", #tanks(), #infantry(), raw))

  -- the infantry, then the tanks, to a rally point by the road
  boxselect(infantry())
  order(13, 20)
  boxselect(tanks())
  order(14, 18)
  waitfor(function()                             -- (until all are there)
    for _, i in ipairs(army()) do
      local c = G.tile(i)
      if c < 10 then return false end
    end
    return true
  end, 900)
  wait(30)
  boxselect(army())                              -- all of them: off we go
  follow = true
  order(20, 16)
  moveto(150, 160, 30)
  waitfor(function() local i = lead(); return not i or G.tile(i) >= 19 end, 1500)
  order(20, 12)
  moveto(200, 170, 30)
  waitfor(function()                             -- (the slow ones catch up)
    local i = lead()
    if not i then return true end
    local c0, r0 = G.tile(i)
    for _, j in ipairs(army()) do
      local c, r = G.tile(j)
      if math.abs(c - c0) + math.abs(r - r0) > 5 then return false end
    end
    return true
  end, 900)
  wait(30)

  -- the battle: attack the nearest enemy unit in sight (closer first if
  -- none is), again whenever the lead unit has nothing to shoot at
  local t1, advanced = raw, false
  while raw - t1 < 3600 do
    local i = lead()
    if not i or #army() < 3 then break end       -- (all but gone)
    local j, d = nearestenemy(i)
    if DEBUG then
      print(string.format("  %d: lead %d at (%d,%d) target %04X, army %d, enemy %s d=%s", raw, i,
        G.w(V.UTILE, i) % 32, G.w(V.UTILE, i) // 32, G.w(V.UTARGET, i), #army(), tostring(j), tostring(d)))
    end
    if not j or d > 7 then
      if not advanced then                       -- none in sight: closer
        order(21, 9)
        advanced = true
        moveto(200, 170, 30)
      elseif raw - t1 > 1200 then
        break                                    -- (none left near)
      end
    elseif G.w(V.UTARGET, i) == 0xFFFF then
      follow = false
      local x, y = G.unitxy(j)
      if x >= 8 and x < 248 and y >= 16 and y < 192 then
        movep(20, x, y)
        click()                                  -- (a red cross)
        print(string.format("attack at frame %d: unit %d at (%d,%d)", raw, j,
          G.w(V.UTILE, j) % 32, G.w(V.UTILE, j) // 32))
        moveto(math.min(240, x + 40), math.min(185, y + 50), 30)
      end
      follow = true
    end
    wait(60)
  end
  follow = false                                 -- (the view stays there)
  wait(240)
  print(string.format("demo done at frame %d (game frame %d): %d of ours left", raw,
    G.w(V.FRAME), #army()))
end

local co = coroutine.create(demo)
sub = emu.add_machine_frame_notifier(function()
  raw = raw + 1
  local rd = mem:read_u8(0xC013) >= 0x80          -- (main memory, as gs.lua)
  local wr = mem:read_u8(0xC014) >= 0x80
  if rd then mem:write_u8(0xC002, 0) end
  if wr then mem:write_u8(0xC004, 0) end
  if glide then
    glide.t = glide.t + 1
    local u = glide.t / glide.n
    u = u * u * (3 - 2 * u)                       -- (eased)
    cur.x = math.floor(glide.x0 + (glide.x1 - glide.x0) * u + 0.5)
    cur.y = math.floor(glide.y0 + (glide.y1 - glide.y0) * u + 0.5)
    if glide.t >= glide.n then glide = nil end
  end
  if mem:read_u16(V.OPTWAIT) == 1 or mem:read_u16(V.GAMEGO) == 0xC0DE then
    mem:write_u16(V.CX, cur.x); mem:write_u16(V.CY, cur.y)
  end
  if follow and raw % 10 == 0 then view() end
  if coroutine.status(co) ~= "dead" then
    local ok, err = coroutine.resume(co)
    if not ok then print("demo: " .. tostring(err)) end
  else
    manager.machine:exit()
  end
  if rd then mem:write_u8(0xC003, 0) end
  if wr then mem:write_u8(0xC005, 0) end
end)
