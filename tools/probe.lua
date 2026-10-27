-- Debug probe: after PROBE_FRAMES frames print CPU state, dump Super Hi-Res
-- memory ($E1/2000-$E1/9FFF) to build/mame/shr.bin, snapshot, then quit.
local frames = 0
local target = tonumber(os.getenv("PROBE_FRAMES") or "900")
local tick = dofile("tools/clock.lua")   -- (the game starts at frame 660)
sub = emu.add_machine_frame_notifier(function()
  local nf = tick()
  if nf == frames then return end
  frames = nf
  if frames == target then
    local cpu = manager.machine.devices[":maincpu"]
    local mem = cpu.spaces["program"]
    print(string.format("PC=%04X PB=%02X NEWVIDEO=$%02X", cpu.state["PC"].value,
      cpu.state["PB"].value, mem:read_u8(0xE0C029)))
    local f = io.open("build/mame/shr.bin", "wb")
    for a = 0xE12000, 0xE19FFF do f:write(string.char(mem:read_u8(a))) end
    f:close()
    local g = io.open("build/mame/bank0.bin", "wb")
    for a = 0x2000, 0x4FFF do g:write(string.char(mem:read_u8(a))) end
    g:close()
    manager.machine.video:snapshot()
  end
  if frames == target + 5 then manager.machine:exit() end
end)
