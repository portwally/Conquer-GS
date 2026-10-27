# Conquer GS

A real-time strategy game in the style of Command & Conquer for the Apple IIgs,
written in 65816 assembly.

## Build and run

```
./build.sh   # graphics -> assemble -> build/conquer.po (800K ProDOS boot disk)
./run.sh     # boot the disk in MAME (the copy inside Ample)
```

The disk holds ProDOS 8, the game (CONQUER.SYSTEM), its packed graphics
(CONQUER.DATA), its sound effects (CONQUER.SOUND) and the title picture
(CONQUER.TITLE, from `assets/title.shr`). The game reads its files from its own folder, or else
from the top folder of the disk it started from. The title shows as soon as
it is loaded; CLICK TO START appears on it once the game is ready, and a
click or a key goes on to the options screen (see Options and maps):
choose the difficulty and the map, then click START or press RETURN. After
a game ends, a click on the banner brings the options back, set as last
time. Without CONQUER.TITLE the options screen comes straight away, without
CONQUER.SOUND it is silent; if CONQUER.DATA is missing or damaged it says
so on the text screen and stops.

## Controls

- The world is 32x24 tiles (twice the screen in each direction); where the
  bases are depends on the map. Scroll the view one
  tile at a time with the arrow keys or by holding the mouse against any
  edge of the screen, or click the radar to center the view there.
- The radar shows the whole world: your units and buildings in gold, the
  enemy's in red, and a white frame around the part you are looking at.
- M turns the music off or on.
- Rest the mouse on a unit or a building for a moment and its name shows
  below the arrow (yours in gold, the enemy's in red); on a build icon, its
  name and price.
- Fog of war: the map and the radar stay black where none of your units has
  been. Units see around them as they move (soldiers and the harvester 3
  tiles, tanks 4, turrets 5, buildings 4), and what they have seen stays
  uncovered. Enemies in the dark are not shown and cannot be clicked, so a
  click there is a move order; you can send units into the dark, but not
  place structures there.
- Click one of your (gold) units to select it, or drag a box around several.
- With units selected, click open ground to move there (green cross cursor)
  or click an enemy to attack it (red cross cursor).
- Units find their way around water, trees, rocks and buildings, one unit
  per tile. Idle units of the same side step aside to let others through
  (harvesters only when they have no work); a unit whose way is blocked by
  units that cannot move waits and keeps trying instead of giving up. Armed units fire at enemies in range on their own and shoot back
  when hit.
- The harvester works on its own: it mines the nearest ore (25 credits a
  scoop, 500 a load), drives to the dock next to the command center and
  unloads into your credits. Click an ore field to send it there, or
  elsewhere to park it. Mined-out tiles turn to bare dirt.
- Build from the sidebar. Structures and units build in two separate queues,
  one item each at a time; the cost is paid up front and a bar under the
  icon shows progress (half speed when power is low).
  - Units roll out next to the command center: tank (800 credits, 8 s),
    harvester (1000, 10 s), buggy (300, 5 s). Soldiers (100, 3 s) and
    rocket soldiers (300, 5 s) need a barracks and come out next to it -
    their icons are greyed out until you have one.
  - Structures show READY when done. Click the icon again and move the mouse
    over the map: the outline is green where the structure fits, red where it
    doesn't (it needs open ground without ore or units, not the harvester
    dock, within 4 tiles of one of your buildings). Click to place it, or
    click the icon again to stop placing. Power plant (300, 6 s, 2x2,
    +100 power), barracks (500, 8 s, 2x2, uses 30), turret (600, 8 s, 1x1,
    uses 40, turns to fire at enemies in range).
- Power: the command center makes 100, each power plant 100. The top bar shows
  used/made (red when you use more than you make) and so does the sidebar bar
  (green up to what is made, a light mark at what is used).
