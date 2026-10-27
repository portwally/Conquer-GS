![Conquer GS title screen](docs/images/title.png)

# Conquer GS

A real-time strategy game for the Apple IIgs in the spirit of Command &
Conquer, written from scratch in 65816 assembly. Build a base, harvest ore,
train an army and destroy the enemy, at 60 frames a second in Super Hi-Res,
with Ensoniq sound and music.

## Features

- **Base building:** a command center, power plants, barracks and gun
  turrets. Place structures where you want them; sell or repair them.
- **Economy:** your harvester mines ore fields and brings the credits home;
  power plants keep production at full speed.
- **Five kinds of units:** tanks, fast buggies, soldiers, rocket soldiers
  and the harvester, with weapons that are strong or weak against
  infantry, vehicles and buildings.
- **A computer opponent** that builds an army and attacks in waves, at three
  difficulties: easy, normal and hard.
- **Two maps,** Green Valley and River Crossing, with fog of war: you have
  to scout to find the enemy.
- **A scrolling battlefield** twice the size of the screen, with a radar
  that shows the whole world.
- **Original pixel art** in Super Hi-Res (320x200, 16 colors); units face the
  way they move.
- **Recorded weapon sounds and two original music tracks** on the Ensoniq
  sound chip.
- **Name tags:** rest the mouse on a unit, a building or a build icon to see
  what it is (and what it costs).

## Screenshots

| | |
|---|---|
| ![The start of a game](docs/images/start.png) | ![A base](docs/images/base.png) |
| The start of a game on Green Valley | A base with a power plant, barracks and a turret |
| ![A battle](docs/images/battle.png) | ![River Crossing](docs/images/river-crossing.png) |
| A fight at the enemy base | River Crossing, with a name tag on a tank |
| ![Build icons](docs/images/build-icons.png) | ![Mission accomplished](docs/images/win.png) |
| Build icons show their name and price | Mission accomplished |

## Download and play

Download **conquer.po** from the
[Releases](https://github.com/portwally/conquer-gs/releases) page: an 800K
ProDOS disk that boots straight into the game.

**You need** an Apple IIgs (ROM 01 or ROM 3) with at least 1 MB of memory
and a mouse, or an emulator.

- **On a real IIgs:** write the disk image to a 3.5" disk, or use it with a
  FloppyEmu, BlueSCSI or similar device, and boot from it. The game also
  finds its files in a folder on a hard disk: copy CONQUER.SYSTEM,
  CONQUER.DATA, CONQUER.SOUND and CONQUER.TITLE into one folder and start
  CONQUER.SYSTEM.
- **In MAME** (on a Mac, easiest through [Ample](https://github.com/ksherlock/ample)):
  choose the Apple IIgs (ROM 3 or ROM 01) with 1 MB of memory or more (2 MB
  is the default), put conquer.po in the first 3.5" drive and start it.

The game has been tested in MAME. It takes a little while to load (the
screen says LOADING and counts along with dots); then the title appears
with its music.

## How to play

**Your goal:** destroy the enemy's barracks and every enemy unit. You lose
if your command center is destroyed. After a game, click the banner to play
again.

### Starting a game

![The mission setup screen](docs/images/options.png)

Click (or press a key) on the title. On the mission setup screen choose:

- **Difficulty:** easy, normal or hard.
- **Map:** Green Valley or River Crossing. The preview shows your base as a
  gold dot; where the enemy is, you find out by scouting.
- **Music:** on or off.

Then click START or press RETURN. Your choices are kept for the next game.

### Controls

| To... | Do this |
|---|---|
| Select a unit | Click it |
| Select several units | Drag a box around them |
| Move | With units selected, click open ground (a green cross) |
| Attack | With units selected, click an enemy (a red cross) |
| Scroll the view | Arrow keys, or hold the mouse at an edge of the screen |
| Jump to a place | Click it on the radar |
| Build | Click an icon in the sidebar |
| Place a structure | When it says READY, click the icon again, then a spot where the outline is green |
| Sell or repair | Click SELL or REPAIR, then one of your structures; click the button again to stop |
| See what something is | Rest the mouse on it |
| Turn the music off or on | M |

### Economy and power

- You start with 2500 credits. Your harvester mines the nearest ore on its
  own (25 credits a scoop, 500 a load) and unloads at the dock next to your
  command center. Click an ore field to send it there, or elsewhere to park
  it.
- Structures and units build in two separate queues, one of each at a time.
  The cost is paid up front; a bar under the icon shows the progress.
- Your command center makes 100 power and each power plant 100 more. The
  barracks and turrets use power; the top bar shows what is used and what
  is made. With too little power everything builds at half speed.
- Structures go on open ground (not on ore) within 4 tiles of one of your
  buildings.
- Selling gives you half the price back. Repairing costs 3 credits for every
  4 hit points.

### Units

| Unit | Cost | Build time | Hit points | Range | Weapon | |
|---|---:|---:|---:|---:|---|---|
| Tank | 800 | 8 s | 120 | 3 | cannon, 15 | |
| Buggy | 300 | 5 s | 90 | 2 | machine gun, 5, rapid fire | fast |
| Soldier | 100 | 3 s | 40 | 2 | rifle, 6 | needs a barracks |
| Rocket soldier | 300 | 5 s | 30 | 4 | rockets, 15, slow to reload | needs a barracks |
| Harvester | 1000 | 10 s | 200 | | | mines ore |

### Structures

| Structure | Cost | Build time | Size | Power |
|---|---:|---:|---|---:|
| Power plant | 300 | 6 s | 2x2 | +100 |
| Barracks | 500 | 8 s | 2x2 | -30 |
| Turret (200 hit points, cannon 20, range 4) | 600 | 8 s | 1x1 | -40 |

### Weapons and armor

- **Cannons and rifles** do full damage to everything.
- **The machine gun** does double damage to infantry, but only a quarter to
  vehicles and buildings.
- **Rockets** do double damage to vehicles and 1.5 times to buildings, but
  little to infantry.

### The enemy

The enemy builds soldiers, rocket soldiers, tanks and buggies at its
barracks and sends them against your base in waves that grow bigger over
time. Its starting units stay home and defend.

| | Easy | Normal | Hard |
|---|---|---|---|
| Its first attack after | 3 minutes | 2 minutes | 90 seconds |
| Then attacks at least every | 80 seconds | 60 seconds | 45 seconds |
| Units in an attack | 2 to 4 | 3 to 5 | 3 to 6 |
| Its income | low | medium | high |

### Tips

- Send a unit ahead to scout: the fog hides the enemy until you have seen
  it.
- A couple of turrets next to your command center hold off the early
  attacks.
- Rocket soldiers are best against tanks and buildings, the buggy's machine
  gun against soldiers.
- Keep your harvester safe: without it there are no credits.

## Credits

- Game, graphics and music: © 2026 Walter Tengler
- Weapon sounds (CC0): a Mosin Nagant rifle shot and a PPSh burst from "The
  Free Firearm Sound Library" by Ben Jaszczak, Brian Nelson, Kevin Heras and
  Matthew Nanney, and "cannon fire" by Thimras, both from OpenGameArt
  (details in [assets/sounds/CREDITS.txt](assets/sounds/CREDITS.txt))
- The disk boots ProDOS 2.4.3. The game is built with Merlin 32 and Cadius
  and tested in MAME.

## For developers

- [Building the game](docs/BUILDING.md): the tools, building the disk,
  running it in MAME, and the test scripts.
- [How it works](docs/TECHNICAL.md): the memory layout, rendering,
  pathfinding, the enemy AI, sound and music, the art and performance.
