*-------------------------------------------------------------------
* Conquer GS
*
* Milestone 18: an options screen (difficulty, two maps) and name tags;
* milestone 12: more unit types - a fast buggy with a machine gun and a
* rocket soldier, for both sides - and armor: damage depends on the
* weapon and what it hits (on top of graphics loaded from CONQUER.DATA,
* selling and repairing, fog of war, a 32 x 24 tile world that scrolls,
* a radar, building and placing structures, power, the enemy AI, win and
* lose, harvesting, production, selection, pathfinding and combat).
*
* Loaded by ProDOS as a SYS file at $00/2000 in emulation mode. It first
* shows the title picture (CONQUER.TITLE) and reads CONQUER.DATA (the
* packed screens and sprites) through ProDOS, then takes over the machine
* and never returns; the game starts with a click on the title.
*
* Screen buffers (same layout, offsets $2000-$9CFF):
*   bank $02  background of the top bar and sidebar
*   bank $01  work buffer: what the screen will show
*   bank $E1  the visible Super Hi-Res screen
* The screen is split into 20 x 13 cells: row 0 is the 8-line top bar,
* rows 1-12 line up with the map tiles. Each frame, cells touched by
* anything that changed are marked dirty and redrawn into the work
* buffer: map cells from their tile and any building piece on it,
* sidebar cells from the background, then units, effects and the cursor
* on top. Only the dirty cells are copied to the screen. Scrolling marks
* the whole view.
*
* Units stand on world tiles (16x16, tile = row * 32 + column) and walk
* from tile to tile; their positions are world pixels. Tiles none of our
* units has seen are drawn black, and so is their part of the radar;
* enemies standing there are not drawn and cannot be clicked.
*-------------------------------------------------------------------

         dsk   CONQUER.SYSTEM
         typ   $FF              ; ProDOS SYS file
         org   $2000

         put   ../build/gfx/gfxequ.s
         put   ../build/gfx/sndequ.s
         put   ../build/gfx/musequ.s

*--- hardware

SHR      equ   $E12000          ; Super Hi-Res pixel memory
SHRPAL   equ   $E19E00          ; 16 palettes x 16 colors
MOUSEDAT equ   $C024            ; ADB mouse: X and Y deltas alternate
KMSTATUS equ   $C027            ; bit 7 = mouse data, bit 1 = Y is next
NEWVIDEO equ   $C029            ; bit 7 = SHR on, bit 6 = linear
CLOCKCTL equ   $C034            ; low nibble = border color
SHADOW   equ   $C035            ; set bits inhibit shadowing
VBLBAR   equ   $C019            ; bit 7 flips at vertical blank
VERTCNT  equ   $C02E            ; scan line / 2: $7D-$FF, 131 a frame
RAMRDOFF equ   $C002            ; bank 0 reads from main / aux (bank 1)
RAMRDON  equ   $C003
RAMWRTOFF equ  $C004            ; bank 0 writes to main / aux
RAMWRTON equ   $C005
SOUNDCTL equ   $C03C            ; sound GLU: bit 7 busy, bit 6 = sound
SOUNDDATA equ  $C03D            ;   RAM (else DOC registers), bit 5 =
SOUNDADRL equ  $C03E            ;   auto-increment, bits 0-3 volume;
SOUNDADRH equ  $C03F            ;   data, address
KBD      equ   $C000            ; bit 7 = a key is waiting
KBDSTRB  equ   $C010            ; read: done with that key

BGBANK   equ   $02
WORKBANK equ   $01
UIBANK   equ   $03              ; unpacked top bar and sidebar
WINBANK  equ   $04              ; unpacked end-of-game banners
LOSEBANK equ   $05
CODEBANK equ   $06              ; compiled sprites
TILEBANK equ   $09              ; compiled map tiles
SPRBANK  equ   $07              ; unpacked sprite pixels (from $0000)
DOCDEST  equ   $FF              ; loadfile: "bank" meaning DOC sound RAM
DATABANK equ   $08              ; CONQUER.DATA as loaded, at DATAADDR
DATAADDR equ   $0000            ;   (a bank of its own: up to 64K)

*--- ProDOS 8 and ROM, used only before we take over

MLI      equ   $BF00            ; ProDOS calls: JSR MLI / call / params
DEVNUM   equ   $BF30            ; the last drive used (the startup one)
COUT     equ   $FDED            ; print a character
HOME     equ   $FC58            ; clear the text screen
IOBUF    equ   $0800            ; loaddata: ProDOS's 1K file buffer and
CHUNK    equ   $1000            ;   4K read at a time (both free then)

*--- screen layout (must match tools/makegfx.py)

LINE     equ   160              ; bytes per SHR scanline
TOPH     equ   8                ; top bar height
VIEWW    equ   16               ; view in tiles
VIEWH    equ   12
VIEWPX   equ   256              ; view width in pixels
SIDEX    equ   128              ; sidebar byte column (pixel 256)
CELLCOLS equ   20               ; dirty cells across the screen
CELLROWS equ   13
MAXUNITS equ   48
MAXFX    equ   8
PATHMAX  equ   64               ; path steps stored per unit
NONE     equ   $FFFF
NODESMAX equ   64               ; search steps per frame: at most,
NODESMIN equ   4                ;   at least, and none more once the
PATHEND  equ   118              ;   frame is this far (VERTCNT steps,
                                ;   131 a frame; see pathwork)
OFFVIEW  equ   $8000            ; uox: not on screen

F_CLEAN  equ   $7FFF            ; flags & F_CLEAN clears F_DIRTY
F_REPAIR equ   $0800            ; one of our structures being repaired
F_BLINK  equ   $1000            ;   (its wrench shows now)
F_HOLD   equ   $2000            ; it stopped to shoot (see think)

*--- fixed memory in bank 0: $0800-$1FFF (below the program) and from
*--- $9000 (above it; build.sh checks the program ends below) to $BFFF.
*--- Per-tile tables have one entry per world tile (32 x 24 = 768),
*--- per-unit tables one word per unit slot (MAXUNITS). The test scripts
*--- get these addresses from build/equates.lua (tools/equates.py).

LOWMEM   equ   $0800
occ      equ   $0800            ; per tile: unit * 2 + 2, or 0 if free
claimed  equ   $0E00            ; per tile: = cstamp if already a goal
queue    equ   $1400            ; search: queue of tiles
seen     equ   $1A00            ; search, per tile (bytes): visited/blocked
prev     equ   $1D00            ; search, per tile (bytes): direction in
LOWEND   equ   $2000

UTAB     equ   MAXUNITS*2       ; bytes in a per-unit table (a word each)
VARS     equ   $9000            ; (each address below follows the last)
ux       equ   VARS             ; position (world pixels)
uy       equ   ux+UTAB
uox      equ   uy+UTAB          ; position on screen as last drawn, or
uoy      equ   uox+UTAB         ;   uox = OFFVIEW
uspr     equ   uoy+UTAB         ; right-facing sprite index
uflags   equ   uspr+UTAB
uspd     equ   uflags+UTAB      ; frame mask for walking speed
utile    equ   uspd+UTAB        ; tile the unit stands on
unext    equ   utile+UTAB       ; tile it is walking into, or NONE
ugoal    equ   unext+UTAB       ; tile it is heading for, or NONE
upathpos equ   ugoal+UTAB       ; next step in upath
upathlen equ   upathpos+UTAB
utarget  equ   upathlen+UTAB    ; unit * 2 it is attacking, or NONE
uhp      equ   utarget+UTAB
umaxhp   equ   uhp+UTAB
urange   equ   umaxhp+UTAB      ; weapon range in tiles (0 = unarmed)
udmg     equ   urange+UTAB
urate    equ   udmg+UTAB        ; frames between shots
ureload  equ   urate+UTAB
ublock   equ   ureload+UTAB     ; frames spent waiting for a busy tile
ucargo   equ   ublock+UTAB      ; harvester load
ustate   equ   ucargo+UTAB      ; harvester state (H_...)
upower   equ   ustate+UTAB      ; power: + makes, - uses (player only)
fxx      equ   upower+UTAB      ; effects: world position, sprite,
fxy      equ   fxx+$10          ;   frames left
fxspr    equ   fxy+$10
fxtime   equ   fxspr+$10
fxnew    equ   fxtime+$10       ; per effect: just spawned, not drawn yet
ucost    equ   fxnew+$20        ; per unit: credits it sells for
cmdmode  equ   ucost+UTAB       ; 0, MODE_SELL or MODE_REPAIR: what a
                                ;   click on one of our structures does
quiet    equ   cmdmode+$2       ; kill: nonzero = no explosion (sold)
dmgf     equ   quiet+$2         ; fire: damage factor, then damage
bdunit   equ   dmgf+$2          ; budge: the unit in the way,
bdtile   equ   bdunit+$2        ;   tiles along the mover's path,
bdpos    equ   bdtile+$2        ;   where in its path,
bdn      equ   bdpos+$2         ;   how many left to keep free
bdself   equ   bdn+$2           ;   (the mover)
aiwait   equ   bdself+$2        ; ai: frames until the next wave may go
aimax    equ   aiwait+$2        ;   units it may have built alive at once
aisend   equ   aimax+$2         ;   units still to send in this wave
aicnt    equ   aisend+$2        ; aicount: scratch
aistuck  equ   aicnt+$2         ; ai: nonzero = no room for its next unit
aineed   equ   aistuck+$2       ;   units needed for the next wave
lcx      equ   aineed+$2        ; updcursor: the mouse when it last looked
lcy      equ   lcx+$2
fogchg   equ   lcy+$2           ; nonzero: a tile came out of the fog
acol     equ   fogchg+$2        ; acq: the unit's column, row, range
arow     equ   acol+$2
arng     equ   arow+$2
aside    equ   arng+$2          ;   and side (F_PLAYER or 0)
elast    equ   aside+$2         ; elapsed: the last value this frame
lookx    equ   elast+$2         ; test scripts: view to move to (top
looky    equ   lookx+$2         ;   left tile), or lookx = NONE
sndreq   equ   looky+$2         ; sounds to start this frame (SND_ bits)
svoice   equ   sndreq+$2        ; sounds: per sound, its voice last used
sreq     equ   svoice+$2        ;   (scratch: bits left, this sound's
sbit     equ   sreq+$2          ;   bit, its oscillator; initsound: the
so       equ   sbit+$2          ;   oscillator, how many are left)
sk       equ   so+$2
mvol     equ   sk+$2            ; music: per tone voice (words):
mmode    equ   mvol+$6          ;   its volume, and 0 silent, 1 note
mtick    equ   mmode+$6         ;   decaying, 2 note fading out; frames
mstep    equ   mtick+$2         ;   into the step, the step,
mfreq    equ   mstep+$2         ;   (scratch)
mdbase   equ   mfreq+$2
qicon    equ   mdbase+$40       ; per build queue (0 = structures, 1 =
qtype    equ   qicon+$4         ;   units): icon being built or NONE,
qseg     equ   qtype+$4         ;   its template, bar segments filled,
qtime    equ   qseg+$4          ;   frames to the next segment, and
qready   equ   qtime+$4         ;   nonzero once a structure is done
vcol     equ   qready+$10       ; updplace: footprint in view tiles
vrow     equ   vcol+$2
radmk    equ   vrow+$2          ; raddot: nonzero = also mark its cells
sgtile   equ   radmk+$4         ; sight: the tile seen around,
sgcol    equ   sgtile+$2        ;   its column, row,
sgrow    equ   sgcol+$2
sgrad    equ   sgrow+$2         ;   how far the unit sees,
sgidx    equ   sgrad+$2         ;   the next row's width in sighttab,
sgr      equ   sgidx+$2         ;   the row being looked at, the last,
sgend    equ   sgr+$2
sgw      equ   sgend+$2         ;   its half width, first column
sgc      equ   sgw+$2
sgn      equ   sgc+$2           ;   and tiles left in it
fgtile   equ   sgn+$2           ; revtile: the tile, its neighbors on
fgin     equ   fgtile+$2        ;   the map, its unseen neighbors,
fgmask   equ   fgin+$2
fgx      equ   fgmask+$2        ;   its radar pixel
fgy      equ   fgx+$2
fgm      equ   fgy+$2           ; fogpix: mask of the pixel's nibble
hidt     equ   fgm+$2           ; unseen: scratch
fogspr   equ   hidt+$2          ; restorecell: next edge sprite
blackink equ   fogspr+$2        ; compile: nonzero = draw in black
seeallf  equ   blackink+$2      ; test scripts: nonzero = see everything
fqhead   equ   seeallf+$2       ; FOGQ: next tile to uncover * 2,
fqtail   equ   fqhead+$2        ;   where the next one goes * 2
fqn      equ   fqtail+$2        ; fogwork: tiles left this frame
radfl    equ   fqn+$4           ; drawradar: the entry's size flags
fgold    equ   radfl+$2         ; revtile: a neighbor's edges drawn
fgnew    equ   fgold+$2         ;   before and after
fstart   equ   fgnew+$2         ; VERTCNT when this frame's work began
fogwait  equ   fstart+$2        ; fogwork: frames since it last uncovered
fogtime  equ   fogwait+$2       ;   (test scripts: its time estimate)
radidx   equ   fogtime+$6       ; drawradar: the next dot to redraw * 4
radstop  equ   radidx+$2        ;   where this frame's share ends
ytab     equ   radstop+$16      ; y * 160, 200 words
dirty    equ   ytab+$200        ; per screen cell: = stamp if dirty
dirtylist equ  dirty+$210       ; dirty cells: buffer address,
dirtycell equ  dirtylist+$210   ;   and row * 256 + column
upath    equ   dirtycell+$210   ; PATHMAX directions per unit
temppath equ   upath+{MAXUNITS*PATHMAX} ; path while it is being reversed
passw    equ   temppath+$100    ; per tile (bytes): blocked; passmap plus
                                ;   whatever was built
oreamt   equ   passw+$300       ; per tile (bytes): scoops of ore left
overlay  equ   oreamt+$300      ; per tile (bytes): building piece drawn
                                ;   on it, sprite + 1, or 0
urx      equ   overlay+$300     ; per unit: its radar dot as last drawn:
ury      equ   urx+UTAB         ;   x (NONE: none), y (+$8000: 2x2)
radlist  equ   ury+UTAB         ; drawradar: dots to redraw, x and y
RADLMAX  equ   40               ;   (+$8000: 2 wide, +$4000: 2 high);
                                ;   40 at most, else redraw it all
iconok   equ   radlist+$A0      ; per icon: drawn as available
uclass   equ   iconok+$18       ; per unit: armor class (bits 0-1:
                                ;   infantry, vehicle, building) and
                                ;   weapon class * 4 (gun, machine gun,
                                ;   rockets); see fire
curbuf   equ   uclass+UTAB      ; options: what the cursor covers (16
curaddr  equ   curbuf+$80       ;   lines of 8 bytes) and where
optmap   equ   curaddr+$2       ;   the map whose preview is drawn
musicon  equ   optmap+$2        ; a tune is playing
aiincome equ   musicon+$2       ; the enemy at this difficulty: credits
aigap    equ   aiincome+$2      ;   every 8 frames, frames between
aiwave0  equ   aigap+$2         ;   waves, units in the first wave and
aiwavemax equ  aiwave0+$2       ;   at most
lbltgt   equ   aiwavemax+$2     ; name tags: what the mouse is on (tag
lbltime  equ   lbltgt+$2        ;   number or NONE) and for how long,
lblnum   equ   lbltime+$2       ;   the tag shown (NONE: none), where
lblx     equ   lblnum+$2        ;   (pixels) and how wide (bytes); the
lbly     equ   lblx+$2          ;   mouse when it last looked
lblw     equ   lbly+$2
lblmx    equ   lblw+$2
lblmy    equ   lblmx+$2
mtr      equ   lblmy+$2         ; music: the tune's numbers (see MT_)
mlast    equ   mtr+MTRSZ        ;   per tone voice: volume last written
mvc      equ   mlast+$6         ;   VERTCNT when musictick last looked
slamfrom equ   mvc+$2           ; slam: the first line's address, and
slamrows equ   slamfrom+$2      ;   how many lines
udock    equ   slamrows+$2      ; per harvester: the dock it heads for
DOCKSMAX equ   8                ; docks: where our harvesters unload -
docks    equ   udock+UTAB       ;   by the command center, then at each
ndocks   equ   docks+{DOCKSMAX*2} ;   refinery (see calcpower); how many * 2
radaron  equ   ndocks+$2        ; the radar works: a radar center and
radhave  equ   radaron+$2       ;   enough power (calcpower)
radoff   equ   radhave+$2       ; drawradar: the radar is shown off
radarall equ   radoff+$2        ; test scripts: nonzero = radar without
                                ;   a radar center
factunit equ   radarall+$2      ; the enemy's war factory, refinery and
refunit  equ   factunit+$2      ;   power plant (unit * 2; see standing)
ppunit   equ   refunit+$2
paused   equ   ppunit+$2        ; nonzero: the game is paused (the P key)
pmusic   equ   paused+$2        ;   and the music was playing
bnoff    equ   pmusic+$2        ; drawbanner: where its picture is
VARSEND  equ   bnoff+$2

*--- two words the test scripts watch from the very start, so outside
*--- the variables (cleared at restart) and outside $2000-$9FFF (which
*--- the emulator's script writes may reach the screen through)

TITLEWAIT equ  $BE00            ; nonzero: the title is up, waiting (a
                                ;   test script clears it to go on)
GAMEGO   equ   $BE02            ; $C0DE once the game runs
OPTWAIT  equ   $BE04            ; nonzero: the options screen is up (a
                                ;   test script clears it to start)
DIFF     equ   $BE06            ; the difficulty chosen (0-2), the map
MAPNO    equ   $BE08            ;   (0-3) and whether the music is off
MUSICOFF equ   $BE0A            ;   (0-1): kept from game to game

*--- fog of war, in bank 1 above the work buffer

FOG      equ   WORKBANK*$10000+$A000   ; per tile (words): UNSEEN until one
UNSEEN   equ   $8000            ;   of our units has seen it; then a bit
                                ;   per neighbor still unseen (N E S W
                                ;   NE SE SW NW, as in dirofs), and in
                                ;   bits 8-10 how far a unit standing
                                ;   there has looked around already
QUEUED   equ   $4000            ;   (with UNSEEN: waiting in FOGQ)
FOGQ     equ   WORKBANK*$10000+$A600   ; tiles seen, to be uncovered a few
FQSIZE   equ   1024             ;   per frame (each tile goes in at most
                                ;   once, so it never fills up)
SPCODE   equ   WORKBANK*$10000+$AE00   ; per sprite, then per tile: entry
                                ;   of its compiled code (256 at most)
FOGTILES equ   4                ; fogwork: tiles uncovered per frame at
FOGLATE  equ   72               ;   most, while the frame is not this
                                ;   late (frameest); at least one every
FOGEVERY equ   16               ;   this many frames
RADLATE  equ   100              ; drawradar: more than one dot a frame
                                ;   only while not this late
* The radar's terrain is kept at +$8000 in the sidebar layer's bank; the
* layer itself is black where nothing has been seen.

*--- direct page variables

jmpvec   equ   $30              ; drawspr: compiled sprite entry, 3 bytes
cptr     equ   $34              ; compile: code output pointer, 3 bytes
sidx     equ   $38              ; compile: sprite * 2
soff     equ   $3A              ;   offset in the sprite pixels
scr      equ   $3C              ;   offset on the screen
wleft    equ   $3E              ;   words left in the row
rowsleft equ   $2E              ;   rows left
tmpm     equ   $2C              ;   mask word
tmpd     equ   $2A              ;   pixel word
opaque   equ   $0A              ;   nonzero: a map tile (no mask)
sprbanks equ   $26              ; sprat: data bank for drawing, twice

src      equ   $80              ; source pointer (bank 0)
msk      equ   $82              ; mask pointer (bank 0)
dst      equ   $84              ; destination pointer, 3 bytes (+$86 bank)
width    equ   $88              ; blit width in bytes (even)
height   equ   $8A              ; blit height in lines
tx       equ   $8C              ; map column
ty       equ   $8E              ; map row
rows     equ   $90              ; lines in a cell copy
rx       equ   $92              ; rectangle x (pixels, even)
ry       equ   $94              ; rectangle y
cx       equ   $96              ; mouse position (pixels)
cy       equ   $98
btn      equ   $9A              ; 1 while the button is down
click    equ   $9C              ; 1 on the frame the button went down
rawx     equ   $9E              ; last mouse bytes (high byte stays 0)
rawy     equ   $A0
csx      equ   $A2              ; cursor sprite position and shape
csy      equ   $A4
cshape   equ   $A6
ocsx     equ   $A8              ; cursor as last drawn
ocsy     equ   $AA
ocshape  equ   $AC
fogbits  equ   $AE              ; restorecell: edges still to draw
frame    equ   $B0              ; frame counter
nunits   equ   $B2              ; units * 2
dragging equ   $B4              ; button went down over the map
boxon    equ   $B6              ; drag has become a selection box
dragx0   equ   $B8              ; where the drag started
dragy0   equ   $BA
bx0      equ   $BC              ; selection box, normalized
by0      equ   $BE
bx1      equ   $C0
by1      equ   $C2
oboxon   equ   $C4              ; box as last drawn
obx0     equ   $C6
oby0     equ   $C8
obx1     equ   $CA
oby1     equ   $CC
mcol     equ   $CE              ; cell or tile column/row scratch
mrow     equ   $D0
tmp      equ   $D2
tmp2     equ   $D4
tmp3     equ   $D6
self     equ   $D8              ; unit * 2 being updated
goal     equ   $DA              ; pathfinding goal tile
start    equ   $DC              ; pathfinding start tile
head     equ   $DE              ; BFS queue read/write offsets
tail     equ   $E0
avoid    equ   $E2              ; nonzero: treat other units as walls
cur      equ   $E4              ; BFS current tile
col      equ   $E6
row      equ   $E8
ntile    equ   $EA              ; neighbor tile
btile    equ   $EC              ; tile being tested by blocked
fxtimer  equ   $EE              ; frames for a new effect
px0      equ   $F0              ; rectangle outline for markperim
py0      equ   $F2
px1      equ   $F4
py1      equ   $F6
anysel   equ   $F8              ; nonzero if a unit is selected
clicked  equ   $FA              ; tile of a move order
mwx      equ   $FC              ; hitunit: the mouse in world pixels
fullview equ   $00              ; render: the whole view is being redrawn
savesp   equ   $38              ; slam: our stack pointer (sidx's word:
                                ;   that is only used at start)
mwy      equ   $FE
credits  equ   $40              ; money
shown    equ   $42              ; credits as last drawn
slot     equ   $4C              ; unit * 2 for a new unit
hqunit   equ   $4E              ; the player's command center (unit * 2;
barunit  equ   $50              ;   see standing), the enemy barracks
gameover equ   $52              ; 0 = playing, 1 = won, 2 = lost
aicredits equ  $54              ; enemy money
aibuild  equ   $56              ; template the enemy is building, or NONE
aitimer  equ   $58              ; frames until it is done
aiidx    equ   $5A              ; position in the build order * 2
wavesize equ   $5C              ; idle units needed to launch an attack
spawnat  equ   $5E              ; spawnunit: tile to appear around
spawnt   equ   $60              ; spawnunit: template offset
spawnfl  equ   $62              ; spawnunit: extra flags
acqskip  equ   $64              ; acquire: flags of units to ignore
lsrc     equ   $72              ; long source pointer, 3 bytes (+$74 bank)
camx     equ   $76              ; view: top-left world tile column / row
camy     equ   $7E
viewx    equ   $44              ; world pixel x of the view's left edge
viewy    equ   $46              ; world y minus screen y of the view
scrolled equ   $48              ; nonzero: the view moved, redraw it all
lastscroll equ $4A              ; frame of the last scroll step
radtime  equ   $6E              ; frame of the last radar update
radchg   equ   $36              ; drawradar: a dot moved (cptr's bank
                                ;   word: that is only used at start)
stamp    equ   $66              ; render pass number (dirty cells)
ndirty   equ   $68              ; dirty cells * 2
jobunit  equ   $6A              ; unit * 2 whose path is being searched
jobgoal  equ   $6C              ; its goal tile
nodes    equ   $70              ; search steps left this frame
jobinit  equ   $78              ; nonzero: search not set up yet
jobavoid equ   $7A              ; its avoid setting
cstamp   equ   $7C              ; claimed[t] = cstamp: tile handed out
newbanner equ  $28              ; game just ended: render marks the banner
placing  equ   $10              ; nonzero: placing the finished structure
placeok  equ   $12              ; ...and it fits where the mouse is
placetile equ  $14              ; ...top-left tile
boxcol   equ   $16              ; box color: byte, then left-pixel nibble
oboxcol  equ   $18
pwrmade  equ   $1A              ; power made / used by the player
pwrused  equ   $1C
shownmade equ  $1E              ; as last drawn
shownused equ  $20
lowpower equ   $22              ; nonzero: using more than made
bsize    equ   $24              ; footprint size scratch
glyphs0  equ   $0C              ; putnum: first glyph of the color
ftile    equ   $0E              ; findbld: scratch

grange   equ   $08              ; pathto: 0 = reach goal, else get within
                                ;   this many tiles of it (reset by pathto)
jobrange equ   $06              ; the search's range,
jobtc    equ   $04              ;   goal column
jobtr    equ   $02              ;   and row

*-------------------------------------------------------------------

         mx    %11
main     sei                    ; no interrupts: we own the machine
         stz   TITLEWAIT        ; (no title yet, no game yet)
         stz   TITLEWAIT+1
         stz   GAMEGO
         stz   GAMEGO+1
         stz   OPTWAIT
         stz   OPTWAIT+1
         lda   #DIFF0           ; (8 bits here) NORMAL, the first map
         sta   DIFF
         stz   DIFF+1
         stz   MAPNO
         stz   MAPNO+1
         stz   MUSICOFF
         stz   MUSICOFF+1
         lda   NEWVIDEO
         ora   #$40             ; linear SHR memory: must be set before
         sta   NEWVIDEO         ; writing to $E1/2000, or bytes land
                                ; in the IIe interleaved layout
         jsr   loadmsg          ; (while ProDOS is still in charge, on
         jsr   loadtitle        ;   the text screen: LOADING and a dot
         jsr   loaddata         ;   for every 4K read; the title shows
         jsr   loadsound        ;   once the game is ready, with music)
         lda   SHADOW
         ora   #$3E             ; no shadowing of banks 0/1 into E0/E1,
         sta   SHADOW           ; so bank 1 can be a private buffer (and
                                ; $0800-$0BFF is ordinary fast memory)
         clc
         xce                    ; native 65816 mode
         rep   #$30
         mx    %00
         lda   #0
         tcd                    ; direct page = $0000
         phk
         plb                    ; data bank = program bank (0)
         jsr   initsound        ; the sound chip, once

restart  lda   #0               ; clear our variables
         ldx   #VARSEND-VARS-2
:clr     sta   VARS,x
         dex
         dex
         bpl   :clr
         ldx   #LOWEND-LOWMEM-2
:clrlow  sta   LOWMEM,x
         dex
         dex
         bpl   :clrlow
         stz   ndirty           ; no dirty cells (they hold 0, stamp 1)
         lda   #1
         sta   stamp
         ldx   #NICONS*2-2      ; icons are drawn available, to begin
:ok      sta   iconok,x
         dex
         dex
         bpl   :ok
         lda   #NONE            ; both build queues idle
         sta   qicon
         sta   qicon+2
         sta   lookx            ; (no view move asked for)
         sta   lblnum           ; no name tag
         sta   lbltgt

         jsr   makeytab
         jsr   unpack
         jsr   compile
         lda   #slamend-slamcode-1  ; the screen copier runs from bank 6
         ldx   #slamcode
         ldy   #SLAMADDR
         mvn   0,CODEBANK
         phk
         plb                    ; (mvn changed the data bank)

         lda   TITLEWAIT        ; the first start: the title until a
         beq   :opts            ; click (only now does the game touch
         jsr   title            ; the screen)
:opts    jsr   options          ; difficulty and map, until START
         jsr   loadmap
         jsr   initunits        ; (the icons depend on the units)
         lda   #BGBANK          ; the top bar and sidebar into bank 2
         sta   dst+2
         jsr   drawui
         jsr   initicons
         jsr   clearshr
         jsr   setpalette

         lda   #31999           ; copy it to the work buffer and screen
         ldx   #$2000
         ldy   #$2000
         mvn   BGBANK,WORKBANK
         lda   #31999
         ldx   #$2000
         ldy   #$2000
         mvn   BGBANK,^SHR
         phk
         plb                    ; mvn changed the data bank

         ldx   #MAPW*MAPH-2     ; terrain as built on, ore in each tile
:pass    lda   passmap,x
         sta   passw,x
         lda   oredata,x
         sta   oreamt,x
         dex
         dex
         bpl   :pass
         ldx   #0               ; the starting buildings' pieces