- Destroyed structures leave the ground as it was; units can walk there again.
- Units and their weapons:

  | Unit | Hit points | Range | Speed | Weapon |
  |------|-----------:|------:|-------|--------|
  | Tank | 120 | 3 | medium | cannon, 15 |
  | Buggy | 90 | 2 | fast (twice a tank) | machine gun, 5, rapid |
  | Soldier | 40 | 2 | slow | rifle, 6 |
  | Rocket soldier | 30 | 4 | slow | rockets, 15, slow to reload |
  | Harvester | 200 | - | slow | none |
  | Turret | 200 | 4 | - | cannon, 20 |

  What a hit does depends on the weapon and what it hits (infantry,
  vehicles, or buildings including turrets). Cannons and rifles do their
  full damage to everything; the machine gun does double to infantry but a
  quarter to vehicles and buildings; rockets do double to vehicles, 1.5x to
  buildings and little to infantry (3/8). Rocket hits show a small blast.
- SELL and REPAIR (below the power bar) are switches: click one and it shows
  pressed. While selling, click one of your structures to sell it for half
  its price (the command center cannot be sold). While repairing, click a
  damaged structure to repair it: 4 hit points every 8 frames for 3 credits,
  with a blinking wrench over it, until it is whole or you run out of
  credits; click it again to stop. The cursor shows $ or a wrench over what
  you can sell or repair, and a no sign elsewhere. Click the button again,
  empty ground or a build icon to stop selling or repairing.

## Sound

Sound effects play on the IIgs's Ensoniq sound chip: cannon shots (tanks,
turrets), rifle shots, the buggy's machine gun, rockets, explosions, a
chime when a unit rolls out or a structure is ready, and a thud when one
is placed. Shots and explosions are heard when they happen on screen (none
from inside the fog), production and placing only for your own. The volume
is the one set in the IIgs control panel.

The cannon, rifle and machine gun are real recordings in the public domain
(CC0): a Mosin Nagant rifle shot and a PPSh burst from "The Free Firearm
Sound Library" (Ben Jaszczak, Brian Nelson, Kevin Heras, Matthew Nanney)
and "cannon fire" by Thimras, both from OpenGameArt; `assets/sounds/`
holds them prepared for the chip, with the details in
`assets/sounds/CREDITS.txt`. The other sounds are synthesized by
`tools/makesound.py` (sine waves and noise), which uses a recording from
`assets/sounds/` instead wherever there is one. It also writes every sound
as a WAV file to `build/gfx/sounds/` to listen to.

