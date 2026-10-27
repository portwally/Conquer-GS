-- Sound test: asks the game for each sound effect in turn, one second
-- apart (writing its SND_ bit into sndreq), and prints when; run with
-- -wavwrite <file> and check the recording with tools/soundcheck.py.
local V = dofile("tools/vars.lua")
local mem = manager.machine.devices[":maincpu"].spaces["program"]
local tick = dofile("tools/clock.lua")
local sym = {}
for line in io.lines("build/symbols.txt") do
  local a, n = line:match(";00/(%x+);([%w_]+);")
  if n then sym[n] = tonumber(a, 16) end
end
local names = {"cannon", "rifle", "mgun", "rocket", "boom", "ready", "place"}
local f = 0
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == f then return end
  f = nf
  if f > 700 then mem:write_u16(V.AICREDITS, 0) end              -- quiet enemy
  if f == 700 then print("sounds loaded: " .. (mem:read_u16(sym.soundok) ~= 0 and "yes" or "NO")) end
  for k, name in ipairs(names) do
    if f == 700 + 60 * k then
      mem:write_u16(V.SNDREQ, 1 << (k - 1))
      print(string.format("play %s at %.4f s", name, manager.machine.time:as_double()))
    end
  end
  if f == 700 + 60 * (#names + 1) then manager.machine:exit() end
end)