:over    lda   overdata,x
         cmp   #NONE
         beq   :overd
         tay
         lda   overdata+2,x
         inc
         sep   #$20
         mx    %10
         sta   overlay,y
         rep   #$20
         mx    %00
         inx
         inx
         inx
         inx
         bra   :over
:overd   jsr   initblds
         lda   camx0            ; the first view
         sta   camx
         lda   camy0
         sta   camy
         jsr   setview
         lda   #NONE
         sta   radtime          ; draw the radar on the first frame
         lda   #CREDITS0
         sta   credits
         lda   #NONE
         sta   shown            ; draw the numbers on the first frame
         sta   shownmade
         stz   placing
         lda   #$C0CC           ; white box
         sta   boxcol
         jsr   calcpower
         jsr   initfog          ; nothing seen but what our units see

         lda   #WORKBANK        ; from now on sprites go to bank 1
         sta   dst+2
         jsr   initai
         lda   #NONE            ; no path search running
         sta   jobunit
         stz   grange
         stz   cstamp
         stz   newbanner
         jsr   initmouse
         jsr   markall          ; first frame: everything is dirty
         jsr   render

         sep   #$20
         mx    %10
         lda   CLOCKCTL
         and   #$F0             ; black border
         sta   CLOCKCTL
         lda   NEWVIDEO
         ora   #$80             ; Super Hi-Res display on
         sta   NEWVIDEO
         rep   #$20
         mx    %00
         lda   MUSICOFF         ; the battle tune
         bne   :quiet
         lda   #TUNE_BATTLE
         jsr   musstart
         lda   #1
         sta   musicon
:quiet   lda   #$C0DE           ; (test scripts: the game runs)
         sta   GAMEGO

*-------------------------------------------------------------------
* main loop, once per video frame

mainloop jsr   musictick        ; (the music keeps time: see musictick)
         jsr   waitvbl
         jsr   musictick
         jsr   readmouse
         lda   seeallf          ; (test scripts: everything seen)
         beq   :look
         jsr   seeall
:look    lda   lookx            ; (test scripts: move the view)
         bmi   :play
         sta   tmp
         lda   looky
         sta   tmp2
         lda   #NONE
         sta   lookx
         jsr   moveview
:play    lda   paused
         bne   :paused
         lda   gameover
         bne   :over
         jsr   scroll
         jsr   updplace
         jsr   input
         jsr   updcursor
         jsr   updlabel
         jsr   units
         jsr   elapsed          ; (so a frame running long is noticed)
         jsr   production
         jsr   repairs
         jsr   ai
         jsr   checkend
         jsr   render
         jsr   sounds           ; start this frame's sounds
         jsr   pathwork         ; paths in the time left
         bra   mainloop
:over    lda   click            ; game over: a click starts again
         beq   :wait
         jmp   restart
:paused  jsr   updcursor        ; paused: only the panel and the arrow
         jsr   pauseinput
         bcc   :pz
         stz   paused           ; QUIT MISSION: to the mission setup
         jmp   restart
:pz      jsr   render
         jmp   mainloop
:wait    jsr   updcursor
         jsr   updlabel         ; (the tag goes)
         jsr   render
         jmp   mainloop

*-------------------------------------------------------------------
* waitvbl: wait for the next change of the vertical blank bit

waitvbl  sep   #$20
         mx    %10
:in      lda   VBLBAR
         bmi   :in