How it works: CONQUER.SOUND is an image of the chip's 64K sound RAM (50K
used, with the music's instruments: a sample only has to start on a multiple of its table size, so the
smaller ones fill the ends of the bigger ones' tables), streamed into it at
start. The chip has 32 oscillators: 0-9 play the music, the rest the
sound effects. Each voice of a sound is two of them (the left and the
right channel), set up once to play its 13,160 Hz sample once
("one-shot": it stops at the sample's 0 byte). The cannon, rifle, machine
gun and rockets have two voices each, the explosion, chime and thud one.
Events during a frame set a bit per sound; at the end of the frame each
requested sound restarts its voice - with two, the other one than last
time, so a second shot right after the first doesn't cut it off.

### Music

Two original loops play on the same chip, with the sound effects on top:
the title tune (8 bars in E minor at about 128 beats a minute, 15 seconds
a loop) on the title and options screens, and the battle tune during a
game: 16 bars in A minor at 150 beats a minute (26 seconds a loop) with a
galloping sixteenth-note bass, a riff that climbs through two eight-bar
halves, a sixteenth-note arpeggio, syncopated kicks with snare fills and
sixteenth-note hi-hats - mixed under the sound effects (about a quarter as
loud as the title tune). Each has a bass, a melody, an arpeggio, kick and
snare, and a hi-hat. MUSIC
ON / OFF on the options screen turns both off or on (the choice stays for
the next game), and so does the M key during a game.

`tools/makemusic.py` holds the scores and the instruments. The bass, lead
and arpeggio are each one 256-byte waveform cycle the chip loops
("free-run"), on two oscillators (left and right); the player sets their
pitch through the frequency register and shapes every note with a volume
envelope, once a video frame (writing a volume only when it changes). The
drums are short one-shot samples on four more oscillators. A score is a
step sequence (16 steps a bar, 7 or 6 frames a step): one byte per voice
per step (nothing, a note, or note off). The script writes both tunes'
steps, the frequency table they share and each tune's numbers - tempo,
length, envelopes, drum volumes, waves - for the program
(`build/gfx/music.bin`, `musfreq.bin`, `mustracks.bin`) and
`build/gfx/music_preview.wav` and `battle_preview.wav`, the loops rendered
as the chip and the player make them. `tools/makesound.py` packs the
instruments into CONQUER.SOUND with the effects. In a game the tune keeps
time by its own clock: whenever the screen's line counter (VERTCNT) has
started over since it last looked, a video frame has passed and the tune
moves a frame on. It looks before and after each wait for the blank and
inside the long loops (every 8 cells redrawn, every 16 units, between the
parts of the full-view copy), so it keeps the beat even through a scroll,
whose redraw of the whole view takes several frames.

## Options and maps

Before each game the options screen - a mission setup in the style of a
tactical display: the CONQUER GS logo, riveted gunmetal panels, green
headings and corner brackets, scanlines - sets the difficulty (EASY,
NORMAL - the first choice - or HARD), the map and the music (ON or OFF):
click a button (the chosen ones light up green) or a map's preview, then
the red START button. The choices stay for the next
game. A preview shows the map's terrain and your base (a gold dot), but
not the enemy's: where they are, you find out by scouting.

- GREEN VALLEY: your base in the south-west, the enemy's in the north-east;
  a river from the north ends in a lake in the middle, with roads around
  it. Ore by each base, in the middle and far in the south-east.
- RIVER CROSSING: your base in the south-east, the enemy's in the
  north-west; a river runs from north to south through the middle and can
  only be crossed at a ford in the north and one in the south. Ore by each
  base, by each ford and far in two corners.

The difficulty sets how the enemy plays (see The enemy); you always start
with 2500 credits.

## The enemy

The enemy starts with some credits, earns a steady trickle more and
builds soldier, rocket soldier, tank, soldier, buggy, rocket soldier, over
and over, at its barracks, with at most a few of the units it built alive
at once. New units gather there. After a while its first attack wave
leaves; after that, waves go at least some seconds apart, one unit bigger
each time up to a limit, and units beyond the wave's size stay home. A
wave marches on your command center, fighting anything it meets on the
way. Its starting units stay home and defend. All units and structures
share one table of 48; when it is full and the enemy cannot build, its
next wave goes with as many units as its first. The numbers per
difficulty (`DIFFICULTIES` in `tools/makegfx.py`):

| | EASY | NORMAL | HARD |
|---|---|---|---|
| credits at the start | 400 | 700 | 1000 |
| earns, a second | 7.5 | 15 | 22.5 |
| first wave after | 3 min | 2 min | 90 s |
| then waves at least apart | 80 s | 60 s | 45 s |
| wave size, first to most | 2 to 4 | 3 to 5 | 3 to 6 |
| its units out at once, at most | 5 | 6 | 8 |

HARD is how the enemy played before there was a choice.

How hard that is: on GREEN VALLEY a player who does nothing loses after
about 4 3/4 minutes on EASY, 2 3/4 on NORMAL and 2 on HARD; on RIVER
CROSSING the enemy's way over a ford is longer (about 2 3/4 minutes on
NORMAL and on HARD). Two turrets by the command center and a few tanks
hold the base through the 8 minutes `tools/defendtest.lua` plays: on
NORMAL without a scratch on the command center, on HARD slowly losing
units if the harvester is lost and nothing is rebuilt.

**You win** when the barracks and every enemy unit (the turret included) are
destroyed. **You lose** when your command center is destroyed. Click the banner
to play again. Buildings have hit points like units: click the barracks with
units selected to attack it.


MAME captures the mouse; switch away with Cmd-Tab.

## Testing

`tools/battletest.lua` plays a scripted game (a soldier walks around the
command center, box select, an attack across the map) and prints the unit table, then dumps
screen memory to `build/mame/*.bin` (render with `tools/shr2png.py`):

```
./run.sh -video none -sound none -nothrottle -seconds_to_run 120 -autoboot_script tools/battletest.lua
```

