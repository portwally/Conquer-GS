# How Conquer GS works

The inside of the game: how it starts, where things live in memory, how it
draws, moves units, plays the enemy, makes sound and music, and how the art
is made. How to build and test it is in [BUILDING.md](BUILDING.md); how to
play is in the [README](../README.md).

## The program

The game is one ProDOS 8 SYS file, CONQUER.SYSTEM, written in 65816
assembly for Merlin 32 (`src/main.s`). ProDOS loads it at $00/2000 in
emulation mode. While ProDOS is still in charge, it loads its data files;
then it switches to native mode, disables interrupts, turns off shadowing of
banks 0 and 1 and never returns to ProDOS.

### Start-up

1. The text screen shows CONQUER GS and LOADING; the loader prints a dot for
   every 4K it reads.
2. CONQUER.TITLE (a Super Hi-Res screen image, from `assets/title.shr`)
   loads straight into screen memory in bank $E1, not shown yet.
3. CONQUER.DATA (the packed graphics, maps, options screen and name tags)
   loads into bank $08.
4. CONQUER.SOUND (an image of the sound chip's RAM) streams into the sound
   chip.
5. The game unpacks the graphics, compiles the sprites into code, then shows
   the title with CLICK TO START and starts the title tune; after a click,
   the options screen; then the chosen map is unpacked and the game starts.

Each file is looked for next to the program, else at the top of the startup
disk; the loader reads through ProDOS 4 KB at a time into bank 0 and copies
on from there. In MAME at normal speed the loading takes about 12 seconds
after ProDOS has booted (the title 3.3 s, CONQUER.DATA 3.1 s, CONQUER.SOUND
5.4 s), the preparing about half a second.

### Memory

The game needs a IIgs with at least 1 MB (banks up to $09).

| Bank | What |
|------|------|
| $00 | the program ($2000-$8FFF, at most 28K: `build.sh` checks), its tables from $0800 and from $9000, ProDOS and the stack |
| $01 | the work buffer (what the screen will show), the fog table ($A000), its queue ($A600), the sprite code entries ($AE00) |
| $02 | the background of the top bar and sidebar |
| $03 | the top bar and sidebar layer, with a copy of the radar's terrain at +$8000 |
| $04, $05 | the two end-of-game banners |
| $06 | the compiled sprites, and the screen copier at $F000 |
| $07 | the sprite and tile pixels, then the name tags and the radar's "offline" picture |
| $08 | CONQUER.DATA as loaded (up to 64K) |
| $09 | the compiled map tiles |
| $E1 | the visible Super Hi-Res screen |

Game state lives at fixed addresses in bank 0, so test scripts can read it:
per-tile tables and search buffers at $0800-$1FFF, and from $9000 the unit
tables (a word per slot, 48 slots for units and structures), dirty cells,
paths, ore and the rest. ProDOS 8 only loads a start-up program into bank 0,
which it shares with the stack, the text screen, these tables and ProDOS
itself, hence the program's limit; data goes in other banks. Four words at
$BE00-$BE0A are kept from game to game and watched by the test scripts:
TITLEWAIT, GAMEGO, OPTWAIT, and the chosen difficulty, map and music.

CONQUER.DATA holds, run-length packed: the top bar and sidebar layer, the
two banners, the sprites and tiles, the CLICK TO START line, the options
screen, the name tags and each map as one block. It is unpacked at start and
again at every restart.

## The screen

320x200 Super Hi-Res, one 16-color palette: an 8-line top bar (credits and
power), a 16x12-tile view (256x192 pixels) of the 32x24-tile world, and a
64-pixel sidebar with the radar (48x36 pixels, 1.5 per tile), the build
icons, the power bar and the SELL and REPAIR buttons.

## Drawing

The screen is divided into 20x13 cells of 16x16 pixels, lined up with the
map tiles (row 0 is the top bar), so a unit standing on a tile covers
exactly one cell. Each frame, cells under anything that changed go on a
dirty list; they are redrawn (the tile and any building piece, or the UI
from its background), then units, effects, the selection box, a name tag
and the cursor are drawn into the work buffer, and only those cells are
copied to the screen. Effects only dirty their cells when they appear,
change or vanish. Units standing still are not looked at again unless
something about them changed.

The map is never stored as pixels: every tile is compiled into a routine
that draws it, and a building is a few overlay pieces drawn over the ground
of its tiles. Sprites are compiled at start-up into code in bank $06: one
routine per sprite that stores its solid words directly and masks only edge
words (the masks come from the pixels: color 0 is see-through). Tiles are
compiled the same way without masks; the fog's edge sprites draw black
where their pixels are set. `tools/makegfx.py` checks that the compiled code
fits below the screen copier (48K of 60K now). Compiled code can't cut a
sprite off at the screen's edge, so the cursor, which may run off the right
and bottom edges, is drawn there pixel by pixel instead (`drawclip`): the
arrow's tip can reach the last pixel, where the view scrolls, past the
sidebar's icons.

Scrolling moves the view one tile at a time: all 192 cells of the view are
redrawn and the view is copied to the screen in six parts of 32 lines, with
the stack pointer walking the screen rows and `PEI` pushing 64 words per row
(bank 0 is mapped onto the work buffer in bank 1 for the copy). A scroll
step takes about 12 frames.

The radar is drawn once in full after the view moves. After that, every 32
frames it redraws only dots whose unit moved, appeared or died (a few per
frame), each pixel as terrain, then dots, then the view frame on top. It
works only while we have a radar center and enough power (`radaron`, set
by `calcpower` whenever our buildings change); otherwise it shows its
"offline" picture and a click on it does nothing.

### Fog of war

A table in bank $01 holds a word per tile: not seen yet, or seen plus a bit
for each of its 8 neighbors that is still unseen. A cell of an unseen tile
is drawn black; a seen tile next to unseen ones gets soft black edges (one
sprite per side, and per corner where neither side next to it has one).
When one of our units steps onto a new tile it looks around in a circle
(soldiers and the harvester 3 tiles, tanks 4, turrets 5, buildings 4);
tiles seen for the first time go into a queue, and each frame uncovers a few
of them, as many as the time left in that frame allows (it reads the scan
line counter, $C02E). Uncovering a tile redraws it and any neighbor whose
edges change, and copies its radar pixels from the radar's terrain kept in
bank $03. Enemies on unseen tiles are not drawn and cannot be clicked: an
enemy or an effect (a hit, an explosion) is drawn only when the tiles
under all four of its corners have been seen (`anyunseen`), so none shows
halfway into the dark.

## Units

Every unit and structure has a slot in the unit tables: sprite, tile, world
position, flags, hit points, weapon numbers, path and so on. Units walk from
tile to tile, one unit per tile.

Each unit type has four sprites one after the other: facing right, left
(the same, mirrored), up and down; the flags F_LEFT and F_VERT pick one.
A unit turns left or right when its next tile is in another column, up or
down when it moves straight up or down, and toward its target (the way it
is furthest) when it shoots; turrets and guard towers turn too.

### Structures

Everything that can be built has a template (`templates()` in
`tools/makegfx.py`, 30 bytes each): sprite, flags, speed, hit points,
weapon, cost, build time, size, power, armor and weapon class, name tag,
and the template of the building it needs. Turrets and guard towers are
units that never move (F_STATIC); the other structures are buildings
(F_BUILDING): their slot's sprite is their template, its cargo and state
words hold the top-left tile and size of their footprint (walled off in
the passability table), and they are drawn as 16x16 pieces with the map.
The starting buildings come from the map like the units.

Our side builds in four queues (`QUEUES` in `tools/makegfx.py`; each icon
names its own): structures, infantry, vehicles and harvesters, one item
each at a time, all four at once (`production` runs each queue's
`prodq` every frame). A click on an icon whose queue is busy with
something else does nothing; on the unit it is building, it queues one
more (`qmore`, up to 5 in all, the number drawn on the icon from a fifth
set of digit glyphs), paid at once; when one is out the next starts.
With Option or Apple held (`KEYMODS`, $C025) a click takes one back, or
stops the queue (a ready structure: not placed), and refunds it. The
enemy builds one unit at a time.

A click on our barracks or war factory, then on open ground, sets its
rally point (kept in the building's `udock` word, which only harvesters
use otherwise; `findbld` leaves the building it found in `bldat`): its
new units walk there (`torally`).

A building's door is the tile below its bottom-left corner. Units come out
by the door of the building they need (`findbld`): soldiers a barracks,
tanks and buggies a war factory, for both sides, and a war factory a
barracks (the template's "needs" works for structures too); without one,
its icons are greyed out. Harvesters need nothing and come out by the
command center (the map's exit tile, where units also appear whose
building is gone meanwhile). Our harvesters unload at a dock: the one next
to the command center or one in front of a refinery (its door).
`calcpower` keeps the list of docks along with the power; a harvester
heads for the nearest (column plus row distance), and if that refinery is
gone on the way, for the next. No structure may be placed on a dock, and
units of the harvester's side parked on one move aside. A refinery comes
with a harvester. The enemy's harvester works the same way and unloads at
its refinery's door (`nearestdock`, `dockok`).

A harvester (`harvest`) seeks the nearest ore nobody stands on, mines a
scoop every 8 frames, goes home with a full load and unloads a scoop
every 4 frames. With no ore to find, or no dock (the enemy's refinery
gone), it waits (`H_WAIT`, 4 seconds) and looks again. Each ore
tile starts with 24 scoops (600 credits); the map draws it mined out
when it has none left. Ore grows back (`regrow`): every 2048 frames a
sweep, one tile a frame through the map's list of ore tiles, gives each
tile below full and not built on 3 scoops more, and redraws one that was
mined out.

### Pathfinding

Breadth-first search on a copy of the map with a wall border (the world has
one, so there are no edge checks); a path is one direction byte per step.
One search runs at a time, last in each frame, for as many steps as the
frame has time left for (4 to 64; it reads the scan line counter); a unit
stands still for the few frames until its path is ready. Attack routes end
at the first reachable tile from which the target is in range. Idle units of
the same side step aside to let others through (harvesters only when they
have no work); a unit whose way is blocked by units that cannot move waits
and keeps trying.

Units take turns: each decides what to do every other frame (half of them
each frame; harvesters every frame), idle units look for targets every 32
frames, and walking is staggered by unit number, so the work is spread
evenly over frames.

### Combat

Damage is the weapon's damage times a factor for what it hits (infantry,
vehicles, buildings including turrets), in eighths:

| Weapon | Infantry | Vehicles | Buildings |
|---|---:|---:|---:|
| Cannon, rifle | 1 | 1 | 1 |
| Machine gun | 2 | 1/4 | 1/4 |
| Rockets | 3/8 | 2 | 1.5 |

Armed units fire at enemies in range on their own and shoot back when hit.
Every 32 frames an armed unit looks for an enemy in range, also while it
walks: one found on the way (F_MFIRE) is shot at whenever the unit has
reloaded, without stopping, and dropped once out of range; when the unit
arrives it becomes an ordinary target.
Shots and explosions are heard when they happen on screen (not inside the
fog).

## The enemy

The enemy's base has a barracks, a war factory, a refinery, a power plant,
a turret and two guard towers. It starts with some credits and a
harvester; for each scoop the harvester unloads at its refinery it gets
its share, and without a harvester (while its refinery stands) the
refinery makes a new one, free, in 30 seconds, building nothing else
meanwhile. Its harvester is not one of the units it built: it never joins
a wave. It builds soldier, rocket soldier,
tank, soldier, buggy, rocket soldier, over and over - infantry at its
barracks, vehicles at its war factory, skipping what it has no building
for, at half speed without its power plant - with at most a few of the
units it built alive at once. New units gather by their building's door
(`standing` checks that a building in a remembered slot is still the one
it was). After a while its first attack wave leaves;
after that, waves go at least some seconds apart, one unit bigger each time
up to a limit, and units beyond the wave's size stay home. A wave marches on
the command center, fighting anything it meets on the way. Its starting
units stay home and defend. All units and structures share one table of 48;
when it is full and the enemy cannot build, its next wave goes with as many
units as its first. It rebuilds its buildings (`airebuild`): when one
is gone, it has the money (`STRUCTS`: 500 to 1500) and no unit stands on
the spot, it puts it up there again after its build time (15 to 25
seconds; `putbld`, shared with our placing), the refinery first, then
the power plant, the war factory, the barracks; nothing else is built
meanwhile. The numbers per difficulty (`DIFFICULTIES` in
`tools/makegfx.py`):

| | EASY | NORMAL | HARD |
|---|---|---|---|
| credits at the start | 400 | 700 | 1000 |
| credits for each scoop (25) its harvester unloads | 4 | 6 | 9 |
| first wave after | 3 min | 2 min | 90 s |
| then waves at least apart | 80 s | 60 s | 45 s |
| wave size, first to most | 2 to 4 | 3 to 5 | 3 to 6 |
| its units out at once, at most | 5 | 6 | 8 |

How hard that is (`tools/aitest.lua`): a player who does nothing loses
after about this many minutes.

| | EASY | NORMAL | HARD |
|---|---:|---:|---:|
| Green Valley | 6 1/4 | 2 3/4 | 2 1/4 |
| River Crossing (the way over a ford is long) | 6 1/4 | 3 1/2 | 3 1/2 |
| Twin Lakes | 4 | 2 3/4 | 2 1/4 |
| Stone Pass | 5 | 2 3/4 | 2 1/4 |

At its limit of units the enemy sends what it has, so units held up
somewhere can't stop it from attacking. Two turrets by the command center,
then a barracks, a war factory and a few tanks hold the base through the 8
minutes `tools/defendtest.lua` plays, on NORMAL and on HARD, without a
scratch on the command center.

You win when every enemy unit and building is gone, and lose when your
command center falls. The end-of-game panel (taller than the pause
panel, 6 cell rows) shows what the game counted: our units built and
lost, enemy units and buildings destroyed, credits from ore and the time
played (`drawstats` writes them into the panel's layer when it ends).

## Pausing

P pauses: the main loop then only moves the arrow and redraws, so the
game's frame count, the units, production and the enemy all stand still,
and the music stops (it starts again from the top on RESUME). The pause
panel is drawn like the end-of-game banners, over the middle of the view;
its picture is unpacked into the win banner's bank at +$8000. RESUME (or P,
Space, RETURN) goes on; QUIT MISSION (or Q) goes back to the mission setup
the way the end of a game does. Space unselects the units and stops placing
a structure (it stays ready), selling or repairing.

## Maps

Each map is painted from a few shapes in `tools/makegfx.py`
(`green_valley`, `river_crossing`, `twin_lakes`, `stone_pass`; the border
is impassable) and described
in `MAPS`: its starting buildings (our command center; the
enemy's barracks, war factory, refinery and power plant) and units, where
harvesters unload, where new units appear when no building makes them and
the first view.

- Green Valley: our base in the south-west, the enemy's in the north-east;
  a river from the north ends in a lake in the middle, with roads around it.
  Ore by each base, in the middle and far in the south-east.
- River Crossing: our base in the south-east, the enemy's in the
  north-west; a river runs from north to south through the middle and can
  only be crossed at a ford in the north and one in the south. Ore by each
  base, by each ford and far in two corners.
- Twin Lakes: our base in the north-west, the enemy's in the south-east;
  two lakes in the middle with a land bridge between them, so there are
  three ways across. Ore by each base, on either side of the bridge and in
  two corners.
- Stone Pass: our base in the west, the enemy's in the east; a ridge of
  rock and forest runs from north to south and can only be crossed at a
  pass in the north and one in the south. Ore by each base, at each pass
  and in two corners.

Each map goes into CONQUER.DATA as one packed block (`MAP_BLOCK`): those
positions, the tiles, which tiles are blocked, the ore in each, the radar
picture, a preview picture (the radar's without the enemy's base pad), the
starting buildings' pieces and the starting units. When a game starts the
chosen map's block is unpacked into `mapblk` in the program and its radar
picture into the sidebar layer, so the code works on whichever map it is.
`map_checks` makes sure that nothing stands where it shouldn't and that
every building's door, the dock and the exit can be reached from the rest
of the map (units step only straight past wall corners). The tiles of all
the maps share one tile set. A table made with
CONQUER.DATA (`maptab.bin`) gives each map's block.

## The options screen

Before each game: the difficulty, the map and the music, then START. The
screen is drawn by `tools/makegfx.py` (logo, panels, buttons) and packed
into CONQUER.DATA. The game unpacks it into bank $01 (free before a game),
copies it to the screen and draws each button from that clean copy, lit
(its colors through the `optbtn` table: green) when it is the chosen one.
One map shows at a time, picked with the arrows (or a click on it for the
next): its preview picture at twice its size, a gold dot on our base, and
its name below (pictures of the names wait in the sprite bank after the
name tags). A click still held from the title or the last game doesn't
count: the button must go up first. The arrow is drawn straight onto the

screen, what it covers saved and put back as it moves. The choices are kept
in the words at $BE06-$BE0A for the next game.

## Name tags

When the mouse has rested on a unit or building we can see, or on a build
icon, for a moment, its name (and an icon's price) shows below the arrow:
ours in gold, theirs in red. The tags are drawn by `tools/makegfx.py`,
packed into CONQUER.DATA and unpacked into bank $07 after the sprites; each
frame the game looks at what is under the resting mouse every 8th frame and
draws the tag into the work buffer when its cells are redrawn.

## Sound

Sound effects play on the IIgs's Ensoniq sound chip: cannon shots (tanks,
turrets), rifle shots, the buggy's machine gun, rockets, explosions, a
chime when a unit rolls out or a structure is ready, and a thud when one
is placed. The volume is the one set in the IIgs control panel.

The cannon, rifle and machine gun are recordings in the public domain (CC0;
see [assets/sounds/CREDITS.txt](../assets/sounds/CREDITS.txt)), prepared for
the chip in `assets/sounds/`. The other sounds are synthesized by
`tools/makesound.py` from sine waves and noise; it uses a recording from
`assets/sounds/` instead wherever there is one.

CONQUER.SOUND is an image of the chip's 64K sound RAM (50K used, with the
music's instruments: a sample only has to start on a multiple of its table
size, so the smaller ones fill the ends of the bigger ones' tables),
streamed into it at start. The chip has 32 oscillators: 0-9 play the music,
the rest the sound effects. Each voice of a sound is two of them (the left
and the right channel), set up once to play its 13,160 Hz sample once
("one-shot": it stops at the sample's 0 byte). The cannon, rifle, machine
gun and rockets have two voices each, the explosion, chime and thud one.
Events during a frame set a bit per sound; at the end of the frame each
requested sound restarts its voice (with two, the other one than last time,
so a second shot right after the first doesn't cut it off).

### Music

Two original loops: the title tune (8 bars in E minor at about 128 beats a
minute, 15 seconds a loop) on the title and options screens, and the battle
tune during a game (16 bars in A minor at 150 beats a minute, 26 seconds a
loop: a galloping sixteenth-note bass, a riff that climbs through two
eight-bar halves, a sixteenth-note arpeggio, syncopated kicks with snare
fills and sixteenth-note hi-hats), mixed under the sound effects at about a
quarter of the title tune's loudness. Each has a bass, a melody, an
arpeggio, kick and snare, and a hi-hat.

`tools/makemusic.py` holds the scores and the instruments. The bass, lead
and arpeggio are each one 256-byte waveform cycle the chip loops
("free-run"), on two oscillators (left and right); the player sets their
pitch through the frequency register and shapes every note with a volume
envelope, once a video frame (writing a volume only when it changes). The
drums are short one-shot samples on four more oscillators. A score is a step
sequence (16 steps a bar, 7 or 6 frames a step): one byte per voice per step
(nothing, a note, or note off). The script writes both tunes' steps, the
frequency table they share and each tune's numbers (tempo, length,
envelopes, drum volumes, waves) for the program, and renders the loops as
the chip and the player make them, to listen to.

In a game the tune keeps time by its own clock: whenever the screen's line
counter (VERTCNT) has started over since it last looked, a video frame has
passed and the tune moves a frame on. It looks before and after each wait
for the blank and inside the long loops (every 8 cells redrawn, every 16
units, between the parts of the full-view copy), so it keeps the beat even
through a scroll. MUSIC ON / OFF on the options screen and the M key in a
game turn it off or on.

## Art

All the art is original, drawn by `tools/makegfx.py` in the screen's 16
colors with the light from the top left: lit edges up and left, shaded ones
down and right, a dark outline, a shadow on the ground. Our side is gold,
the enemy red.

- The units (16x16) are drawn by hand as grids of letters, one per pixel:
  the tank (its turret lit on top, casting a shadow on the hull), the
  harvester (an ore hopper and a cab with a windshield), the buggy (four
  wheels, a driver and a machine gun), the soldier (helmet, face, rifle) and
  the rocket soldier (a launcher on the shoulder), each facing right (left
  is the same mirrored), up (seen from behind) and down (from the front).
- The buildings and the turret are little 3D models made of 1-pixel blocks
  (boxes, cylinders, domes, a hut's half cylinder, waisted cooling towers),
  drawn as seen from the south at an angle: tops facing the light are lit
  and south walls shaded, parts cast shadows onto lower parts and onto the
  ground, and where one part meets a lower one it gets a dark line. The
  command center (a hall with a radar dome and a command tower flying a
  flag, on its 3x3 pad), the barracks (a Quonset hut with a porch and
  sandbags), the power plant (a hall with two cooling towers), the war
  factory (a long hall with a big door, a control room and a stack), the
  refinery (a hall with an unloading bay and two silos), the radar center
  (a dish on a mast, tilted toward the viewer), the turret (a gun dome on a
  concrete base, its barrel facing each of the four ways) and the guard
  tower (a small tower with a machine gun on its platform) are made this
  way. The sidebar's 16x16 icons of the structures are the same models at
  half size (each 2x2x2 block becomes one, in its most telling material).

- The terrain tiles (grass, dirt roads, water, ore, trees, rocks, concrete)
  are drawn procedurally, with edges where they meet other ground.
- The options screen, the name tags, the banners and the fonts are drawn
  there too; the title picture is `assets/title.shr`.

## Performance

The game runs at 60 frames a second in normal play (the benchmark's slowest
5 seconds: 60 fps). In the stress test (immortal units fighting, the enemy
filling the unit table, the whole player army re-ordered every 4 seconds,
46-48 units) the worst 5-second stretch is 51-55 fps and the run averages
58.5, with the music on or off. The name tags cost about 1 fps of that
average there (the mouse rests where the crowd fights, so a tag is often
showing). These runs are exactly repeatable, but a small change in timing
anywhere changes what the units do, so their worst stretch moves by a fps
or two from build to build. Scrolling is the exception: each scroll step
costs about 12 frames.