:out     lda   VBLBAR
         bpl   :out
         lda   VERTCNT          ; (where the frame's work starts)
         rep   #$20
         mx    %00
         and   #$00FF
         sta   fstart
         stz   elast
         rts

* frameest: A = how long this frame's work will take if nothing more is
* added: the time so far plus 8 steps (1 ms) for each cell to redraw
frameest jsr   elapsed
         clc
         adc   ndirty           ; (cells * 2)
         adc   ndirty
         adc   ndirty
         adc   ndirty
         rts

* elapsed: A = how far into the frame's work we are, in VERTCNT steps
* (2 scan lines, 1/131 of a frame); past the end of the frame it goes on
* counting (it never goes back within a frame) (keeps X, Y)
elapsed  sep   #$20
         mx    %10
         lda   VERTCNT
         rep   #$20
         mx    %00
         and   #$00FF
         sec
         sbc   fstart
         bpl   :pos
         clc
         adc   #131
:pos     cmp   elast            ; went back: the frame ran past the
         bcs   :keep            ; next blank
         clc
         adc   #131
:keep    sta   elast
         rts

*-------------------------------------------------------------------
* initmouse / readmouse: poll the ADB mouse through the GLU.
* Each data byte: bit 7 = button up, bits 6-0 = signed delta.

initmouse
         lda   #CURX0
         sta   cx
         lda   #CURY0
         sta   cy
         stz   btn
         stz   click
         stz   rawx
         stz   rawy
         stz   dragging
         stz   boxon
         stz   oboxon
         stz   ocsx             ; (the "old" cursor: the first frame
         stz   ocsy             ; redraws everything anyway)
         jmp   updcursor

readmouse
         stz   click
         sep   #$20
         mx    %10
         lda   KMSTATUS
         bpl   :none            ; no new data
         and   #$02
         bne   :yonly           ; out of step: Y comes next
         lda   MOUSEDAT
         sta   rawx
         lda   MOUSEDAT
         sta   rawy
         bra   :got
:yonly   lda   MOUSEDAT
         sta   rawy
         and   #$80             ; keep button, no X movement
         sta   rawx
:got     rep   #$20
         mx    %00

         lda   rawx             ; x += delta, clamp to 0..319
         jsr   delta
         clc
         adc   cx
         bpl   :x1
         lda   #0
:x1      cmp   #320
         bcc   :x2
         lda   #319
:x2      sta   cx

         lda   rawy             ; y += delta, clamp to 0..199
         jsr   delta
         clc
         adc   cy
         bpl   :y1
         lda   #0
:y1      cmp   #200
         bcc   :y2
         lda   #199
:y2      sta   cy

         lda   rawy             ; button: bit 7 clear = down
         and   #$80
         bne   :up
         lda   btn
         bne   :done            ; still held
         lda   #1
         sta   btn
         sta   click
:done    rts
:up      stz   btn
         rts
:none    rep   #$20
         mx    %00
         rts

* delta: A = mouse byte -> A = signed 16-bit movement
delta    and   #$7F
         bit   #$40
         beq   :pos
         ora   #$FF80
:pos     rts

*-------------------------------------------------------------------
* input: press over the map starts a drag; moving 5+ pixels while
* held turns it into a selection box; release ends it.

input    lda   placing          ; placing a structure: clicks place it
         beq   :normal
         lda   click
         beq   :prts
         jsr   inmap
         bcs   :pmap
         lda   cx
         cmp   #VIEWPX
         bcc   :prts
         jmp   sidebarclick
:pmap    lda   placeok
         beq   :prts
         jmp   place
:prts    rts
:normal  lda   click
         beq   :held
         jsr   inmap
         bcs   :map
         lda   cx               ; click on the sidebar?
         cmp   #VIEWPX
         bcc   :held
         jsr   sidebarclick
         bra   :held
:map     lda   cmdmode          ; selling or repairing: act on what
         beq   :drag            ; was clicked
         jmp   modeclick
:drag    lda   #1
         sta   dragging
         stz   boxon
         lda   cx
         and   #$FFFE
         sta   dragx0
         lda   cy
         sta   dragy0
:held    lda   dragging
         beq   :rts
         lda   btn
         beq   :release
         lda   boxon
         bne   :box
         lda   cx
         sec
         sbc   dragx0
         jsr   absval
         cmp   #5
         bcs   :boxon
         lda   cy
         sec
         sbc   dragy0
         jsr   absval
         cmp   #5
         bcc   :rts
:boxon   lda   #1
         sta   boxon
:box     jmp   setbox
:rts     rts
:release stz   dragging
         lda   boxon
         beq   :click
         stz   boxon
         jmp   selectbox
:click   jmp   clickact

* setbox: box from the drag start to the mouse, inside the map
setbox   lda   #$C0CC           ; white
         sta   boxcol
         lda   cx
         cmp   #VIEWPX
         bcc   :x
         lda   #VIEWPX-2
:x       and   #$FFFE
         sta   tmp
         lda   cy
         cmp   #TOPH
         bcs   :y
         lda   #TOPH
:y       sta   tmp2
         lda   dragx0
         cmp   tmp
         bcc   :xa
         lda   tmp
         sta   bx0
         lda   dragx0
         sta   bx1
         bra   :ys
:xa      sta   bx0
         lda   tmp
         sta   bx1
:ys      lda   dragy0
         cmp   tmp2
         bcc   :ya
         lda   tmp2
         sta   by0
         lda   dragy0
         sta   by1
         rts
:ya      sta   by0
         lda   tmp2
         sta   by1
         rts

* selectbox: select the player units whose centers are in the box
selectbox
         jsr   deselect
         ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         bit   #F_DEAD
         bne   :next
         bit   #F_PLAYER
         beq   :next
         bit   #F_BUILDING
         bne   :next
         lda   uox,x            ; (on screen only)
         cmp   #OFFVIEW
         beq   :next
         clc
         adc   #8
         cmp   bx0
         bcc   :next
         cmp   bx1
         beq   :xin
         bcs   :next
:xin     lda   uoy,x
         clc
         adc   #8
         cmp   by0
         bcc   :next
         cmp   by1
         beq   :yin
         bcs   :next
:yin     lda   uflags,x
         ora   #F_SEL+F_DIRTY
         sta   uflags,x
:next    inx
         inx
         bra   :loop
:done    rts

* clickact: click on own unit = select it, on an enemy = attack,
* on open ground = move there
clickact jsr   inmap
         bcc   :rts             ; released outside the map
         jsr   hitunit
         bmi   :ground
         lda   uflags,x
         bit   #F_PLAYER
         beq   :enemy
         bit   #F_BUILDING
         bne   :rts             ; own building: nothing to do
         phx
         jsr   deselect
         plx
         lda   uflags,x
         ora   #F_SEL+F_DIRTY
         sta   uflags,x
:rts     rts
:enemy   jmp   attackorder
:ground  jmp   moveorder

* deselect: clear the selection on all units
deselect ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         bit   #F_SEL
         beq   :next
         eor   #F_SEL
         ora   #F_DIRTY
         sta   uflags,x
:next    inx
         inx
         bra   :loop
:done    rts

* hitunit: X = live unit * 2 under the mouse (N clear), or NONE (N set)
hitunit  lda   cx               ; the mouse in world pixels
         clc
         adc   viewx
         sta   mwx
         lda   cy
         clc
         adc   viewy
         sta   mwy
         ldx   #0
:loop    cpx   nunits
         bcs   :none
         lda   uflags,x
         bit   #F_DEAD
         bne   :next
         bit   #F_BUILDING
         bne   :big
         lda   mwx
         sec
         sbc   ux,x
         cmp   #16              ; unsigned: also rejects cx < ux
         bcs   :next
         lda   mwy
         sec
         sbc   uy,x
         cmp   #16
         bcs   :next
         bra   :hit
:big     lda   mwx              ; buildings: 32x32 around their tile
         clc
         adc   #8
         sec
         sbc   ux,x
         cmp   #32
         bcs   :next
         lda   mwy
         clc
         adc   #8
         sec
         sbc   uy,x
         cmp   #32
         bcs   :next
:hit     lda   uflags,x         ; theirs where we have not looked: not
         lsr                    ;   there for the mouse
         bcs   :yes
         lda   ux,x
         ldy   uy,x
         jsr   unseen
         bcs   :next
:yes     txa                    ; set N from X
         rts
:next    inx
         inx
         bra   :loop
:none    ldx   #NONE
         rts

* mousetile: A = world tile under the mouse (caller checks inmap)
mousetile
         lda   cy
         sec
         sbc   #TOPH
         lsr
         lsr
         lsr
         lsr
         clc
         adc   camy
         asl                    ; row * 32
         asl
         asl
         asl
         asl
         sta   tmp
         lda   cx
         lsr
         lsr
         lsr
         lsr
         clc
         adc   camx
         clc
         adc   tmp
         rts

* inmap: carry set if the mouse is over the map viewport
inmap    lda   cx
         cmp   #VIEWPX
         bcs   :no
         lda   cy
         cmp   #TOPH
         rts                    ; carry set if cy >= TOPH
:no      clc
         rts

* absval: A = |A|
absval   ora   #0
         bpl   :pos
         eor   #$FFFF
         inc
:pos     rts

*-------------------------------------------------------------------
* moveorder: send the selected units to the clicked tile, each to the
* nearest free tile around it

moveorder
         jsr   mousetile
         sta   clicked
         tay
         lda   passw,y
         and   #$00FF
         beq   :ok
         rts                    ; can't go there
:ok      jsr   clearclaimed     ; no goals handed out yet

         ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         bit   #F_SEL
         beq   :next
         bit   #F_DEAD+F_STATIC
         bne   :next
         and   #$FFFF-F_CHASE
         sta   uflags,x
         lda   #NONE
         sta   utarget,x
         stx   self
         jsr   pickgoal
         bcc   :next0
         sta   goal
         asl
         tay
         lda   cstamp
         sta   claimed,y
         stz   avoid
         ldx   self
         jsr   pathto
         ldx   self
         lda   uflags,x         ; harvester: mine if sent to ore
         bit   #F_HARV
         beq   :next0
         ldy   clicked
         lda   oreamt,y
         and   #$00FF
         beq   :hi
         lda   #H_GOTO
         bra   :hs
:hi      lda   #H_IDLE
:hs      sta   ustate,x
:next0   ldx   self
:next    inx
         inx
         bra   :loop
:done    rts

* pickgoal: A = nearest tile around the clicked tile that is open,
* not taken by another unit and not already handed out; carry clear
* if there is none
pickgoal ldy   #0
:loop    lda   ringtab,y
         cmp   #$8000
         beq   :none
         sta   tmp              ; dx
         lda   clicked
         and   #MAPW-1
         clc
         adc   tmp
         cmp   #MAPW            ; unsigned: also rejects < 0
         bcs   :next
         sta   col
         lda   clicked
         lsr
         lsr
         lsr
         lsr
         lsr
         clc
         adc   ringtab+2,y      ; dy
         cmp   #MAPH
         bcs   :next
         asl
         asl
         asl
         asl
         asl
         ora   col
         sta   ntile
         tax
         lda   passw,x
         and   #$00FF
         bne   :next
         lda   ntile
         asl
         tax
         lda   claimed,x
         cmp   cstamp
         beq   :next
         lda   occ,x
         beq   :got
         sec
         sbc   #2
         cmp   self
         bne   :next            ; somebody else stands there
:got     lda   ntile
         sec
         rts
:next    iny
         iny
         iny
         iny
         bra   :loop
:none    clc
         rts

* attackorder: selected armed units attack unit X
attackorder
         stx   tmp3
         ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         bit   #F_SEL
         beq   :next
         bit   #F_DEAD
         bne   :next
         lda   urange,x
         beq   :next            ; unarmed
         lda   tmp3
         sta   utarget,x
         lda   uflags,x
         ora   #F_CHASE
         sta   uflags,x
         stx   self
         ldy   tmp3
         jsr   approach
         ldx   self
:next    inx
         inx
         bra   :loop
:done    rts

*-------------------------------------------------------------------
* updcursor: pick the cursor shape and place its sprite.
* Arrow normally; with units selected: attack cross over enemies,
* move cross over open ground.

updcursor
         lda   cx               ; mouse still: look again only every 4th
         cmp   lcx              ; frame (what is under it may change)
         bne   :look
         lda   cy
         cmp   lcy
         bne   :look
         lda   frame
         and   #3
         beq   :look
         rts
:look    lda   cx
         sta   lcx
         lda   cy
         sta   lcy
         lda   paused           ; paused: the arrow
         beq   :mode
         jmp   :arrow
:mode    lda   cmdmode          ; selling or repairing: $ or wrench over
         beq   :normal          ; what it works on, else "no" on the map
         jsr   inmap
         bcs   :mmap
         jmp   :arrow
:mmap    jsr   hitunit
         bmi   :no
         jsr   modeok
         bcc   :no
         lda   #SPR_SELL
         ldx   cmdmode
         cpx   #MODE_SELL
         beq   :cross
         lda   #SPR_REPAIR
         bra   :cross
:no      lda   #SPR_NO
         bra   :cross
:normal  lda   placing          ; placing: plain arrow
         bne   :arrow0
         stz   anysel
         ldx   #0
:sl      cpx   nunits
         bcs   :sd
         lda   uflags,x
         and   #F_SEL
         tsb   anysel
         inx
         inx
         bra   :sl
:sd      lda   anysel
         beq   :arrow
         jsr   inmap
         bcc   :arrow
         jsr   hitunit
         bmi   :ground
         lda   uflags,x
         bit   #F_PLAYER
         bne   :arrow
         lda   #SPR_ATTACK
         bra   :cross
:ground  jsr   mousetile
         tay
         lda   passw,y
         and   #$00FF
         bne   :arrow
         lda   #SPR_MOVE
:cross   sta   cshape           ; (the cursor may run off the right and
         lda   cx               ;   bottom edges: render cuts it off
         sec                    ;   there, see drawclip)
         sbc   #7               ; hotspot (7, 8)
         ldx   #318
         jsr   clamp
         and   #$FFFE
         sta   csx
         lda   cy
         sec
         sbc   #8
         ldx   #199
         jsr   clamp
         sta   csy
         rts
:arrow0
:arrow   lda   #SPR_ARROW
         sta   cshape
         lda   cx               ; hotspot (0, 0)
         and   #$FFFE
         sta   csx
         lda   cy
         sta   csy
         rts

* clamp: A = value, X = maximum -> A clamped to 0..X
clamp    ora   #0
         bpl   :pos
         lda   #0
         rts
:pos     stx   tmp
         cmp   tmp
         bcc   :ok
         txa
:ok      rts

*-------------------------------------------------------------------
* units: think and move for every live unit

units    inc   frame
         ldx   #0
:loop    txa                    ; (every 16 units the music's clock)
         and   #$001F
         bne   :clk
         jsr   musictick
:clk     cpx   nunits
         bcc   :one
         rts
:one     lda   uflags,x
         bit   #F_DEAD+F_BUILDING   ; (buildings do nothing here)
         bne   :next
         stx   self
         jsr   think
         ldx   self
:next    inx
         inx
         bra   :loop

* think: X = self. Decide on targets and shoot, then walk.
think    lda   ureload,x
         beq   :loaded
         dec   ureload,x
:loaded  lda   uflags,x         ; decide every other frame, half the
         bit   #F_HARV          ; units each (harvesters every frame)
         bne   :decide
         txa
         lsr
         eor   frame
         lsr
         bcs   :skip
:decide  jsr   decide
         ldx   self
         lda   uflags,x         ; (keep whether it holds position)
         and   #$FFFF-F_HOLD
         bcc   :walk
         ora   #F_HOLD
         sta   uflags,x
         rts                    ; holding position to shoot
:walk    sta   uflags,x
         bra   :move
:skip    lda   uflags,x         ; not its turn: as it decided last time
         bit   #F_HOLD
         bne   :rts
:move    lda   uflags,x
         bit   #F_STATIC
         bne   :rts
         txa                    ; walk on frames where (unit number +
         lsr                    ; frame) & speed = 0: units take turns
         clc
         adc   frame
         and   uspd,x
         bne   :rts
         jmp   step
:rts     rts

* decide: X = self. Pick, chase or shoot targets; harvesters work.
* Carry set if the unit should stay put this frame.
decide   lda   utarget,x
         bmi   :notgt
         tay
         lda   uflags,y         ; target died?
         bit   #F_DEAD
         bne   :lost
         eor   uflags,x         ; (or its slot went to a new unit of
         and   #F_PLAYER        ; our own side)
         bne   :hastgt
:lost    lda   #NONE
         sta   utarget,x
         lda   uflags,x
         and   #$FFFF-F_CHASE
         sta   uflags,x

:notgt   lda   uflags,x         ; attack wave: fight what's in range,
         bit   #F_AMOVE         ; else march on the command center
         beq   :nt2
         jsr   acquire
         bcs   :go
         lda   hqunit
         sta   utarget,x
         lda   uflags,x
         ora   #F_CHASE
         sta   uflags,x
:go      clc
         rts
:nt2     lda   urange,x         ; armed and idle: look for enemies
         beq   :unarmed
         lda   unext,x
         bpl   :go
         lda   upathpos,x
         cmp   upathlen,x
         bne   :go
         txa                    ; every 32 frames (unit number + frame:
         lsr                    ;   spread out; on its turn, see think)
         clc
         adc   frame
         and   #31
         bne   :go
         jsr   acquire
         clc
         rts
:unarmed lda   uflags,x
         bit   #F_HARV
         beq   :go
         jsr   harvest
         clc
         rts

:hastgt  lda   uflags,x         ; attacking a building: deal with
         bit   #F_AMOVE         ; defenders on the way first
         beq   :ht2
         lda   uflags,y
         bit   #F_BUILDING
         beq   :ht2
         txa                    ; (every 32 frames, spread out)
         lsr
         clc
         adc   frame
         and   #31
         bne   :ht2
         jsr   acqunit
         ldy   utarget,x
:ht2     lda   unext,x          ; finish the step first
         bpl   :go2
         jsr   inrange
         bcc   :out
         lda   upathlen,x       ; in range: stop and shoot
         sta   upathpos,x
         lda   #NONE
         sta   ugoal,x
         jsr   facetarget
         lda   ureload,x
         bne   :stay
         jsr   fire
:stay    sec
         rts
:out     lda   uflags,x
         bit   #F_CHASE
         bne   :chase
         lda   #NONE            ; target walked out of range
         sta   utarget,x
:go2     clc
         rts
:chase   lda   uflags,y
         bit   #F_BUILDING
         beq   :cunit
         lda   ugoal,x          ; building: head for a tile near it
         bpl   :go2
         txa                    ; (not every frame)
         lsr
         clc
         adc   frame
         and   #15
         bne   :go2
         bra   :capp
:cunit   lda   utile,y          ; unit: follow it if it moved
         cmp   ugoal,x
         beq   :go2
         lda   ugoal,x          ; replanning is costly: unless the old
         bmi   :capp            ; path is used up, only every 16 frames
         txa                    ; (unit number + frame: spread out)
         lsr
         clc
         adc   frame
         and   #15
         bne   :go2
:capp    jsr   approach
         clc
         rts

* inrange: X = unit, Y = other -> carry set if within X's range
* (tile distance: the larger of the column and row differences)
inrange  lda   utile,y          ; columns apart: further than the
         and   #MAPW-1          ; range, done (most are)
         sta   tmp
         lda   utile,x
         and   #MAPW-1
         sec
         sbc   tmp
         bpl   :c
         eor   #$FFFF
         inc
:c       cmp   urange,x
         beq   :rows
         bcs   :no
:rows    lda   utile,y          ; then rows apart
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   tmp
         lda   utile,x
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   tmp
         bpl   :r
         eor   #$FFFF
         inc
:r       sta   tmp
         lda   urange,x
         cmp   tmp              ; carry set if range >= distance
         rts
:no      clc
         rts

* acquire: X = unit; target the first enemy in range, carry set if
* found. acqunit ignores buildings.
acquire  lda   #F_DEAD
         bra   acq
acqunit  lda   #F_DEAD+F_BUILDING
acq      sta   acqskip          ; (inrange, unrolled: this runs over
         lda   utile,x          ;   every unit for every unit)
         and   #MAPW-1
         sta   acol
         lda   utile,x
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   arow
         lda   urange,x
         sta   arng
         lda   uflags,x
         and   #F_PLAYER
         sta   aside
         ldy   #0
:loop    cpy   nunits
         bcs   :none
         lda   uflags,y
         bit   acqskip
         bne   :next
         and   #F_PLAYER
         cmp   aside
         beq   :next            ; same side
         lda   utile,y          ; columns apart
         and   #MAPW-1
         sec
         sbc   acol
         bpl   :c
         eor   #$FFFF
         inc
:c       cmp   arng
         beq   :row
         bcs   :next
:row     lda   utile,y          ; rows apart
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   arow
         bpl   :r
         eor   #$FFFF
         inc
:r       cmp   arng
         beq   :hit
         bcs   :next
:hit     tya
         sta   utarget,x
         sec
         rts
:next    iny
         iny
         bra   :loop
:none    clc
         rts

* approach: X = unit, Y = target; plan a path to the nearest reachable
* tile from which the target is in range (buildings stand on blocked
* tiles; walled-in spots near them are skipped).
approach lda   utile,y          ; any tile from where it's in range
         sta   goal
         lda   urange,x
         sta   grange
         stz   avoid
         stx   self
         jmp   pathto

* facetarget: X = unit, Y = target; turn toward it: sideways, or up or
* down when it is further that way (keeps X, Y)
facetarget
         phy
         lda   uy,y             ; dy, dx to the target
         sec
         sbc   uy,x
         sta   tmp2
         lda   ux,y
         sec
         sbc   ux,x
         sta   tmp
         ora   tmp2
         beq   :keep            ; (the same spot: as it is)
         lda   tmp2
         jsr   absval
         pha                    ; |dy|
         lda   tmp
         jsr   absval
         cmp   1,s              ; |dx| >= |dy|: sideways
         pla
         bcs   :side
         lda   #F_VERT          ; up (dy < 0) or down
         ldy   tmp2
         bmi   :turn
         lda   #F_VERT+F_LEFT
         bra   :turn
:side    lda   #0               ; right (dx > 0) or left
         ldy   tmp
         bpl   :turn
         lda   #F_LEFT
:turn    jsr   face
:keep    ply
         rts

* face: X = unit, A = the way it is to face (0 right, F_LEFT left,
* F_VERT up, F_VERT + F_LEFT down): turned (and redrawn) if it faces
* another way (keeps X)
face     sta   tmp
         lda   uflags,x
         and   #F_LEFT+F_VERT
         cmp   tmp
         beq   :rts
         lda   uflags,x
         and   #$FFFF-F_LEFT-F_VERT
         ora   tmp
         ora   #F_DIRTY
         sta   uflags,x
:rts     rts

* fire: X = shooter, Y = target
fire     lda   urate,x
         sta   ureload,x
         lda   uclass,x         ; damage = udmg * dmgtab[weapon, armor] / 8
         and   #$000C           ; (at least 1)
         sta   dmgf
         lda   uclass,y
         and   #$0003
         ora   dmgf
         phx
         tax
         lda   dmgtab,x
         and   #$00FF
         plx
         sta   dmgf
         lda   #0
:mul     dec   dmgf
         bmi   :muld
         clc
         adc   udmg,x
         bra   :mul
:muld    lsr
         lsr
         lsr
         bne   :hit
         inc
:hit     sta   dmgf
         lda   uhp,y
         sec
         sbc   dmgf
         sta   uhp,y
         lda   uflags,y         ; redraw the health bar
         ora   #F_DIRTY
         sta   uflags,y
         lda   ux,y
         sta   rx
         lda   uy,y
         sta   ry
         lda   uclass,x         ; a spark, or a small blast for rockets
         and   #$000C
         cmp   #WPN_ROCKETS*4
         beq   :blast
         lda   #6
         sta   fxtimer
         lda   #SPR_HIT
         bra   :fx
:blast   lda   #8
         sta   fxtimer
         lda   #SPR_BOOM0
:fx      jsr   spawnfx
         lda   uox,x            ; on screen: the sound of its weapon
         cmp   #OFFVIEW
         beq   :quiet
         lda   uclass,x
         and   #$000F
         phx
         tax
         lda   shotsnd,x
         and   #$00FF
         plx
         tsb   sndreq
:quiet
         lda   uhp,y
         beq   :dead
         bmi   :dead
         lda   utarget,y        ; shoot back if idle and armed
         bpl   :rts
         lda   urange,y
         beq   :rts
         txa
         sta   utarget,y
:rts     rts
:dead    jmp   kill

* kill: Y = unit; remove it and leave an explosion (keeps X)
kill     phx
         tyx
         lda   uflags,x
         ora   #F_DEAD+F_DIRTY
         and   #$FFFF-F_SEL
         sta   uflags,x
         lda   utile,x          ; free its tiles
         asl
         tay
         lda   #0
         sta   occ,y
         lda   unext,x
         bmi   :n
         asl
         tay
         lda   #0
         sta   occ,y
:n       lda   uflags,x
         bit   #F_BUILDING
         beq   :static
         jsr   razebuilding
         bra   :power
:static  bit   #F_STATIC        ; a turret: its tile opens up again
         beq   :unit
         lda   utile,x
         jsr   unblock
:power   lda   upower,x         ; player power changed?
         beq   :unit
         phx
         jsr   calcpower
         plx
:unit    lda   quiet            ; (sold: no explosion)
         bne   :done
         lda   uox,x            ; on screen: heard too
         cmp   #OFFVIEW
         beq   :seen
         lda   #SND_BOOM
         tsb   sndreq
:seen    lda   ux,x
         sta   rx
         lda   uy,x
         sta   ry
         lda   #16
         sta   fxtimer
         lda   #SPR_BOOM0
         jsr   spawnfx
:done    plx
         rts

* spawnfx: effect sprite A at rx, ry for fxtimer frames (keeps X, Y)
spawnfx  phx
         phy
         pha
         ldx   #0
:find    lda   fxtime,x
         beq   :free
         inx
         inx
         cpx   #MAXFX*2
         bne   :find
         pla                    ; all busy: skip it
         ply
         plx
         rts
:free    pla
         sta   fxspr,x
         lda   fxtimer
         sta   fxtime,x
         sta   fxnew,x          ; (nonzero: draw it)
         lda   rx
         sta   fxx,x
         lda   ry
         sta   fxy,x
         ply
         plx
         rts

*-------------------------------------------------------------------
* step: X = unit; walk 2 pixels along the path

step     lda   unext,x
         bmi   :plan
         jmp   :walk
:plan    lda   upathpos,x       ; standing on a tile: take the next step?
         cmp   upathlen,x
         bcc   :adv
         lda   ugoal,x
         bmi   :rts
         cmp   utile,x
         beq   :arrived
         sta   goal             ; path ran out early: plan again
         lda   utarget,x        ; (chasing: to within range again)
         bmi   :plain
         tay
         jsr   approach
         bra   :planned
:plain   stz   avoid
         jsr   pathto
:planned ldx   self
         lda   upathpos,x
         cmp   upathlen,x
         bcc   :adv
         rts                    ; no path yet: try again next step
:arrived lda   #NONE
         sta   ugoal,x
:rts     rts

:adv     txa                    ; next tile = utile + the direction at
         asl                    ; upath[unit*64 + pos]
         asl
         asl
         asl
         asl
         clc
         adc   upathpos,x
         tay
         lda   upath,y
         and   #$00FF
         asl
         tay
         lda   dirofs,y
         clc
         adc   utile,x
         sta   ntile
         tay                    ; built over since we planned? plan again
         lda   passw,y
         and   #$00FF
         beq   :open
         lda   upathlen,x
         sta   upathpos,x
         rts
:open    lda   ntile
         asl
         tay
         lda   occ,y
         beq   :free
         sec
         sbc   #2
         cmp   self
         beq   :free
         tay                    ; tile busy: one of ours standing idle
         jsr   budge            ; there makes room; else wait, then go
         inc   ublock,x         ; around
         lda   ublock,x
         cmp   #40
         bcc   :rts
         stz   ublock,x
         lda   ugoal,x
         sta   goal
         lda   #1
         sta   avoid
         jsr   pathto
         stz   avoid
         ldx   self
         rts
:free    stz   ublock,x
         txa                    ; reserve the tile
         inc
         inc
         sta   occ,y
         lda   ntile
         sta   unext,x
         inc   upathpos,x
         lda   uflags,x         ; ours: it sees around that tile
         lsr
         bcc   :face
         lda   ntile
         jsr   sight
:face    lda   ntile            ; face the way we go: sideways when the
         and   #MAPW-1          ;   column changes, else up or down
         sta   tmp
         lda   utile,x
         and   #MAPW-1
         cmp   tmp
         beq   :vert
         lda   #0               ; right
         bcc   :turn
         lda   #F_LEFT          ; left
         bra   :turn
:vert    lda   ntile
         cmp   utile,x
         lda   #F_VERT          ; up (a row above)
         bcc   :turn
         lda   #F_VERT+F_LEFT   ; down
:turn    jsr   face

:walk    lda   unext,x          ; world pixels of the next tile
         and   #MAPW-1
         asl
         asl
         asl
         asl
         sta   tmp
         lda   unext,x
         and   #$FFE0
         lsr
         sta   tmp2
         lda   ux,x
         cmp   tmp
         beq   :wy
         bcc   :xr
         sbc   #2
         bra   :xs
:xr      adc   #2
:xs      sta   ux,x
:wy      lda   uy,x
         cmp   tmp2
         beq   :check
         bcc   :yd
         sbc   #2
         bra   :ys
:yd      adc   #2
:ys      sta   uy,x
:check   lda   ux,x
         cmp   tmp
         bne   :rts2
         lda   uy,x
         cmp   tmp2
         bne   :rts2
         lda   utile,x          ; arrived: free the old tile
         asl
         tay
         lda   #0
         sta   occ,y
         lda   unext,x
         sta   utile,x
         lda   #NONE
         sta   unext,x
:rts2    rts

*-------------------------------------------------------------------
* pathto: X = unit, goal, avoid, grange. Ask for a path; pathwork delivers it
* into upath a few frames later. Meanwhile the unit keeps its goal with
* an empty path and stands still. One search runs at a time; a unit
* asking while another unit's search runs asks again on its next step.

pathto   stx   self
         stz   upathlen,x       ; stand still until the path is ready
         stz   upathpos,x
         lda   goal
         sta   ugoal,x
         lda   jobunit
         bmi   :start           ; no search running: start ours
         cmp   self
         bne   :rts             ; somebody else's: wait our turn
         lda   jobgoal
         cmp   goal
         beq   :rts             ; ours is already running
:start   lda   self             ; new search (or a new goal for ours):
         sta   jobunit          ; pathwork sets it up on its next turn
         lda   goal
         sta   jobgoal
         lda   avoid
         sta   jobavoid
         lda   grange
         sta   jobrange
         lda   #1
         sta   jobinit
:rts     stz   grange           ; (the next caller sets it again)
         rts

* newsearch: X = unit; set up a breadth-first search toward jobgoal on
* the world's tiles. The world's border is all walls, so there are no
* edge checks. 8 directions, no cutting corners past terrain. seen
* holds walls and visited tiles, prev the direction a tile was entered.
newsearch
         lda   unext,x          ; mid-step: plan from where it's going
         bpl   :st
         lda   utile,x
:st      sta   start
         lda   jobgoal          ; goal column and row, for range goals
         and   #MAPW-1
         sta   jobtc
         lda   jobgoal
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   jobtr
         lda   #MAPW*MAPH-1     ; walls and terrain
         ldx   #passw
         ldy   #seen
         mvn   0,0
         lda   jobavoid
         beq   :queue
         ldy   #0               ; tiles taken by other units are walls
:av      cpy   nunits
         bcs   :avd
         cpy   self
         beq   :avn
         lda   uflags,y
         bit   #F_DEAD
         bne   :avn
         lda   utile,y
         jsr   wallup
         lda   unext,y
         bmi   :avn
         jsr   wallup
:avn     iny
         iny
         bra   :av
:avd
         lda   jobrange         ; ...but never the goal itself
         bne   :queue
         ldx   jobgoal
         sep   #$20
         mx    %10
         stz   seen,x
         rep   #$20
         mx    %00
:queue   lda   start
         sta   queue
         stz   head
         lda   #2
         sta   tail
         ldx   start
         sep   #$20
         mx    %10
         lda   #1
         sta   seen,x
         rep   #$20
         mx    %00
         rts

* pathwork: once per frame, last: run steps of the search while the frame
* has time (NODESMIN to NODESMAX of them)
pathwork lda   jobunit
         bpl   :run
         rts
:run     tax
         stx   self
         lda   uflags,x         ; unit died meanwhile: drop the search
         bit   #F_DEAD
         bne   :drop
         lda   ugoal,x          ; it wants somewhere else now: drop it
         cmp   jobgoal
         beq   :work
:drop    lda   #NONE
         sta   jobunit
         rts
:work    lda   jobinit          ; first turn: just set up
         beq   :steps
         stz   jobinit
         jmp   newsearch
:steps   lda   #NODESMAX        ; as many steps as the frame has time
         sta   nodes            ; for, NODESMIN at least
:loop    ldy   head
         cpy   tail
         bcc   :more
         jmp   :fail
:more    dec   nodes            ; out of steps: go on next frame
         beq   :out
         lda   nodes            ; every 4 steps, past the first few:
         and   #3               ; time left?
         bne   :pop
         lda   nodes
         cmp   #NODESMAX-NODESMIN
         bcs   :pop
         jsr   elapsed          ; (keeps Y)
         cmp   #PATHEND
         bcc   :pop
:out     rts
:pop     lda   queue,y
         iny
         iny
         sty   head
         sta   cur
         ldx   jobrange
         bne   :inrange
         cmp   jobgoal          ; exact goal
         bne   :expand
         jmp   :found
:inrange and   #MAPW-1          ; range goal: within jobrange of it?
         sec
         sbc   jobtc
         jsr   absval
         cmp   jobrange
         beq   :col
         bcs   :expand
:col     lda   cur
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   jobtr
         jsr   absval
         cmp   jobrange
         beq   :reached
         bcs   :expand
:reached jmp   :found
:expand  ldx   cur
         sep   #$20
         mx    %10
         lda   seen-MAPW,x        ; north
         bne   :d1
         inc   seen-MAPW,x
         lda   #0
         sta   prev-MAPW,x
         rep   #$20
         mx    %00
         txa
         sec
         sbc   #MAPW
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d1      lda   seen+1,x           ; east
         bne   :d2
         inc   seen+1,x
         lda   #1
         sta   prev+1,x
         rep   #$20
         mx    %00
         txa
         inc
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d2      lda   seen+MAPW,x        ; south
         bne   :d3
         inc   seen+MAPW,x
         lda   #2
         sta   prev+MAPW,x
         rep   #$20
         mx    %00
         txa
         clc
         adc   #MAPW
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d3      lda   seen-1,x           ; west
         bne   :d4
         inc   seen-1,x
         lda   #3
         sta   prev-1,x
         rep   #$20
         mx    %00
         txa
         dec
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d4      lda   seen-MAPW+1,x      ; north-east, if north and east are open
         bne   :d5
         lda   passw-MAPW,x
         bne   :d5
         lda   passw+1,x
         bne   :d5
         inc   seen-MAPW+1,x
         lda   #4
         sta   prev-MAPW+1,x
         rep   #$20
         mx    %00
         txa
         sec
         sbc   #MAPW-1
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d5      lda   seen+MAPW+1,x      ; south-east
         bne   :d6
         lda   passw+MAPW,x
         bne   :d6
         lda   passw+1,x
         bne   :d6
         inc   seen+MAPW+1,x
         lda   #5
         sta   prev+MAPW+1,x
         rep   #$20
         mx    %00
         txa
         clc
         adc   #MAPW+1
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d6      lda   seen+MAPW-1,x      ; south-west
         bne   :d7
         lda   passw+MAPW,x
         bne   :d7
         lda   passw-1,x
         bne   :d7
         inc   seen+MAPW-1,x
         lda   #6
         sta   prev+MAPW-1,x
         rep   #$20
         mx    %00
         txa
         clc
         adc   #MAPW-1
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d7      lda   seen-MAPW-1,x      ; north-west
         bne   :d8
         lda   passw-MAPW,x
         bne   :d8
         lda   passw-1,x
         bne   :d8
         inc   seen-MAPW-1,x
         lda   #7
         sta   prev-MAPW-1,x
         rep   #$20
         mx    %00
         txa
         sec
         sbc   #MAPW+1
         ldy   tail
         sta   queue,y
         iny
         iny
         sty   tail
         sep   #$20
         mx    %10
:d8      rep   #$20
         mx    %00
         jmp   :loop

:found   ldy   #0               ; walk back from it, collecting the
         lda   cur              ; directions
:back    cmp   start
         beq   :copy
         tax
         lda   prev,x
         and   #$00FF
         sep   #$20
         mx    %10
         sta   temppath,y
         rep   #$20
         mx    %00
         iny
         asl
         tax
         lda   cur
         sec
         sbc   dirofs,x
         sta   cur
         bra   :back
:copy    lda   self             ; they are reversed, last step first
         asl
         asl
         asl
         asl
         asl
         sta   tmp2             ; unit * 64
         tax
:cp      cpy   #0
         beq   :cpd
         dey
         lda   temppath,y
         sep   #$20
         mx    %10
         sta   upath,x
         rep   #$20
         mx    %00
         inx
         txa
         sec
         sbc   tmp2
         cmp   #PATHMAX
         bcc   :cp
:cpd     txa
         sec
         sbc   tmp2
         ldx   self
         sta   upathlen,x
         stz   upathpos,x
         stz   ublock,x
         lda   #NONE
         sta   jobunit
         rts

:fail    ldx   self             ; no way there: the unit stops
         stz   upathlen,x
         stz   upathpos,x
         lda   jobavoid         ; (no way around the units in the way:
         bne   :later           ;   it keeps its goal and tries again,
         lda   #NONE            ;   as they may move off)
         sta   ugoal,x
:later   lda   #NONE
         sta   jobunit
         rts

* wallup: A = tile; mark it blocked for the search (keeps Y)
wallup   tax
         sep   #$20
         mx    %10
         lda   #1
         sta   seen,x
         rep   #$20
         mx    %00
         rts

* the offset of a step in each direction: N, E, S, W, NE, SE, SW, NW
dirofs   dw    -MAPW,1,MAPW,-1,-MAPW+1,MAPW+1,MAPW-1,-MAPW-1
* per direction: its bit in a FOG word, and a mask that clears the
* opposite direction's bit (a neighbor's bit pointing back at us)
dirbit   dw    1,2,4,8,16,32,64,128
* per set of sides (N E S W bits): the corners next to them
cornerkill dfb 0,144,48,176,96,240,112,240,192,208,240,240,224,240,240,240
dirnot   dw    $FFFB,$FFF7,$FFFE,$FFFD,$FFBF,$FF7F,$FFEF,$FFDF

*-------------------------------------------------------------------
* render: update every cell that changed since the last frame
* (cells marked anywhere before render, e.g. by production or a
* destroyed building, are part of this pass too)

render   stz   fullview
         lda   scrolled         ; the view moved: redraw all of it
         beq   :units
         stz   scrolled
         inc   fullview
         jsr   markview
:units   ldx   #0               ; units that moved or changed look
:uloop   txa                    ; (every 16 units the music's clock)
         and   #$001F
         bne   :clk
         jsr   musictick
:clk     cpx   nunits
         bcc   :unit
         jmp   :fx
:unit    lda   fullview         ; (standing still, nothing changed, the
         ora   fogchg           ;   view and the fog as they were: as
         bne   :where           ;   drawn)
         lda   unext,x
         bpl   :where
         lda   uflags,x
         bit   #F_DIRTY
         beq   :unext
:where   jsr   scrpos           ; rx, ry = where it shows now
         lda   uflags,x
         bit   #F_DEAD
         beq   :alive
         bit   #F_DIRTY         ; dead: erase it once
         beq   :unext
         lda   #OFFVIEW
         sta   rx
         bra   :mark
:alive   bit   #F_DIRTY
         bne   :mark
         lda   rx
         cmp   uox,x
         bne   :mark
         lda   ry
         cmp   uoy,x
         beq   :unext
:mark    lda   uox,x            ; where it was
         cmp   #OFFVIEW
         beq   :new
         lda   rx
         sta   tmp
         lda   ry
         sta   tmp2
         lda   uox,x
         sta   rx
         lda   uoy,x
         sta   ry
         jsr   markrect
         lda   tmp
         sta   rx
         lda   tmp2
         sta   ry
:new     lda   rx               ; where it is
         sta   uox,x
         lda   ry
         sta   uoy,x
         lda   rx
         cmp   #OFFVIEW
         beq   :clean
         jsr   markrect
:clean   lda   uflags,x
         and   #F_CLEAN
         sta   uflags,x
:unext   inx
         inx
         jmp   :uloop

:fx      stz   fogchg           ; (tiles uncovered from here on count
                                ;   on the next frame)
         ldx   #0               ; effects: age them; redraw only when
:fxl     lda   fxtime,x         ; they appear, change or go away
         beq   :fxn
         dec   fxtime,x
         beq   :fxmark          ; gone now
         lda   fxnew,x
         bne   :fxmark          ; just appeared
         lda   fxspr,x          ; explosion: second frame halfway
         cmp   #SPR_BOOM0
         bne   :fxn
         lda   fxtime,x
         cmp   #7
         bne   :fxn
         lda   #SPR_BOOM1
         sta   fxspr,x
:fxmark  stz   fxnew,x
         jsr   fxpos
         bcc   :fxn
         jsr   markrect
:fxn     inx
         inx
         cpx   #MAXFX*2
         bne   :fxl

         lda   csx              ; cursor moved or changed shape
         cmp   ocsx
         bne   :cmark
         lda   csy
         cmp   ocsy
         bne   :cmark
         lda   cshape
         cmp   ocshape
         beq   :box
:cmark   lda   ocsx             ; (past the edges: the cells at them)
         ldx   #304
         jsr   clamp
         sta   rx
         lda   ocsy
         ldx   #184
         jsr   clamp
         sta   ry
         jsr   markrect
         lda   csx
         sta   ocsx
         ldx   #304
         jsr   clamp
         sta   rx
         lda   csy
         sta   ocsy
         ldx   #184
         jsr   clamp
         sta   ry
         jsr   markrect
         lda   cshape
         sta   ocshape

:box     jsr   boxdirty
         lda   newbanner        ; game just ended: show the panel
         beq   :credits
         stz   newbanner
         jsr   markbanner
:credits jsr   drawcredits
         jsr   drawpower
         jsr   fogwork          ; (after the marks: it sees how busy we are)
         jsr   drawradar
         lda   ndirty
         bne   :draw
         rts

:draw    jsr   restorecells
         ldx   #0               ; units touching dirty cells
:d1      txa                    ; (a full view: many units; every 16
         and   #$001F           ;   the music's clock)
         bne   :clk2
         jsr   musictick
:clk2    cpx   nunits
         bcs   :fxdraw
         lda   uox,x            ; (off screen or dead: not drawn)
         cmp   #OFFVIEW
         beq   :d2
         lda   uflags,x
         bit   #F_DEAD
         bne   :d2
         lda   uox,x
         sta   rx
         lda   uoy,x
         sta   ry
         jsr   touched
         bcc   :d2
         lda   uflags,x         ; buildings are drawn with the map
         bit   #F_BUILDING
         bne   :hurt
         phx
         lda   uflags,x         ; its sprite: right, left (F_LEFT), up
         and   #F_LEFT+F_VERT   ;   (F_VERT) or down (both), one after
         lsr                    ;   the other
         lsr
         clc
         adc   uspr,x
         jsr   drawspr
         plx
         lda   uflags,x
         bit   #F_SEL
         beq   :hurt
         phx
         lda   #SPR_SELECT
         jsr   drawspr
         plx
         jsr   hpbar
         bra   :wrench
:hurt    lda   uhp,x            ; damaged units always show health
         cmp   umaxhp,x
         beq   :wrench
         jsr   hpbar
:wrench  lda   uflags,x         ; being repaired: a blinking wrench
         bit   #F_BLINK
         beq   :d2
         phx
         lda   uox,x
         sta   rx
         lda   uoy,x
         sta   ry
         lda   #SPR_REPAIR
         jsr   drawspr
         plx
:d2      inx
         inx
         jmp   :d1

:fxdraw  ldx   #0
:f1      lda   fxtime,x
         beq   :f2
         jsr   fxpos
         bcc   :f2
         jsr   touched
         bcc   :f2
         phx
         lda   fxspr,x
         jsr   drawspr
         plx
:f2      inx
         inx
         cpx   #MAXFX*2
         bne   :f1

         lda   boxon
         beq   :over
         jsr   drawbox
:over    lda   gameover         ; the end-of-game panel, or the pause one
         ora   paused
         beq   :label
         jsr   drawbanner
:label   lda   lblnum           ; a name tag
         cmp   #NONE
         beq   :cursor
         jsr   labeltouched
         bcc   :cursor
         jsr   drawlabel
:cursor  lda   csx              ; cursor always on top (cut off at the
         sta   rx               ;   right and bottom edges)
         lda   csy
         sta   ry
         lda   csx
         cmp   #305
         bcs   :clip
         lda   csy
         cmp   #185
         bcs   :clip
         lda   cshape
         jsr   drawspr
         bra   :copy
:clip    lda   cshape
         jsr   drawclip
:copy    jsr   copycells
         lda   fullview         ; the whole view: fast copies, SLAMLINES
         beq   :next            ; lines at a time (the music looks at
         lda   #$2000+{TOPH*LINE}  ; its clock in between)
         sta   slamfrom
         lda   #SLAMLINES
         sta   slamrows
:slam    jsr   musictick
         jsl   SLAMADDR
         phk                    ; (data bank 0)
         plb
         lda   slamfrom
         clc
         adc   #SLAMLINES*LINE
         sta   slamfrom
         cmp   #$2000+{200*LINE}
         bcc   :slam
         jsr   musictick
:next    stz   ndirty           ; start the next pass: nothing dirty yet
         inc   stamp
         bne   :rts
         jmp   clearstamps
:rts     rts

* scrpos: X = unit -> rx, ry = its screen position, carry set if the
* whole sprite is in the view; else rx = OFFVIEW (keeps X)
scrpos   lda   ux,x
         sec
         sbc   viewx
         sta   rx
         cmp   #VIEWPX-16+1     ; (unsigned: left of the view too)
         bcs   :out
         lda   uy,x
         sec
         sbc   viewy
         sta   ry
         cmp   #TOPH
         bcc   :out
         cmp   #200-16+1
         bcs   :out
         lda   uflags,x         ; theirs where we have not looked: hidden
         lsr
         bcs   :in
         lda   ux,x
         ldy   uy,x
         jsr   unseen
         bcs   :out
:in      sec
         rts
:out     lda   #OFFVIEW
         sta   rx
         stz   ry
         clc
         rts

* fxpos: X = effect -> rx, ry on screen, carry set if in the view
fxpos    lda   fxx,x
         sec
         sbc   viewx
         sta   rx
         cmp   #VIEWPX-16+1
         bcs   :out
         lda   fxy,x
         sec
         sbc   viewy
         sta   ry
         cmp   #TOPH
         bcc   :out
         cmp   #200-16+1
         bcs   :out
         lda   fxx,x            ; (none where we have not looked)
         ldy   fxy,x
         jsr   unseen
         bcs   :out
         sec
         rts
:out     clc
         rts

* setview: viewx / viewy from camx / camy
setview  lda   camx
         asl
         asl
         asl
         asl
         sta   viewx
         lda   camy
         asl
         asl
         asl
         asl
         sec
         sbc   #TOPH
         sta   viewy
         rts

* markview / markall: mark the cells of the view / of the whole screen
markview lda   #1
         sta   mrow
:row     stz   mcol
:col     jsr   markcell
         inc   mcol
         lda   mcol
         cmp   #VIEWW
         bne   :col
         inc   mrow
         lda   mrow
         cmp   #CELLROWS
         bne   :row
         rts
markall  stz   mrow
:row     stz   mcol
:col     jsr   markcell
         inc   mcol
         lda   mcol
         cmp   #CELLCOLS
         bne   :col
         inc   mrow
         lda   mrow
         cmp   #CELLROWS
         bne   :row
         rts

* boxdirty: mark the old and new box outlines if the box changed
boxdirty lda   boxon
         cmp   oboxon
         bne   :chg
         lda   boxon
         beq   :rts
         lda   boxcol
         cmp   oboxcol
         bne   :chg
         lda   bx0
         cmp   obx0
         bne   :chg
         lda   by0
         cmp   oby0
         bne   :chg
         lda   bx1
         cmp   obx1
         bne   :chg
         lda   by1
         cmp   oby1
         bne   :chg
:rts     rts
:chg     lda   oboxon
         beq   :new
         lda   obx0
         sta   px0
         lda   oby0
         sta   py0
         lda   obx1
         sta   px1
         lda   oby1
         sta   py1
         jsr   markperim
:new     lda   boxcol
         sta   oboxcol
         lda   boxon
         sta   oboxon
         beq   :rts
         lda   bx0
         sta   obx0
         sta   px0
         lda   by0
         sta   oby0
         sta   py0
         lda   bx1
         sta   obx1
         sta   px1
         lda   by1
         sta   oby1
         sta   py1
         jmp   markperim

*-------------------------------------------------------------------
* dirty cells

* markcell: mark cell mcol, mrow (keeps X; ignores cells off screen)
markcell lda   mrow
         cmp   #CELLROWS
         bcs   :rts
         lda   mcol
         cmp   #CELLCOLS
         bcs   :rts
         lda   mrow
         asl
         tay
         lda   rowx40,y
         clc
         adc   mcol
         adc   mcol
         tay
         lda   dirty,y          ; already in the list?
         cmp   stamp
         beq   :rts
         lda   stamp
         sta   dirty,y
         lda   mrow             ; add its buffer address to the list
         asl
         tay
         lda   mcol
         asl
         asl
         asl
         clc
         adc   rowaddr,y
         clc
         adc   #$2000
         ldy   ndirty
         sta   dirtylist,y
         lda   mrow             ; ...and the cell
         xba
         ora   mcol
         sta   dirtycell,y
         iny
         iny
         sty   ndirty
:rts     rts

* clearstamps: the stamp wrapped around: forget all old marks
clearstamps
         lda   #0
         ldy   #CELLCOLS*CELLROWS*2-2
:loop    sta   dirty,y
         dey
         dey
         bpl   :loop
         lda   #1
         sta   stamp
         rts

* markrect: mark the cells under the 16x16 rectangle at rx, ry
* (one cell if it sits exactly on one, else two or four)
markrect jsr   rectcell
         jsr   markcell
         lda   rx
         and   #15
         beq   :down            ; one column wide
         inc   mcol
         jsr   markcell
         dec   mcol
:down    lda   ry
         clc
         adc   #8
         and   #15
         beq   :rts             ; one row high
         inc   mrow
         jsr   markcell
         lda   rx
         and   #15
         beq   :rts
         inc   mcol
         jmp   markcell
:rts     rts

* rectcell: mcol, mrow = the cell holding pixel rx, ry
* (cell rows start 8 lines down, in line with the map tiles)
rectcell lda   rx
         lsr
         lsr
         lsr
         lsr
         sta   mcol
         lda   ry
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   mrow
         rts

* markperim: mark the cells under the outline px0,py0 - px1,py1
markperim
         lda   px0
         lsr
         lsr
         lsr
         lsr
         sta   tmp              ; first column
         lda   px1
         lsr
         lsr
         lsr
         lsr
         sta   tmp2             ; last column
         lda   py0
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   tmp3             ; first row
         lda   tmp              ; top and bottom edges
         sta   mcol
:h       lda   tmp3
         sta   mrow
         jsr   markcell
         lda   py1
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   mrow
         jsr   markcell
         lda   mcol
         cmp   tmp2
         beq   :v
         inc   mcol
         bra   :h
:v       lda   tmp3             ; left and right edges
         sta   mrow
:vl      lda   tmp
         sta   mcol
         jsr   markcell
         lda   tmp2
         sta   mcol
         jsr   markcell
         lda   py1
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         cmp   mrow
         beq   :rts
         inc   mrow
         bra   :vl
:rts     rts

* touched: carry set if any cell under the 16x16 rectangle at rx, ry
* is dirty (keeps X)
touched  jsr   rectcell
         jsr   celltest
         bcs   :rts
         lda   rx
         and   #15
         beq   :down            ; one column wide
         inc   mcol
         jsr   celltest
         bcs   :rts
         dec   mcol
:down    lda   ry
         clc
         adc   #8
         and   #15
         beq   :no              ; one row high
         inc   mrow
         jsr   celltest
         bcs   :rts
         lda   rx
         and   #15
         beq   :no
         inc   mcol
         jmp   celltest
:no      clc
:rts     rts

* celltest: carry set if cell mcol, mrow is dirty
celltest lda   mrow
         asl
         tay
         lda   rowx40,y
         clc
         adc   mcol
         adc   mcol
         tay
         lda   dirty,y
         cmp   stamp
         beq   :yes
         clc
         rts
:yes     sec
         rts

* restorecells / copycells: background -> work buffer, and work
* buffer -> screen, for each cell in the dirty list
restorecells
         ldy   #0
:loop    tya                    ; (every 8 cells the music's clock: a
         and   #$000F           ;   full view takes several frames)
         bne   :clk
         jsr   musictick
:clk     cpy   ndirty
         bcs   :done
         lda   dirtylist,y
         tax
         lda   dirtycell,y
         phy
         jsr   restorecell
         ply
         iny
         iny
         bra   :loop
:done    rts

* restorecell: X = buffer address, A = row * 256 + column of a cell.
* Map cells: draw their tile (mined-out ore if its ore is gone) and any
* building piece on it; the top bar and sidebar: copy the background.
restorecell
         sta   tmp
         and   #$00FF
         cmp   #VIEWW
         bcs   :ui              ; sidebar
         lda   tmp
         xba
         and   #$00FF
         bne   :map             ; (row 0: top bar)
:ui      jsr   cellrows
         jmp   bg2work
:map     dec                    ; tile = (camy + row - 1) * 32 + camx + col
         clc
         adc   camy
         asl
         asl
         asl
         asl
         asl
         sta   tmp2
         lda   tmp
         and   #$00FF
         clc
         adc   camx
         clc
         adc   tmp2
         sta   tmp2             ; the tile
         stx   tmp3             ; the address
         asl                    ; not seen yet: black
         tax
         ldal  FOG,x
         bpl   :seen
         lda   #NSPRITES+TILE_SHROUD
         ldy   tmp3
         ldx   #WORKBANK*$101
         jmp   sprat
:seen    and   #$00FF           ; unseen neighbors: edges (below); a
         sta   fogbits          ; corner only where neither side next
         and   #$000F
         tax                    ; to it has an edge
         lda   cornerkill,x
         and   #$00FF
         trb   fogbits
         ldy   tmp2
         lda   map,y
         and   #$00FF
         sta   tmp
         tax
         lda   tileflags,x      ; ore tile without ore left?
         and   #$00FF
         beq   :draw
         lda   oreamt,y
         and   #$00FF
         bne   :draw
         lda   #TILE_EMPTY
         sta   tmp
:draw    lda   tmp
         clc
         adc   #NSPRITES        ; (tile code follows the sprites')
         ldy   tmp3
         ldx   #WORKBANK*$101
         jsr   sprat
         ldy   tmp2             ; a building piece on it?
         lda   overlay,y
         and   #$00FF
         beq   :edges
         dec
         ldy   tmp3
         ldx   #WORKBANK*$101
         jsr   sprat
:edges   lda   fogbits          ; soft black edges toward unseen
         beq   :rts             ; neighbors, one sprite per side and
         lda   #SPR_FOG         ; corner
         sta   fogspr
:edge    lsr   fogbits
         bcc   :nextedge
         lda   fogspr
         ldy   tmp3
         ldx   #WORKBANK*$101
         jsr   sprat
:nextedge inc  fogspr
         lda   fogbits
         bne   :edge
:rts     rts

copycells
         ldy   #0
:loop    tya                    ; (every 8 cells the music's clock)
         and   #$000F
         bne   :clk
         jsr   musictick
:clk     cpy   ndirty
         bcs   :done
         lda   fullview         ; (the view's cells go by slam then)
         beq   :copy
         lda   dirtycell,y
         and   #$00FF
         cmp   #VIEWW
         bcs   :copy
         lda   dirtycell,y
         cmp   #$0100
         bcs   :skip
:copy    lda   dirtylist,y
         tax
         jsr   cellrows
         phy
         jsr   work2scr
         ply
:skip    iny
         iny
         bra   :loop
:done    rts

* cellrows: X = cell address -> rows = its height (top bar: 8 lines)
cellrows lda   #16
         cpx   #$2000+{TOPH*LINE}
         bcs   :full
         lda   #8
:full    sta   rows
         rts

rowx40   dw    0,40,80,120,160,200,240,280,320,360,400,440,480
* cell rows: row 0 is the top bar (8 lines), rows 1-12 are the map
* tile rows, so a unit standing on a tile covers exactly one cell
rowaddr  dw    0,1280,3840,6400,8960,11520,14080
         dw    16640,19200,21760,24320,26880,29440

* bg2work / work2scr: copy a cell (8 bytes x rows) at buffer address X
bg2work
:row     ldal  BGBANK*$10000,x
         stal  WORKBANK*$10000,x
         ldal  BGBANK*$10000+2,x
         stal  WORKBANK*$10000+2,x
         ldal  BGBANK*$10000+4,x
         stal  WORKBANK*$10000+4,x
         ldal  BGBANK*$10000+6,x
         stal  WORKBANK*$10000+6,x
         txa
         clc
         adc   #LINE
         tax
         dec   rows
         bne   :row
         rts

work2scr
:row     ldal  WORKBANK*$10000,x
         stal  $E10000,x
         ldal  WORKBANK*$10000+2,x
         stal  $E10002,x
         ldal  WORKBANK*$10000+4,x
         stal  $E10004,x
         ldal  WORKBANK*$10000+6,x
         stal  $E10006,x
         txa
         clc
         adc   #LINE
         tax
         dec   rows
         bne   :row
         rts

*-------------------------------------------------------------------
* drawing into the work buffer

* rectaddr: A = buffer address of pixel rx, ry ($2000 + ry*160 + rx/2)
rectaddr lda   ry
         asl
         tax
         lda   rx
         lsr
         clc
         adc   ytab,x
         clc
         adc   #$2000
         rts

* drawclip: sprite A at rx (even), ry into the work buffer, cut off at
* the screen's right and bottom edges (the cursor near them; a compiled
* sprite can't be cut off). Color 0 is see-through.
drawclip asl                    ; its pixels: sprite * 128 in SPRBANK
         asl
         asl
         asl
         asl
         asl
         asl
         sta   lsrc
         lda   #SPRBANK
         sta   lsrc+2
         lda   #WORKBANK
         sta   dst+2
         lda   rx
         lsr
         sta   tmp3             ; its first byte on a line,
         lda   #160
         sec
         sbc   tmp3
         cmp   #8
         bcc   :w
         lda   #8
:w       sta   tmp2             ;   bytes of it on the screen
         lda   ry
         sta   tx               ; the line
         lda   #16
         sta   ty
:row     lda   tx
         cmp   #200
         bcs   :done
         asl
         tax
         lda   ytab,x
         clc
         adc   #$2000
         adc   tmp3
         sta   dst
         ldy   #0
         sep   #$20
         mx    %10
:byte    lda   [lsrc],y         ; 2 pixels: see-through where 0
         beq   :next
         bit   #$F0
         bne   :hi
         sta   tmp              ; (only the right one)
         lda   [dst],y
         and   #$F0
         ora   tmp
         bra   :put
:hi      bit   #$0F
         bne   :put
         sta   tmp              ; (only the left one)
         lda   [dst],y
         and   #$0F
         ora   tmp
:put     sta   [dst],y
:next    iny
         cpy   tmp2
         bne   :byte
         rep   #$20
         mx    %00
         lda   lsrc
         clc
         adc   #8
         sta   lsrc
         inc   tx
         dec   ty
         bne   :row
:done    rts

* drawspr: draw sprite A at rx, ry into the work buffer by calling its
* compiled code (see compile)

drawspr  pha
         jsr   rectaddr
         tay
         pla
         ldx   #WORKBANK*$101

* sprat: draw sprite A with its top left at address Y, in the bank in
* both bytes of X (the data bank while its code runs)
sprat    stx   sprbanks
         asl
         tax
         ldal  SPCODE,x
         sta   jmpvec
         sep   #$20             ; its code: a sprite's in CODEBANK, a
         mx    %10              ;   tile's in TILEBANK
         lda   #CODEBANK
         cpx   #NSPRITES*2
         bcc   :bank
         lda   #TILEBANK
:bank    sta   jmpvec+2
         rep   #$20
         mx    %00
         phb
         lda   sprbanks
         pha
         plb
         plb
         phk                    ; return address for its RTL
         per   :back-1
         dfb   $DC              ; jml [jmpvec] (Merlin has no syntax)
         dw    jmpvec
:back    plb
         rts

* compile: turn every sprite (pixels unpacked in SPRBANK) into code in
* CODEBANK that draws it. Per 16-bit word of the sprite: fully
* transparent - nothing; solid - LDA #pixels / STA off,Y; partly -
* LDA off,Y / AND #mask / ORA #pixels / STA off,Y. Then RTL. off is the
* word's offset from the top left; mask has $F where a pixel is 0.
compile  lda   #CODEBANK
         sta   cptr+2
         sta   jmpvec+2
         stz   cptr
         ldy   #0               ; where the code goes
         stz   sidx
:sprite  lda   sidx
         cmp   #NSPRITES+NTILES*2
         bcc   :one
         rts
:one     cmp   #NSPRITES*2      ; the first map tile: the tiles' code
         bne   :same            ;   goes into TILEBANK, from its start
         lda   #TILEBANK
         sta   cptr+2
         ldy   #0
         lda   sidx
:same    cmp   #NSPRITES*2      ; map tiles: every word drawn as is
         lda   #0
         rol
         sta   opaque
         lda   sidx             ; shroud edges: black where they draw
         sec
         sbc   #SPR_FOG*2
         cmp   #8*2
         lda   #0
         rol
         eor   #1
         sta   blackink
         ldx   sidx
         tya
         stal  SPCODE,x         ; entry point
         txa                    ; * 64 = sprite * 128
         asl
         asl
         asl
         asl
         asl
         asl
         sta   soff
         stz   scr
         lda   #16
         sta   rowsleft
:row     lda   #4
         sta   wleft
:word    ldx   soff
         ldal  SPRBANK*$10000,x
         sta   tmpd
         lda   opaque
         bne   :solid
         lda   tmpd
         beq   :next            ; nothing to draw
         jsr   maskof
         ldx   blackink
         beq   :mask
         stz   tmpd             ; (black: pixels 0 where not masked)
:mask    cmp   #0
         bne   :part
:solid   lda   #$A9             ; LDA #pixels
         jsr   emit1
         lda   tmpd
         jsr   emit2
         bra   :store
:part    lda   #$B9             ; LDA off,Y
         jsr   emit1
         lda   scr
         jsr   emit2
         lda   #$29             ; AND #mask
         jsr   emit1
         lda   tmpm
         jsr   emit2
         lda   #$09             ; ORA #pixels
         jsr   emit1
         lda   tmpd
         jsr   emit2
:store   lda   #$99             ; STA off,Y
         jsr   emit1
         lda   scr
         jsr   emit2
:next    inc   soff
         inc   soff
         inc   scr
         inc   scr
         dec   wleft
         bne   :word
         lda   scr              ; next row
         clc
         adc   #LINE-8
         sta   scr
         dec   rowsleft
         bne   :row
         lda   #$6B             ; RTL
         jsr   emit1
         inc   sidx
         inc   sidx
         jmp   :sprite

* maskof: tmpm = A = mask of the pixel word tmpd ($F per 0 pixel)
maskof   stz   tmpm
         lda   tmpd
         bit   #$000F
         bne   :n1
         lda   #$000F
         tsb   tmpm
:n1      lda   tmpd
         bit   #$00F0
         bne   :n2
         lda   #$00F0
         tsb   tmpm
:n2      lda   tmpd
         bit   #$0F00
         bne   :n3
         lda   #$0F00
         tsb   tmpm
:n3      lda   tmpd
         bit   #$F000
         bne   :n4
         lda   #$F000
         tsb   tmpm
:n4      lda   tmpm
         rts

* emit1 / emit2: a byte / a word of code at [cptr],y
emit1    sep   #$20
         mx    %10
         sta   [cptr],y
         rep   #$20
         mx    %00
         iny
         rts
emit2    sta   [cptr],y
         iny
         iny
         rts

* hpbar: X = unit; 12-pixel health bar over the top of its sprite
* (keeps X)
hpbar    phx
         lda   uhp,x            ; segments = ceil(hp * 6 / maxhp)
         asl
         sta   tmp
         asl
         clc
         adc   tmp
         sta   tmp
         ldy   #0
:seg     cpy   #6
         beq   :segd
         lda   tmp
         beq   :segd
         bmi   :segd
         sec
         sbc   umaxhp,x
         sta   tmp
         iny
         bra   :seg
:segd    tya
         clc
         adc   #LINE
         sta   tmp2             ; end of colored part on line 2
         lda   #$FFFF           ; green, yellow or red
         cpy   #4
         bcs   :col
         lda   #$DDDD
         cpy   #2
         bcs   :col
         lda   #$EEEE
:col     sta   tmp3
         lda   uox,x
         sta   rx
         lda   uoy,x
         sta   ry
         jsr   rectaddr
         inc                    ; start 2 pixels in
         sta   dst
         sep   #$20
         mx    %10
         ldy   #0               ; line 1: dark frame
         lda   #$11
:l1      sta   [dst],y
         iny
         cpy   #6
         bne   :l1
         ldy   #LINE            ; line 2: color, then dark
:l2      lda   #$11
         cpy   tmp2
         bcs   :w
         lda   tmp3
:w       sta   [dst],y
         iny
         cpy   #LINE+6
         bne   :l2
         rep   #$20
         mx    %00
         plx
         rts

* drawbox: box outline bx0,by0 - bx1,by1 in boxcol
drawbox  lda   bx0
         sta   rx
         lda   by0
         sta   ry
         jsr   rectaddr
         sta   dst
         jsr   hline
         lda   by1
         sta   ry
         jsr   rectaddr
         sta   dst
         jsr   hline
         lda   bx0
         sta   rx
         lda   by0
         sta   ry
         jsr   vline
         lda   bx1
         sta   rx
         lda   by0
         sta   ry
         jmp   vline

* hline: bytes from dst covering bx0..bx1
hline    lda   bx1
         sec
         sbc   bx0
         lsr
         inc
         sta   width
         sep   #$20
         mx    %10
         ldy   #0
         lda   boxcol
:l       sta   [dst],y
         iny
         cpy   width
         bne   :l
         rep   #$20
         mx    %00
         rts

* vline: left pixel of the byte at rx, from ry down to by1
vline    jsr   rectaddr
         sta   dst
         lda   by1
         sec
         sbc   ry
         inc
         sta   height
:l       sep   #$20
         mx    %10
         lda   [dst]
         and   #$0F
         ora   boxcol+1
         sta   [dst]
         rep   #$20
         mx    %00
         lda   dst
         clc
         adc   #LINE
         sta   dst
         dec   height
         bne   :l
         rts

*-------------------------------------------------------------------
* harvest: X = harvester. Find ore, mine it, bring it home, repeat.
* ureload doubles as its work timer (think counts it down).

harvest  lda   ustate,x
         cmp   #H_SEEK
         beq   :seek
         cmp   #H_GOTO
         beq   :goto
         cmp   #H_MINE
         beq   :mine
         cmp   #H_HOME
         bne   :h1
         jmp   :home
:h1      cmp   #H_UNLOAD
         bne   :rts
         jmp   :unload
:rts     rts

:seek    jsr   findore
         bmi   :noore
         sta   goal
         stz   avoid
         jsr   pathto
         ldx   self
         lda   ugoal,x
         bmi   :noore           ; can't get there
         lda   #H_GOTO
         sta   ustate,x
         rts
:noore   lda   ucargo,x
         beq   :idle
         jmp   :gohome
:idle    lda   #H_IDLE
         sta   ustate,x
         rts

:goto    lda   unext,x          ; still on the way?
         bpl   :rts
         lda   ugoal,x
         bpl   :rts
         ldy   utile,x          ; arrived: standing on ore?
         lda   oreamt,y
         and   #$00FF
         beq   :reseek
         lda   #H_MINE
         sta   ustate,x
         rts
:reseek  lda   #H_SEEK
         sta   ustate,x
         rts

:mine    lda   ureload,x        ; a scoop every 8 frames
         bne   :rts
         lda   #8
         sta   ureload,x
         ldy   utile,x
         lda   oreamt,y
         and   #$00FF
         beq   :reseek          ; mined out: find more (or go home)
         dec
         sep   #$20
         mx    %10
         sta   oreamt,y
         rep   #$20
         mx    %00
         and   #$00FF
         bne   :t3
         lda   utile,x          ; last of it: the crystals are gone
         jsr   marktile
:t3      lda   ucargo,x
         clc
         adc   #SCOOP
         sta   ucargo,x
         cmp   #CAPACITY
         bcs   :gohome
         rts

:gohome  jsr   nearestdock      ; to the nearest dock
         sta   udock,x
         sta   goal
         stz   avoid
         jsr   pathto
         ldx   self
         lda   #H_HOME
         sta   ustate,x
         rts

:home    lda   unext,x          ; mid-step?
         bpl   :rts2
         lda   utile,x
         cmp   udock,x
         beq   :dock
         lda   ureload,x        ; every 30 frames: is its refinery gone,
         bne   :rts2            ;   or the dock blocked?
         lda   #30
         sta   ureload,x
         lda   udock,x
         jsr   isdock
         bcc   :gohome
         jsr   nudge
         ldx   self
         lda   ugoal,x
         bpl   :rts2            ; still on its way
         jmp   :gohome          ; no path: plan again
:dock    lda   #H_UNLOAD
         sta   ustate,x
:rts2    rts

:unload  lda   ureload,x        ; 25 credits every 4 frames
         bne   :rts2
         lda   #4
         sta   ureload,x
         lda   ucargo,x
         cmp   #25
         bcc   :u1
         lda   #25
:u1      sta   tmp
         lda   ucargo,x
         sec
         sbc   tmp
         sta   ucargo,x
         lda   credits
         clc
         adc   tmp
         bcc   :u2
         lda   #$FFFF           ; that's plenty
:u2      sta   credits
         lda   ucargo,x
         bne   :rts2
         lda   #H_SEEK
         sta   ustate,x
         rts

* nearestdock: X = harvester -> A = the dock nearest to it (column plus
* row distance; keeps X)
nearestdock
         lda   utile,x
         and   #MAPW-1
         sta   col
         lda   utile,x
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   row
         lda   #$7FFF
         sta   tmp3
         ldy   #0
:loop    lda   docks,y
         and   #MAPW-1
         sec
         sbc   col
         jsr   absval
         sta   tmp
         lda   docks,y
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   row
         jsr   absval
         clc
         adc   tmp
         cmp   tmp3
         bcs   :next
         sta   tmp3
         lda   docks,y
         sta   tmp2
:next    iny
         iny
         cpy   ndocks
         bcc   :loop
         lda   tmp2
         rts

* nudge: X = harvester. A unit parked on its dock moves aside.
nudge    lda   udock,x
         sta   clicked
         asl
         tay
         lda   occ,y
         beq   :rts
         dec
         dec
         cmp   self
         beq   :rts
         tay
         lda   unext,y          ; only if it is standing still
         bpl   :rts
         lda   ugoal,y
         bpl   :rts
         lda   self
         pha
         tyx
         stx   self
         jsr   clearclaimed     ; claims the docks, so it won't stay
         jsr   pickgoal         ;   (clicked: the dock)
         bcc   :done
         sta   goal
         stz   avoid
         ldx   self
         jsr   pathto
:done    pla
         sta   self
:rts     rts

* budge: X = self, walking into tile ntile, where unit Y stands. If that
* unit is on the same side, can move and stands idle (no goal, no target;
* a harvester only when it has no work), send it to the nearest free tile
* around it - not one of self's next two steps - so self can pass.
* (keeps X)
budge    lda   uflags,y
         eor   uflags,x
         and   #F_PLAYER
         bne   :no              ; theirs
         lda   uflags,y
         bit   #F_STATIC+F_BUILDING+F_DEAD
         bne   :no
         bit   #F_HARV
         beq   :idle
         lda   ustate,y
         cmp   #H_IDLE
         bne   :no
:idle    lda   unext,y          ; standing still, going nowhere,
         and   ugoal,y
         and   utarget,y        ; fighting nobody
         bmi   :yes             ; (all three NONE: all negative)
:no      rts
:yes     sty   bdunit
         stx   bdself
         jsr   clearclaimed
         ldx   bdself           ; keep self's next two steps free
         lda   ntile
         sta   bdtile
         lda   upathpos,x
         sta   bdpos
         lda   #2
         sta   bdn
:claim   inc   bdpos
         lda   bdpos
         cmp   upathlen,x
         bcs   :pick
         txa                    ; upath[self * 64 + pos]
         asl
         asl
         asl
         asl
         asl
         clc
         adc   bdpos
         tay
         lda   upath,y
         and   #$00FF
         asl
         tay
         lda   bdtile
         clc
         adc   dirofs,y
         sta   bdtile
         asl
         tay
         lda   cstamp
         sta   claimed,y
         dec   bdn
         bne   :claim
:pick    ldy   bdunit           ; the nearest free tile around it (its
         lda   utile,y          ; own does not count)
         sta   clicked
         lda   #$FFF0
         sta   self
         jsr   pickgoal
         bcc   :done
         sta   goal
         stz   avoid
         ldx   bdunit
         jsr   pathto
:done    ldx   bdself
         stx   self
:rts     rts

* findore: X = harvester -> A = nearest tile with ore that nobody else
* stands on, or NONE (N set)
findore  lda   #$7FFF
         sta   tmp2             ; best distance
         lda   #NONE
         sta   tmp3             ; best tile
         stz   btile
:loop    ldy   btile
         lda   oreamt,y
         and   #$00FF
         beq   :next
         tya
         asl
         tay
         lda   occ,y
         beq   :free
         sec
         sbc   #2
         cmp   self
         bne   :next
:free    lda   btile
         and   #MAPW-1
         sta   tmp
         lda   utile,x
         and   #MAPW-1
         sec
         sbc   tmp
         jsr   absval
         sta   col
         lda   btile
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   tmp
         lda   utile,x
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   tmp
         jsr   absval
         cmp   col
         bcs   :max
         lda   col
:max     cmp   tmp2
         bcs   :next
         sta   tmp2
         lda   btile
         sta   tmp3
:next    inc   btile
         lda   btile
         cmp   #MAPW*MAPH
         bne   :loop
         lda   tmp3
         rts

* marktile: A = tile; redraw its cell if it is in the view (keeps X)
marktile sta   tmp
         and   #MAPW-1
         sec
         sbc   camx
         cmp   #VIEWW           ; (unsigned: left of the view too)
         bcs   :rts
         sta   mcol
         lda   tmp
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   camy
         cmp   #VIEWH
         bcs   :rts
         inc                    ; (cell row 0 is the top bar)
         sta   mrow
         jsr   markcell
:rts     rts

* drawcredits: draw the credits number into the background top bar
* when it changed (5 digits, no leading zeros)
drawcredits
         lda   credits
         cmp   shown
         bne   :draw
         rts
:draw    sta   shown
         lda   #BGBANK
         sta   dst+2
         stz   glyphs0          ; gold
         lda   #$2000+CREDX
         sta   tmp3
         lda   credits
         ldx   #0
         jsr   putnum
         lda   #WORKBANK
         sta   dst+2
         lda   #CREDX*2         ; mark it dirty
         sta   rx
         stz   ry
         jmp   markrect

pow10    dw    10000,1000,100,10,1

*-------------------------------------------------------------------
* production: two queues (0 = structures, 1 = units), each building one
* thing at a time from the sidebar icons. A finished unit rolls out; a
* finished structure waits (READY) until it is placed on the map.

* sidebarclick: the icon under the mouse
sidebarclick
         lda   cy               ; the SELL and REPAIR buttons: turn their
         cmp   #BTNY0           ; mode on or off
         bcc   :radar
         cmp   #BTNY1+1
         bcs   :radar
         lda   cx
         cmp   #SELLX0
         bcc   :radar
         cmp   #SELLX1+1
         bcs   :rep
         lda   #MODE_SELL
         bra   :toggle
:rep     cmp   #REPX0
         bcc   :radar
         cmp   #REPX1+1
         bcs   :radar
         lda   #MODE_REPAIR
:toggle  cmp   cmdmode
         bne   :set
         lda   #0
:set     jmp   setmode
:radar   jsr   radarclick       ; on the radar: move the view there
         bcc   :icons
         rts
:icons   lda   #0               ; (an icon ends selling / repairing)
         jsr   setmode
         ldy   #0
:loop    lda   icons,y
         cmp   #NONE
         beq   :rts
         lda   cx
         cmp   icons,y
         bcc   :next
         cmp   icons+4,y
         beq   :xin
         bcs   :next
:xin     lda   cy
         cmp   icons+2,y
         bcc   :next
         cmp   icons+6,y
         beq   :hit
         bcs   :next
:hit     jmp   iconclick
:next    tya
         clc
         adc   #ICONSZ
         tay
         bra   :loop
:rts     rts

* iconclick: Y = icon. Start building it if its queue is idle, it is
* available and affordable; if it is a finished structure, start (or
* stop) placing it.
iconclick
         ldx   icons+18,y       ; X = queue * 2
         lda   qicon,x
         bmi   :start
         tya
         cmp   qicon,x
         bne   :rts             ; the queue is busy with something else
         lda   qready,x
         beq   :rts             ; still building
         lda   placing          ; finished: place it, or stop placing
         eor   #1
         sta   placing
         bne   :rts
         stz   boxon            ; (stopped: hide the outline)
:rts     rts
:start   jsr   available
         bcc   :rts
         stx   tmp3
         lda   icons+8,y
         tax
         lda   credits
         cmp   templates+14,x
         bcc   :rts             ; can't afford it
         sbc   templates+14,x
         sta   credits
         txa
         ldx   tmp3
         sta   qtype,x
         tya
         sta   qicon,x
         stz   qseg,x
         stz   qready,x
         phx
         lda   qtype,x
         tax
         lda   templates+16,x
         plx
         sta   qtime,x
         lda   icons+10,y       ; empty progress bar
         tax
         lda   #BARSEGS
         sta   tmp
         sep   #$20
         mx    %10
         lda   #$11
:track   stal  BGBANK*$10000+$2000,x
         stal  BGBANK*$10000+$2000+LINE,x
         inx
         dec   tmp
         bne   :track
         rep   #$20
         mx    %00
         jmp   markicon

* production: once per frame, both queues
production
         jsr   refreshicons
         ldx   #0
         jsr   prodq
         ldx   #2

* prodq: X = queue * 2; fill the bar, then deliver
prodq    lda   qicon,x
         bmi   :rts0
         lda   qready,x
         beq   :busy            ; (else waiting to be placed)
:rts0    rts
:busy
         lda   qseg,x
         cmp   #BARSEGS
         bcs   :done
         lda   lowpower         ; low power: half speed
         beq   :tick
         lda   frame
         and   #1
         bne   :rts
:tick    dec   qtime,x
         bne   :rts
         lda   qtype,x
         tay
         lda   templates+16,y
         sta   qtime,x
         ldy   qicon,x          ; next segment of the bar
         lda   icons+10,y
         clc
         adc   qseg,x
         phx
         tax
         sep   #$20
         mx    %10
         lda   #$DD
         stal  BGBANK*$10000+$2000,x
         stal  BGBANK*$10000+$2000+LINE,x
         rep   #$20
         mx    %00
         plx
         inc   qseg,x
         jmp   markicon
:done    lda   qtype,x
         tay
         lda   templates+18,y   ; structure: READY until placed
         beq   :unit
         lda   #1
         sta   qready,x
         lda   #SND_READY       ; (a structure is ready to place)
         tsb   sndreq
         ldy   qicon,x
         jmp   drawready
:unit    sty   spawnt
         lda   exittile         ; units roll out of the building they
         sta   spawnat          ;   need - harvesters, needing none, by
         ldy   qicon,x          ;   the command center (so do the others
                                ;   if their building is gone meanwhile)
         lda   icons+12,y
         bmi   :out
         jsr   findbld
         bmi   :out
         sta   spawnat
:out     lda   #F_DIRTY
         sta   spawnfl
         phx
         jsr   spawnunit
         plx
         bcc   :rts             ; no room yet: try again next frame
         lda   #SND_READY       ; (a unit rolled out)
         tsb   sndreq
         jmp   finishq
:rts     rts

* finishq: X = queue * 2; it is idle again, its icon as it was
finishq  ldy   qicon,x
         lda   #NONE
         sta   qicon,x
         stz   qready,x
         jmp   drawicon

* refreshicons: every 8 frames, grey out icons that became unavailable
* and restore those that became available (unless being built)
refreshicons
         lda   frame
         and   #7
         beq   initicons
         rts
initicons
         ldy   #0
         ldx   #0               ; icon * 2
:loop    lda   icons,y
         cmp   #NONE
         beq   :rts
         lda   #0
         jsr   available
         rol
         cmp   iconok,x
         beq   :next
         sta   iconok,x
         tya                    ; being built? leave it alone
         cmp   qicon
         beq   :next
         cmp   qicon+2
         beq   :next
         phx
         phy
         jsr   drawicon
         ply
         plx
:next    inx
         inx
         tya
         clc
         adc   #ICONSZ
         tay
         bra   :loop
:rts     rts

* available: Y = icon -> carry set if it can be built now (soldiers
* need a barracks, vehicles a war factory). Keeps X, Y, A.
available
         pha
         lda   icons+12,y
         bmi   :yes
         jsr   findbld
         bmi   :no
:yes     pla
         sec
         rts
:no      pla
         clc
         rts

* findbld: A = a building's template -> A = the door of one still
* standing, or NONE (N set). Templates are ours or theirs. Keeps X, Y.
findbld  phx
         sta   ftile
         ldx   #0
:loop    cpx   nunits
         bcs   :none
         lda   uflags,x
         and   #F_BUILDING+F_DEAD
         cmp   #F_BUILDING
         bne   :next
         lda   uspr,x
         cmp   ftile
         bne   :next
         jsr   doorof
         bra   :done
:next    inx
         inx
         bra   :loop
:none    lda   #NONE
:done    sta   ftile
         plx
         lda   ftile
         rts

* doorof: X = building -> A = its door, the tile below its bottom left:
* top left + size * MAPW (keeps X, Y)
doorof   lda   ustate,x
         xba                    ; (size * 256 / 8)
         lsr
         lsr
         lsr
         clc
         adc   ucargo,x
         rts

* standing: X = unit, A = template -> carry set if unit X is a building
* of that template still standing (its slot may have gone to another
* unit since). Keeps X, Y.
standing cmp   uspr,x
         bne   :no
         lda   uflags,x
         and   #F_BUILDING+F_DEAD
         cmp   #F_BUILDING
         bne   :no
         sec
         rts
:no      clc
         rts

* drawicon: Y = icon; copy it back from the sidebar layer, grey it out
* if unavailable, and redraw it
drawicon lda   icons+2,y        ; top left in both banks
         asl
         tax
         lda   icons,y
         lsr
         clc
         adc   ytab,x
         clc
         adc   #$2000
         sta   lsrc
         sta   dst
         lda   #UIBANK
         sta   lsrc+2
         lda   #BGBANK
         sta   dst+2
         lda   #ICONWB
         sta   width
         lda   #24
         sta   height
         phy
         jsr   blitlong
         ply
         lda   #WORKBANK
         sta   dst+2
         jsr   available
         bcs   markicon
         jsr   dimicon

* markicon: Y = icon; redraw its 20 x 24 pixels
markicon lda   icons,y
         sta   rx
         lda   icons+2,y
         sta   ry
         phy
         jsr   markrect
         lda   rx
         clc
         adc   #4
         sta   rx
         jsr   markrect
         lda   ry
         clc
         adc   #8
         sta   ry
         jsr   markrect
         lda   rx
         sec
         sbc   #4
         sta   rx

         jsr   markrect
         ply
         rts

* dimicon: Y = icon; darken every other pixel inside it (keeps Y)
dimicon  lda   icons+2,y        ; rows y0+2 .. y1-2
         clc
         adc   #2
         sta   ry
         lda   icons,y          ; bytes (x0+2)/2 .. (x1-2)/2
         clc
         adc   #2
         lsr
         sta   tmp
         lda   icons+4,y
         sec
         sbc   #2
         lsr
         sec
         sbc   tmp
         inc
         sta   tmp3             ; bytes per row
:row     lda   ry
         asl
         tax
         lda   ytab,x
         clc
         adc   tmp
         clc
         adc   #$2000
         tax
         lda   tmp3
         sta   tmp2
         lda   ry
         lsr                    ; even rows: left pixel, odd: right
         sep   #$20
         mx    %10
         bcs   :odd
:even    ldal  BGBANK*$10000,x
         and   #$0F
         ora   #$10
         stal  BGBANK*$10000,x
         inx
         dec   tmp2
         bne   :even
         bra   :rowd
:odd     ldal  BGBANK*$10000,x
         and   #$F0
         ora   #$01
         stal  BGBANK*$10000,x
         inx
         dec   tmp2
         bne   :odd
:rowd    rep   #$20
         mx    %00
         inc   ry
         lda   icons+6,y
         sec
         sbc   #2
         cmp   ry
         bcs   :row
         rts

* drawready: Y = icon; put the READY label on it
drawready
         lda   #ready
         sta   src
         lda   icons+20,y
         clc
         adc   #$2000
         sta   dst
         lda   #BGBANK
         sta   dst+2
         lda   #10
         sta   width
         lda   #7
         sta   height
         phy
         jsr   blit
         ply
         lda   #WORKBANK
         sta   dst+2
         jmp   markicon

*-------------------------------------------------------------------
* scrolling and the radar

* scroll: move the view a tile when the mouse is at the edge of the
* screen or an arrow key is pressed (at most every 4 frames); the M key
* turns the music off or on
scroll   stz   tmp              ; tmp, tmp2 = step in x, y
         stz   tmp2
         sep   #$20
         mx    %10
         lda   KBD
         bmi   :key
         rep   #$20
         mx    %00
         bra   :mouse
:key     sta   KBDSTRB
         rep   #$20
         mx    %00
         and   #$007F
         cmp   #$20             ; Space: nothing selected, nothing to
         bne   :pkey            ;   place, no selling or repairing
         jmp   cancel
:pkey    cmp   #$50             ; P (or p): pause
         beq   :pause
         cmp   #$70
         bne   :mkey
:pause   jmp   pause
:mkey    cmp   #$4D             ; M (or m): the music off or on
         beq   :music
         cmp   #$6D
         bne   :arrow
:music   jmp   togglemusic
:arrow   cmp   #$08             ; left arrow
         bne   :k1
         dec   tmp
:k1      cmp   #$15             ; right
         bne   :k2
         inc   tmp
:k2      cmp   #$0B             ; up
         bne   :k3
         dec   tmp2
:k3      cmp   #$0A             ; down
         bne   :go
         inc   tmp2
         bra   :go
:mouse   lda   frame            ; mouse at the edge: every 4 frames
         sec
         sbc   lastscroll
         cmp   #4
         bcc   :rts
         lda   cx
         bne   :m1
         dec   tmp
:m1      cmp   #319
         bne   :m2
         inc   tmp
:m2      lda   cy
         bne   :m3
         dec   tmp2
:m3      cmp   #199
         bne   :go
         inc   tmp2
:go      lda   camx
         clc
         adc   tmp
         sta   tmp
         lda   camy
         clc
         adc   tmp2
         sta   tmp2
         jmp   moveview
:rts     rts

* moveview: view top left = tmp, tmp2 (clamped); redraw if it moved
moveview lda   tmp
         bpl   :x0
         lda   #0
:x0      cmp   #MAPW-VIEWW+1
         bcc   :x1
         lda   #MAPW-VIEWW
:x1      sta   tmp
         lda   tmp2
         bpl   :y0
         lda   #0
:y0      cmp   #MAPH-VIEWH+1
         bcc   :y1
         lda   #MAPH-VIEWH
:y1      sta   tmp2
         lda   tmp
         cmp   camx
         bne   :move
         lda   tmp2
         cmp   camy
         beq   :rts
:move    lda   tmp
         sta   camx
         lda   tmp2
         sta   camy
         jsr   setview
         lda   #1
         sta   scrolled
         lda   frame
         sta   lastscroll
         lda   #NONE            ; the radar's frame moves too
         sta   radtime
:rts     rts

* radarclick: carry set if the mouse is on the radar; then center the
* view on that spot (radar pixels are 2/3 of a tile)
radarclick
         lda   radaron          ; (off: no)
         beq   :no
         lda   cx
         sec
         sbc   #RADX
         cmp   #RADW
         bcs   :no
         asl
         jsr   div3
         sec
         sbc   #VIEWW/2
         sta   tmp
         lda   cy
         sec
         sbc   #RADY
         cmp   #RADH
         bcs   :no
         asl
         jsr   div3
         sec
         sbc   #VIEWH/2
         sta   tmp2
         jsr   moveview
         sec
         rts
:no      clc
         rts

* div3: A = A / 3 (small numbers)
div3     ldy   #0
:loop    cmp   #3
         bcc   :done
         sbc   #3
         iny
         bra   :loop
:done    tya
         rts

* drawradar: the radar shows a dot per unit (2x2 for buildings; gold
* ours, red theirs) and a light frame around the view. After the view
* moved, all of it is drawn again; otherwise, every 32 frames, only dots
* that moved or went away are redrawn, so few cells change - up to 4 a
* frame, as time allows. Tiles uncovered from the fog are redrawn the same
* way. Without a radar center (or with too little power) it is off.
drawradar
         lda   radaron
         bne   :on
         lda   radoff           ; off: say so, once
         bne   :rts0
         inc   radoff
         jmp   radblank
:on      lda   radoff           ; on again: all of it
         beq   :was
         stz   radoff
         lda   #NONE
         sta   radtime
:was     lda   radtime
         cmp   #NONE
         beq   :full
         lda   radidx           ; dots still to redraw: a few per frame
         cmp   radchg
         bcs   :due
         jmp   :redraw
:due     lda   frame
         sec
         sbc   radtime
         cmp   #32
         bcs   :some
:rts0    rts

:full    lda   frame            ; all of it: the terrain first
         sta   radtime
         stz   radchg           ; (nothing left to redraw dot by dot)
         stz   radidx
         lda   #UIBANK
         sta   lsrc+2
         lda   #BGBANK
         sta   dst+2
         lda   #$2000+{RADY*LINE}+{RADX/2}
         sta   lsrc
         sta   dst
         lda   #RADW/2
         sta   width
         lda   #RADH
         sta   height
         jsr   blitlong
         lda   #WORKBANK
         sta   dst+2
         ldx   #0               ; record and draw every dot, then
:all     txa                    ;   the frame (every 16 units the
         and   #$001F           ;   music's clock)
         bne   :clk
         jsr   musictick
:clk     cpx   #MAXUNITS*2
         bcs   :alld
         jsr   radpos
         lda   rx
         sta   urx,x
         lda   ry
         sta   ury,x
         inx
         inx
         bra   :all
:alld    stz   radmk
         jsr   raddots
         jsr   radframe
         jmp   markradar

:some    lda   frame            ; only what changed
         sta   radtime
         jsr   framepos
         stz   radchg           ; (dots to redraw * 4)
         ldx   #0
:unit    cpx   #MAXUNITS*2
         bcs   :listed
         jsr   radpos           ; rx, ry = where its dot belongs now
         lda   rx
         cmp   urx,x
         bne   :moved
         lda   ry
         cmp   ury,x
         beq   :next
:moved   lda   urx,x            ; its old place and its new one
         cmp   #NONE
         beq   :new
         ldy   radchg
         cpy   #RADLMAX*4
         bcs   :toomany
         sta   radlist,y
         lda   ury,x            ; (2x2: 2 wide and 2 high)
         bpl   :o1
         ora   #$4000
:o1      sta   radlist+2,y
         iny
         iny
         iny
         iny
         sty   radchg
:new     lda   rx
         sta   urx,x
         lda   ry
         sta   ury,x
         lda   rx
         cmp   #NONE
         beq   :next
         ldy   radchg
         cpy   #RADLMAX*4
         bcs   :toomany
         sta   radlist,y
         lda   ry
         bpl   :n1
         ora   #$4000
:n1      sta   radlist+2,y
         iny
         iny
         iny
         iny
         sty   radchg
:next    inx
         inx
         bra   :unit
:toomany lda   #NONE            ; a lot moved: redraw it all next frame
         sta   radtime
         rts
:listed  stz   radidx           ; redraw them from the next frame on
         rts
:redraw  jsr   framepos         ; each pixel of up to 4 of those dots:
         ldy   radidx           ; as it should look now
         tya
         clc
         adc   #4*4
         sta   radstop
:dot     cpy   radchg
         bcs   :done
         cpy   radstop
         bcs   :done
         cpy   radidx           ; more than one: only with time to spare
         beq   :first
         jsr   frameest
         cmp   #RADLATE
         bcs   :done
:first   lda   radlist,y
         sta   rx
         lda   radlist+2,y
         sta   radfl
         and   #$3FFF
         sta   ry
         jsr   radpix
         bit   radfl            ; 2 wide?
         bpl   :tall
         inc   rx
         jsr   radpix
         dec   rx
:tall    bit   radfl            ; 2 high?
         bvc   :dn
         inc   ry
         jsr   radpix
         bit   radfl
         bpl   :dn
         inc   rx
         jsr   radpix
:dn      iny
         iny
         iny
         iny
         bra   :dot
:done    sty   radidx
         rts

* radblank: the radar off: its picture for that (after the name tags in
* the sprite bank) into the sidebar background
radblank lda   #RADOFFADDR
         sta   lsrc
         lda   #SPRBANK
         sta   lsrc+2
         lda   #$2000+{RADY*LINE}+{RADX/2}
         sta   dst
         lda   #BGBANK
         sta   dst+2
         lda   #RADW/2
         sta   width
         lda   #RADH
         sta   height
         jsr   pastelong
         lda   #WORKBANK
         sta   dst+2

* markradar: redraw the radar's cells
markradar
         lda   #1
         sta   mrow
:mr      lda   #CELLCOLS-4
         sta   mcol
:mc      jsr   markcell
         inc   mcol
         lda   mcol
         cmp   #CELLCOLS
         bne   :mc
         inc   mrow
         lda   mrow
         cmp   #4
         bne   :mr
         rts


* radpix: draw radar pixel rx, ry as it should look - the terrain, any
* unit's dot over it (in table order), the view frame on top - and mark
* its cell (keeps X, Y; framepos must be set)
radpix   phx
         phy
         lda   #NONE            ; terrain, unless...
         sta   tmp3
         ldx   #0
:unit    lda   rx               ; dx = rx - dot x: 0, or 0-1 for 2x2
         sec                    ; (no dot: x = NONE, so dx = rx + 1)
         sbc   urx,x
         cmp   #2
         bcs   :next
         sta   tmp2
         lda   ury,x
         bmi   :big
         lda   tmp2
         bne   :next
         lda   ury,x
         cmp   ry
         bne   :next
         bra   :hit
:big     lda   tmp2
         cmp   #2
         bcs   :next
         lda   ury,x
         and   #$7FFF
         sta   tmp2
         lda   ry
         sec
         sbc   tmp2
         cmp   #2
         bcs   :next
:hit     jsr   dotcol
:next    inx
         inx
         cpx   #MAXUNITS*2
         bcc   :unit
:frame   lda   rx               ; on the frame's top or bottom edge?
         cmp   px0
         bcc   :sides
         cmp   px1
         beq   :xin
         bcs   :sides
:xin     lda   ry
         cmp   py0
         beq   :light
         cmp   py1
         beq   :light
:sides   lda   ry               ; ...or its left or right edge?
         cmp   py0
         bcc   :draw
         cmp   py1
         beq   :yin
         bcs   :draw
:yin     lda   rx
         cmp   px0
         beq   :light
         cmp   px1
         bne   :draw
:light   lda   #$000C
         sta   tmp3
:draw    jsr   plot
         lda   rx               ; and its cell
         lsr
         lsr
         lsr
         lsr
         sta   mcol
         lda   ry
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   mrow
         jsr   markcell
         ply
         plx
         rts

* radpos: X = unit -> rx, ry = its radar dot (ry + $8000 for buildings);
* rx = NONE if it has none (dead, hidden, or no unit in that slot)
radpos   cpx   nunits
         bcs   :none
         lda   uflags,x
         bit   #F_DEAD
         bne   :none
         lsr                    ; theirs where we have not looked: none
         bcs   :ours
         lda   ux,x
         ldy   uy,x
         jsr   unseen
         bcs   :none
:ours    lda   utile,x          ; x = RADX + column * 3 / 2
         and   #MAPW-1
         sta   tmp
         asl
         clc
         adc   tmp
         lsr
         clc
         adc   #RADX
         sta   rx
         lda   utile,x          ; y = RADY + row * 3 / 2
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   tmp
         asl
         clc
         adc   tmp
         lsr
         clc
         adc   #RADY
         sta   ry
         lda   uflags,x
         bit   #F_BUILDING
         beq   :rts
         lda   ry
         ora   #$8000
         sta   ry
:rts     rts
:none    lda   #NONE
         sta   rx
         stz   ry
         rts

* raddots: draw every unit's dot as recorded in urx / ury
raddots  ldx   #0
:loop    txa                    ; (every 16 units the music's clock)
         and   #$001F
         bne   :clk
         jsr   musictick
:clk     cpx   #MAXUNITS*2
         bcs   :done
         lda   urx,x
         cmp   #NONE
         beq   :next
         sta   rx
         lda   ury,x
         sta   ry
         jsr   dotcol
         jsr   raddot
:next    inx
         inx
         bra   :loop
:done    rts

* dotcol: X = unit -> tmp3 = its dot's color: gold ours, red theirs
dotcol   lda   uflags,x
         and   #F_PLAYER
         beq   :red
         lda   #$000D
         sta   tmp3
         rts
:red     lda   #$000E
         sta   tmp3
         rts

* raddot: dot (1x1, or 2x2 when ry has $8000) at rx, ry in color tmp3,
* or the terrain again when tmp3 = NONE; with radmk set, marks its cells
* (keeps X)
raddot   lda   ry
         bit   #$8000
         beq   :one
         and   #$7FFF
         sta   ry
         jsr   :pix
         inc   rx
         jsr   :pix
         inc   ry
         jsr   :pix
         dec   rx
         jsr   :pix
         dec   ry
         lda   ry
         ora   #$8000
         sta   ry
:rts     rts
:one     jmp   :pix
:pix     jsr   plot
         lda   radmk
         beq   :rts
         lda   rx               ; and its cell
         lsr
         lsr
         lsr
         lsr
         sta   mcol
         lda   ry
         clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   mrow
         jmp   markcell

* radframe: the light frame around the view (keeps nothing)
radframe jsr   framepos
         lda   #$000C
         sta   tmp3
         jmp   framedraw

* framepos: px0, py0 - px1, py1 = the view frame on the radar
framepos lda   camx             ; x0 = RADX + camx * 3 / 2
         asl
         clc
         adc   camx
         lsr
         clc
         adc   #RADX
         sta   px0
         clc
         adc   #VIEWW*3/2-1
         sta   px1
         lda   camy
         asl
         clc
         adc   camy
         lsr
         clc
         adc   #RADY
         sta   py0
         clc
         adc   #VIEWH*3/2-1
         sta   py1
         rts

* framedraw: draw the frame at px0,py0 - px1,py1 in color tmp3
framedraw
         lda   px0              ; top and bottom
         sta   rx
:h       lda   py0
         sta   ry
         jsr   plot
         lda   py1
         sta   ry
         jsr   plot
         inc   rx
         lda   rx
         cmp   px1
         bcc   :h
         beq   :h
         lda   py0              ; left and right
         sta   ry
:v       lda   px0
         sta   rx
         jsr   plot
         lda   px1
         sta   rx
         jsr   plot
         inc   ry
         lda   ry
         cmp   py1
         bcc   :v
         beq   :v
         rts

* plot: pixel rx, ry in the background = color tmp3, or the terrain's
* pixel from the sidebar layer when tmp3 = NONE (keeps X)
plot     phx
         lda   ry
         asl
         tax
         lda   rx
         lsr
         clc
         adc   ytab,x
         tax
         lda   rx
         lsr                    ; carry = right pixel
         sep   #$20
         mx    %10
         bcs   :right
         lda   tmp3+1           ; color NONE: the terrain's pixel
         bmi   :tleft
         ldal  BGBANK*$10000+$2000,x
         and   #$0F
         sta   tmp
         lda   tmp3
         asl
         asl
         asl
         asl
         ora   tmp
         bra   :put
:tleft   ldal  UIBANK*$10000+$2000,x
         and   #$F0
         sta   tmp
         ldal  BGBANK*$10000+$2000,x
         and   #$0F
         ora   tmp
         bra   :put
:right   lda   tmp3+1
         bmi   :tright
         ldal  BGBANK*$10000+$2000,x
         and   #$F0
         ora   tmp3
         bra   :put
:tright  ldal  UIBANK*$10000+$2000,x
         and   #$0F
         sta   tmp
         ldal  BGBANK*$10000+$2000,x
         and   #$F0
         ora   tmp
:put     stal  BGBANK*$10000+$2000,x
         rep   #$20
         mx    %00
         plx
         rts

*-------------------------------------------------------------------
* fog of war: tiles none of our units has seen yet are black, on the map
* and on the radar. A seen tile stays visible. Seen tiles next to unseen
* ones get soft black edges (restorecell).

* initfog: nothing seen yet - the radar's terrain is put aside at +$8000
* and blacked out in the sidebar layer - then what our units see
initfog  ldx   #MAPW*MAPH*2-2
         lda   #UNSEEN
:clr     stal  FOG,x
         dex
         dex
         bpl   :clr
         ldx   #$2000+{RADY*LINE}+{RADX/2}
         lda   #RADH
         sta   tmp2
:row     ldy   #RADW/4          ; words in a row
         phx
:word    ldal  UIBANK*$10000,x
         stal  UIBANK*$10000+$8000,x
         lda   #0
         stal  UIBANK*$10000,x
         inx
         inx
         dey
         bne   :word
         pla
         clc
         adc   #LINE
         tax
         dec   tmp2
         bne   :row
         ldx   #0
:unit    cpx   nunits
         bcs   :rts
         lda   uflags,x
         lsr                    ; (F_PLAYER)
         bcc   :next
         lda   utile,x
         jsr   sight
:next    inx
         inx
         bra   :unit
:rts     lda   #FQSIZE          ; uncover all of it now
         sta   fqn
         jmp   fogrun

* fogwork: (render) uncover tiles waiting in FOGQ, up to FOGTILES, while
* the frame has time to spare (frameest below FOGLATE; when the whole
* view is redrawn anyway, cells cost nothing more). At least one tile
* every FOGEVERY frames.
fogwork  ldx   fqhead
         cpx   fqtail
         bne   :some
         rts
:some    lda   #FOGTILES
         sta   fqn
         inc   fogwait
:next    lda   fullview         ; time left for another tile?
         beq   :est
         jsr   elapsed
         bra   :late
:est     jsr   frameest
:late    sta   fogtime
         cmp   #FOGLATE
         bcc   :go
         lda   fogwait          ; too late - unless we have waited long
         cmp   #FOGEVERY
         bcc   :rts
:go      stz   fogwait
         ldx   fqhead
         ldal  FOGQ,x
         pha
         txa
         inc
         inc
         and   #FQSIZE*2-1
         sta   fqhead
         pla
         jsr   revtile
         ldx   fqhead
         cpx   fqtail
         beq   :rts
         dec   fqn
         bne   :next
:rts     rts

* fogrun: uncover all fqn tiles waiting (initfog)
fogrun   ldx   fqhead
         cpx   fqtail
         beq   :rts
         ldal  FOGQ,x
         pha
         txa
         inc
         inc
         and   #FQSIZE*2-1
         sta   fqhead
         pla
         jsr   revtile
         dec   fqn
         bne   fogrun
:rts     rts

* seeall: everything seen (only the test scripts ask for it)
seeall   stz   seeallf
         stz   fqhead           ; (nothing left to uncover)
         stz   fqtail
         ldx   #MAPW*MAPH*2-2
         lda   #0
:clr     stal  FOG,x
         dex
         dex
         bpl   :clr
         ldx   #$2000+{RADY*LINE}+{RADX/2}
         lda   #RADH
         sta   tmp2
:row     ldy   #RADW/4
         phx
:word    ldal  UIBANK*$10000+$8000,x
         stal  UIBANK*$10000,x
         inx
         inx
         dey
         bne   :word
         pla
         clc
         adc   #LINE
         tax
         dec   tmp2
         bne   :row
         lda   #1               ; redraw the view and the radar
         sta   scrolled
         lda   #NONE
         sta   radtime
         rts

* sight: X = one of our units; it sees the tiles around tile A, in a
* circle: buildings 4 tiles, units one more than their weapons reach
* but at least 3. Tiles seen for the first time go into FOGQ, and
* fogwork uncovers them a few per frame (keeps X)
sight    phx
         sta   sgtile
         and   #MAPW-1
         sta   sgcol
         lda   sgtile
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   sgrow
         lda   uflags,x
         bit   #F_BUILDING
         beq   :unit
         lda   #4
         bra   :r
:unit    lda   urange,x
         inc
         cmp   #3
         bcs   :r
         lda   #3
:r       sta   sgrad
         lda   sgtile           ; looked around from here this far
         asl                    ; before? Then nothing is new
         tax
         ldal  FOG,x
         bmi   :new             ; (this tile not uncovered yet)
         xba
         and   #$0007
         cmp   sgrad
         bcc   :more
         plx
         rts
:more    ldal  FOG,x            ; (it will have now)
         and   #$F8FF
         sta   sgw
         lda   sgrad
         xba
         ora   sgw
         stal  FOG,x
:new     lda   sgrad
         asl
         asl
         asl
         asl
         sta   sgidx            ; its rows' half widths in sighttab
         lda   sgrow
         sec
         sbc   sgrad
         sta   sgr              ; rows from row - r
         lda   sgrow
         clc
         adc   sgrad
         sta   sgend            ;   to row + r
:row     lda   sgr
         cmp   #MAPH            ; (unsigned: above the map too)
         bcs   :nrow
         ldy   sgidx
         lda   sighttab,y
         and   #$00FF
         sta   sgw
         lda   sgcol            ; columns col - w .. col + w on the map
         sec
         sbc   sgw
         bpl   :c0
         lda   #0
:c0      sta   sgc
         lda   sgcol
         clc
         adc   sgw
         cmp   #MAPW
         bcc   :c1
         lda   #MAPW-1
:c1      sec
         sbc   sgc
         inc
         sta   sgn              ; tiles in the row
         lda   sgr
         asl
         asl
         asl
         asl
         asl
         clc
         adc   sgc
         asl
         tax
:tile    ldal  FOG,x
         bpl   :seen
         bit   #QUEUED
         bne   :seen            ; (already waiting)
         ora   #QUEUED          ; seen: to be uncovered soon (fogwork)
         stal  FOG,x
         phx
         txa
         lsr
         ldx   fqtail
         stal  FOGQ,x
         txa
         inc
         inc
         and   #FQSIZE*2-1
         sta   fqtail
         plx
:seen    inx
         inx
         dec   sgn
         bne   :tile
:nrow    inc   sgidx
         lda   sgr
         cmp   sgend
         beq   :done
         inc   sgr
         jmp   :row
:done    plx
         rts

* revtile: tile A is seen for the first time. Work out which of its
* neighbors are still unseen (its edges), take it out of its seen
* neighbors' edges, redraw it and them, and show its terrain on the radar
revtile  sta   fgtile
         lda   #1               ; (render looks at every unit again)
         sta   fogchg
         lda   #$FF             ; its neighbors that are on the map
         sta   fgin
         lda   fgtile
         and   #MAPW-1
         bne   :notw
         lda   #$C8             ; (none to the W, SW, NW)
         trb   fgin
         bra   :rows
:notw    cmp   #MAPW-1
         bne   :rows
         lda   #$32             ; (none to the E, NE, SE)
         trb   fgin
:rows    lda   fgtile
         cmp   #MAPW
         bcs   :notn
         lda   #$91             ; (none to the N, NE, NW)
         trb   fgin
         bra   :look
:notn    cmp   #MAPW*MAPH-MAPW
         bcc   :look
         lda   #$64             ; (none to the S, SE, SW)
         trb   fgin
:look    stz   fgmask
         ldy   #0               ; direction * 2
:dir     lda   fgin
         and   dirbit,y
         beq   :ndir
         lda   fgtile
         clc
         adc   dirofs,y
         asl
         tax
         ldal  FOG,x
         bpl   :seenn
         lda   dirbit,y         ; unseen: an edge on that side
         tsb   fgmask
         bra   :ndir
:seenn   sta   fgold            ; seen: its edge toward us goes
         and   dirnot,y
         stal  FOG,x
         phx                    ; redraw it if that changes the edges
         sta   fgnew            ; it draws (see restorecell)
         and   #$000F
         tax
         lda   cornerkill,x
         and   #$00FF
         trb   fgnew
         lda   fgold
         and   #$000F
         tax
         lda   cornerkill,x
         and   #$00FF
         eor   #$FFFF
         and   fgold
         plx
         cmp   fgnew
         beq   :ndir
         txa
         lsr
         phy
         jsr   marktile
         ply
:ndir    iny
         iny
         cpy   #16
         bne   :dir
         lda   fgtile
         asl
         tax
         lda   fgmask
         stal  FOG,x            ; seen now
         lda   fgtile
         jsr   marktile

         lda   fgtile           ; its radar pixels: x = RADX + (col * 3
         and   #MAPW-1          ; + 1) / 2, two wide for an even column
         sta   fgx
         asl
         adc   fgx
         inc
         lsr
         clc
         adc   #RADX
         sta   fgx
         lda   fgtile           ; y the same from the row
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   fgy
         asl
         adc   fgy
         inc
         lsr
         clc
         adc   #RADY
         sta   fgy
         jsr   :two
         lda   fgtile
         and   #MAPW            ; (odd row: one pixel high)
         bne   :queue
         inc   fgy
         jsr   :two
         dec   fgy
:queue   lda   radtime          ; redraw them, unless all of the radar
         cmp   #NONE            ; is about to be
         beq   :rts
         ldy   radchg
         cpy   #RADLMAX*4
         bcs   :all
         lda   fgx
         sta   radlist,y
         lda   fgy              ; 2 wide for an even column, 2 high
         sta   radfl            ; for an even row
         lda   fgtile
         lsr
         bcs   :w1
         lda   #$8000
         tsb   radfl
:w1      lda   fgtile
         and   #MAPW
         bne   :h1
         lda   #$4000
         tsb   radfl
:h1      lda   radfl
         sta   radlist+2,y
         iny
         iny
         iny
         iny
         sty   radchg
:rts     rts
:all     lda   #NONE            ; too many: redraw it all
         sta   radtime
         rts
:two     jsr   fogpix           ; pixel fgx, fgy and, for an even
         lda   fgtile           ; column, the one to its right
         lsr
         bcs   :rts
         inc   fgx
         jsr   fogpix
         dec   fgx
         rts

* fogpix: radar pixel fgx, fgy shows its terrain from now on (from the
* copy initfog put aside)
fogpix   lda   fgx
         lsr
         lda   #$00F0           ; even x: the left pixel (high nibble)
         bcc   :m
         lda   #$000F
:m       sta   fgm
         lda   fgy
         asl
         tax
         lda   fgx
         lsr
         clc
         adc   ytab,x
         tax
         sep   #$20
         mx    %10
         ldal  UIBANK*$10000+$A000,x
         and   fgm
         oral  UIBANK*$10000+$2000,x
         stal  UIBANK*$10000+$2000,x
         rep   #$20
         mx    %00
         rts

* unseen: A = world x, Y = world y of something 16x16 -> carry set if
* the tile under its middle has not been seen (keeps X)
unseen   clc
         adc   #8
         lsr
         lsr
         lsr
         lsr
         sta   hidt
         tya
         clc
         adc   #8
         and   #$FFF0
         asl
         clc
         adc   hidt
         asl
         phx
         tax
         ldal  FOG,x
         plx
         cmp   #UNSEEN
         rts

*-------------------------------------------------------------------
* selling and repairing: the SELL and REPAIR buttons turn a mode on (the
* button shows pressed) in which a click on one of our structures sells
* it or starts (or stops) its repair. A click anywhere else on the map,
* or on a build icon, ends the mode.

* setmode: A = the mode from now on (0 = none); redraw the buttons
setmode  cmp   cmdmode
         beq   :rts
         ldx   cmdmode
         sta   cmdmode
         txa
         beq   :new
         jsr   button           ; the old one back to normal
:new     lda   cmdmode
         beq   :rts
         stz   placing          ; (stops placing a structure)
         stz   boxon
         stz   dragging
         jsr   button           ; the new one pressed
:rts     rts

* button: draw button A (MODE_SELL or MODE_REPAIR) into the background
* from the sidebar layer - pressed (colors through btnmap) if it is the
* mode now - and mark its cells
button   sta   tmp3
         ldx   #SELLOFF
         ldy   #SELLW
         lda   #SELLCOL
         sta   mcol
         lda   tmp3
         cmp   #MODE_SELL
         beq   :go
         ldx   #REPOFF
         ldy   #REPW
         lda   #REPCOL
         sta   mcol
:go      sty   width
         lda   #BTNH
         sta   ty
         lda   tmp3
         cmp   cmdmode
         beq   :row             ; (tmp3 nonzero: pressed)
         stz   tmp3
:row     lda   width
         sta   tx
         phx
:byte    lda   tmp3
         bne   :map
         sep   #$20             ; as in the sidebar
         mx    %10
         ldal  UIBANK*$10000+$2000,x
         bra   :put
:map     sep   #$20             ; pressed: both pixels' colors mapped
         mx    %10
         ldal  UIBANK*$10000+$2000,x
         pha
         and   #$0F
         tay
         lda   btnmap,y
         sta   tmp
         pla
         lsr
         lsr
         lsr
         lsr
         tay
         lda   btnmap,y
         asl
         asl
         asl
         asl
         ora   tmp
:put     stal  BGBANK*$10000+$2000,x
         rep   #$20
         mx    %00
         inx
         dec   tx
         bne   :byte
         pla
         clc
         adc   #LINE
         tax
         dec   ty
         bne   :row
         lda   #BTNROW          ; its 2 x 2 cells
         sta   mrow
         jsr   markcell
         inc   mcol
         jsr   markcell
         inc   mrow
         jsr   markcell
         dec   mcol
         jmp   markcell

* modeok: X = unit -> carry set if the mode can work on it: one of our
* structures (not the command center, for selling; damaged or being
* repaired already, for repairing) (keeps X)
modeok   lda   uflags,x
         and   #F_PLAYER+F_DEAD
         cmp   #F_PLAYER
         bne   :no
         lda   uflags,x
         and   #F_BUILDING+F_STATIC
         beq   :no
         lda   cmdmode
         cmp   #MODE_SELL
         bne   :rep
         cpx   hqunit
         beq   :no
         sec
         rts
:rep     lda   uflags,x
         bit   #F_REPAIR
         bne   :yes
         lda   uhp,x
         cmp   umaxhp,x
         bcs   :no
:yes     sec
         rts
:no      clc
         rts

* modeclick: a click on the map while selling or repairing
modeclick
         jsr   hitunit
         bmi   :off
         jsr   modeok
         bcc   :off
         lda   cmdmode
         cmp   #MODE_SELL
         beq   sell
         lda   uflags,x         ; repair: start, or stop
         eor   #F_REPAIR
         and   #$FFFF-F_BLINK
         ora   #F_DIRTY
         sta   uflags,x
         rts
:off     lda   #0               ; nothing to sell or repair there: done
         jmp   setmode

* sell: X = one of our structures; half its price back, and it goes
* (as if destroyed, but without explosions)
sell     lda   credits
         clc
         adc   ucost,x
         bcc   :c
         lda   #$FFFF
:c       sta   credits
         txy
         lda   #1
         sta   quiet
         jsr   kill
         stz   quiet
         rts

* repairs: every REPAIRSTEP frames, each structure being repaired gets
* REPAIRHP hit points for REPAIRCOST credits; repair stops when it is
* whole again or we run out of credits
repairs  lda   frame
         and   #REPAIRSTEP-1
         bne   :rts
         ldx   #0
:loop    cpx   nunits
         bcs   :rts
         lda   uflags,x
         and   #F_REPAIR+F_DEAD
         cmp   #F_REPAIR
         bne   :next
         lda   credits
         cmp   #REPAIRCOST
         bcc   :stop            ; (no money left)
         sbc   #REPAIRCOST
         sta   credits
         lda   uhp,x
         clc
         adc   #REPAIRHP
         cmp   umaxhp,x
         bcc   :hp
         lda   umaxhp,x         ; whole again
         sta   uhp,x
:stop    lda   uflags,x
         and   #$FFFF-F_REPAIR-F_BLINK
         ora   #F_DIRTY
         sta   uflags,x
         bra   :next
:hp      sta   uhp,x
         lda   uflags,x         ; (and the wrench blinks)
         eor   #F_BLINK
         ora   #F_DIRTY
         sta   uflags,x
:next    inx
         inx
         bra   :loop
:rts     rts

*-------------------------------------------------------------------
* sound effects on the Ensoniq DOC: each sound has four oscillators set up
* once (initsound) - two voices, each on the left and the right channel -
* playing its sample once (one-shot mode: it stops at its 0 byte). Events
* set SND_ bits in sndreq; sounds starts them once a frame, taking turns
* with each sound's two voices.

* shotsnd: per unit class (weapon * 4 + armor): the sound of its shots
shotsnd  dfb   SND_RIFLE,SND_CANNON,SND_CANNON,SND_CANNON   ; gun
         dfb   SND_MGUN,SND_MGUN,SND_MGUN,SND_MGUN          ; machine gun
         dfb   SND_ROCKET,SND_ROCKET,SND_ROCKET,SND_ROCKET  ; rockets
         dfb   0,0,0,0

         mx    %11
* docw: DOC register X = A (8-bit; keeps X, Y)
docw     pha
:busy    lda   SOUNDCTL
         bmi   :busy
         and   #$0F             ; registers, no auto-increment; the
         sta   SOUNDCTL         ; volume as the control panel set it
         stx   SOUNDADRL
         pla
         sta   SOUNDDATA
         rts
         mx    %00

* initsound: every oscillator stopped, all 32 running (so a scan is
* 26,320 Hz), and each sound's set up from sndtab: two per voice (left,
* right), from its first oscillator (the music has 0-9)
initsound
         lda   soundok
         bne   :go
         rts
:go      sep   #$30
         mx    %11
         ldx   #$BF             ; (control registers $A0-$BF: halt)
:halt    lda   #$01
         jsr   docw
         dex
         cpx   #$9F
         bne   :halt
         ldx   #$E1
         lda   #$3E             ; (number of oscillators - 1) * 2
         jsr   docw
         ldy   #0               ; Y = the sound's sndtab entry
:snd     cpy   #NSOUNDS*8
         bcs   :done
         lda   sndtab+5,y       ; its first oscillator
         sta   so
         lda   sndtab+6,y       ; voices * 2 of them
         asl
         sta   sk
:osc     ldx   so               ; frequency, low and high
         lda   sndtab+2,y
         jsr   docw
         lda   so
         ora   #$20
         tax
         lda   sndtab+3,y
         jsr   docw
         lda   so               ; volume
         ora   #$40
         tax
         lda   sndtab+4,y
         jsr   docw
         lda   so               ; where the sample is (its page)
         ora   #$80
         tax
         lda   sndtab,y
         jsr   docw
         lda   so               ; table size and resolution
         ora   #$C0
         tax
         lda   sndtab+1,y
         jsr   docw
         lda   so               ; one-shot, halted, on channel so & 1
         ora   #$A0
         tax
         lda   so
         and   #1
         asl
         asl
         asl
         asl
         ora   #$03
         jsr   docw
         inc   so
         dec   sk
         bne   :osc
         tya
         clc
         adc   #8
         tay
         bra   :snd
:done    rep   #$30
         mx    %00
         rts

* sounds: (once a frame) start the sounds asked for: each restarts its
* voice (with two: the other one than last time), both channels (halt,
* then run: it plays from the start)
sounds   lda   sndreq
         bne   :some
         rts
:some    ldx   soundok
         beq   :clear
         sep   #$30
         mx    %11
         sta   sreq
         lda   #1
         sta   sbit
         ldy   #0               ; Y = sound number
:loop    lsr   sreq
         bcc   :skip
         tya                    ; its sndtab entry
         asl
         asl
         asl
         tax
         lda   sndtab+5,x       ; its first oscillator
         sta   so
         lda   sndtab+6,x       ; two voices: + 2 for the other one
         cmp   #2
         bcc   :v0
         lda   svoice
         eor   sbit
         sta   svoice
         and   sbit
         beq   :v0
         lda   so
         clc
         adc   #2
         sta   so
:v0      lda   so
         ora   #$A0
         tax
         lda   #$03             ; left: halt
         jsr   docw
         inx
         lda   #$13             ; right: halt
         jsr   docw
         dex
         lda   #$02             ; left: run (from the start)
         jsr   docw
         inx
         lda   #$12             ; right: run
         jsr   docw
:skip    asl   sbit
         iny
         cpy   #NSOUNDS
         bne   :loop
         rep   #$30
         mx    %00
:clear   stz   sndreq
         rts

*-------------------------------------------------------------------
* music (tools/makemusic.py): the title tune and the battle tune, five
* voices on oscillators 0-9, each on the left and the right channel.
* Bass, lead and arpeggio loop a 256-byte wave (free-run) at a note's
* frequency; their volume follows an envelope, once a frame. Kick/snare
* and hi-hat are one-shot samples. Every so many frames the next step of
* the score: per voice 0 nothing, 255 note off, else a note (musfreq,
* from 1) or a drum (1-3). A tune's numbers (mustracks) are copied into
* mtr when it starts:
MT_FPS   equ   0                ; frames a step
MT_STEPS equ   2                ; steps
MT_VBASE equ   4                ; per voice: where its steps start in musdata
MT_PK    equ   14               ; per tone voice: peak volume, decay a
MT_DC    equ   20               ;   frame, sustain level, release a frame
MT_SU    equ   26
MT_RL    equ   32
MT_DVOL  equ   38               ; per drum: volume
MT_WAVE  equ   44               ; per tone voice: its wave (wavepgs)

* docx: (16-bit caller) DOC register X = A, low bytes (keeps X, Y < 256)
docx     php
         sep   #$30
         mx    %11
         jsr   docw
         plp
         mx    %00
         rts

* musstart: start tune A (TUNE_TITLE, TUNE_BATTLE) from the beginning
musstart ldx   soundok
         bne   :go
         rts
:go      ldx   #0               ; its numbers into mtr
         asl                    ; (A * 50 = A * 2 + A * 16 + A * 32)
         sta   tmp
         asl
         asl
         asl
         sta   tmp2
         asl
         clc
         adc   tmp2
         adc   tmp
         tay
:copy    lda   mustracks,y
         sta   mtr,x
         iny
         iny
         inx
         inx
         cpx   #MTRSZ
         bne   :copy
         ldx   #$A0             ; oscillators 0-9 stopped
:halt    lda   #$01
         jsr   docx
         inx
         cpx   #$AA
         bne   :halt
         ldy   #0               ; tone voices: Y = voice * 2 = its left
:tone    lda   mtr+MT_WAVE,y    ;   oscillator (+1: right); its wave:
         tax                    ;   256 bytes, resolution 0
         lda   wavepgs,x
         and   #$00FF
         sta   mfreq
         tya
         ora   #$80
         tax
         lda   mfreq
         jsr   docx
         inx
         jsr   docx
         tya
         ora   #$C0
         tax
         lda   #0
         jsr   docx
         inx
         jsr   docx
         tya                    ; silent for now
         ora   #$40
         tax
         lda   #0
         jsr   docx
         inx
         jsr   docx
         tya                    ; looping (free-run), running
         ora   #$A0
         tax
         lda   #$00
         jsr   docx
         inx
         lda   #$10
         jsr   docx
         lda   #0
         sta   mvol,y
         sta   mmode,y
         iny
         iny
         cpy   #6
         bne   :tone
         ldx   #6               ; drum voices (oscillators 6-9): at the
:drum    stx   mdbase           ; sample rate (frequency 256: low 0,
         lda   #0               ; high 1), one-shot, stopped, on its
         jsr   docx             ; side
         lda   mdbase
         ora   #$20
         tax
         lda   #1
         jsr   docx
         lda   mdbase
         ora   #$A0
         tax
         lda   mdbase
         and   #1
         asl
         asl
         asl
         asl
         ora   #$03
         jsr   docx
         ldx   mdbase
         inx
         cpx   #10
         bne   :drum
         stz   mstep
         lda   mtr+MT_FPS
         dec
         sta   mtick
         rts

* musplay: (once a frame) the next step when it is time, then the
* envelopes (as makemusic.py's render does it)
musplay  lda   soundok
         bne   :go
         rts
:go      inc   mtick
         lda   mtick
         cmp   mtr+MT_FPS
         bcs   :step
         jmp   :env
:step    stz   mtick
         ldy   #0               ; tone voices (Y = voice * 2)
:tone    lda   mtr+MT_VBASE,y   ; its steps
         clc
         adc   mstep
         tax
         lda   musdata,x
         and   #$00FF
         beq   :tnext
         cmp   #$FF
         bne   :on
         lda   #2               ; note off: fade out
         sta   mmode,y
         bra   :tnext
:on      dec                    ; a note: its frequency, both sides
         asl
         tax
         lda   musfreq,x
         sta   mfreq
         tya
         tax
         lda   mfreq
         jsr   docx
         inx
         jsr   docx
         tya
         ora   #$20
         tax
         lda   mfreq
         xba
         jsr   docx
         inx
         jsr   docx
         lda   mtr+MT_PK,y      ; loud, then decaying
         sta   mvol,y
         lda   #1
         sta   mmode,y
         lda   #NONE            ; (its volume to be written)
         sta   mlast,y
:tnext   iny
         iny
         cpy   #6
         bne   :tone
         ldy   #6               ; kick/snare: oscillators 6, 7
         lda   mtr+MT_VBASE+6
         jsr   :drum
         ldy   #8               ; hi-hat: oscillators 8, 9
         lda   mtr+MT_VBASE+8
         jsr   :drum
         inc   mstep            ; (and round again)
         lda   mstep
         cmp   mtr+MT_STEPS
         bcc   :env
         stz   mstep
:env     ldy   #0               ; envelopes
:ev      lda   mmode,y
         beq   :enext
         cmp   #1
         bne   :rel
         lda   mvol,y           ; decay down to the sustain level
         sec
         sbc   mtr+MT_DC,y
         bmi   :sus
         cmp   mtr+MT_SU,y
         bcs   :setv
:sus     lda   mtr+MT_SU,y
         bra   :setv
:rel     lda   mvol,y           ; fade out to silence
         sec
         sbc   mtr+MT_RL,y
         beq   :quiet
         bpl   :setv
:quiet   lda   #0
         sta   mmode,y
:setv    sta   mvol,y
         cmp   mlast,y          ; (the same as it is: nothing to write)
         beq   :enext
         sta   mlast,y
         sta   mfreq
         tya                    ; volume, both sides
         ora   #$40
         tax
         lda   mfreq
         jsr   docx
         inx
         jsr   docx
:enext   iny
         iny
         cpy   #6
         bne   :ev
         rts
* (a drum voice: Y = its left oscillator, A = where its steps start)
:drum    clc
         adc   mstep
         tax
         lda   musdata,x
         and   #$00FF
         bne   :hit
         rts
:hit     dec                    ; drum 0-2: its sample, size, volume
         sta   mdbase
         tax
         lda   drumpg,x
         jsr   :both80
         ldx   mdbase
         lda   drumsr,x
         jsr   :bothC0
         lda   mdbase
         asl
         tax
         lda   mtr+MT_DVOL,x
         jsr   :both40
         tya                    ; and from the start: stop, then run
         ora   #$A0
         tax
         lda   #$03
         jsr   docx
         inx
         lda   #$13
         jsr   docx
         dex
         lda   #$02
         jsr   docx
         inx
         lda   #$12
         jmp   docx
:both80  pha                    ; (A to register $80/$C0/$40 + Y, Y + 1)
         tya
         ora   #$80
         bra   :both
:bothC0  pha
         tya
         ora   #$C0
         bra   :both
:both40  pha
         tya
         ora   #$40
:both    tax
         pla
         jsr   docx
         inx
         jmp   docx

* musstop: the music silenced (oscillators 0-9 stopped)
musstop  lda   soundok
         beq   :rts
         ldx   #$A0
:halt    lda   #$01
         jsr   docx
         inx
         cpx   #$AA
         bne   :halt
:rts     rts

* musictick: the music's clock in a game. Each video frame that has begun
* since the last look (VERTCNT counting from the top again) moves the
* tune a frame on. It is looked at before and after each wait for the
* blank, and inside the long loops (every 8 cells redrawn, every 16
* units), more than once a frame, so a frame of the game that takes
* several (a scroll redraws the whole view) doesn't slow the tune.
* (Keeps X, Y; data bank 0.)
musictick
         lda   musicon
         beq   :rts
         sep   #$20
         mx    %10
         lda   VERTCNT
         cmp   mvc              ; lower than last time: a new frame
         sta   mvc
         rep   #$20
         mx    %00
         bcs   :rts
         phx
         phy
         jsr   musplay
         ply
         plx
:rts     rts

* cancel: the Space bar - no unit selected, no structure being placed (it
* stays ready), no selling or repairing
cancel   jsr   deselect
         stz   placing
         stz   boxon
         stz   dragging
         lda   #0
         jmp   setmode

* pause: the P key - the game stops, the music too, under a panel with
* RESUME and QUIT MISSION (see pauseinput)
pause    lda   #1
         sta   paused
         stz   pmusic
         lda   musicon
         beq   :quiet
         inc   pmusic
         stz   musicon
         jsr   musstop
:quiet   stz   dragging
         stz   boxon
         jsr   hidelabel
         jmp   markbanner

* unpause: on with the game (the panel's cells drawn again), the battle
* tune again if it was playing
unpause  stz   paused
         jsr   markbanner
         lda   pmusic
         beq   :rts
         lda   #TUNE_BATTLE
         jsr   musstart
         lda   #1
         sta   musicon
:rts     rts

* pauseinput: while paused - P, Space or RETURN, or a click on RESUME, goes
* on; Q, or a click on QUIT MISSION: carry set (back to the mission setup)
pauseinput
         sep   #$20
         mx    %10
         lda   KBD
         bmi   :key
         rep   #$20
         mx    %00
         bra   :mouse
:key     sta   KBDSTRB
         rep   #$20
         mx    %00
         and   #$007F
         cmp   #$20             ; Space
         beq   :go
         cmp   #$0D             ; RETURN
         beq   :go
         and   #$005F           ; (capitals)
         cmp   #$51             ; Q
         beq   :quit
         cmp   #$50             ; P
         beq   :go
:mouse   lda   click
         beq   :stay
         lda   cy
         cmp   #PBTNY0
         bcc   :stay
         cmp   #PBTNY1+1
         bcs   :stay
         lda   cx
         cmp   #PRESX0
         bcc   :stay
         cmp   #PRESX1+1
         bcc   :go
         cmp   #PQUITX0
         bcc   :stay
         cmp   #PQUITX1+1
         bcc   :quit
:stay    clc
         rts
:go      jsr   unpause
         clc
         rts
:quit    sec
         rts

* togglemusic: the M key - the music off, or the battle tune on again
togglemusic
         lda   MUSICOFF
         eor   #1
         sta   MUSICOFF
         bne   :off
         lda   #TUNE_BATTLE
         jsr   musstart
         lda   #1
         sta   musicon
         rts
:off     stz   musicon
         jmp   musstop

wavepgs  dfb   PG_BASS,PG_LEAD,PG_ARP,PG_PAD   ; the tone voices' waves
drumpg   dfb   PG_KICK,PG_SNARE,PG_HAT   ; per drum: page, size/resolution
drumsr   dfb   SR_KICK,SR_SNARE,SR_HAT

*-------------------------------------------------------------------
* placing structures

* updplace: while placing, follow the mouse with the footprint outline:
* green where it fits, red where it doesn't
updplace lda   placing
         bne   :on
         rts
:on      jsr   inmap
         bcs   :in
         stz   boxon
         rts
:in      ldx   qtype            ; size of the structure
         lda   templates+20,x
         sta   bsize
         dec                    ; the mouse is near its middle:
         asl                    ; top left = (mouse - (size-1)*8) / 16
         asl
         asl
         sta   tmp
         lda   cx
         sec
         sbc   tmp
         bpl   :x0
         lda   #0
:x0      lsr
         lsr
         lsr
         lsr
         sta   vcol
         lda   #VIEWW
         sec
         sbc   bsize
         cmp   vcol
         bcs   :x1
         sta   vcol
:x1      lda   cy
         sec
         sbc   #TOPH
         sec
         sbc   tmp
         bpl   :y0
         lda   #0
:y0      lsr
         lsr
         lsr
         lsr
         sta   vrow
         lda   #VIEWH
         sec
         sbc   bsize
         cmp   vrow
         bcs   :y1
         sta   vrow
:y1      lda   vrow             ; in the world
         clc
         adc   camy
         asl
         asl
         asl
         asl
         asl
         sta   tmp
         lda   vcol
         clc
         adc   camx
         clc
         adc   tmp
         sta   placetile
         jsr   canplace
         lda   #$E0EE           ; red
         bcc   :col
         lda   #$F0FF           ; green
:col     sta   boxcol
         lda   #0
         rol
         sta   placeok
         lda   vcol             ; the outline, on the screen
         asl
         asl
         asl
         asl
         sta   bx0
         lda   vrow
         asl
         asl
         asl
         asl
         clc
         adc   #TOPH
         sta   by0
         lda   bsize
         asl
         asl
         asl
         asl
         sta   tmp
         clc
         adc   bx0
         dec
         dec
         sta   bx1
         lda   tmp
         clc
         adc   by0
         dec
         sta   by1
         lda   #1
         sta   boxon
         rts

* canplace: carry set if a bsize x bsize structure fits at placetile:
* open ground without ore, units or a harvester dock, near one of the
* player's buildings; a refinery's dock (below its bottom left) open
canplace stz   ty
:row     stz   tx
:col     lda   ty
         asl
         asl
         asl
         asl
         asl
         clc
         adc   tx
         clc
         adc   placetile
         jsr   isdock
         bcs   :no2
         tay
         lda   passw,y
         and   #$00FF
         bne   :no2
         lda   oreamt,y
         and   #$00FF
         bne   :no2
         tya
         asl
         tay
         lda   occ,y
         bne   :no2
         tyx                    ; and seen
         ldal  FOG,x
         bmi   :no2
         inc   tx
         lda   tx
         cmp   bsize
         bne   :col
         inc   ty
         lda   ty
         cmp   bsize
         bne   :row
         lda   qtype            ; a refinery: its dock open
         cmp   #TMPL_REFP
         bne   :near0
         lda   placetile
         clc
         adc   #2*MAPW
         tay
         lda   passw,y
         and   #$00FF
         beq   :near0
:no2     clc
         rts
:near0   lda   placetile        ; near a building of ours?
         and   #MAPW-1
         sta   col
         lda   placetile
         lsr
         lsr
         lsr
         lsr
         lsr
         sta   row
         ldx   #0
:near    cpx   nunits
         bcs   :no
         lda   uflags,x
         and   #F_PLAYER+F_BUILDING+F_DEAD
         cmp   #F_PLAYER+F_BUILDING
         bne   :next
         lda   utile,x
         and   #MAPW-1
         sec
         sbc   col
         jsr   absval
         cmp   #PLACERANGE+1
         bcs   :next
         lda   utile,x
         lsr
         lsr
         lsr
         lsr
         lsr
         sec
         sbc   row
         jsr   absval
         cmp   #PLACERANGE+1
         bcc   :yes
:next    inx
         inx
         bra   :near
:yes     sec
         rts
:no      clc
         rts

* place: put the finished structure at placetile
place    lda   qtype
         sta   spawnt
         jsr   findslot
         bcs   :slot
         rts                    ; no room in the unit table
:slot    lda   placetile
         sta   tmp2
         jsr   claimslot
         lda   #F_DIRTY
         sta   spawnfl
         jsr   fillunit         ; Y = the new unit
         ldx   spawnt
         lda   templates+14,x   ; it sells for half its price
         lsr
         sta   ucost,y
         lda   templates+22,x
         sta   upower,y
         lda   templates+20,x
         sta   bsize
         lda   templates+2,x
         bit   #F_BUILDING
         beq   :block
         txa                    ; building: uspr = its template,
         sta   uspr,y           ; footprint, centered position
         lda   placetile
         sta   ucargo,y
         lda   bsize
         sta   ustate,y
         lda   ux,y
         clc
         adc   #8
         sta   ux,y
         lda   uy,y
         clc
         adc   #8
         sta   uy,y
         lda   templates,x      ; its four pieces on the map
         inc
         sta   tmp3
         lda   placetile
         jsr   :piece
         lda   placetile
         inc
         jsr   :piece
         lda   placetile
         clc
         adc   #MAPW
         jsr   :piece
         lda   placetile
         clc
         adc   #MAPW+1
         jsr   :piece
:block   lda   placetile        ; its tiles are walls now
         sta   tmp2
         jsr   blockfoot
         jsr   calcpower        ; (a refinery: a dock more)
         stz   placing          ; done
         stz   boxon
         lda   #SND_PLACE
         tsb   sndreq
         lda   qtype            ; a refinery comes with a harvester,
         cmp   #TMPL_REFP       ;   at its dock
         bne   :fin
         lda   placetile
         clc
         adc   #2*MAPW
         sta   spawnat
         lda   #TMPL_HARVP
         sta   spawnt
         lda   #F_DIRTY
         sta   spawnfl
         jsr   spawnunit
:fin     ldx   #0
         jmp   finishq
:piece   tay                    ; tile A gets piece tmp3 (sprite + 1)
         lda   tmp3
         inc   tmp3
         sep   #$20
         mx    %10
         sta   overlay,y
         rep   #$20
         mx    %00
         tya
         jmp   marktile

* blockfoot: wall off a bsize x bsize footprint, top left tile tmp2
* (keeps X)
blockfoot
         stz   ty
:row     stz   tx
:col     lda   ty
         asl
         asl
         asl
         asl
         asl
         clc
         adc   tx
         clc
         adc   tmp2
         jsr   blocktile
         inc   tx
         lda   tx
         cmp   bsize
         bne   :col
         inc   ty
         lda   ty
         cmp   bsize
         bne   :row
         rts

* blocktile / unblock: A = tile; wall it off, or make it as passable as
* the map says (keeps X, Y)
blocktile
         phy
         tay
         sep   #$20
         mx    %10
         lda   #1
         sta   passw,y
         rep   #$20
         mx    %00
         ply
         rts
unblock  phy
         tay
         sep   #$20
         mx    %10
         lda   passmap,y
         sta   passw,y
         rep   #$20
         mx    %00
         ply
         rts

*-------------------------------------------------------------------
* power: the command center and power plants make it, barracks and
* turrets use it. Using more than is made halves production speed.

calcpower
         stz   pwrmade
         stz   pwrused
         stz   radhave
         lda   dock             ; the docks: by the command center,
         sta   docks            ;   then at each refinery
         lda   #2
         sta   ndocks
         ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         and   #F_PLAYER+F_DEAD
         cmp   #F_PLAYER
         bne   :next
         lda   uflags,x
         bit   #F_BUILDING
         beq   :pow
         lda   uspr,x
         cmp   #TMPL_RADARP
         bne   :ref
         inc   radhave
:ref     cmp   #TMPL_REFP
         bne   :pow
         ldy   ndocks
         cpy   #DOCKSMAX*2
         bcs   :pow
         jsr   doorof
         sta   docks,y
         iny
         iny
         sty   ndocks
:pow     lda   upower,x
         beq   :next
         bmi   :use
         clc
         adc   pwrmade
         sta   pwrmade
         bra   :next
:use     eor   #$FFFF
         inc
         clc
         adc   pwrused
         sta   pwrused
:next    inx
         inx
         bra   :loop
:done    stz   lowpower
         lda   pwrmade
         cmp   pwrused
         bcs   :rad
         inc   lowpower
         stz   radhave          ; (the radar needs power too)
:rad     lda   radhave
         ora   radarall
         beq   :off
         lda   #1
:off     sta   radaron
         rts

* isdock: carry set if tile A is one of the docks (keeps A, X, Y)
isdock   phy
         ldy   ndocks
:loop    dey
         dey
         bmi   :no
         cmp   docks,y
         bne   :loop
         ply
         sec
         rts
:no      ply
         clc
         rts


* drawpower: the numbers in the top bar ("used/made", green, red when
* low) and the bar in the sidebar, when they changed
drawpower
         lda   pwrmade
         cmp   shownmade
         bne   :draw
         lda   pwrused
         cmp   shownused
         bne   :draw
         rts
:draw    lda   pwrmade
         sta   shownmade
         lda   pwrused
         sta   shownused
         lda   #BGBANK
         sta   dst+2
         lda   #NGLYPHS         ; green glyphs, or red
         ldx   lowpower
         beq   :c
         lda   #NGLYPHS*2
:c       sta   glyphs0
         lda   #$2000+POWX
         sta   tmp3
         lda   pwrused
         ldx   #4               ; 3 digits (from 100)
         jsr   putnum
         lda   #11              ; '/'
         jsr   putglyph
         lda   pwrmade
         ldx   #4
         jsr   putnum
         lda   #POWX*2          ; redraw them
         sta   rx
         stz   ry
         jsr   markrect
         lda   #POWX*2+16
         sta   rx
         jsr   markrect

         lda   pwrmade          ; bar: green (red when low) up to
         lsr                    ; made/16 steps, a light mark at used/16
         lsr
         lsr
         lsr
         cmp   #POWBARN
         bcc   :n
         lda   #POWBARN
:n       sta   tmp
         lda   pwrused
         beq   :nomark
         lsr
         lsr
         lsr
         lsr
         cmp   #POWBARN
         bcc   :m
         lda   #POWBARN-1
:m       sta   tmp2
         bra   :fill
:nomark  lda   #NONE
         sta   tmp2
:fill    ldx   #$2000+POWBAROFF
         ldy   #0               ; step
         sep   #$20
         mx    %10
:step    lda   #$11
         cpy   tmp
         bcs   :mark
         lda   #$FF             ; green
         bit   lowpower
         beq   :mark            ; (bit tests the low byte only)
         lda   #$EE             ; red
:mark    cpy   tmp2
         bne   :put
         lda   #$CC
:put     stal  BGBANK*$10000,x
         stal  BGBANK*$10000+LINE,x
         stal  BGBANK*$10000+{2*LINE},x
         stal  BGBANK*$10000+{3*LINE},x
         stal  BGBANK*$10000+{4*LINE},x
         inx
         iny
         cpy   #POWBARN
         bne   :step
         rep   #$20
         mx    %00
         lda   #WORKBANK
         sta   dst+2
         lda   #POWBARX
         sta   rx
         lda   #POWBARY
         sta   ry
         jsr   markrect
         lda   #POWBARX+16
         sta   rx
         jsr   markrect
         lda   #POWBARX+32
         sta   rx
         jmp   markrect

* putnum: print A right-aligned with X/2 digits left out of 5 (X = 0:
* 5 digits, 4: 3 digits), glyph colors from glyphs0, at tmp3 onwards
putnum   sta   tmp
         stz   tmp2             ; set once a digit has been printed
:digit   ldy   #0               ; digit = how often pow10 fits
:sub     lda   tmp
         cmp   pow10,x
         bcc   :got
         sbc   pow10,x
         sta   tmp
         iny
         bra   :sub
:got     tya
         bne   :nz
         ldy   tmp2             ; (A stays 0)
         bne   :glyph           ; zero inside the number
         cpx   #8
         beq   :glyph           ; the last digit always shows
         lda   #10              ; leading zero: blank
         bra   :glyph
:nz      lda   #1
         sta   tmp2
         tya
:glyph   phx
         jsr   putglyph
         plx
         inx
         inx
         cpx   #10
         bne   :digit
         rts

* putglyph: glyph A (+ glyphs0) into the background at tmp3; tmp3
* moves on (needs dst+2 = BGBANK)
putglyph clc
         adc   glyphs0
         asl                    ; * 16 bytes per glyph
         asl
         asl
         asl
         clc
         adc   #glyphs
         sta   src
         lda   tmp3
         sta   dst
         lda   #2
         sta   width
         lda   #TOPH
         sta   height
         jsr   blit
         lda   tmp3
         clc
         adc   #2
         sta   tmp3
         rts

* spawnunit: put a new unit of template spawnt, with extra flags
* spawnfl, near tile spawnat. Carry clear if no free slot or tile.
spawnunit
         jsr   findslot
         bcs   :slot
         rts
:slot    jsr   clearclaimed     ; nearest free tile around the exit
         lda   spawnat
         sta   clicked
         lda   #$FFF0           ; no unit's own tile counts as free
         sta   self
         jsr   pickgoal
         bcs   :tile
         rts
:tile    sta   tmp2
         jsr   claimslot
         jsr   fillunit
         sec
         rts

* findslot: Y = slot = a dead unit's slot, or a new one; carry clear if
* the table is full
findslot ldy   #0
:find    cpy   nunits
         bcs   :append
         lda   uflags,y
         bit   #F_DEAD
         bne   :slot
         iny
         iny
         bra   :find
:append  cpy   #MAXUNITS*2
         bcc   :slot
         clc
         rts
:slot    sty   slot
         sec
         rts

* claimslot: take slot (Y = slot): grow the table, or make sure nobody
* still aims at the dead unit that had it
claimslot
         ldy   slot
         cpy   nunits
         bcc   :reuse
         tya
         inc
         inc
         sta   nunits
         rts
:reuse   ldx   #0               ; a dead unit's slot: nobody may still
:forget  cpx   nunits           ; be aiming at it
         bcs   :done
         tya
         cmp   utarget,x
         bne   :fn
         lda   #NONE
         sta   utarget,x
         lda   uflags,x
         and   #$FFFF-F_CHASE
         sta   uflags,x
:fn      inx
         inx
         bra   :forget
:done    rts

* fillunit: unit slot (-> Y) from template spawnt, flags + spawnfl,
* standing on tile tmp2
fillunit ldy   slot
         ldx   spawnt
         lda   templates,x
         sta   uspr,y
         lda   templates+2,x
         ora   spawnfl
         sta   uflags,y
         and   #F_HARV
         beq   :st
         lda   #H_SEEK
:st      sta   ustate,y
         lda   templates+4,x
         sta   uspd,y
         lda   templates+6,x
         sta   uhp,y
         sta   umaxhp,y
         lda   templates+8,x
         sta   urange,y
         lda   templates+10,x
         sta   udmg,y
         lda   templates+12,x
         sta   urate,y
         lda   templates+24,x
         sta   uclass,y
         lda   tmp2
         sta   utile,y
         jsr   tilepos
         lda   #OFFVIEW
         sta   uox,y
         lda   #NONE
         sta   unext,y
         sta   ugoal,y
         sta   utarget,y
         lda   #0
         sta   upathpos,y
         sta   upathlen,y
         sta   ureload,y
         sta   ublock,y
         sta   ucargo,y
         sta   upower,y
         lda   tmp2             ; it stands there
         asl
         tax
         tya
         inc
         inc
         sta   occ,x
         lda   uflags,y         ; ours: it sees around it
         lsr
         bcc   :rts
         phx
         phy
         tyx
         lda   utile,x
         jsr   sight
         ply
         plx
:rts     rts

* tilepos: Y = unit standing on tile A: ux, uy = its world pixels
* (keeps X, Y)
tilepos  pha
         and   #MAPW-1
         asl
         asl
         asl
         asl
         sta   ux,y
         pla
         and   #$FFE0           ; row * 32 -> row * 16
         lsr
         sta   uy,y
         rts

* clearclaimed: forget the goals handed out by the last order. The
* harvester docks are never handed out. Keeps X.
clearclaimed
         inc   cstamp           ; older marks no longer count
         bne   :dock
         lda   #0               ; wrapped around: really clear
         ldy   #MAPW*MAPH*2-2
:loop    sta   claimed,y
         dey
         dey
         bpl   :loop
         inc   cstamp
:dock    phx
         ldy   ndocks
:d       dey
         dey
         bmi   :done
         lda   docks,y
         asl
         tax
         lda   cstamp
         sta   claimed,x
         bra   :d
:done    plx
         rts


*-------------------------------------------------------------------
* enemy AI (its numbers depend on the difficulty: initai, difftab):
* a trickle of income (aiincome credits every 8 frames) while its
* refinery stands, a build order - infantry at its barracks, vehicles at
* its war factory, at half speed without its power plant - while it has
* fewer than aimax of its units out, and attack waves of the units it
* built: the first after a while
* with aiwave0 units, then one more unit each time (up to aiwavemax) at
* least aigap frames apart. When the unit table is full and it cannot
* build, a wave goes with aiwave0 units.

initai   lda   DIFF             ; its numbers at this difficulty (see
         cmp   #NDIFF           ;   difftab)
         bcc   :d
         lda   #NDIFF-1
:d       asl
         sta   tmp
         asl
         asl
         asl
         sec
         sbc   tmp              ; * 14
         tax
         lda   difftab,x
         sta   aicredits
         lda   difftab+2,x
         sta   aiincome
         lda   difftab+4,x      ; the first wave waits a while
         sta   aiwait
         lda   difftab+6,x
         sta   aigap
         lda   difftab+8,x
         sta   aiwave0
         sta   wavesize
         lda   difftab+10,x
         sta   aiwavemax
         lda   difftab+12,x
         sta   aimax
         lda   #NONE
         sta   aibuild
         stz   aiidx
         stz   gameover
         ldx   #0               ; find our command center and the
:loop    cpx   nunits           ;   enemy's buildings
         bcs   :done
         lda   uflags,x
         bit   #F_BUILDING
         beq   :next
         lda   uspr,x
         cmp   #TMPL_HQP
         bne   :b
         stx   hqunit
:b       cmp   #TMPL_BARE
         bne   :f
         stx   barunit
:f       cmp   #TMPL_FACTE
         bne   :r
         stx   factunit
:r       cmp   #TMPL_REFE
         bne   :p
         stx   refunit
:p       cmp   #TMPL_PPE
         bne   :next
         stx   ppunit
:next    inx
         inx
         bra   :loop
:done    rts

ai       lda   frame            ; AIINCOME credits every 8 frames, while
         and   #7               ;   its refinery stands
         bne   :prod
         ldx   refunit
         lda   #TMPL_REFE
         jsr   standing
         bcc   :prod
         lda   aicredits
         cmp   #60000
         bcs   :prod
         clc
         adc   aiincome
         sta   aicredits
:prod    lda   aiwait           ; (count down to the next wave)
         beq   :bar
         dec   aiwait
:bar     lda   aibuild
         bpl   :busy
         ldy   aiidx            ; next in the build order: if the
         ldx   aiorder,y        ;   building it needs stands (else on to
         lda   templates+28,x   ;   the next) and it can afford it
         jsr   findbld
         bpl   :can
         jmp   :nextidx
:can     lda   aicredits
         cmp   templates+14,x
         bcc   :wave
         jsr   aicount          ; and it has fewer than aimax out
         cmp   aimax
         bcs   :wave
         ldy   aiidx
         ldx   aiorder,y
         lda   aicredits
         sec
         sbc   templates+14,x
         sta   aicredits
         stx   aibuild
         lda   templates+16,x   ; build time = BARSEGS segments
         asl
         asl
         asl
         sta   aitimer
         bra   :wave
:busy    ldx   ppunit           ; without its power plant: half speed
         lda   #TMPL_PPE
         jsr   standing
         bcs   :fast
         lda   frame
         lsr
         bcs   :wave
:fast    dec   aitimer
         bne   :wave
         lda   aibuild          ; done: it comes out of its building
         sta   spawnt           ;   (gone meanwhile: lost)
         tax
         lda   templates+28,x
         jsr   findbld
         bmi   :built
         sta   spawnat
         lda   #F_DIRTY+F_AI
         sta   spawnfl
         jsr   spawnunit
         bcs   :built
         lda   #30              ; no room: try again in a bit
         sta   aitimer
         lda   #1
         sta   aistuck
         bra   :wave
:built   stz   aistuck
         lda   #NONE
         sta   aibuild
:nextidx lda   aiidx
         inc
         inc
         cmp   #NAIORDER*2
         bcc   :idx
         lda   #0
:idx     sta   aiidx

:wave    lda   frame            ; every 64 frames: time for a wave, and
         and   #63              ; enough units for it?
         bne   :rts
         lda   aiwait
         bne   :rts
         stz   tmp
         ldx   #0
:count   cpx   nunits
         bcs   :counted
         lda   uflags,x
         and   #F_DEAD+F_AI+F_AMOVE
         cmp   #F_AI
         bne   :c2
         inc   tmp
:c2      inx
         inx
         bra   :count
:counted jsr   aicount          ; at its limit of units, or no room for
         cmp   aimax            ;   more: it goes with what it has,
         bcs   :few             ;   AIWAVE0 at least (else it could wait
         lda   wavesize         ;   for ever with some of them away)
         ldx   aistuck
         beq   :need
:few     lda   aiwave0
:need    sta   aineed
         lda   tmp
         cmp   aineed
         bcc   :rts
         lda   aineed           ; go: that many of them (the rest stay)
         sta   aisend
         ldx   #0
:send    cpx   nunits
         bcs   :sent
         lda   uflags,x
         and   #F_DEAD+F_AI+F_AMOVE
         cmp   #F_AI
         bne   :s2
         lda   uflags,x
         ora   #F_AMOVE
         sta   uflags,x
         dec   aisend
         beq   :sent
:s2      inx
         inx
         bra   :send
:sent    lda   aigap            ; the next one later, and bigger
         sta   aiwait
         lda   wavesize
         cmp   aiwavemax
         bcs   :rts
         inc   wavesize
:rts     rts

* aicount: A = how many units the enemy built that are alive (keeps X)
aicount  phx
         stz   aicnt
         ldx   #0
:loop    cpx   nunits
         bcs   :done
         lda   uflags,x
         and   #F_AI+F_DEAD
         cmp   #F_AI
         bne   :next
         inc   aicnt
:next    inx
         inx
         bra   :loop
:done    plx
         lda   aicnt
         rts


* checkend: lost when the command center falls, won when every enemy
* unit and building is gone
checkend lda   frame
         and   #15
         bne   :rts
         ldx   hqunit
         lda   #TMPL_HQP
         jsr   standing
         bcs   :alive
         lda   #2
         bra   :end
:alive   ldx   #0
:loop    cpx   nunits
         bcs   :win
         lda   uflags,x
         and   #F_DEAD+F_PLAYER
         beq   :rts             ; a live enemy
         inx
         inx
         bra   :loop
:win     lda   #1
:end     sta   gameover
         jsr   deselect
         jmp   banner
:rts     rts

* banner: the game ended; render shows the end-of-game panel from now on
banner   lda   #1
         sta   newbanner
         rts

* markbanner: mark the cells under the end-of-game panel
markbanner
         lda   #BANNERY0
         sta   ry
:row     lda   #BANNERX0
         sta   rx
:col     jsr   markrect
         lda   rx
         clc
         adc   #16
         sta   rx
         cmp   #BANNERX1
         bcc   :col
         lda   ry
         clc
         adc   #16
         sta   ry
         cmp   #BANNERY1
         bcc   :row
         rts

* drawbanner: the end-of-game panel into the work buffer. It covers
* exactly two cell rows; each is redrawn only if one of its cells under
* the panel is dirty.
drawbanner
         stz   bnoff
         lda   #WINBANK         ; paused: the pause panel, at +$8000 in
         ldy   paused           ;   the win banner's bank
         beq   :end
         ldy   #$8000
         sty   bnoff
         bra   :src
:end     ldy   gameover
         cpy   #1
         beq   :src
         lda   #LOSEBANK
:src     sta   lsrc+2
         lda   #BANNERY0        ; first band
         jsr   :band
         lda   #BANNERY0+16     ; second band
:band    sta   ry
         lda   #BANNERX0        ; any dirty cell along it?
         sta   rx
:test    jsr   rectcell
         jsr   celltest
         bcs   :draw
         lda   rx
         clc
         adc   #16
         sta   rx
         cmp   #BANNERX1+15
         bcc   :test
         rts
:draw    lda   ry               ; copy the band from the banner layer
         sta   rx               ; (rx is free again)
         lda   ry
         asl
         tax
         lda   ytab,x
         clc
         adc   #$2000+{BANNERX0/2}
         sta   dst
         clc
         adc   bnoff
         sta   lsrc
         lda   #BANNERW
         sta   width
         lda   #16
         sta   height
         jmp   blitlong

* razebuilding: X = building; put back the ground under its footprint
* and leave some explosions (keeps X)
razebuilding
         lda   ucargo,x         ; its footprint: top left, size
         sta   tmp2
         lda   ustate,x
         sta   bsize
         stz   ty
:row     stz   tx
:col     lda   ty
         asl
         asl
         asl
         asl
         asl
         clc
         adc   tx
         clc
         adc   tmp2
         pha
         tay                    ; no building piece on it any more
         sep   #$20
         mx    %10
         lda   #0
         sta   overlay,y
         rep   #$20
         mx    %00
         pla
         pha
         jsr   marktile         ; the ground as it was
         pla
         jsr   unblock          ; ...and passable if it was
         inc   tx
         lda   tx
         cmp   bsize
         bne   :col
         inc   ty
         lda   ty
         cmp   bsize
         bne   :row
         lda   quiet            ; (sold: no explosions)
         beq   :boom
         rts
:boom    lda   #16
         sta   fxtimer
         lda   ux,x             ; four more explosions around it
         sec
         sbc   #8
         sta   rx
         lda   uy,x
         sec
         sbc   #8
         sta   ry
         lda   #SPR_BOOM0
         jsr   spawnfx
         lda   rx
         clc
         adc   #16
         sta   rx
         lda   #SPR_BOOM0
         jsr   spawnfx
         lda   ry
         clc
         adc   #16
         sta   ry
         lda   #SPR_BOOM0
         jsr   spawnfx
         lda   rx
         sec
         sbc   #16
         sta   rx
         lda   #SPR_BOOM0
         jmp   spawnfx

*-------------------------------------------------------------------
* initunits: load the unit table from the map's unit records: sprite,
* tile, flags, speed, hp, range, damage, rate, power, footprint top left,
* size, class. Buildings: their sprite is their template; ucargo /
* ustate hold the footprint top left / size.


initunits
         ldx   #0               ; record offset
         ldy   #0               ; unit * 2
:loop    lda   unitdata+2,x     ; the list ends with tile NONE
         cmp   #NONE
         bne   :one
         jmp   :done
:one     lda   unitdata,x
         sta   uspr,y
         lda   unitdata+2,x
         sta   utile,y
         jsr   tilepos          ; world pixels of the tile
         lda   #OFFVIEW         ; (not drawn yet)
         sta   uox,y
         lda   utile,y          ; it stands there
         asl
         phx
         tax
         tya
         inc
         inc
         sta   occ,x
         plx
         lda   unitdata+4,x
         ora   #F_DIRTY         ; draw everything on the first frame
         sta   uflags,y
         and   #F_HARV          ; harvesters go to work
         beq   :nh
         lda   #H_SEEK
         sta   ustate,y
:nh
         lda   unitdata+6,x
         sta   uspd,y
         lda   unitdata+8,x
         sta   uhp,y
         sta   umaxhp,y
         lda   unitdata+10,x
         sta   urange,y
         lda   unitdata+12,x
         sta   udmg,y
         lda   unitdata+14,x
         sta   urate,y
         lda   unitdata+16,x
         sta   upower,y
         lda   unitdata+22,x
         sta   uclass,y
         lda   uflags,y         ; buildings: footprint top left, size;
         bit   #F_BUILDING      ;   a 2x2 one stands on its top-left
         beq   :nb              ;   tile, its middle at the corner
         lda   unitdata+18,x
         sta   ucargo,y
         lda   unitdata+20,x
         sta   ustate,y
         cmp   #2
         bne   :nb
         lda   ux,y
         clc
         adc   #8
         sta   ux,y
         lda   uy,y
         clc
         adc   #8
         sta   uy,y
:nb      lda   #NONE
         sta   unext,y
         sta   ugoal,y
         sta   utarget,y
         txa
         clc
         adc   #24
         tax
         iny
         iny
         jmp   :loop
:done    sty   nunits
         stz   frame
         lda   #NONE            ; force the first cursor draw
         sta   ocshape
         rts

* initblds: the starting buildings' footprints and the turrets' and
* guard towers' tiles are walls; the buildings sell for half their price
initblds ldx   #0
:loop    cpx   nunits
         bcs   :rts
         lda   uflags,x
         bit   #F_BUILDING
         beq   :st
         lda   ucargo,x
         sta   tmp2
         lda   ustate,x
         sta   bsize
         jsr   blockfoot
         ldy   uspr,x
         lda   templates+14,y
         lsr
         sta   ucost,x
         bra   :next
:st      bit   #F_STATIC
         beq   :next
         lda   utile,x
         jsr   blocktile
:next    inx
         inx
         bra   :loop
:rts     rts

* makeytab: ytab[y] = y * 160
makeytab ldx   #0
         lda   #0
:loop    sta   ytab,x
         clc
         adc   #LINE
         inx
         inx
         cpx   #400
         bne   :loop
         rts

*-------------------------------------------------------------------
* clearshr: zero pixels, SCBs (palette 0, 320 mode) and palettes

clearshr lda   #0
         ldx   #$7FFE
:loop    stal  SHR,x
         dex
         dex
         bpl   :loop
         rts

*-------------------------------------------------------------------
* setpalette: copy our 16 colors into palette 0

setpalette
         ldx   #30
:loop    lda   palette,x
         stal  SHRPAL,x
         dex
         dex
         bpl   :loop
         rts

*-------------------------------------------------------------------
* Loading, at start, in emulation mode, while ProDOS is still in charge.
* Each file is looked for next to this program (the current folder),
* else at the top of the startup disk.

         mx    %11

* loadtitle: the title picture, CONQUER.TITLE (a Super Hi-Res screen
* image: pixels, line palette numbers, palettes), straight onto the
* screen, which is then switched on. Without it, no title.
loadtitle
         lda   #<titlename
         sta   lfname
         lda   #>titlename
         sta   lfname+1
         lda   #^SHR
         sta   lfbank
         lda   #<$2000
         sta   lfaddr
         lda   #>$2000
         sta   lfaddr+1
         lda   #<32768
         sta   lfsize
         lda   #>32768
         sta   lfsize+1
         jsr   loadfile
         bcs   :rts
         lda   #1               ; (on the screen, but not shown yet:
         sta   TITLEWAIT        ;   restart shows it, then waits for a
:rts     rts                    ;   click on it)

* loadmsg: CONQUER GS and LOADING on the text screen (the loader adds a
* dot for every 4K it reads)
loadmsg  jsr   HOME
         ldx   #0
:p       lda   lmsg,x
         beq   :rts
         jsr   COUT
         inx
         bne   :p
:rts     rts
lmsg     dfb   $8D,$8D,$8D,$8D,$8D,$8D,$8D,$8D,$8D
         asc   "               CONQUER GS",8D,8D
         asc   "                LOADING",8D,8D
         asc   "     ",00

* loaddata: the packed screens and sprites, CONQUER.DATA, into DATABANK
* at DATAADDR. Without it the game cannot run: it says so on the text
* screen and stops.
loaddata lda   #<dataname
         sta   lfname
         lda   #>dataname
         sta   lfname+1
         lda   #DATABANK
         sta   lfbank
         lda   #<DATAADDR
         sta   lfaddr
         lda   #>DATAADDR
         sta   lfaddr+1
         lda   #<DATASIZE
         sta   lfsize
         lda   #>DATASIZE
         sta   lfsize+1
         jsr   loadfile
         bcs   :fail
         rts
:fail    lda   NEWVIDEO         ; (back to the text screen)
         and   #$7F
         sta   NEWVIDEO
         jsr   HOME
         ldx   #0
:msg     lda   failmsg,x
         beq   :stop
         jsr   COUT
         inx
         bra   :msg
:stop    bra   :stop

* loadsound: the sound effects, CONQUER.SOUND (an image of the DOC's
* sound RAM from address 0), straight into the sound RAM. Without it the
* game is silent.
loadsound
         lda   #<soundname
         sta   lfname
         lda   #>soundname
         sta   lfname+1
         lda   #DOCDEST
         sta   lfbank
         stz   lfaddr
         stz   lfaddr+1
         lda   #<SOUNDSIZE
         sta   lfsize
         lda   #>SOUNDSIZE
         sta   lfsize+1
         jsr   loadfile
         bcs   :rts
         lda   #1
         sta   soundok
:rts     rts

* loadfile: read the file named at lfname into bank lfbank from lfaddr
* (or into the DOC's sound RAM: lfbank = DOCDEST), 4K at a time through
* bank 0 (CHUNK). Carry clear if it is exactly
* lfsize bytes long and was read whole.
loadfile lda   lfname           ; (the name, for bootpath)
         sta   src
         sta   openpath
         lda   lfname+1
         sta   src+1
         sta   openpath+1
         jsr   MLI              ; open it in the current folder
         dfb   $C8              ; (OPEN)
         dw    openp
         beq   :open
         jsr   bootpath         ; else at the top of the startup disk
         jsr   MLI
         dfb   $C8
         dw    openp
         beq   :open
         sec
         rts
:open    lda   openref
         sta   readref
         sta   closeref
         stz   loaded
         stz   loaded+1
         stz   lfbad
:read    jsr   MLI
         dfb   $CA              ; (READ) up to 4K into CHUNK
         dw    readp
         beq   :got
         cmp   #$4C             ; end of the file
         beq   :end
         inc   lfbad
:end     jmp   :eof
:got     lda   #"."             ; (a dot on the loading screen)
         jsr   COUT
         clc                    ; (native mode: 16-bit sums, long
         xce                    ;   stores)
         rep   #$30
         mx    %00
         lda   loaded           ; past the size? not our file
         clc
         adc   readgot
         bcs   :big
         cmp   lfsize
         beq   :fits
         bcs   :big
:fits    lda   lfbank           ; (into sound RAM: below)
         and   #$00FF
         cmp   #DOCDEST
         beq   :doc
         lda   lfaddr           ; copy it over
         clc
         adc   loaded
         sta   dst
         lda   lfbank
         and   #$00FF
         sta   dst+2
         sep   #$20
         mx    %10
         ldy   #0
:cp      cpy   readgot
         bcs   :cpd
         lda   CHUNK,y
         sta   [dst],y
         iny
         bra   :cp
         mx    %00
:doc     sep   #$20             ; sound RAM, through the sound GLU:
         mx    %10              ; RAM, auto-increment, the volume as it
:dbusy   lda   SOUNDCTL         ; is, from lfaddr + loaded
         bmi   :dbusy
         and   #$0F
         ora   #$60
         sta   SOUNDCTL
         rep   #$20
         mx    %00
         lda   lfaddr
         clc
         adc   loaded
         sep   #$20
         mx    %10
         sta   SOUNDADRL
         xba
         sta   SOUNDADRH
         ldy   #0
:dcp     cpy   readgot
         bcs   :cpd
:dwait   lda   SOUNDCTL
         bmi   :dwait
         lda   CHUNK,y
         sta   SOUNDDATA
         iny
         bra   :dcp
:cpd     rep   #$20
         mx    %00
         lda   loaded
         clc
         adc   readgot
         sta   loaded
         sep   #$30
         mx    %11
         sec
         xce
         jmp   :read
:big     sep   #$30
         mx    %11
         sec
         xce
         inc   lfbad
:eof     jsr   MLI
         dfb   $CC              ; (CLOSE)
         dw    closep
         lda   lfbad
         bne   :bad
         lda   loaded           ; all of it?
         cmp   lfsize
         bne   :bad
         lda   loaded+1
         cmp   lfsize+1
         bne   :bad
         clc
         rts
:bad     sec
         rts

* bootpath: point the OPEN at "/<startup disk>/<the name at src>"
bootpath lda   DEVNUM
         sta   onunit
         jsr   MLI
         dfb   $C5              ; (ON_LINE) the disk's name
         dw    onlinep
         bne   :rts             ; (then the OPEN fails)
         lda   volbuf           ; name length: low 4 bits
         and   #$0F
         beq   :rts
         sta   vlen
         ldx   #0               ; X = where in fullpath
         lda   #'/'
         jsr   :put
         ldy   #0
:name    lda   volbuf+1,y
         jsr   :put
         iny
         cpy   vlen
         bne   :name
         lda   #'/'
         jsr   :put
         lda   (src)            ; the file's name: length, letters
         sta   vlen
         ldy   #1
:file    lda   (src),y
         jsr   :put
         cpy   vlen
         beq   :done
         iny
         bra   :file
:done    stx   fullpath         ; (its length)
         lda   #<fullpath
         sta   openpath
         lda   #>fullpath
         sta   openpath+1
:rts     rts
:put     sta   fullpath+1,x
         inx
         rts

openp    dfb   3                ; OPEN: path, buffer, -> file number
openpath dw    dataname
         dw    IOBUF
openref  dfb   0
readp    dfb   4                ; READ: file, into, up to, -> got
readref  dfb   0
         dw    CHUNK
         dw    $1000
readgot  dw    0
closep   dfb   1                ; CLOSE: file
closeref dfb   0
onlinep  dfb   2                ; ON_LINE: drive, -> its name
onunit   dfb   0
         dw    volbuf
volbuf   ds    16
dataname dfb   12
         asc   'CONQUER.DATA'
titlename dfb  13
         asc   'CONQUER.TITLE'
soundname dfb  13
         asc   'CONQUER.SOUND'
soundok  dw    0                ; nonzero: the sounds are in the DOC
fullpath ds    32
vlen     dfb   0
lfname   dw    0                ; loadfile: the file's name,
lfbank   dfb   0                ;   where it goes,
lfaddr   dw    0
lfsize   dw    0                ;   how long it must be
lfbad    dfb   0                ;   (nonzero: something went wrong)
loaded   dw    0                ; bytes read so far
failmsg  asc   "CONQUER.DATA IS MISSING OR DAMAGED.",8D
         asc   "IT MUST BE NEXT TO CONQUER.SYSTEM.",00
         mx    %00

* title: (native) the title picture is on the screen, not shown yet:
* draw CLICK TO START on it (from CONQUER.DATA: see-through where 0),
* show it, start the title tune, and wait for a click, a key, or a test
* script clearing TITLEWAIT
title    lda   #DATAADDR+DATA_PROMPT
         sta   lsrc
         lda   #DATABANK
         sta   lsrc+2
         lda   #$2000+PROMPTOFF
         sta   dst
         lda   #^SHR
         sta   dst+2
         lda   #PROMPTH
         sta   ty
:row     sep   #$20
         mx    %10
         ldy   #0
:byte    lda   [lsrc],y
         beq   :skip            ; (both pixels see-through)
         sta   tmp              ; its pixels, and a mask that keeps the
         stz   tmp+1            ; picture's where they are 0
         bit   #$F0
         bne   :lo
         lda   #$F0
         sta   tmp+1
:lo      lda   tmp
         bit   #$0F
         bne   :mask
         lda   #$0F
         tsb   tmp+1
:mask    lda   [dst],y
         and   tmp+1
         ora   tmp
         sta   [dst],y
:skip    iny
         cpy   #PROMPTW
         bne   :byte
         rep   #$20
         mx    %00
         lda   lsrc
         clc
         adc   #PROMPTW
         sta   lsrc
         lda   dst
         clc
         adc   #LINE
         sta   dst
         dec   ty
         bne   :row
         sep   #$20             ; now the title shows (it was loaded
         mx    %10              ;   while the text screen said LOADING)
         lda   CLOCKCTL
         and   #$F0             ; black border
         sta   CLOCKCTL
         lda   NEWVIDEO
         ora   #$80             ; Super Hi-Res on
         sta   NEWVIDEO
         rep   #$20
         mx    %00
         lda   MUSICOFF         ; the title tune (on into the options)
         bne   :wait
         lda   #TUNE_TITLE
         jsr   musstart
         lda   #1
         sta   musicon
:wait    jsr   waitvbl
         lda   musicon
         beq   :tw
         jsr   musplay
:tw      lda   TITLEWAIT
         beq   :go
         jsr   readmouse
         lda   click
         bne   :go
         sep   #$20
         mx    %10
         lda   KBD
         bmi   :key
         rep   #$20
         mx    %00
         bra   :wait
:key     sta   KBDSTRB
         rep   #$20
         mx    %00
:go      stz   TITLEWAIT
         rts

*-------------------------------------------------------------------
* options: before each game, the difficulty, the map and the music on
* or off (the buttons of the chosen ones pressed), then START - a click
* on it, RETURN, or a test script clearing OPTWAIT. The title tune plays
* on (or starts), unless the music is off.
* The screen comes packed from CONQUER.DATA; a clean copy stays in the
* work buffer (bank 1: free until the game starts), from which buttons
* are drawn pressed or not. The previews are the maps' radar pictures,
* twice the size. The arrow is drawn straight onto the screen, what it
* covers kept in curbuf.

options  jsr   optmusic
         jsr   clearshr
         jsr   setpalette
         lda   #DATAADDR+DATA_OPTS
         ldx   #WORKBANK
         ldy   #$2000
         jsr   unrle
         lda   #31999           ; onto the screen
         ldx   #$2000
         ldy   #$2000
         mvn   WORKBANK,^SHR
         phk
         plb                    ; (mvn changed the data bank)
         jsr   previews
         jsr   optbtns
         sep   #$20
         mx    %10
         lda   CLOCKCTL
         and   #$F0             ; black border
         sta   CLOCKCTL
         lda   NEWVIDEO
         ora   #$80             ; Super Hi-Res on (no title: not yet)
         sta   NEWVIDEO
         rep   #$20
         mx    %00
         lda   #CURX0           ; the arrow
         sta   cx
         sta   lcx
         lda   #CURY0
         sta   cy
         sta   lcy
         lda   #1               ; (the button counts as down: a click that
         sta   btn              ;   left the title or the last game is
         jsr   curshow          ;   still held, and must not pick a map)
         lda   #1
         sta   OPTWAIT
:loop    jsr   waitvbl
         lda   musicon
         beq   :quiet
         jsr   musplay
:quiet   jsr   readmouse
         lda   OPTWAIT
         bne   :keys
         jmp   :go
:keys    sep   #$20
         mx    %10
         lda   KBD
         bpl   :nokey
         sta   KBDSTRB
         cmp   #$8D             ; RETURN
         bne   :nokey
         jmp   :go8
:nokey   rep   #$20
         mx    %00
         lda   click
         beq   :move
         jsr   opthit
         bmi   :move
         cmp   #32              ; START
         beq   :go
         pha
         jsr   curhide
         pla
         cmp   #48
         bcs   :music
         cmp   #16
         bcs   :map
         sta   DIFF
         bra   :redraw
:music   sec                    ; 48 on, 49 off
         sbc   #48
         sta   MUSICOFF
         jsr   optmusic
         bra   :redraw
:map     jsr   pickmap
:redraw  jsr   optbtns
         jsr   curshow
:move    lda   cx               ; the arrow follows the mouse
         cmp   lcx
         bne   :moved
         lda   cy
         cmp   lcy
         beq   :loop
:moved   lda   cx
         sta   lcx
         lda   cy
         sta   lcy
         jsr   curhide
         jsr   curshow
         bra   :loop
:go8     rep   #$20
         mx    %00
:go      stz   OPTWAIT
         lda   DIFF             ; (a test script may have chosen)
         cmp   #NDIFF
         bcc   :dok
         lda   #NDIFF-1
         sta   DIFF
:dok     lda   MAPNO
         cmp   #NMAPS
         bcc   :mok
         stz   MAPNO
:mok     lda   MUSICOFF
         and   #1
         sta   MUSICOFF
         stz   musicon          ; (the title tune stops)
         jmp   musstop

* pickmap: A = 16: the previous map, 17: the next one (the arrows; a
* click on the map or its name is the next one too) - and draw it
pickmap  cmp   #17
         beq   :next
         lda   MAPNO
         bne   :prev
         lda   #NMAPS
:prev    dec
         bra   :set
:next    lda   MAPNO
         inc
         cmp   #NMAPS
         bcc   :set
         lda   #0
:set     sta   MAPNO
         jmp   previews

* optmusic: the title tune playing if the music is on, else silence
optmusic lda   MUSICOFF
         bne   :off
         lda   musicon
         bne   :rts
         lda   #TUNE_TITLE
         jsr   musstart
         lda   #1
         sta   musicon
:rts     rts
:off     lda   musicon
         beq   :rts
         stz   musicon
         jmp   musstop

* opthit: A = action of the options screen area under the mouse (0-2 a
* difficulty, 16 + map, 32 START, 48 music on, 49 off; N clear), or NONE
* (N set)
opthit   ldx   #0
:next    lda   opttab,x
         cmp   #NONE
         beq   :none
         lda   cx
         cmp   opttab,x
         bcc   :skip
         cmp   opttab+4,x
         beq   :xin
         bcs   :skip
:xin     lda   cy
         cmp   opttab+2,x
         bcc   :skip
         cmp   opttab+6,x
         beq   :yin
         bcs   :skip
:yin     lda   opttab+8,x
         rts
:skip    txa
         clc
         adc   #16
         tax
         bra   :next
:none    lda   #NONE
         rts

* optbtns: draw the options screen's buttons from the clean copy, the
* chosen difficulty's and music's lit (colors through optbtn)
optbtns  ldx   #0
:next    lda   opttab,x
         cmp   #NONE
         beq   :rts
         lda   opttab+12,x      ; bytes across (0: not a button)
         beq   :skip
         sta   width
         lda   opttab+14,x
         sta   ty
         stz   tmp3
         lda   opttab+8,x
         cmp   DIFF
         beq   :on
         sec
         sbc   #48
         cmp   MUSICOFF
         bne   :draw
:on      inc   tmp3
:draw    phx
         lda   opttab+10,x
         clc
         adc   #$2000
         tax
         jsr   optrect
         plx
:skip    txa
         clc
         adc   #16
         tax
         bra   :next
:rts     rts

* optrect: width x ty bytes at offset X, from the work buffer to the
* screen - through optbtn (lit green) if tmp3 is nonzero
optrect
:row     lda   width
         sta   tx
         phx
:byte    sep   #$20
         mx    %10
         ldal  WORKBANK*$10000,x
         ldy   tmp3
         beq   :put
         pha
         and   #$0F
         tay
         lda   optbtn,y
         sta   tmp
         pla
         lsr
         lsr
         lsr
         lsr
         tay
         lda   optbtn,y
         asl
         asl
         asl
         asl
         ora   tmp
:put     stal  SHR&$FF0000,x
         rep   #$20
         mx    %00
         inx
         dec   tx
         bne   :byte
         pla
         clc
         adc   #LINE
         tax
         dec   ty
         bne   :row
         rts

* previews: the chosen map's preview picture (the radar's without the
* enemy's base), twice the size, with a gold dot on ours (optmark), and
* its name below (a picture after the name tags in the sprite bank)
previews lda   MAPNO
         jsr   unmap
         lda   #PREVOFF
         jsr   preview
         lda   MAPNO
         asl
         asl
         tax
         jsr   optdot
         lda   #MAPNAMES        ; its name: MAPNAMESZ bytes each
         ldx   MAPNO
:nm      dex
         bmi   :name
         clc
         adc   #MAPNAMESZ
         bra   :nm
:name    sta   lsrc
         lda   #SPRBANK
         sta   lsrc+2
         lda   #$2000+NAMEOFF
         sta   dst
         lda   #^SHR
         sta   dst+2
         lda   #MAPNAMEW
         sta   width
         lda   #MAPNAMEH
         sta   height
         jmp   pastelong

* preview: mapblk's preview picture, twice the size, at screen offset A
preview  clc
         adc   #$2000
         sta   dst
         lda   #^SHR
         sta   dst+2
         ldx   #0               ; byte in the picture
         lda   #RADH
         sta   ty
:row     ldy   #0               ; byte on the screen line
:byte    lda   mapblk+MB_PREVIEW,x  ; pixels pq -> bytes pp qq
         and   #$000F
         sta   tmp
         asl
         asl
         asl
         asl
         ora   tmp
         xba
         sta   tmp2
         lda   mapblk+MB_PREVIEW,x
         and   #$00F0
         sta   tmp
         lsr
         lsr
         lsr
         lsr
         ora   tmp
         ora   tmp2
         sta   [dst],y
         inx
         iny
         iny
         cpy   #PREVW
         bne   :byte
         ldy   #PREVW-2         ; the line again below
:dup     lda   [dst],y
         sta   tmp
         tya
         clc
         adc   #LINE
         tay
         lda   tmp
         sta   [dst],y
         tya
         sec
         sbc   #LINE+2
         tay
         bpl   :dup
         lda   dst
         clc
         adc   #LINE*2
         sta   dst
         dec   ty
         bne   :row
         rts

* optdot: X = optmark entry (screen offset, color byte): a 4x4 dot
* (keeps X)
optdot   phx
         lda   optmark+2,x
         and   #$00FF
         sta   tmp
         xba
         ora   tmp
         sta   tmp
         lda   optmark,x
         clc
         adc   #$2000
         tax
         ldy   #4
:row     lda   tmp
         stal  SHR&$FF0000,x
         txa
         clc
         adc   #LINE
         tax
         dey
         bne   :row
         plx
         rts

* curshow / curhide: the arrow onto the screen at the mouse (what it
* covers saved in curbuf) / what it covered back
curshow  lda   cx
         ldx   #304
         jsr   clamp
         and   #$FFFE
         sta   rx
         lda   cy
         ldx   #184
         jsr   clamp
         sta   ry
         jsr   rectaddr
         sta   curaddr
         tax
         ldy   #0
:save    ldal  SHR&$FF0000,x
         sta   curbuf,y
         ldal  SHR&$FF0000+2,x
         sta   curbuf+2,y
         ldal  SHR&$FF0000+4,x
         sta   curbuf+4,y
         ldal  SHR&$FF0000+6,x
         sta   curbuf+6,y
         txa
         clc
         adc   #LINE
         tax
         tya
         clc
         adc   #8
         tay
         cpy   #128
         bne   :save
         lda   #SPR_ARROW
         ldy   curaddr
         ldx   #$E1E1           ; (the screen's bank, twice)
         jmp   sprat
curhide  ldx   curaddr
         ldy   #0
:put     lda   curbuf,y
         stal  SHR&$FF0000,x
         lda   curbuf+2,y
         stal  SHR&$FF0000+2,x
         lda   curbuf+4,y
         stal  SHR&$FF0000+4,x
         lda   curbuf+6,y
         stal  SHR&$FF0000+6,x
         txa
         clc
         adc   #LINE
         tax
         tya
         clc
         adc   #8
         tay
         cpy   #128
         bne   :put
         rts

*-------------------------------------------------------------------
* loadmap: the chosen map (MAPNO) into mapblk, and its radar picture
* into the sidebar layer (the game's radar starts from there)

loadmap  lda   MAPNO
         jsr   unmap
         lda   #mapblk+MB_RADAR
         sta   src
         lda   #$2000+{RADY*LINE}+{RADX/2}
         sta   dst
         lda   #UIBANK
         sta   dst+2
         lda   #RADW/2
         sta   width
         lda   #RADH
         sta   height
         jmp   blit

* unmap: map A's block unpacked into mapblk
unmap    asl
         tax
         lda   mapdata,x
         ldx   #0
         ldy   #mapblk
         jmp   unrle
mapdata  putbin ../build/gfx/maptab.bin  ; each map's block in CONQUER.DATA


*-------------------------------------------------------------------
* name tags: when the mouse has rested on a unit or building we can see,
* or on a build icon, for a moment (LBLDELAY frames after it was looked
* at), its name (and an icon's price) shows below the arrow; it goes when
* the mouse moves or what it was on is no longer there.

LBLDELAY equ   12

* updlabel: once a frame. While the mouse moves there is no tag; once
* it rests, what is under it is looked at every 8th frame.
updlabel lda   gameover
         ora   dragging
         ora   placing
         bne   :none
         lda   cx
         cmp   lblmx
         bne   :moved
         lda   cy
         cmp   lblmy
         bne   :moved
         lda   frame
         and   #7
         bne   :same0
         jsr   inmap
         bcc   :side
         jsr   hitunit
         bmi   :none
         jsr   unitlabel
         bra   :got
:side    lda   cx
         cmp   #VIEWPX
         bcc   :none
         jsr   hiticon
         bmi   :none
         clc
         adc   #LBL_ICON0
         bra   :got
:moved   lda   cx
         sta   lblmx
         lda   cy
         sta   lblmy
:none    lda   #NONE
:got     cmp   lbltgt
         beq   :same
         sta   lbltgt
         stz   lbltime
         jmp   hidelabel
:same0   lda   lbltgt
:same    cmp   #NONE
         beq   :rts
         lda   lblnum
         cmp   #NONE
         bne   :rts             ; showing already
         inc   lbltime
         lda   lbltime
         cmp   #LBLDELAY
         bcc   :rts
         jmp   showlabel
:rts     rts

* unitlabel: X = unit -> A = its tag (NONE: none)
unitlabel
         lda   uflags,x
         bit   #F_BUILDING
         bne   :bld
         ldy   uspr,x
         lda   sprlabel,y
         and   #$00FF
         cmp   #$FF
         bne   :rts
         lda   #NONE
:rts     rts
:bld     ldy   uspr,x           ; buildings: their template's
         lda   templates+26,y
         rts

* hiticon: A = build icon under the mouse (N clear), or NONE (N set)
hiticon  ldy   #0
         ldx   #0
:loop    lda   icons,y
         cmp   #NONE
         beq   :none
         lda   cx
         cmp   icons,y
         bcc   :next
         cmp   icons+4,y
         beq   :xin
         bcs   :next
:xin     lda   cy
         cmp   icons+2,y
         bcc   :next
         cmp   icons+6,y
         beq   :yin
         bcs   :next
:yin     txa
         rts
:next    tya
         clc
         adc   #ICONSZ
         tay
         inx
         bra   :loop
:none    lda   #NONE
         rts

* showlabel: tag lbltgt, below and right of the arrow (left of it or
* above, where the screen ends)
showlabel
         lda   lbltgt
         sta   lblnum
         asl
         asl
         tax
         lda   labtab+2,x       ; bytes across
         sta   lblw
         asl
         sta   tmp
         lda   cx
         clc
         adc   #4
         sta   tmp2
         clc
         adc   tmp
         cmp   #321
         bcc   :x
         lda   #320
         sec
         sbc   tmp
         sta   tmp2
:x       lda   tmp2
         and   #$FFFE
         sta   lblx
         lda   cy
         clc
         adc   #18
         cmp   #200-LABELH+1
         bcc   :y
         lda   cy
         sec
         sbc   #LABELH+3
:y       sta   lbly
         jmp   marklabel

* hidelabel: no tag (its cells redrawn)
hidelabel
         lda   lblnum
         cmp   #NONE
         beq   :rts
         jsr   marklabel
         lda   #NONE
         sta   lblnum
:rts     rts

* marklabel: mark the cells under the tag
marklabel
         lda   lbly
         ldx   #184
         jsr   clamp
         sta   ry
         lda   lblx
         sta   tmp2
         lda   lblw             ; 16-pixel steps across
         clc
         adc   #7
         lsr
         lsr
         lsr
         sta   tmp3
:step    lda   tmp2
         ldx   #304
         jsr   clamp
         sta   rx
         jsr   markrect
         lda   tmp2
         clc
         adc   #16
         sta   tmp2
         dec   tmp3
         bne   :step
         rts

* labeltouched: carry set if the tag touches a dirty cell
labeltouched
         lda   lbly
         ldx   #184
         jsr   clamp
         sta   ry
         lda   lblx
         sta   tmp2
         lda   lblw
         clc
         adc   #7
         lsr
         lsr
         lsr
         sta   tmp3
:step    lda   tmp2
         ldx   #304
         jsr   clamp
         sta   rx
         jsr   touched
         bcs   :rts
         lda   tmp2
         clc
         adc   #16
         sta   tmp2
         dec   tmp3
         bne   :step
         clc
:rts     rts

* drawlabel: the tag into the work buffer
drawlabel
         lda   lblnum
         asl
         asl
         tax
         lda   labtab,x
         clc
         adc   #LABELADDR
         sta   lsrc
         lda   #SPRBANK
         sta   lsrc+2
         lda   lblx
         sta   rx
         lda   lbly
         sta   ry
         jsr   rectaddr
         sta   dst
         lda   #WORKBANK
         sta   dst+2
         lda   lblw             ; (tags are whole words across)
         sta   width
         lda   #LABELH
         sta   height

* pastelong: copy height rows of width bytes (even), one after the other
* at [lsrc], into [dst] laid out like the screen
pastelong
:row     ldy   #0
:word    lda   [lsrc],y
         sta   [dst],y
         iny
         iny
         cpy   width
         bcc   :word
         lda   lsrc
         clc
         adc   width
         sta   lsrc
         lda   dst
         clc
         adc   #LINE
         sta   dst
         dec   height
         bne   :row
         rts


*-------------------------------------------------------------------
* drawui: top bar across the screen, sidebar on the right

drawui   lda   #UIBANK
         sta   lsrc+2
         lda   #SHR
         sta   lsrc
         sta   dst
         lda   #LINE
         sta   width
         lda   #TOPH
         sta   height
         jsr   blitlong

         lda   #SHR+{TOPH*LINE}+SIDEX
         sta   lsrc
         sta   dst
         lda   #32
         sta   width
         lda   #200-TOPH
         sta   height
         jmp   blitlong

* blitlong: copy width x height bytes from [lsrc] to [dst], both laid
* out like the screen (both advance a scanline per row)
blitlong
:row     ldy   width
         dey
         dey
:col     lda   [lsrc],y
         sta   [dst],y
         dey
         dey
         bpl   :col
         lda   lsrc
         clc
         adc   #LINE
         sta   lsrc
         lda   dst
         clc
         adc   #LINE
         sta   dst
         dec   height
         bne   :row
         rts

* unpack: run-length decode the screen layers and the sprites into
* their banks
unpack   lda   #DATAADDR+DATA_UI
         ldx   #UIBANK
         ldy   #$2000
         jsr   unrle
         lda   #DATAADDR+DATA_WIN
         ldx   #WINBANK
         ldy   #$2000
         jsr   unrle
         lda   #DATAADDR+DATA_LOSE
         ldx   #LOSEBANK
         ldy   #$2000
         jsr   unrle
         lda   #DATAADDR+DATA_PAUSE  ; (the pause panel's rows: in the
         ldx   #WINBANK              ;   win banner's bank at +$8000)
         ldy   #$A000
         jsr   unrle

         lda   #DATAADDR+DATA_LABELS
         ldx   #SPRBANK
         ldy   #LABELADDR
         jsr   unrle
         lda   #DATAADDR+DATA_SPR
         ldx   #SPRBANK
         ldy   #0

* unrle: decode the packed data at A in DATABANK into bank X from
* address Y. Control byte 1-127: that many bytes follow as they are;
* 129-255: repeat the next byte (control - 127) times; 0: end.
unrle    sta   lsrc
         lda   #DATABANK
         sta   lsrc+2
         stx   dst+2
         sty   dst
         ldy   #0               ; read offset
         ldx   #0               ; write offset
         sep   #$20
         mx    %10
:ctl     lda   [lsrc],y
         beq   :done
         iny
         cmp   #$80
         bcs   :run
         sta   tmp              ; literal bytes
:lit     lda   [lsrc],y
         iny
         phy
         txy
         sta   [dst],y
         iny
         tyx
         ply
         dec   tmp
         bne   :lit
         bra   :ctl
:run     sbc   #127             ; (carry set) repeat count
         sta   tmp
         lda   [lsrc],y
         iny
         phy
         txy
:fill    sta   [dst],y
         iny
         dec   tmp
         bne   :fill
         tyx
         ply
         bra   :ctl
:done    rep   #$20
         mx    %00
         rts

*-------------------------------------------------------------------
* blit: copy width x height bytes from (src) to [dst]
* src advances by width per line, dst by one scanline

blit
:row     ldy   width
         dey
         dey
:col     lda   (src),y
         sta   [dst],y
         dey
         dey
         bpl   :col
         lda   src
         clc
         adc   width
         sta   src
         lda   dst
         clc
         adc   #LINE
         sta   dst
         dec   height
         bne   :row
         rts

*-------------------------------------------------------------------
* slam: copy slamrows lines of the view from slamfrom (the work buffer's
* map area) to the screen, fast. Runs from SLAMADDR in bank 6 (copied
* there at start): with RAMRD and
* RAMWRT on, bank 0 accesses at $0200-$BFFF go to bank 1, and with SHR
* shadowing on, writes there also go to the screen. Direct page and the
* stack point into a work buffer row, and PEI pushes each word of it
* back onto itself - and so onto the screen. Code here must not use
* absolute jumps (it runs elsewhere) or the stack.

SLAMADDR equ   CODEBANK*$10000+$F000
SLAMLINES equ  32               ; lines a slam copies (192 in 6 goes)

slamcode tsc                    ; (D = 0 here)
         sta   savesp
         ldy   slamfrom         ; (read before bank 0 reads switch)
         ldx   slamrows
         sep   #$20
         mx    %10
         lda   SHADOW           ; SHR shadowing on
         and   #$F7
         sta   SHADOW
         sta   RAMRDON
         sta   RAMWRTON
         rep   #$20
         mx    %00
         tya                    ; the first row's address
:rowjmp
:row     tcd                    ; direct page = the row,
         clc
         adc   #VIEWPX/2-1      ; the stack = its last byte
         tcs
         pei   $7E
         pei   $7C
         pei   $7A
         pei   $78
         pei   $76
         pei   $74
         pei   $72
         pei   $70
         pei   $6E
         pei   $6C
         pei   $6A
         pei   $68
         pei   $66
         pei   $64
         pei   $62
         pei   $60
         pei   $5E
         pei   $5C
         pei   $5A
         pei   $58
         pei   $56
         pei   $54
         pei   $52
         pei   $50
         pei   $4E
         pei   $4C
         pei   $4A
         pei   $48
         pei   $46
         pei   $44
         pei   $42
         pei   $40
         pei   $3E
         pei   $3C
         pei   $3A
         pei   $38
         pei   $36
         pei   $34
         pei   $32
         pei   $30
         pei   $2E
         pei   $2C
         pei   $2A
         pei   $28
         pei   $26
         pei   $24
         pei   $22
         pei   $20
         pei   $1E
         pei   $1C
         pei   $1A
         pei   $18
         pei   $16
         pei   $14
         pei   $12
         pei   $10
         pei   $0E
         pei   $0C
         pei   $0A
         pei   $08
         pei   $06
         pei   $04
         pei   $02
         pei   $00
         tdc                    ; next row
         clc
         adc   #LINE
         dex
         beq   :done
         jmp   :rowjmp-slamcode+SLAMADDR
:done    sep   #$20
         mx    %10
         sta   RAMRDOFF
         sta   RAMWRTOFF
         lda   SHADOW
         ora   #$08
         sta   SHADOW
         rep   #$20
         mx    %00
         lda   #0
         tcd
         lda   savesp
         tcs
         rtl
slamend

*-------------------------------------------------------------------
* data generated by tools/makegfx.py

palette  putbin ../build/gfx/palette.bin
tileflags putbin ../build/gfx/tileflags.bin
         ds    2
ringtab  putbin ../build/gfx/ringtab.bin
sighttab putbin ../build/gfx/sight.bin   ; sight circles' half widths
btnmap   putbin ../build/gfx/btnmap.bin  ; a pressed button's colors
aiorder  putbin ../build/gfx/aiorder.bin ; the enemy's build order (templates)
musdata  putbin ../build/gfx/music.bin   ; the tunes' steps, per voice
musfreq  putbin ../build/gfx/musfreq.bin ; their notes' frequencies
mustracks putbin ../build/gfx/mustracks.bin ; each tune's numbers (MT_)
sndtab   putbin ../build/gfx/sndtab.bin  ; per sound: page, size/res, frequency,
                                ;   volume (8 bytes each)
dmgtab   putbin ../build/gfx/dmgtab.bin  ; damage factor (eighths) per weapon * 4
                                ;   + armor class
templates putbin ../build/gfx/templates.bin
icons    putbin ../build/gfx/icons.bin
glyphs   putbin ../build/gfx/glyphs.bin
ready    putbin ../build/gfx/ready.bin
difftab  putbin ../build/gfx/difftab.bin ; the enemy's numbers per difficulty
opttab   putbin ../build/gfx/opttab.bin  ; options screen: click areas, buttons,
optbtn   putbin ../build/gfx/optbtn.bin  ;   a lit button's colors
optmark  putbin ../build/gfx/optmark.bin ;   a dot on our base in the previews
labtab   putbin ../build/gfx/labtab.bin  ; name tags: offset, bytes across
sprlabel putbin ../build/gfx/sprlabel.bin ;  the tag of each unit sprite
         ds    2

* the map being played, unpacked from CONQUER.DATA by loadmap (its parts:
* MAP_BLOCK in tools/makegfx.py)
mapblk   ds    MB_SIZE
         ds    2                ; padding: map is read 16 bits at a time
dock     equ   mapblk+MB_DOCK   ; harvesters unload here
exittile equ   mapblk+MB_EXIT   ; our new units appear around here

camx0    equ   mapblk+MB_CAMX   ; the first view's top-left tile
camy0    equ   mapblk+MB_CAMY
map      equ   mapblk+MB_MAP    ; per tile: its graphic
passmap  equ   mapblk+MB_PASS   ;   blocked
oredata  equ   mapblk+MB_ORE    ;   scoops of ore
overdata equ   mapblk+MB_OVER   ; the starting buildings' pieces
unitdata equ   mapblk+MB_UNITS  ; the starting units (see initunits)