`tools/aitest.lua` lets the enemy play against an idle player until the game
ends (printing when the first wave left, the command center was first hit
and the game ended, and what the enemy built), then clicks to restart;
`tools/defendtest.lua` plays a simple defense (two turrets, then tanks
while there is money) for up to 8 minutes (`-seconds_to_run 900`); `tools/wintest.lua` removes the enemy's units and
destroys the barracks with one tank. Both print progress as they go (each
needs `-seconds_to_run 400`). Test scripts get game addresses from
`tools/vars.lua`, which reads `build/equates.lua`: `build.sh` evaluates every
`equ` in `src/main.s` and the generated equates with `tools/equates.py`, so
the scripts always match the program. `run.sh` turns the Mac's mouse off in
scripted runs (`-autoboot_script`), so it cannot move the game's cursor
under a test. The scripts move the view and lift the fog through small test
hooks the game checks at the start of each frame (`G.look`, `G.seeall` in
`tools/gs.lua`).

`tools/buildtest.lua` builds and places a power plant (after a refused spot
on water), a barracks and a turret, trains a soldier at the barracks, then
has an enemy tank destroy the power plant, printing power, queues and the
structures as it goes (`-seconds_to_run 200`).

`tools/scrolltest.lua` scrolls with the mouse at the screen edge, jumps
with a radar click and sends a tank across the world (`-seconds_to_run 200`).

`tools/fogtest.lua` checks the fog of war: what is seen at the start, that
the enemy base is black with its units hidden and unclickable, then sends a
tank there and checks as it goes that the fog table, the black cells on
screen and the radar all agree with what the units have seen
(`-seconds_to_run 200`). The other tests that fight across the map lift
the fog first (`G.seeall()` in `tools/gs.lua`).

Most scripts use `tools/gs.lua` for clicks, frame steps and reading the unit
tables. It switches memory reads back to main RAM while a script looks at
the game, because a frame can end in the middle of the screen copy, which
runs with bank 0 mapped to bank 1.

`tools/selltest.lua` builds a power plant and a turret, damages and repairs
them (checking hit points against the credits paid, the pressed button and
the cursors), sells both (checking the refund, power and that their tiles
open up), then tries a repair without enough credits (`-seconds_to_run 200`).

`tools/blocktest.lua` boxes a new buggy in at the exit with parked units
and checks it gets out, then holds the units around a tank in place and
checks it keeps its order and gets through once they can move
(`-seconds_to_run 200`). Since parked units step aside for others, the
tests that place structures first clear the spot (`G.clear()` in
`tools/gs.lua`) and park the harvester.

`tools/typetest.lua` builds a buggy, a barracks and a rocket soldier from the
sidebar and checks their stats, times the buggy and a tank over open ground,
then sets up single fights to check the damage of each weapon against each
kind of armor (`-seconds_to_run 200`). `tools/aitest.lua` also prints which
unit types the enemy built.

