# Building Conquer GS

How to build the boot disk from the sources, run it in MAME and run the
tests. To just play, download the disk from the
[Releases](https://github.com/portwally/conquer-gs/releases) page instead
(see the [README](../README.md)). How the game works inside is in
[TECHNICAL.md](TECHNICAL.md).

## What you need

- **Python 3**, for the tools that make the graphics, sounds and music.
- **Cadius** (`brew install cadius`), to make the ProDOS disk image.
- **Ample**, which includes MAME and the `apple2gs` ROM set, to run and
  test the game. `run.sh` expects it at `/Applications/Emulatoren/Ample.app`
  and its ROMs in `~/Library/Application Support/Ample`; change the two
  paths at the top of `run.sh` if yours are elsewhere.
- **Merlin 32**, the assembler, is included: `tools/merlin32` is built for
  macOS (Apple silicon) from the v1.2b2 source; on another system build it
  from its source and put it there. Its macro library is in
  `vendor/merlin32/`.

## Build and run

```
./build.sh   # graphics, music, sounds -> assemble -> build/conquer.po
./run.sh     # boot the disk in MAME
```

(Both also run with `sh build.sh` and `sh run.sh`.)

`build.sh`:

1. `tools/makegfx.py` draws all the art and writes the packed graphics
   (`build/gfx/conquer.data`) and the tables the program includes
   (`build/gfx/*.bin`, `gfxequ.s`), plus pictures to look at
   (`build/gfx/preview.png`, `preview2.png`, `options_preview.png`,
   `labels.png`).
2. `tools/makemusic.py` writes the two tunes (`music.bin`, `musfreq.bin`,
   `mustracks.bin`, `musequ.s`) and renders them to listen to
   (`music_preview.wav`, `battle_preview.wav`).
3. `tools/makesound.py` makes the sound effects and packs them with the
   music's instruments into an image of the sound chip's RAM
   (`build/gfx/conquer.sound`, `sndtab.bin`, `sndequ.s`); every sound is
   also written as a WAV file to `build/gfx/sounds/`.
4. Merlin 32 assembles `src/main.s` into CONQUER.SYSTEM (it must end below
   $9000; `build.sh` checks), and `tools/equates.py` writes every equate and
   the program's labels to `build/equates.lua` for the test scripts.
5. Cadius makes `build/conquer.po`, an 800K ProDOS disk with ProDOS 2.4.3,
   CONQUER.SYSTEM, CONQUER.DATA, CONQUER.SOUND and CONQUER.TITLE (the title
   picture, from `assets/title.shr`).

The game reads its files from its own folder, or else from the top folder
of the disk it started from. Without CONQUER.TITLE the options screen comes
straight away, without CONQUER.SOUND the game is silent; if CONQUER.DATA is
missing or damaged it says so on the text screen and stops.

`run.sh` passes extra arguments to MAME, and turns the Mac's mouse off when
a test script runs (`-autoboot_script`), so it cannot move the game's cursor
under a test. MAME captures the mouse; switch away with Cmd-Tab.

## Repository layout

| Path | What |
|------|------|
| `src/main.s` | the game (Merlin 32 syntax), a ProDOS 8 SYS file at $2000 |
| `tools/makegfx.py` | draws the art and writes the graphics, maps, options screen and name tags |
| `tools/makemusic.py` | the two tunes: scores, instruments, and previews rendered as the chip plays them |
| `tools/makesound.py` | makes the sound effects and lays them out in the sound chip's RAM |
| `tools/equates.py` | evaluates the program's equates for the test scripts |
| `tools/*.lua` | test and measuring scripts for MAME (below) |
| `tools/*check.py`, `tools/shr2png.py` | check recordings, turn screen dumps into PNGs |
| `tools/merlin32` | Merlin 32 assembler, built from the v1.2b2 source |
| `assets/title.shr` | the title picture (Super Hi-Res screen image: 320 mode, 16 palettes) |
| `assets/sounds/` | the recorded shots (CC0), prepared for the chip, and their credits |
| `vendor/` | ProDOS 2.4.3 and Merlin's macro library |
| `docs/` | these documents and the README's screenshots |

## Tests

The tests are Lua scripts MAME runs while the game plays. Run them like
this (`-seconds_to_run` as given for each; `-nothrottle` runs as fast as
the Mac allows):

```
./run.sh -video none -sound none -nothrottle -seconds_to_run 120 -autoboot_script tools/battletest.lua
```

Most print their findings and end with `problems: 0` when all is well.

### How the scripts work

- They get the game's addresses from `tools/vars.lua`, which reads
  `build/equates.lua` (written by `build.sh`), so they always match the
  program.
- They count video frames with `tools/clock.lua`, which holds the count at
  659 while the disk loads, so the game always starts at frame 660 however
  long loading takes. It skips the title (it clears the game's TITLEWAIT
  word; `SHOWTITLE=1` keeps it) and the options screen whenever it comes up
  (OPTWAIT; `SHOWOPTIONS=1` keeps it). It chooses the difficulty and the map
  from `DIFFICULTY` (0-2, default 2: HARD, how the enemy played before there
  was a choice, so the tests keep their meaning) and `MAP` (0 or 1, default
  0), and turns the music off unless `MUSIC=1` (so the sound tests hear only
  the effects), e.g. `DIFFICULTY=1 MAP=1 ./run.sh ... -autoboot_script
  tools/aitest.lua`.
- Most use `tools/gs.lua` for clicks, frame steps and reading the unit
  tables. It switches memory reads back to main RAM while a script looks at
  the game, because a frame can end in the middle of the screen copy, which
  runs with bank 0 mapped to bank 1. The scripts move the view, lift the
  fog and turn the radar on without a radar center through small hooks the
  game checks (`G.look`, `G.seeall`, `G.radar`). Since parked units step
  aside for others, the
  tests that place structures first clear the spot (`G.clear()`) and park
  the harvester.
- Build icon positions come from `build/gfx/icons.lua`, the options screen's
  buttons from `options.lua` and the name tags from `labels.lua`, all written
  by `tools/makegfx.py`.

### Gameplay

- `tools/battletest.lua` (120 s): a scripted game (a soldier walks around the
  command center, box select, an attack across the map); prints the unit
  table and dumps the screen to `build/mame/*.bin`.
- `tools/aitest.lua` (400 s): the enemy plays against an idle player until
  the game ends; prints when the first wave left, when the command center
  was first hit, when the game ended and what the enemy built, then clicks
  to restart.
- `tools/defendtest.lua` (900 s): a simple defense (two turrets, a
  barracks and a war factory, then tanks while there is money) for up to 8
  minutes.
- `tools/wintest.lua` (400 s): removes the enemy's units and its other
  buildings and destroys the barracks with one tank, then prints how long a
  new game takes to start after the click (about 2.5 seconds).
- `tools/queuetest.lua` (70 s): a soldier, a tank, a harvester and a power
  plant build at the same time, each in its own queue; a rocket soldier
  and a buggy clicked meanwhile are ignored; the units come out by the
  barracks, the war factory and the command center. Three soldiers
  queued, one taken back with an Option-click (the test sets `optheld`),
  two come out; a structure stopped with an Option-click, money back.
- `tools/movefiretest.lua` (60 s): a tank sent along the road past an enemy
  tank shoots it on the way without stopping, and gets where it was sent.
- `tools/rallytest.lua` (60 s): rally points for the barracks and the war
  factory; their new units walk there.
- `tools/rebuildtest.lua` (120 s): the enemy rebuilds its power plant (once
  our tank leaves its spot) and its barracks, on the same spots.
- `tools/endtest.lua` (60 s): the end-of-game panel's numbers; dumps it
  (`build/mame/end_lose.bin`).
- `tools/harvtest.lua` (200 s): harvesters have 400 hit points; the
  enemy's harvester unloads at its refinery's door and the enemy gets its
  share a scoop; killed, a new one comes by the refinery's door in 30
  seconds (none while the refinery is gone), and it never joins a wave;
  our harvester waits with no ore left and goes back to work once ore has
  grown back.
- `tools/bldtest.lua` (200 s): the new buildings (built at once by the
  script, `G.quickbuild`): we start with a command center only, the war
  factory needs a barracks; the radar is off (and says so) until a radar
  center stands, then on, and off again with too little power; a refinery
  comes with a harvester and a second dock where harvesters unload; a
  guard tower stands like a turret; tanks roll out of
  the war factory, and after it is sold none can be built. Then the enemy:
  infantry out of its barracks, vehicles out of its war factory, none of
  those once the factory is gone, no income without its refinery and half
  speed without its power plant.
- `tools/buildtest.lua` (200 s): builds and places a power plant (after a
  refused spot on water), a barracks and a turret, trains a soldier, then has
  an enemy tank destroy the power plant, printing power, queues and the
  structures as it goes.
- `tools/selltest.lua` (200 s): builds a power plant and a turret, damages
  and repairs them (checking hit points against the credits paid, the
  pressed button and the cursors), sells both (checking the refund, power
  and that their tiles open up), then tries a repair without enough credits.
- `tools/typetest.lua` (200 s): a barracks and a war factory (at once),
  then builds a buggy and a rocket soldier and checks their stats,
 times the buggy and a tank over open
  ground, then sets up single fights to check the damage of each weapon
  against each kind of armor.
- `tools/blocktest.lua` (200 s): boxes a new buggy in by the war factory
  with parked units and checks it gets out, then holds the units around a
  tank in place and checks it keeps its order and gets through once they
  can move.
- `tools/econtest.lua` (200 s): watches the harvester for a few minutes and
  builds a tank, printing credits and the harvester's state.
- `tools/scrolltest.lua` (200 s): scrolls with the mouse at the screen
  edge, jumps with a radar click (the radar turned on by the script) and
  sends a tank across the world.

- `tools/fogtest.lua` (200 s): the fog of war: what is seen at the start,
  that the enemy base is black with its units hidden and unclickable; then a
  tank goes there while the script checks that the fog table, the black
  cells on screen and the radar agree with what the units have seen. (The
  other tests that fight across the map lift the fog first.)

### Screens

- `tools/titletest.lua` (200 s): the title must match
  `build/gfx/title_expected.bin` (the picture with CLICK TO START, made by
  `tools/makegfx.py`), stay until a click, and the options screen must
  follow.
- `tools/optionstest.lua` (120 s): the options screen must match
  `build/gfx/options_expected.bin` (but under the arrow); clicking HARD and
  the map (the next one) must show as in `options_expected2.bin`; the
  arrows must go back and forth through the maps, round from the first to
  the last; music OFF must stop the title tune and light its button
  (`options_expected3.bin`); START must begin a game on that map at HARD,
  without music; after the game ends a click must bring the options back
  with the same choices, and RETURN must start the next game.
- `tools/pausetest.lua` (120 s, run with `SHOWOPTIONS=1`): Space must
  unselect, end selling and stop placing a structure; Esc must stop the
  game (its frame count, a moving tank, the music) under the pause panel,
  byte for byte; RESUME and Space must go on; QUIT MISSION must bring back the mission
  setup, and a new game must start from there.

- `tools/labeltest.lua` (60 s): rests the mouse on one of our tanks, the
  command center, a build icon and an enemy tank; each time the right name
  tag must be on the screen byte for byte, and gone over open ground.

### Sound and music

- `tools/soundtest.lua` (120 s) asks the game for each sound in turn. Run it
  with `-wavwrite build/mame/sound.wav`, keep its output in
  `build/mame/sound.log`, then
  `python3 tools/soundcheck.py build/mame/sound.wav build/mame/sound.log`
  checks the recording: each sound must start right after it was asked for
  and be the same waveform as the original (so the chip plays it whole, at
  the right rate), the chime at the right pitches, on both channels.
- `tools/soundevents.lua` (150 s) watches the game's writes to the sound
  chip during play: a fight on screen must be heard, one off screen not,
  and building must chime and thud.
- `tools/musictest.lua` (300 s) stays at the title for 32 seconds of music,
  clicks, goes through the options screen (the title tune plays on there),
  lets the battle tune play 45 seconds in the game, presses M, asks for a
  sound effect and presses M again. Run it with
  `-wavwrite build/mame/music.wav`, keep its output in
  `build/mame/music.log`, then
  `python3 tools/musiccheck.py build/mame/music.wav build/mame/music.log`
  compares the recording with `tools/makemusic.py`'s rendering of each tune:
  each bar as loud as in the render, the same again a loop later, each bar's
  bass on its chord's root, both channels; the battle tune quieter than the
  title's (about a quarter as loud); silence after M, the sound effect
  heard, and the music back after M again. The test also logs every write
  the game makes to the music's oscillators in the game
  (`build/mame/musicwrites.txt`): every note of the battle tune must reach
  the chip on its step's frame, at its frequency on both sides, and every
  frame's volumes must be the render's.
- `tools/tempotest.lua` (run with `MUSIC=1`, 200 s) counts how far the
  battle tune moves against video frames: standing still, scrolling the view
  back and forth, and with every unit of ours sent across the map; each
  must keep at least 97% of the beat (they keep 99.8-100%).

## Measuring speed

These print to the terminal; run them like the tests, with
`-seconds_to_run 400`:

- `tools/bench.lua`: the enemy with unlimited money; the frame rate every 5
  seconds. `PROFILE=<frame>` adds a breakdown of memory reads per routine.
- `tools/stress.lua`: the worst case: immortal units fighting
  (`STRESS_ALL=1`), the enemy filling the unit table, the whole player army
  re-ordered every 4 seconds. `STRESS_END` sets how long it runs
  (`STRESS_END=18000` with `-seconds_to_run 900` fills the table).
- `tools/profile.lua`: the same battle, then counts program reads per
  routine for 300 frames from `PROFILE_AT` (default 14000, when the unit
  table is full) and lists the busiest routines.
- `tools/frametime.lua`: times each phase of the main loop per frame and
  lists the slowest frames with their dirty cells, tiles uncovered and radar
  pixels (`FT_FROM`/`FT_TO` pick the frames, `FT_STRESS=1` sends the army
  around as in the stress test, `FT_ALL=1` keeps everyone alive as
  `STRESS_ALL` does, `FT_NOFOG=1` lifts the fog).

## Screenshots

To grab a screenshot without watching:

```
PROBE_FRAMES=900 ./run.sh -sound none -nothrottle -autoboot_script tools/probe.lua
```

This saves `build/mame/snap/apple2gs/0000.png` and a dump of video memory
(`build/mame/shr.bin`; `python3 tools/shr2png.py build/mame/shr.bin out.png`
turns it into a picture). `tools/artshots.lua` (60 s) dumps three screens
for looking at the art: the start, the enemy base with the fog lifted, and
our units fighting there (`build/mame/art_base.bin`, `art_enemy.bin`,
`art_fight.bin`).

## A demo video

`tools/demo.lua` plays a game from the title to a battle the way a person
would (the arrow glides from one thing to the next): the mission setup, a
power plant, a barracks and a war factory, an army built side by side,
the march on the enemy's base with the view following it, the battle.
Record it with MAME (about four minutes; the raw file is several GB):

```
./run.sh -video none -sound none -nothrottle -seconds_to_run 400 -aviwrite demo.avi -autoboot_script tools/demo.lua
```

That writes `build/mame/snap/demo.avi` (704 x 228, the border included;
the Ensoniq's sound on its second and third channels). The title shows
about 23 seconds in, after the disk has loaded. To make an MP4 from there,
the picture cropped and scaled up 4 times with sharp pixels:

```
ffmpeg -ss 22.9 -i build/mame/snap/demo.avi -vf "crop=640:200:32:14,scale=1280:800:flags=neighbor" -af "pan=stereo|c0=c1|c1=c2,volume=8dB,alimiter=limit=0.95" -c:v libx264 -crf 18 -pix_fmt yuv420p -tune animation -c:a aac -b:a 192k -movflags +faststart build/conquer-gs-demo.mp4
```
