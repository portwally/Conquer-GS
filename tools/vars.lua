-- Addresses and constants of the game for the MAME test scripts: every
-- equ in src/main.s and build/gfx/gfxequ.s, evaluated by tools/equates.py
-- into build/equates.lua when building. Each is here under its name in
-- capitals (uflags -> V.UFLAGS, frame -> V.FRAME, F_DEAD -> V.F_DEAD).
local E = dofile("build/equates.lua")
local V = {}
for k, v in pairs(E) do V[k:upper()] = v end
V.SEEALL = E.seeallf            -- set to 1: the game reveals everything
return V