The scripts count video frames with `tools/clock.lua`, which holds the
count at 659 while the disk is loading and skips the title (it clears the
game's TITLEWAIT word; `SHOWTITLE=1` keeps it) and the options screen
whenever it comes up (OPTWAIT; `SHOWOPTIONS=1` keeps it), so the game
always starts at frame 660 however long loading takes. It chooses the
difficulty and the map from `DIFFICULTY` (0-2, default 2: HARD, how the
enemy played before there was a choice, so the tests keep their meaning)
and `MAP` (0 or 1, default 0), and turns the music off unless `MUSIC=1`
(so the sound tests hear only the effects), e.g.
`DIFFICULTY=1 MAP=1 ./run.sh ... -autoboot_script tools/aitest.lua`.
`tools/titletest.lua` checks the title instead: the screen must match
`build/gfx/title_expected.bin` (the picture with CLICK TO START, made by
`tools/makegfx.py`), stay until a click, and the options screen must
follow (`-seconds_to_run 200`). `tools/optionstest.lua` checks that screen:
it must match `build/gfx/options_expected.bin` (but under the arrow);
clicking HARD and the second map's preview must press those buttons as in
`options_expected2.bin`; music OFF must stop the title tune and press its
button (`options_expected3.bin`); START must begin a game on that map at
HARD, without music; after
the game ends a click must bring the options back with the same choices,
and RETURN must start the next game (`-seconds_to_run 120`).
`tools/labeltest.lua` rests the mouse on one of our tanks, the command
center, a build icon and an enemy tank: each time the right name tag must
be on the screen byte for byte, and gone over open ground
(`-seconds_to_run 60`). `tools/wintest.lua` prints how long a new game
takes to start after the click (about 2.5 seconds). Build icon positions
come from `build/gfx/icons.lua`, the options screen's buttons from
`options.lua` and the tags from `labels.lua`, all written by
`tools/makegfx.py`.

`tools/soundtest.lua` asks the game for each sound in turn; run it with
`-wavwrite build/mame/sound.wav`, keep its output in `build/mame/sound.log`,
then `python3 tools/soundcheck.py build/mame/sound.wav build/mame/sound.log`
checks the recording: each sound must start right after it was asked for
and be the same waveform as the original (so the chip plays it whole, at
the right rate), the chime at the right pitches, on both channels. `tools/soundevents.lua` watches the game's writes to the
sound chip during play: a fight on screen must be heard, one off screen
not, and building must chime and thud (`-seconds_to_run 150`).

`tools/musictest.lua` stays at the title for 32 seconds of music, clicks,
goes through the options screen (the title tune plays on there), lets the
battle tune play 45 seconds in the game, presses M, asks for a sound
effect and presses M again; run it with
`-wavwrite build/mame/music.wav -seconds_to_run 300`, keep its output in
`build/mame/music.log`, then
`python3 tools/musiccheck.py build/mame/music.wav build/mame/music.log`
compares the recording with `tools/makemusic.py`'s rendering of each tune:
each bar as loud as in the render, the same again a loop later, each
bar's bass on its chord's root, both channels; the battle tune quieter
than the title's (about a quarter as loud); silence after M, the sound
effect heard, and the music back after M again. The test also logs every
write the game makes to the music's oscillators in the game
(`build/mame/musicwrites.txt`): every note of the battle tune must reach
the chip on its step's frame, at its frequency on both sides, and every
frame's volumes must be the render's.

`tools/tempotest.lua` (run with `MUSIC=1`, `-seconds_to_run 200`) counts
how far the battle tune moves against video frames: standing still,
scrolling the view back and forth, and with every unit of ours sent across
the map; each must keep at least 97% of the beat (they keep 99.8-100%).

`tools/econtest.lua` watches the harvester for a few minutes of game time and
builds a tank, printing credits and harvester state as they change:

```
./run.sh -video none -sound none -nothrottle -seconds_to_run 200 -autoboot_script tools/econtest.lua
```

`run.sh` passes extra arguments to MAME. To grab a screenshot without
watching:

```
PROBE_FRAMES=900 ./run.sh -sound none -nothrottle -autoboot_script tools/probe.lua
```

This saves `build/mame/snap/apple2gs/0000.png` and a raw dump of video memory
(`build/mame/shr.bin`; render it with `tools/shr2png.py`). For the art,
`tools/artshots.lua` (`-seconds_to_run 60`) dumps three screens: the start,
the enemy base with the fog lifted, and our units fighting there
(`build/mame/art_base.bin`, `art_enemy.bin`, `art_fight.bin`).

## Layout

| Path | What |
|------|------|
| `src/main.s` | the game (Merlin 32 syntax), a ProDOS 8 SYS file at $2000 |
| `tools/makegfx.py` | draws the art (see Art) and writes IIgs-format data (`conquer.data` and the tables the program includes) plus `preview.png` |
| `assets/title.shr` | the title picture (Super Hi-Res screen image: 320 mode, 16 palettes) |
| `tools/makesound.py` | synthesizes the sound effects and lays them out for the sound chip |
| `tools/makemusic.py` | the title music: score, instruments, and a preview rendered as the chip plays it |
| `assets/sounds/` | the recorded shots (CC0), prepared for the chip |
| `tools/merlin32` | Merlin 32 assembler, built from the v1.2b2 source |
| `vendor/` | ProDOS 2.4.3 kernel and Merlin's macro library |

## Rendering

Memory banks: $E1 is the visible screen, $01 a work buffer, $02 the top
bar and sidebar background, $03-$05 the UI layer and the two end banners,
$07 the sprite and tile pixels, $06 the compiled sprites and tiles plus
the screen-copy routine, and $08 CONQUER.DATA as loaded. The UI layer,
banners, sprites and tiles are stored run-length compressed in
CONQUER.DATA. Before it takes over the machine, the game reads that file
through ProDOS (4 KB at a time into bank 0, then on to bank $08) and
unpacks from there, at start and on every restart. The file also holds the options screen, the name tags
(unpacked after the sprites in bank $07) and each map as one packed block:
its tiles, which are blocked, its ore, its radar picture, the starting
buildings and units, where harvesters unload, where new units appear and
the first view. When a game starts the chosen map's block is unpacked
into `mapblk` in the program (and its radar picture into the sidebar
layer), so the code works on whichever map it is; the options screen
unpacks both blocks once to draw their previews (each block has its own
preview picture: the radar's without the enemy's base pad). The options screen
itself is drawn straight onto the screen with a clean copy in bank $01
(free before a game), the arrow saved and restored under itself.

The world is a 32x24 tile map; the view shows 16x12 tiles of it. Units keep
world pixel positions and are only drawn when they are in view. The map
itself is never stored as pixels: every tile is compiled into a routine that
draws it, and a building is a few overlay pieces drawn over the ground of
its tiles.

The screen is divided into 20x13 cells of 16x16 pixels, lined up with the map
tiles (row 0 is the 8-line top bar), so a unit standing on a tile covers
exactly one cell. Each frame, cells under anything that changed go on a dirty
list; they are redrawn (the tile and any building piece, or the UI from its
background), units, effects, the selection box and the cursor are drawn into
the work buffer, and only those cells are copied to the screen. Effects only
dirty their cells when they appear, change or vanish.

Scrolling moves the view one tile at a time: all 192 cells of the view are
redrawn and the view is copied to the screen in six parts of 32 lines (so
the music can keep time in between), with the stack pointer walking the
screen rows and `PEI` pushing 64 words per row (bank 0 is mapped onto the
work buffer in bank 1 for the copy). A scroll step takes about 12 frames.

The radar is drawn once in full after the view moves. After that, every 32
frames it redraws only dots whose unit moved, appeared or died (a few per
frame, so no frame gets the whole job), each pixel as terrain, then dots,
then the view frame on top.

Fog of war: a table in bank $01 (above the work buffer) holds a word per
tile: not seen yet, or seen plus a bit for each of its 8 neighbors that is
still unseen. A cell of an unseen tile is drawn black; a seen tile next to
unseen ones gets soft black edges (one sprite per side, and per corner where
neither side next to it has one). When a unit steps onto a new tile it looks
around in a circle; tiles seen for the first time go into a queue, and each
frame uncovers a few of them, as many as the time left in that frame allows
(it reads the scan line counter, $C02E). Uncovering a tile redraws it and
any neighbor whose edges change, and copies its radar pixels from a copy
of the radar terrain kept in bank $03.

Sprites are compiled at start-up into code in bank $06: one routine per
sprite that stores its solid words directly and masks only edge words (the
masks are derived from the pixels: color 0 is transparent). Tiles are
compiled the same way without masks. The fog's edge sprites are compiled to
draw black where their pixels are set.

Pathfinding is breadth-first search on a copy of the map with a wall border
(the world has one, so no edge checks), with paths stored as one direction
byte per step. One search runs at a time, last in each frame, for as many
steps as the frame has time left for (4 to 64; it reads the scan line
counter); a unit stands still for the few frames until its path is ready.
Attack routes end at the first reachable tile from which the target is in
range. Units take turns: each decides what to do every other frame (half of
them each frame; harvesters every frame), idle units look for targets every
32 frames, and walking is staggered by unit number, so the work is spread
evenly over frames. Units standing still are not looked at again by the
drawing code unless something about them changed.

Game state lives at fixed addresses in bank 0, so test scripts can read it:
per-tile tables and search buffers at $0800-$1FFF, and from $9000 the unit
tables (a word per slot, 48 slots for units and structures), dirty cells,
paths, ore and the rest (the fog table, its queue and the sprite code
entries are at $01/A000). The program loads at $2000 and must end below
$9000 (`build.sh` checks); it is 22 KB of the 28 KB that allows. ProDOS 8
only loads a start-up program into bank 0, which it shares with the stack,
the text screen, these tables and ProDOS itself, hence the limit; data goes
in other banks.

## Performance

The game runs at 60 fps in normal play (the benchmark's slowest 5 seconds:
60 fps). In `tools/stress.lua` with `STRESS_ALL=1` (immortal units
fighting, the enemy filling the unit table, the whole player army
re-ordered every 4 seconds, exploring as it goes) and `STRESS_END=18000`
(so the table fills: 46-48 units), the worst 5-second stretch is 51-55
fps and the run averages 58.5, with the music on or off. The name tags cost about 1 fps of that average
here (the mouse rests where the crowd fights, so a tag is often showing);
without them it is 59.4 and 56. (These runs are exactly repeatable, but a
small change in timing anywhere changes what the units do, so their worst
stretch moves by a fps or two from build to build.) Scrolling is the
exception: each scroll step costs about 12 frames.

Measuring tools (all print to the terminal; run like the tests above, with
`-seconds_to_run 400`):

- `tools/bench.lua`: enemy with unlimited money, frame rate every 5 seconds.
  `PROFILE=<frame>` adds a breakdown of memory reads per routine.
- `tools/stress.lua`: the worst case described above (`STRESS_END` sets
  how long it runs; `-seconds_to_run 900` for 18000 frames).
- `tools/profile.lua`: the same battle, then counts program reads per
  routine for 300 frames from `PROFILE_AT` (default 14000, when the unit
  table is full) and lists the busiest routines.
- `tools/frametime.lua`: times each phase of the main loop per frame and lists
  the slowest frames with their dirty cells, tiles uncovered and radar
  pixels (`FT_FROM`/`FT_TO` pick the frames, `FT_STRESS=1` sends the army
  around as in the stress test, `FT_ALL=1` keeps everyone alive as
  `STRESS_ALL` does, `FT_NOFOG=1` lifts the fog).

## Screen

320x200 Super Hi-Res, one 16-color palette. 8-line top bar, a 16x12 view of
16x16 tiles onto the 32x24 world (256x192 pixels), and a 64-pixel sidebar
with the radar (48x36 pixels, 1.5 per tile).

## Art

All the art is original, drawn by `tools/makegfx.py` in the screen's 16
colors with the light from the top left: lit edges up and left, shaded
ones down and right, a dark outline, a shadow on the ground. Your side is
gold, the enemy red.

- The units (16x16) are drawn by hand as grids of letters, one per pixel:
  the tank (its turret lit on top, casting a shadow on the hull), the
  harvester (an ore hopper and a cab with a windshield), the buggy (four
  wheels, a driver and a machine gun), the soldier (helmet, face, rifle)
  and the rocket soldier (a launcher on the shoulder). Each faces the way
  it moves: right, left (the same, mirrored), up (seen from behind: the
  tank's barrel forward, the soldier's back with the rifle over his
  shoulder) or down (from the front); sideways and diagonal moves turn it
  left or right, straight up or down moves turn it that way, and units
  that shoot (turrets too) turn toward the target the way it is furthest.
  The enemy's are the same drawings in red. Each unit type has its four
  sprites one after the other: right, left, up, down (flags F_LEFT and
  F_VERT pick one).
- The buildings and the defense turret are little 3D models made of
  1-pixel blocks (boxes, cylinders, domes, a hut's half cylinder, waisted
  cooling towers), drawn as seen from the south at an angle: tops facing
  the light are lit and south walls shaded, parts cast shadows onto lower
  parts and onto the ground, and where one part meets a lower one it gets
  a dark line. The command center (a hall with a radar dome and a command
  tower flying a flag, on its 3x3 pad), the barracks (a Quonset hut with a
  porch and sandbags; 2x2, or in the middle of the enemy's 3x3 pad), the
  power plant (a hall with two cooling towers), the turret (a gun dome on
  a concrete base, drawn with its barrel right, left, up and down, the
  light still from the left, so it turns toward its target) and the
  sidebar icons of the power plant and barracks are made this way.

## Requirements

The game needs an Apple IIgs with at least 1 MB of memory (memory banks
up to $08): a ROM 01 with a memory card, or a ROM 3. MAME emulates a 2 MB
IIgs by default.

To build and test it: Python 3, Cadius (`brew install cadius`) and Ample,
which includes MAME and the `apple2gs` ROM set.
