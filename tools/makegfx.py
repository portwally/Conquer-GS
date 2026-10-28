#!/usr/bin/env python3
"""Generate the graphics for Conquer GS.

Terrain is drawn procedurally, units are hand-pixeled grids, and the
buildings and the turret are little 3D models (see "3D models"). Everything is written as raw Apple IIgs Super Hi-Res data
(320 mode, 2 pixels per byte, left pixel in the high nibble) that the
assembler pulls in with PUTBIN.

Outputs (in the given directory):
  palette.bin  16 colors, $0RGB words
  sprites.rle  16x16 sprites (color 0 = transparent), then the map tiles,
               128 bytes each
  map.bin      32x24 tile indices, one byte each; tileflags.bin: per tile
               graphic, 1 = ore
  passmap.bin, oremap.bin  per tile: blocked; scoops of ore
  overlays.bin building pieces on the map: word tile, word sprite
  units.bin, templates.bin, icons.bin  see unit_records, templates, main
  ui.rle       screen layer with the top bar and sidebar
  win.rle, lose.rle  screen layers with the end-of-game banners
               (.rle: see rle())
  gfxequ.s     equates shared with src/main.s
  preview.png  what the first screen should look like (for comparison)

Light comes from the top left: highlights on upper/left edges, dark
edges and shadows to the lower right.
"""

import math
import os
import random
import struct
import sys
import zlib

# ---------------------------------------------------------------- palette

# 4-bit RGB components. One palette serves the whole screen, so every
# entry does double duty (dirt shade = gold shade, sand = skin, ...).
PALETTE = [
    (0, 0, 0),      # 0  transparent in sprites
    (2, 2, 2),      # 1  ink: outlines, shadows
    (2, 4, 1),      # 2  grass dark
    (4, 7, 2),      # 3  grass
    (6, 10, 3),     # 4  grass light
    (5, 3, 1),      # 5  dirt dark, enemy shade
    (8, 6, 2),      # 6  dirt, gold shade
    (12, 10, 6),    # 7  sand, skin, highlights
    (1, 3, 8),      # 8  water deep
    (3, 7, 12),     # 9  water light, glass
    (4, 4, 5),      # 10 steel dark
    (8, 8, 9),      # 11 steel
    (13, 13, 13),   # 12 light
    (14, 11, 2),    # 13 gold (player)
    (13, 2, 2),     # 14 red (enemy)
    (4, 14, 7),     # 15 ore
]
(CLEAR, INK, GRASS_D, GRASS, GRASS_L, DIRT_D, DIRT, SAND, WATER_D, WATER_L,
 STEEL_D, STEEL, LIGHT, GOLD, RED, ORE) = range(16)

# characters used in hand-pixeled grids; T/t/H are the team colors
CHARS = {'.': CLEAR, 'k': INK, 'g': GRASS_D, 'G': GRASS, 'h': GRASS_L,
         'd': DIRT_D, 'D': DIRT, 's': SAND, 'w': WATER_D, 'W': WATER_L,
         'x': STEEL_D, 'X': STEEL, 'L': LIGHT, 'Y': GOLD, 'R': RED, 'O': ORE}
TEAMS = {
    'player': {'T': GOLD, 't': DIRT, 'H': SAND, 'u': DIRT_D},
    'enemy':  {'T': RED, 't': DIRT_D, 'H': SAND, 'u': INK},
}

SCREEN_W, SCREEN_H = 320, 200
TOP_H = 8                       # top bar height
VIEW_COLS, VIEW_ROWS = 16, 12   # visible tiles (256 x 192 pixels)
MAP_COLS, MAP_ROWS = 32, 24     # the world
SIDE_X = VIEW_COLS * 16         # sidebar starts at pixel 256
SIDE_W = SCREEN_W - SIDE_X      # 64 pixels

# ---------------------------------------------------------------- drawing


def blank(w, h, c=CLEAR):
    return [[c] * w for _ in range(h)]


def copy(img):
    return [row[:] for row in img]


def rect(img, x0, y0, x1, y1, c):
    """Filled rectangle, inclusive corners, clipped."""
    for y in range(max(y0, 0), min(y1 + 1, len(img))):
        for x in range(max(x0, 0), min(x1 + 1, len(img[0]))):
            img[y][x] = c


def frame(img, x0, y0, x1, y1, c):
    rect(img, x0, y0, x1, y0, c)
    rect(img, x0, y1, x1, y1, c)
    rect(img, x0, y0, x0, y1, c)
    rect(img, x1, y0, x1, y1, c)


def bevel(img, x0, y0, x1, y1, hi, lo):
    """Raised edge: highlight top/left, shade bottom/right."""
    rect(img, x0, y0, x1, y0, hi)
    rect(img, x0, y0, x0, y1, hi)
    rect(img, x0, y1, x1, y1, lo)
    rect(img, x1, y0, x1, y1, lo)


def disc(img, cx, cy, r, c):
    for y in range(len(img)):
        for x in range(len(img[0])):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                img[y][x] = c


def paste(dst, src, x0, y0):
    """Copy non-transparent pixels."""
    for y, row in enumerate(src):
        for x, p in enumerate(row):
            if p and 0 <= y0 + y < len(dst) and 0 <= x0 + x < len(dst[0]):
                dst[y0 + y][x0 + x] = p


def grid(rows, team='player'):
    """Hand-pixeled art from strings of CHARS (plus team colors)."""
    colors = dict(CHARS)
    colors.update(TEAMS[team])
    w = len(rows[0])
    assert all(len(r) == w for r in rows), rows
    return [[colors[ch] for ch in row] for row in rows]


def mirror(img):
    return [row[::-1] for row in img]


def drop_shadow(img, dx=1, dy=2):
    """Dithered ink shadow to the lower right of all opaque pixels."""
    h, w = len(img), len(img[0])
    out = copy(img)
    for y in range(h):
        for x in range(w):
            if img[y][x]:
                sx, sy = x + dx, y + dy
                if (sx < w and sy < h and not img[sy][sx]
                        and (sx + sy) % 2 == 0):
                    out[sy][sx] = INK
    return out


def shaded_blob(img, inside, hi, mid, lo, edge, shadow=None, rng=None):
    """Fill a shape lit from the top left.

    inside(x, y) -> bool defines the shape. The lower/right boundary gets
    the edge color, the body a three-step ramp along the light direction.
    shadow, if given, is painted solid 2 pixels down-right underneath.
    """
    h, w = len(img), len(img[0])
    pts = {(x, y) for y in range(h) for x in range(w) if inside(x, y)}
    if not pts:
        return
    if shadow is not None:
        for x, y in pts:
            for sx, sy in ((x + 1, y + 1), (x + 2, y + 2), (x + 1, y + 2)):
                if 0 <= sx < w and 0 <= sy < h and (sx, sy) not in pts:
                    img[sy][sx] = shadow
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    size = math.sqrt(len(pts))
    for x, y in pts:
        light = (x - cx) + (y - cy)
        if (x + 1, y) not in pts or (x, y + 1) not in pts:
            c = edge
        elif light < -size * 0.35:
            c = hi
        elif light < size * 0.25:
            c = mid
        else:
            c = lo
        if rng and c == mid and rng.random() < 0.12:
            c = hi if rng.random() < 0.5 else lo
        img[y][x] = c


# ------------------------------------------------------------------ tiles


def grass(v):
    """Grass base, three variants: plain, lusher, with flowers."""
    rng = random.Random(100 + v)
    t = blank(16, 16, GRASS)
    for _ in range((14, 22, 16)[v]):            # tufts: light blade, dark root
        x, y = rng.randrange(16), rng.randrange(15)
        t[y][x] = GRASS_L
        t[y + 1][x] = GRASS_D
    for _ in range(10):
        t[rng.randrange(16)][rng.randrange(16)] = GRASS_D
    if v == 2:
        for _ in range(3):
            x, y = rng.randrange(1, 15), rng.randrange(1, 15)
            t[y][x] = (LIGHT, GOLD)[rng.randrange(2)]
    return t


def wobble(side, p):
    """Small edge irregularity, zero at both ends so neighbors line up."""
    ph = {'N': 0, 'S': math.pi, 'W': math.pi, 'E': 0}[side]
    return round(math.sin(2 * math.pi * p / 16 + ph))


def edge_field(open_sides, inset=3, r=3):
    """Signed distance-ish field: < 0 outside the terrain patch.

    open_sides: the sides whose neighbor is a different terrain. Those
    edges are pulled in by `inset` pixels and the corners between two
    open sides are rounded with radius r.
    """
    e = blank(16, 16, 99.0)
    for y in range(16):
        for x in range(16):
            d = {}
            if 'N' in open_sides:
                d['N'] = y - (inset + wobble('N', x))
            if 'S' in open_sides:
                d['S'] = (15 - y) - (inset + wobble('S', x))
            if 'W' in open_sides:
                d['W'] = x - (inset + wobble('W', y))
            if 'E' in open_sides:
                d['E'] = (15 - x) - (inset + wobble('E', y))
            v = min(d.values()) if d else 99.0
            for a, b in (('N', 'W'), ('N', 'E'), ('S', 'W'), ('S', 'E')):
                if a in d and b in d and d[a] < r and d[b] < r:
                    v = min(v, r - math.hypot(r - d[a], r - d[b]))
            e[y][x] = v
    return e


def dirt_tile(open_sides):
    rng = random.Random(7)
    tex = blank(16, 16, DIRT)
    for _ in range(22):
        tex[rng.randrange(16)][rng.randrange(16)] = DIRT_D
    for _ in range(7):                          # pebbles with a shadow
        x, y = rng.randrange(15), rng.randrange(15)
        tex[y][x] = SAND
        tex[y + 1][x + 1] = DIRT_D
    t = grass(0)
    e = edge_field(open_sides)
    for y in range(16):
        for x in range(16):
            v = e[y][x]
            if v < -1:
                continue
            elif v < 0:
                t[y][x] = GRASS_D                # grass lip
            elif v < 1:
                t[y][x] = DIRT_D                 # rim
            else:
                t[y][x] = tex[y][x]
    return t


def water_tile(open_sides):
    rng = random.Random(3)
    tex = blank(16, 16, WATER_D)
    for y in range(1, 16, 4):                   # ripples
        x = rng.randrange(12)
        rect(tex, x, y, x + rng.randrange(2, 5), y, WATER_L)
    t = grass(0)
    e = edge_field(open_sides, inset=2)
    for y in range(16):
        for x in range(16):
            v = e[y][x]
            if v < 0:
                continue
            elif v < 2:
                t[y][x] = SAND                   # beach
            elif v < 3:
                t[y][x] = WATER_L                # surf
            else:
                t[y][x] = tex[y][x]
    return t


def ore_tile(v, crystals=True):
    """Clusters of crystal shards on bare dirt patches."""
    rng = random.Random(40 + v)
    t = grass(v % 2)
    spots = [(4, 6), (11, 5), (5, 13), (12, 12)]
    for cx, cy in rng.sample(spots, 2 + (v > 0)):
        cx += rng.randrange(-1, 2)
        cy += rng.randrange(-1, 2)
        for y in range(16):                     # dirt patch
            for x in range(16):
                d = ((x - cx) / 4.2) ** 2 + ((y - cy - 0.5) / 2.6) ** 2
                if d <= 1:
                    t[y][x] = DIRT_D if d > 0.6 and y > cy else DIRT
        for dx in (-2, 0, 2) if crystals else ():
            x, h = cx + dx - 1, rng.randrange(5, 7) - 2 * (dx != 0)
            top = cy + 1 - h
            for y in range(max(top, 0), cy + 1):
                t[y][x] = ORE                   # lit face
                if 0 <= x + 1 < 16 and y > top:
                    t[y][x + 1] = GRASS_L       # shaded face
            if top >= 0:
                t[top][x] = LIGHT               # glint
            if cy + 1 < 16:
                for sx in (x + 1, x + 2):
                    if sx < 16:
                        t[cy + 1][sx] = DIRT_D  # shadow
    return t


def tree_tile():
    rng = random.Random(11)
    t = grass(1)
    blobs = [(6, 5.5, 5), (10.5, 7, 4.3), (7, 10.5, 4.3), (10, 11, 3)]

    def inside(x, y):
        return any((x - cx) ** 2 + (y - cy) ** 2 <= r * r for cx, cy, r in blobs)
    shaded_blob(t, inside, GRASS_L, GRASS, GRASS_D, INK, shadow=GRASS_D, rng=rng)
    return t


def rock_tile():
    t = grass(0)
    for cx, cy, r in ((6, 7, 4.2), (11, 10.5, 2.8)):
        shaded_blob(t, lambda x, y: (x - cx) ** 2 + (y - cy) ** 2 <= r * r,
                    LIGHT, STEEL, STEEL_D, INK, shadow=GRASS_D)
    return t


def concrete_tile(open_sides):
    rng = random.Random(5)
    t = blank(16, 16, STEEL)
    for _ in range(12):
        t[rng.randrange(16)][rng.randrange(16)] = STEEL_D
    for _ in range(4):
        t[rng.randrange(16)][rng.randrange(16)] = LIGHT
    rect(t, 0, 0, 15, 0, STEEL_D)               # seams between slabs
    rect(t, 0, 0, 0, 15, STEEL_D)
    if 'N' in open_sides:
        rect(t, 0, 0, 15, 0, LIGHT)
    if 'W' in open_sides:
        rect(t, 0, 0, 0, 15, LIGHT)
    if 'S' in open_sides:
        rect(t, 0, 14, 15, 14, STEEL_D)
        rect(t, 0, 15, 15, 15, INK)
    if 'E' in open_sides:
        rect(t, 14, 0, 14, 15, STEEL_D)
        rect(t, 15, 0, 15, 15, INK)
    return t


# The worlds: 32 x 24 tiles each, painted from a few shapes. The border
# is impassable (pathfinding relies on that).
#   g grass  d dirt road  w water  o ore  t tree  r rocks  c concrete


def new_world():
    """Grass inside a border of forest and rock; and painting helpers."""
    w, h = MAP_COLS, MAP_ROWS
    m = [['g'] * w for _ in range(h)]
    for x in range(w):
        m[0][x] = 'r' if x % 5 == 2 else 't'
        m[h - 1][x] = 'r' if x % 4 == 1 else 't'
    for y in range(h):
        m[y][0] = 'r' if y % 6 == 3 else 't'
        m[y][w - 1] = 'r' if y % 5 == 1 else 't'

    def paint(ch, x0, y0, x1, y1):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                m[y][x] = ch

    def dots(ch, pts):
        for x, y in pts:
            m[y][x] = ch
    return m, paint, dots


def green_valley():
    """Map 1: our base in the south-west, theirs in the north-east; a
    river from the north ends in a lake in the middle."""
    m, paint, dots = new_world()
    for x, y in ((15, 1), (15, 2), (16, 3), (16, 4), (15, 5), (14, 6), (14, 7),
                 (13, 8), (13, 9)):
        paint('w', x, y, x + 1, y)
    paint('w', 11, 10, 15, 11)
    paint('w', 12, 12, 14, 12)
    dots('g', ((11, 10), (15, 11)))
    paint('w', 4, 6, 7, 7)                      # pond in the west
    dots('w', ((5, 5), (6, 5), (5, 8)))
    paint('w', 26, 14, 28, 15)                  # pond in the east
    dots('w', ((27, 13), (29, 15)))
    # roads: from the player's base east, then north to the enemy
    paint('d', 5, 19, 20, 19)
    paint('d', 20, 8, 20, 19)
    paint('d', 20, 8, 25, 8)
    paint('d', 25, 6, 25, 8)
    paint('d', 8, 12, 8, 18)                    # a side road north
    # ore: near each base, in the middle, and far in the south-east
    paint('o', 7, 15, 10, 17)
    dots('g', ((10, 15), (7, 17)))
    paint('o', 18, 13, 22, 15)
    dots('g', ((18, 13), (22, 15), (20, 13)))
    paint('o', 20, 2, 23, 4)
    dots('g', ((23, 2), (20, 4)))
    paint('o', 26, 18, 29, 20)
    dots('g', ((26, 20), (29, 18)))
    # forests and rocks
    dots('t', ((2, 9), (3, 9), (2, 10), (3, 11), (4, 10), (10, 20), (11, 21),
               (12, 20), (11, 22), (24, 12), (25, 13), (24, 13), (23, 12),
               (6, 3), (7, 2), (9, 4), (28, 10), (29, 9), (17, 17), (16, 18),
               (3, 15), (14, 3), (19, 21), (23, 18), (6, 13)))
    dots('r', ((11, 14), (12, 15), (4, 13), (29, 12), (18, 21), (22, 10),
               (10, 3), (3, 4), (27, 21)))
    # base pads
    paint('c', 2, 18, 4, 20)                    # the player's command center
    paint('c', 26, 3, 28, 5)                    # the enemy barracks
    return [''.join(row) for row in m]


def river_crossing():
    """Map 2: a river runs from north to south through the middle, with a
    ford in the north and one in the south; our base in the south-east,
    theirs in the north-west."""
    m, paint, dots = new_world()
    river = {1: (17, 18), 2: (17, 18), 3: (16, 18), 4: (16, 17), 5: (16, 17),
             6: (15, 17), 7: (15, 16), 8: (15, 16), 9: (15, 16), 10: (14, 16),
             11: (13, 17), 12: (13, 17), 13: (14, 16), 14: (14, 15), 15: (14, 15),
             16: (14, 15), 17: (13, 15), 18: (13, 14), 19: (13, 14), 20: (12, 14),
             21: (12, 13), 22: (12, 13)}
    for y, (x0, x1) in river.items():
        paint('w', x0, y, x1, y)
    dots('g', ((13, 11), (17, 12)))
    paint('w', 25, 8, 27, 9)                    # a pond in the east
    dots('w', ((26, 10),))
    paint('w', 4, 15, 6, 16)                    # and one in the west
    # roads: from our base west over the south ford, north to theirs;
    # and a road over the north ford
    paint('d', 17, 18, 25, 18)
    paint('d', 17, 15, 17, 18)
    paint('d', 9, 15, 17, 15)
    paint('d', 14, 16, 15, 16)                  # (the ford is two wide)
    paint('d', 9, 6, 9, 15)
    paint('d', 6, 6, 9, 6)
    paint('d', 9, 7, 22, 7)
    paint('d', 15, 8, 16, 8)
    paint('d', 22, 7, 22, 14)
    paint('d', 22, 14, 25, 14)
    paint('d', 25, 14, 25, 17)
    # ore: by each base, by each ford, and far in two corners
    paint('o', 19, 19, 22, 21)
    dots('g', ((22, 19), (19, 21)))
    paint('o', 2, 8, 5, 10)
    dots('g', ((5, 8), (2, 10)))
    paint('o', 19, 9, 21, 11)
    dots('g', ((21, 9),))
    paint('o', 10, 9, 12, 10)
    dots('g', ((12, 9),))
    paint('o', 26, 2, 29, 4)
    dots('g', ((29, 2), (26, 4)))
    paint('o', 2, 19, 5, 21)
    dots('g', ((2, 19), (5, 21)))
    # forests and rocks
    dots('t', ((23, 2), (24, 3), (23, 4), (24, 5), (25, 3), (6, 18), (7, 19),
               (6, 20), (8, 21), (28, 10), (29, 11), (28, 12), (2, 13), (3, 14),
               (2, 14), (11, 2), (12, 3), (19, 4), (20, 13), (11, 18), (24, 21),
               (29, 15), (7, 12)))
    dots('r', ((12, 13), (19, 16), (4, 12), (27, 13), (10, 20), (21, 3),
               (7, 9), (29, 20), (13, 5)))
    # base pads
    paint('c', 26, 17, 28, 19)                  # the player's command center
    paint('c', 3, 3, 5, 5)                      # the enemy barracks
    return [''.join(row) for row in m]


def twin_lakes():
    """Map 3: two lakes in the middle with a land bridge between them;
    our base in the north-west, theirs in the south-east."""
    m, paint, dots = new_world()
    for y, (x0, x1) in {9: (11, 13), 10: (10, 14), 11: (9, 14), 12: (10, 14),
                        13: (11, 13)}.items():      # the western lake
        paint('w', x0, y, x1, y)
    for y, (x0, x1) in {10: (18, 20), 11: (17, 21), 12: (17, 22), 13: (17, 21),
                        14: (18, 20)}.items():      # the eastern lake
        paint('w', x0, y, x1, y)
    paint('w', 25, 4, 26, 5)                    # ponds
    dots('w', ((27, 5),))
    paint('w', 5, 17, 6, 18)
    dots('w', ((4, 18),))
    # roads: from our base east, south over the bridge, east to theirs
    paint('d', 5, 5, 15, 5)
    paint('d', 15, 5, 15, 17)
    paint('d', 16, 9, 16, 14)                   # (the bridge is two wide)
    paint('d', 15, 17, 25, 17)
    paint('d', 25, 17, 25, 18)
    # ore: by each base, on either side of the bridge, in two corners
    paint('o', 7, 7, 10, 9)
    dots('g', ((10, 7), (7, 9)))
    paint('o', 18, 19, 21, 21)
    dots('g', ((18, 21), (21, 19)))
    paint('o', 17, 6, 19, 8)
    dots('g', ((19, 6),))
    paint('o', 12, 15, 14, 16)
    dots('g', ((12, 16),))
    paint('o', 27, 2, 29, 3)
    paint('o', 2, 20, 4, 21)
    # forests and rocks
    dots('t', ((2, 13), (3, 14), (2, 15), (8, 12), (7, 13), (12, 2), (13, 3), (21, 3),
               (22, 2), (23, 3), (28, 9), (29, 10), (28, 11), (9, 19), (10, 20), (9, 21),
               (24, 8), (6, 21), (29, 22), (30, 13), (20, 16), (3, 9)))
    dots('r', ((5, 13), (11, 18), (22, 7), (26, 11), (13, 21), (8, 2), (30, 7),
               (19, 4), (24, 12)))
    # base pads
    paint('c', 2, 3, 4, 5)                      # the player's command center
    paint('c', 26, 18, 28, 20)                  # the enemy barracks
    return [''.join(row) for row in m]


def stone_pass():
    """Map 4: a ridge of rock and forest runs from north to south through
    the middle, open at a pass in the north and one in the south; our base
    in the west, theirs in the east."""
    m, paint, dots = new_world()
    for y in range(1, 23):
        if y in (5, 6, 7, 16, 17, 18):          # the passes
            continue
        x0, x1 = 15 - (y % 3 == 0), 16 + (y % 4 == 1)
        for x in range(x0, x1 + 1):
            m[y][x] = 'r' if (x + y) % 3 else 't'
    for x, y in ((14, 4), (17, 8), (14, 15), (17, 19)):   # rough pass edges
        m[y][x] = 'r'
    paint('w', 6, 2, 8, 3)                      # ponds
    dots('w', ((7, 4),))
    paint('w', 23, 19, 25, 20)
    dots('w', ((24, 21),))
    # roads: from our base east, north, over the north pass, south to
    # theirs; a branch over the south pass
    paint('d', 5, 11, 12, 11)
    paint('d', 12, 6, 12, 17)
    paint('d', 12, 6, 19, 6)
    paint('d', 19, 6, 19, 11)
    paint('d', 19, 11, 26, 11)
    paint('d', 12, 17, 20, 17)
    paint('d', 20, 12, 20, 16)
    # ore: by each base, at each pass, in two corners
    paint('o', 7, 13, 10, 15)
    dots('g', ((10, 13), (7, 15)))
    paint('o', 26, 15, 29, 17)
    dots('g', ((29, 15), (26, 17)))
    paint('o', 9, 4, 11, 5)
    paint('o', 21, 19, 22, 21)
    paint('o', 2, 19, 4, 21)
    dots('g', ((4, 19),))
    paint('o', 27, 2, 29, 3)
    # forests and rocks
    dots('t', ((2, 3), (3, 2), (2, 4), (4, 17), (5, 18), (3, 16), (9, 20), (10, 21),
               (22, 3), (23, 2), (24, 4), (29, 20), (28, 21), (8, 8), (25, 7), (21, 14)))
    dots('r', ((10, 18), (6, 6), (27, 5), (23, 15), (2, 8), (29, 13), (11, 1), (21, 22)))
    # base pads
    paint('c', 2, 10, 4, 12)                    # the player's command center
    paint('c', 27, 10, 29, 12)                  # the enemy barracks
    return [''.join(row) for row in m]


MAP = green_valley()            # (the map being worked on: see use_map)

SIDES = {'N': (0, -1), 'S': (0, 1), 'W': (-1, 0), 'E': (1, 0)}


def cell_key(x, y):
    """Which tile a map cell needs: terrain, open edges and variant."""
    ch = MAP[y][x]
    h = (x * 7 + y * 13 + x * y) % 10
    if ch in 'dwc':
        open_sides = []
        for s, (dx, dy) in SIDES.items():
            nx, ny = x + dx, y + dy
            if 0 <= nx < MAP_COLS and 0 <= ny < MAP_ROWS and MAP[ny][nx] != ch:
                open_sides.append(s)
        return (ch, ''.join(sorted(open_sides)))
    if ch == 'g':
        return ('g', 0 if h < 5 else 1 if h < 8 else 2)
    if ch == 'o':
        return ('o', h % 3)
    return (ch,)


def make_tile(key):
    ch = key[0]
    if ch == 'g':
        return grass(key[1])
    if ch == 'd':
        return dirt_tile(key[1])
    if ch == 'w':
        return water_tile(key[1])
    if ch == 'c':
        return concrete_tile(key[1])
    if ch == 'o':
        return ore_tile(key[1])
    if ch == 'x':
        return ore_tile(1, crystals=False)
    if ch == 't':
        return tree_tile()
    if ch == 'r':
        return rock_tile()
    raise ValueError(key)


def make_tileset():
    """The tiles all the maps need, and each map as tile indices."""
    keys, tiles, maps = {}, [], []
    for i in range(len(MAPS)):
        use_map(i)
        cells = []
        for y in range(MAP_ROWS):
            for x in range(MAP_COLS):
                k = cell_key(x, y)
                if k not in keys:
                    keys[k] = len(tiles)
                    tiles.append(make_tile(k))
                cells.append(keys[k])
        maps.append(cells)
    use_map(0)
    tiles.append(make_tile(('x',)))         # mined-out ore, swapped in at runtime
    tiles.append(blank(16, 16, CLEAR))      # unexplored: black
    return tiles, maps


# ---------------------------------------------------------------- units
# Units face right (the grids below); left is the same mirrored; up and
# down have grids of their own (further down). Team colors: T main,
# t shade, u darkest, H highlight.

TANK = [  # turret and hull edges: lit to the top left, shaded below
    "................",
    "................",
    ".kkkkkkkkkkkkk..",
    "kXxXxXxXxXxXxXk.",
    "kxkxkxkxkxkxkxk.",
    "kHHHHHHHHHHHHtk.",
    "kHTTHHHHHtTTTtk.",
    "kHTHLTTTTtkkkkkk",
    "kHTHTTTTTtkXXXXL",
    "kTTHTTTTTtkxxxxk",
    "kTTTtttttukkkkk.",
    "kTTTTuuuuuTTTtk.",
    "kttttttttttttuk.",
    "kkkkkkkkkkkkkkk.",
    "kXxXxXxXxXxXxXk.",
    ".kkkkkkkkkkkkk..",
]

HARVESTER = [  # ore hopper, cab with a windshield
    "................",
    "..kkkkkkkkkkk...",
    ".kXxXxXxXxXxXk..",
    ".kxkxkxkxkxkxk..",
    "kHHHHHHHHkkkkk..",
    "kHuuuuuuTkLLLXkk",
    "kHuOhOOOTkLXXXxk",
    "kTuOOOhOTkLWWWxk",
    "kTuOOOOhTkXWWWxk",
    "kTOOOOOOTkXXXxxk",
    "kTTTTTTTTkxxxxxk",
    "kttttttttkkkkkkk",
    "kkkkkkkkkkxWxWxk",
    ".kXxXxXxXxXxXkkk",
    "..kkkkkkkkkkk...",
    "................",
]

SOLDIER = [  # helmet, face, rifle held level
    "................",
    "................",
    "................",
    "......kkk.......",
    ".....kHTTk......",
    ".....kTTtk......",
    "......kssk......",
    ".....kTTTkkkkk..",
    "....kTHTsxXXXXk.",
    "....kTTTtkkkkk..",
    ".....kttk.......",
    ".....kxxk.......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
    "................",
]

BUGGY = [  # four wheels, driver, machine gun over the hood
    "................",
    "................",
    "................",
    "..kkkk....kkkk..",
    ".kxXXxk..kxXXxk.",
    ".kkkkkkkkkkkkkk.",
    "kHHHHkHHkHHHHHtk",
    "kHTTkLTTkkkkkkkk",
    "kHTTkTTtkXXXXXXL",
    "kTTTkttkkkkkkkkk",
    "kuttttttttttttuk",
    ".kkkkkkkkkkkkkk.",
    ".kxXXxk..kxXXxk.",
    "..kkkk....kkkk..",
    "................",
    "................",
]

ROCKET = [  # a soldier with a launcher on the shoulder
    "................",
    "................",
    "................",
    "......kkk.......",
    ".....kHTTk......",
    "..kkkkkkkkkkkk..",
    ".kxXXXXLXXXXXRk.",
    "..kkkkkkkkkkkk..",
    ".....kTTTk......",
    "....kTHTsk......",
    ".....kttk.......",
    ".....kxxk.......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
    "................",
]


# The same units moving up (seen from behind) and down (from the front);
# the light still comes from the top left.

TANK_UP = [
    "......kkkk......",
    "......kLLk......",
    ".kkk..kXxk..kkk.",
    "kXxkHHkXxkHtkxXk",
    "kxkkHTkXxkTtkkxk",
    "kXxkHTkXxkTtkxXk",
    "kxkkHHHHHHttkkxk",
    "kXxkHHLTTTttkxXk",
    "kxkkHHTTTTttkkxk",
    "kXxkHHTTTtttkxXk",
    "kxkkHttttttukkxk",
    "kXxkHTuuuuuukxXk",
    "kxkkHTtTtTTtkkxk",
    "kXxkHTTTTTTtkxXk",
    "kxkktttttttukkxk",
    ".kkkkkkkkkkkkkk.",
]
TANK_DOWN = [
    ".kkkkkkkkkkkkkk.",
    "kXxkHHHHHHHtkxXk",
    "kxkkHTTTTTTtkkxk",
    "kXxkHTTTTTTtkxXk",
    "kxkkHHHHHHttkkxk",
    "kXxkHHLTTTttkxXk",
    "kxkkHHTTTTttkkxk",
    "kXxkHHTTTtttkxXk",
    "kxkkHttkXkttkkxk",
    "kXxkHTukXkuTkxXk",
    "kxkkHTukXkuTkkxk",
    "kXxktttkXktukxXk",
    ".kkk..kXxk..kkk.",
    "......kXxk......",
    "......kLLk......",
    "......kkkk......",
]
HARVESTER_UP = [
    "................",
    "..kkkkkkkkkkkk..",
    ".kXkLLLLLLLXxkk.",
    "kxXkLWWWWWWXxkXk",
    "kXxkLWWWWWWXxkxk",
    "kxXkXXXXXXXxxkXk",
    "kXxkkkkkkkkkkkxk",
    "kxXkHHHHHHHHtkXk",
    "kXxkHuuuuuuTtkxk",
    "kxXkHuOhOOOTtkXk",
    "kXxkHuOOOhOTtkxk",
    "kxXkHuOhOOOTtkXk",
    "kXxkHuOOOOhTtkxk",
    "kxXkHTTTTTTTtkXk",
    "kXxkttttttttukxk",
    ".kkkkkkkkkkkkkk.",
]
HARVESTER_DOWN = [
    ".kkkkkkkkkkkkkk.",
    "kXxkHHHHHHHHtkXk",
    "kxXkHuuuuuuTtkxk",
    "kXxkHuOhOOOTtkXk",
    "kxXkHuOOOhOTtkxk",
    "kXxkHuOhOOOTtkXk",
    "kxXkHTTTTTTTtkxk",
    "kXxkttttttttukXk",
    "kxXkkkkkkkkkkkxk",
    "kXxkLLLLLLLXxkXk",
    "kxXkLXXXXXXXxkxk",
    "kXxkXWWWWWWxxkXk",
    "kxXkxWWWWWWxxkxk",
    ".kkkkxxxxxxkkkk.",
    "....kkkkkkkk....",
    "................",
]
BUGGY_UP = [  # four wheels, the driver, the gun forward
    "................",
    "................",
    "......kkkk......",
    "......kLLk......",
    ".kkk..kXxk..kkk.",
    "kXxXk.kXxk.kXxXk",
    "kxXxkkkXxkkkxXxk",
    "kkkkHHHkkHHtkkkk",
    "...kHkkHTkTtk...",
    "...kHkLTTtkTk...",
    "...kHkTtttkTk...",
    "kkkkHHkkkkHtkkkk",
    "kXxXkHTTTTtkxXxk",
    "kxXxkuttttukXxXk",
    ".kkk.kkkkkk.kkk.",
    "................",
]
BUGGY_DOWN = [
    "................",
    ".kkk.kkkkkk.kkk.",
    "kXxXkHHHHHtkxXxk",
    "kxXxkHTTTTtkXxXk",
    "kkkkHHkkkkHtkkkk",
    "...kHkLTTkkTk...",
    "...kHkTsskTtk...",
    "...kHkTttkkTk...",
    "kkkkHHkkkkHtkkkk",
    "kXxXkkkXxkkkxXxk",
    "kxXxk.kXxk.kXxXk",
    ".kkk..kXxk..kkk.",
    "......kXxk......",
    "......kLLk......",
    "......kkkk......",
    "................",
]
SOLDIER_UP = [  # seen from behind, rifle up over the shoulder
    "................",
    "................",
    "..........kk....",
    ".........kXk....",
    "......kkkXk.....",
    ".....kHTTkk.....",
    ".....kTTtk......",
    "....kkDDdkk.....",
    "....kTDDdTk.....",
    "....kTDddTk.....",
    ".....kTTtk......",
    ".....kxxxk......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
    "................",
]
SOLDIER_DOWN = [  # facing us, rifle held across
    "................",
    "................",
    "................",
    "......kkk.......",
    ".....kHTTk......",
    ".....kTTtk......",
    ".....kssLk......",
    "....kkksskkk....",
    "...kTHTTTTTk....",
    "...kskXXXXXkk...",
    "....kTTTTtkxk...",
    ".....kttk..k....",
    ".....kxxk.......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
]
ROCKET_UP = [  # seen from behind, the launcher along the back, pointing up
    "................",
    ".......kkk......",
    "......kRLRk.....",
    "......kXLxk.....",
    "......kXXxk.....",
    ".....kkXXxkk....",
    ".....kHkXkTk....",
    "....kkTkXktkk...",
    "....kTDkXkdTk...",
    "....kTDkkkdTk...",
    ".....kTTTtk.....",
    ".....kxxxk......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
    "................",
]
ROCKET_DOWN = [  # facing us, the launcher on the shoulder, its mouth to us
    "................",
    "................",
    "................",
    "......kkk.kkkk..",
    ".....kHTTkkXLXk.",
    ".....kTTtkkxRxk.",
    ".....kssLkkXxXk.",
    "....kkksskkkkk..",
    "...kTHTTTTk.....",
    "...ksTTTTtsk....",
    "....kTTTTtk.....",
    ".....kttk.......",
    ".....kxxk.......",
    ".....kxkxk......",
    "....kkk.kkk.....",
    "................",
]


SELECT = [  # corner brackets drawn over a selected unit
    "LLLL........LLLL",
    "L..............L",
    "L..............L",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "L..............L",
    "L..............L",
    "LLLL........LLLL",
]

CURSOR_ARROW = [  # hotspot (0, 0)
    "k...............",
    "kk..............",
    "kLk.............",
    "kLLk............",
    "kLLLk...........",
    "kLLLLk..........",
    "kLLLLLk.........",
    "kLLLLLLk........",
    "kLLLLLLLk.......",
    "kLLLLLkkkk......",
    "kLLkLLk.........",
    "kLk.kLLk........",
    "kk..kLLk........",
    "k....kLLk.......",
    ".....kLLk.......",
    "......kk........",
]

CURSOR_MOVE = [  # hotspot (7, 8)
    "................",
    "......kkk.......",
    "......kOk.......",
    "......kOk.......",
    "......kOk.......",
    "......kkk.......",
    "................",
    "kkkkk.....kkkkk.",
    "kOOOk..L..kOOOk.",
    "kkkkk.....kkkkk.",
    "................",
    "......kkk.......",
    "......kOk.......",
    "......kOk.......",
    "......kOk.......",
    "......kkk.......",
]


def unit(rows, team, flip=False):
    img = grid(rows, team)
    if flip:
        img = mirror(img)
    return drop_shadow(img)


# ------------------------------------------------------------- 3D models
# The buildings and the turret are little 3D models (voxels: x east, y
# south, z up) seen from the south at an angle: a voxel's top shows one
# row above its south side, and each step up moves it one row up. Light
# comes from the top left: tops facing it are lit, south sides shaded, and
# parts cast shadows on lower parts and on the ground. Where a part meets
# a lower one it gets an ink line, and the whole an ink outline.


def ramps(team):
    """Material -> (lit, plain, shaded) colors."""
    T, t, H, u = (TEAMS[team][k] for k in 'TtHu')
    return {'team': (H, T, t), 'teamdark': (T, t, u), 'flag': (H, T, T),
            'steel': (LIGHT, STEEL, STEEL_D), 'dark': (STEEL, STEEL_D, INK),
            'glass': (LIGHT, WATER_L, WATER_D), 'sand': (LIGHT, SAND, DIRT),
            'ink': (INK, INK, INK), 'dish': (LIGHT, LIGHT, STEEL)}


class Model:
    """Voxels: (x, y, z) -> (material, part)."""

    def __init__(self):
        self.v = {}
        self.parts = 0

    def part(self):
        self.parts += 1
        return self.parts

    def fill(self, inside, x0, x1, y0, y1, z0, z1, m, part=None):
        p = part or self.part()
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                for z in range(z0, z1 + 1):
                    if inside(x + 0.5, y + 0.5, z + 0.5):
                        self.v[(x, y, z)] = (m, p)
        return self

    def box(self, x0, x1, y0, y1, z0, z1, m, part=None):
        return self.fill(lambda x, y, z: True, x0, x1, y0, y1, z0, z1, m, part)

    def cyl(self, cx, cy, r, z0, z1, m, part=None):
        return self.fill(lambda x, y, z: (x - cx) ** 2 + (y - cy) ** 2 <= r * r,
                         int(cx - r - 1), int(cx + r + 1), int(cy - r - 1), int(cy + r + 1),
                         z0, z1, m, part)

    def dome(self, cx, cy, r, z0, hz, m, part=None):
        """Half an ellipsoid standing on z0: radius r, hz high."""
        return self.fill(lambda x, y, z: ((x - cx) ** 2 + (y - cy) ** 2) / r ** 2
                         + (z - z0) ** 2 / hz ** 2 <= 1,
                         int(cx - r - 1), int(cx + r + 1), int(cy - r - 1), int(cy + r + 1),
                         z0, z0 + int(hz) + 1, m, part)

    def hut(self, x0, x1, cy, r, hz, m, part=None):
        """Half a cylinder lying along x (a Quonset hut)."""
        return self.fill(lambda x, y, z: (y - cy) ** 2 / r ** 2 + z ** 2 / hz ** 2 <= 1,
                         x0, x1, int(cy - r - 1), int(cy + r + 1), 0, int(hz) + 1, m, part)

    def tower(self, cx, cy, r, z1):
        """A cooling tower: waisted, open at the top."""
        p = self.part()
        for z in range(z1 + 1):
            self.cyl(cx, cy, r * (1 - 0.22 * math.sin(math.pi * min(1, 1.15 * z / z1))),
                     z, z, 'steel', p)
        q = self.part()
        ri = r * 0.78 - 1.2
        for x in range(int(cx - r), int(cx + r + 1)):
            for y in range(int(cy - r), int(cy + r + 1)):
                if (x + 0.5 - cx) ** 2 + (y + 0.5 - cy) ** 2 <= ri * ri:
                    self.v.pop((x, y, z1), None)
                    self.v[(x, y, z1 - 1)] = ('ink', q)
        return self

    def clear(self, x0, x1, y0, y1, z0, z1):
        for k in [k for k in self.v if x0 <= k[0] <= x1 and y0 <= k[1] <= y1
                  and z0 <= k[2] <= z1]:
            del self.v[k]
        return self

    def paint(self, x0, x1, y0, y1, z0, z1, m, where=lambda x, y, z: True):
        """Recolor what is there (the part stays the same)."""
        for (x, y, z), (old, p) in list(self.v.items()):
            if x0 <= x <= x1 and y0 <= y <= y1 and z0 <= z <= z1 and where(x, y, z):
                self.v[(x, y, z)] = (m, p)
        return self


def model_sprite(model, team, w, h, ox, oy, flip=False):
    """Draw a model into a w x h image, voxel (x, y, 0)'s top at pixel
    (x + ox, y + oy - 1); flip mirrors it in the image (the light stays)."""
    v = model.v
    if flip:
        v = {(w - 1 - 2 * ox - x, y, z): q for (x, y, z), q in v.items()}
    R = ramps(team)
    top = {}                                    # column heights
    for (x, y, z) in v:
        top[(x, y)] = max(top.get((x, y), 0), z + 1)
    img, pmap, dmap = blank(w, h), blank(w, h, 0), blank(w, h, -1.0)

    def put(x, y, c, p, d):
        if 0 <= x < w and 0 <= y < h:
            img[y][x], pmap[y][x], dmap[y][x] = c, p, d

    def light(x, y, z):
        """0 lit, 1 plain, 2 shaded: the top of voxel (x, y, z)."""
        hz = z + 1
        for k in range(1, 12):                  # in a shadow?
            if (x - k, y - k, hz + 2 * k - 2) in v or (x - k, y - k, hz + 2 * k - 1) in v:
                return 2

        def near(dx, dy):
            return max(hz - 2, min(top.get((x + dx, y + dy), 0), hz + 2))
        d = near(1, 0) - near(-1, 0) + near(0, 1) - near(0, -1)
        return 0 if d >= 2 else 2 if d <= -3 else 1

    # back to front, bottom to top
    for (x, y, z), (m, p) in sorted(v.items(), key=lambda kv: (kv[0][1], kv[0][2])):
        lit = R[m][light(x, y, z)]
        if (x, y, z + 1) not in v:
            put(x + ox, y + oy - z - 1, lit, p, z + 1)
        if (x, y + 1, z) not in v:              # a slope's step is lit like
            slope = (x, y, z + 1) not in v and (x, y + 1, z - 1) in v   # a top
            put(x + ox, y + oy - z, lit if slope else R[m][2], p, z + 0.5)
    out = copy(img)
    for y in range(h):
        for x in range(w):
            near = [(x + dx, y + dy) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))
                    if 0 <= x + dx < w and 0 <= y + dy < h and img[y + dy][x + dx]]
            if not img[y][x]:
                if near:                        # outline
                    out[y][x] = INK
            elif any(pmap[b][a] != pmap[y][x] and dmap[b][a] > dmap[y][x] + 0.6
                     for a, b in near):         # below another part
                out[y][x] = INK
    img = copy(out)
    for y in range(h):                          # shadow on the ground
        for x in range(w):
            if not img[y][x] and (x + y) % 2 == 0 and any(
                    top.get((x - ox - k, y - oy - k), 0) >= 2 * k - 1 for k in range(1, 24)):
                out[y][x] = INK
    return out


# ------------------------------------------------------------- buildings


def turret_model(facing='right'):
    """Gun turret on a concrete base, its barrel facing right, up or down
    (left: right mirrored)."""
    m = Model()
    m.box(2, 13, 1, 12, 0, 0, 'steel')
    for x, y in ((2, 1), (13, 1), (2, 12), (13, 12)):
        m.clear(x, x, y, y, 0, 0)
    m.cyl(6.5, 6.5, 3.8, 1, 1, 'dark')                     # turning ring
    m.dome(6.5, 6.5, 3.2, 2, 1.6, 'team')
    if facing == 'up':                                      # barrel
        m.box(6, 6, 1, 3, 2, 2, 'dark')
        m.box(6, 6, 0, 0, 2, 2, 'steel')
    elif facing == 'down':
        m.box(6, 6, 9, 13, 2, 2, 'dark')
        m.box(6, 6, 14, 14, 2, 2, 'steel')
    else:
        m.box(10, 14, 6, 6, 2, 2, 'dark')
        m.box(15, 15, 6, 6, 2, 2, 'steel')
    return m


def turret(team, facing='right'):
    oy = 3 if facing == 'up' else 2                         # (room for the barrel)
    return model_sprite(turret_model('right' if facing == 'left' else facing), team,
                        16, 16, 0, oy, facing == 'left')


def hq(team):
    """Command center on its 3 x 3 pad: a hall with a garage door and
    windows, a radar dome and a command tower with a flag."""
    m = Model()
    m.box(0, 33, 10, 31, 0, 5, 'steel')
    m.paint(0, 33, 31, 31, 3, 3, 'team')                    # stripe
    m.paint(3, 10, 31, 31, 0, 2, 'dark')                    # garage door
    for x in (14, 19, 24, 29):
        m.paint(x, x + 2, 31, 31, 1, 2, 'glass')
    m.box(18, 31, 12, 22, 6, 10, 'steel')                   # command tower
    m.paint(18, 31, 12, 22, 10, 10, 'team')
    m.paint(18, 31, 22, 22, 7, 8, 'glass')
    m.dome(9, 19, 5.5, 6, 4, 'steel')                       # radar
    m.box(30, 30, 14, 14, 11, 17, 'dark')                   # flag
    m.box(27, 29, 14, 14, 16, 17, 'flag')
    return model_sprite(m, team, 48, 48, 7, 12)


def barracks_model():
    """A Quonset hut with a porch flying a flag, and sandbags."""
    m = Model()
    m.hut(2, 29, 14, 9, 8, 'team')
    m.paint(2, 29, 0, 23, 0, 8, 'teamdark', where=lambda x, y, z: x % 3 == 0)
    m.box(12, 19, 21, 25, 0, 4, 'steel')                    # porch
    m.paint(14, 17, 25, 25, 0, 2, 'ink')                    # door
    m.box(2, 8, 27, 28, 0, 1, 'sand')                       # sandbags
    m.box(23, 29, 27, 28, 0, 1, 'sand')
    m.box(19, 19, 21, 21, 5, 10, 'dark')                    # flag on
    m.box(16, 18, 21, 21, 9, 10, 'flag')                    #   the porch
    return m


def barracks(team, size=2):
    """On 2 x 2 tiles, or in the middle of a 3 x 3 pad."""
    pad = (size - 2) * 8
    return model_sprite(barracks_model(), team, size * 16, size * 16, pad, 3 + pad)


def power_plant_model():
    """Generator hall with two cooling towers."""
    m = Model()
    m.box(1, 29, 13, 23, 0, 5, 'steel')
    m.paint(1, 29, 23, 23, 3, 3, 'team')                    # stripe
    for x in (4, 10, 16, 22):
        m.paint(x, x + 2, 23, 23, 0, 1, 'ink')              # vents
    m.tower(8.5, 10, 6.5, 10)
    m.tower(21.5, 10, 6.5, 10)
    return m


def power_plant(team):
    return model_sprite(power_plant_model(), team, 32, 32, 1, 8)


def factory_model():
    """War factory: a long hall with team stripes on the roof, a big door
    in front, a control room and a stack."""
    m = Model()
    m.box(1, 30, 9, 24, 0, 5, 'steel')
    m.paint(1, 30, 12, 13, 5, 5, 'team')                    # roof stripes
    m.paint(1, 30, 19, 20, 5, 5, 'team')
    m.paint(1, 30, 24, 24, 4, 4, 'team')                    # front stripe
    m.paint(8, 21, 24, 24, 0, 3, 'ink')                     # the door
    m.paint(8, 21, 24, 24, 1, 1, 'dark')
    m.box(23, 29, 4, 10, 6, 8, 'steel')                     # control room
    m.paint(23, 29, 10, 10, 7, 7, 'glass')
    m.cyl(5, 6.5, 1.6, 6, 8, 'dark')                        # stack
    return m


def factory(team):
    return model_sprite(factory_model(), team, 32, 32, 0, 6)


def refinery_model():
    """Refinery: a processing hall with an unloading bay in front on the
    left (the harvesters' dock is below it) and two silos."""
    m = Model()
    m.box(1, 17, 11, 24, 0, 4, 'steel')
    m.paint(1, 17, 11, 24, 4, 4, 'team')                    # roof edge
    m.paint(2, 16, 12, 23, 4, 4, 'steel')
    m.paint(1, 17, 24, 24, 3, 3, 'team')
    m.paint(3, 9, 24, 24, 0, 2, 'ink')                      # unloading bay
    m.cyl(24, 9.5, 5.2, 0, 9, 'steel')                      # silos with
    m.paint(18, 30, 3, 16, 3, 4, 'team')                    #   team bands
    m.cyl(25, 20.5, 4.2, 0, 6, 'steel')
    m.paint(20, 30, 15, 26, 2, 3, 'team')
    m.box(17, 19, 15, 15, 3, 3, 'dark')                     # pipes
    m.box(6, 18, 7, 7, 5, 5, 'dark')
    m.box(6, 6, 7, 10, 5, 5, 'dark')
    return m


def refinery(team):
    return model_sprite(refinery_model(), team, 32, 32, 0, 6)


def radar_model():
    """Radar center: a low building with a dish on a mast, tilted to face
    south and up (it curves a little), and equipment on the roof."""
    m = Model()
    m.box(2, 29, 13, 23, 0, 4, 'steel')
    m.paint(2, 29, 23, 23, 3, 3, 'team')
    for x in (16, 20, 24):
        m.paint(x, x + 2, 23, 23, 1, 2, 'glass')
    m.box(9, 11, 11, 13, 5, 9, 'dark')                      # mast
    cx, cy, cz = 10, 12, 12                                 # the dish
    nx, ny, nz = 0.0, 0.55, 0.835
    p = m.part()
    for x in range(2, 19):
        for y in range(3, 21):
            for z in range(6, 21):
                dx, dy, dz = x + 0.5 - cx, y + 0.5 - cy, z + 0.5 - cz
                d = dx * nx + dy * ny + dz * nz
                r2 = dx * dx + dy * dy + dz * dz - d * d
                if r2 <= 5.8 ** 2 and abs(d - 0.06 * r2) < 0.75:
                    m.v[(x, y, z)] = ('steel' if r2 > 4.6 ** 2 else 'dish', p)
    m.box(10, 10, 14, 14, 14, 15, 'team')                   # its feed
    m.box(20, 27, 15, 20, 5, 6, 'steel')                    # equipment
    m.paint(20, 27, 15, 20, 6, 6, 'team')
    return m


def radar(team):
    return model_sprite(radar_model(), team, 32, 32, 0, 10)


def tower_model(facing='right'):
    """Guard tower: a small concrete tower with a team platform and a
    machine gun facing right, up or down (left: right mirrored)."""
    m = Model()
    m.box(4, 11, 5, 11, 0, 0, 'steel')                      # footing
    m.box(5, 10, 6, 10, 1, 4, 'steel')
    m.box(4, 11, 5, 11, 5, 5, 'team')                       # platform
    m.box(4, 11, 5, 5, 6, 6, 'team')                        # parapet
    m.box(4, 11, 11, 11, 6, 6, 'team')
    m.box(4, 4, 5, 11, 6, 6, 'team')
    m.box(11, 11, 5, 11, 6, 6, 'team')
    m.box(7, 8, 7, 9, 6, 6, 'dark')                         # the gun
    if facing == 'up':
        m.box(7, 7, 2, 6, 6, 6, 'dark')
    elif facing == 'down':
        m.box(7, 7, 10, 14, 6, 6, 'dark')
    else:
        m.box(9, 14, 8, 8, 6, 6, 'dark')
    return m


def guard_tower(team, facing='right'):
    return model_sprite(tower_model('right' if facing == 'left' else facing), team,
                        16, 16, 0, 4, facing == 'left')


# a model at half size for the sidebar icons: each 2x2x2 block that is at
# least 3/8 full, in its most telling material
TELLING = {'team': 5, 'flag': 5, 'glass': 4, 'ink': 4, 'dish': 4, 'teamdark': 3,
           'dark': 2, 'sand': 2, 'steel': 1}


def half(m):
    blocks = {}
    for (x, y, z), (mat, p) in m.v.items():
        blocks.setdefault((x // 2, y // 2, z // 2), []).append((mat, p))
    h = Model()
    for k, vs in blocks.items():
        if len(vs) >= 3:
            mats = [mat for mat, _ in vs]
            mat = max(set(mats), key=lambda q: (mats.count(q) * TELLING.get(q, 1), q))
            parts = [p for _, p in vs]
            h.v[k] = (mat, max(set(parts), key=lambda q: (parts.count(q), -q)))
    return h


def mini_building(name):
    """A 2x2 structure's 16x16 sidebar icon."""
    model, oy = {'pp': (power_plant_model, 4), 'bar': (barracks_model, 2),
                 'fact': (factory_model, 3), 'ref': (refinery_model, 3),
                 'radar': (radar_model, 5)}[name]
    return model_sprite(half(model()), 'player', 16, 16, 0, oy)



def quarters(img):
    return [[row[x:x + 16] for row in img[y:y + 16]]
            for y in (0, 16) for x in (0, 16)]


def pieces(img, size, dx, dy):
    """Put img at (dx, dy) on a size x size tile footprint and cut it into
    16x16 pieces, row by row."""
    canvas = blank(size * 16, size * 16)
    paste(canvas, img, dx, dy)
    return [[row[x:x + 16] for row in canvas[y:y + 16]]
            for y in range(0, size * 16, 16) for x in range(0, size * 16, 16)]


def make_sprites():
    """All sprites by name. Units come in pairs: facing right, then left."""
    s = {}
    views = {'tank': (TANK, TANK_UP, TANK_DOWN),
             'harv': (HARVESTER, HARVESTER_UP, HARVESTER_DOWN),
             'sold': (SOLDIER, SOLDIER_UP, SOLDIER_DOWN),
             'buggy': (BUGGY, BUGGY_UP, BUGGY_DOWN),
             'rock': (ROCKET, ROCKET_UP, ROCKET_DOWN)}
    for name in UNIT_TYPES:                     # right, left, up, down
        kind, side = name.split('_')
        team = 'player' if side == 'p' else 'enemy'
        if kind in ('turret', 'tower'):
            draw = turret if kind == 'turret' else guard_tower
            for suffix, facing in (('', 'right'), ('_l', 'left'), ('_u', 'up'), ('_d', 'down')):
                s[name + suffix] = draw(team, facing)
            continue
        right, up, down = views[kind]
        s[name] = unit(right, team)
        s[name + '_l'] = unit(right, team, flip=True)
        s[name + '_u'] = unit(up, team)
        s[name + '_d'] = unit(down, team)
    # buildings in tile-sized pieces: the command center and the enemy's
    # barracks on their 3x3 pads, the rest filling 2x2
    draw = {'pp': power_plant, 'bar': barracks, 'fact': factory, 'ref': refinery,
            'radar': radar}
    for name in BUILDING_PIECES:
        kind, side = name.split('_')
        team = 'player' if side == 'p' else 'enemy'
        size = BSIZE.get(name, 2)
        img = hq(team) if kind == 'hq' else draw[kind](team, 3) if size == 3 else draw[kind](team)
        for i, q in enumerate(pieces(img, size, 0, 0)):
            s['%s%d' % (name, i)] = q
    s['select'] = grid(SELECT)
    s['cur_arrow'] = grid(CURSOR_ARROW)
    s['cur_move'] = grid(CURSOR_MOVE)
    s['cur_attack'] = grid([r.replace('O', 'R') for r in CURSOR_MOVE])
    s['hit'], s['boom0'], s['boom1'] = make_effects()
    for name, img in zip(FOG_NAMES, fog_edges()):
        s[name] = img
    s['cur_sell'] = outlined(DOLLAR, GOLD)
    s['cur_repair'] = wrench()            # also blinks over a repair
    s['cur_no'] = no_sign()
    return s


def make_effects():
    """Hit spark and two explosion frames, centered in 16x16."""
    rng = random.Random(9)
    hit = blank(16, 16)
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - 7.5, y - 7.5)
            if d < 1.6:
                hit[y][x] = LIGHT
            elif d < 2.8:
                hit[y][x] = GOLD
            elif d < 4.5 and (x == 7 or x == 8 or y == 7 or y == 8):
                hit[y][x] = GOLD if d < 3.6 else RED
    boom0 = blank(16, 16)
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - 7.5, y - 7.5) + rng.random() * 1.2
            if d < 2.5:
                boom0[y][x] = LIGHT
            elif d < 4.2:
                boom0[y][x] = GOLD
            elif d < 6.2:
                boom0[y][x] = RED
            elif d < 7.0 and (x + y) % 2 == 0:
                boom0[y][x] = INK
    boom1 = blank(16, 16)
    for y in range(16):
        for x in range(16):
            d = math.hypot(x - 7.5, y - 8.5) + rng.random() * 1.6
            if d < 2.0:
                boom1[y][x] = RED
            elif d < 5.5:
                boom1[y][x] = (STEEL_D, STEEL, INK)[rng.randrange(3)]
            elif d < 7.2 and (x + y) % 2 == 0:
                boom1[y][x] = STEEL_D
            if boom1[y][x] and rng.random() < 0.06:
                boom1[y][x] = GOLD                     # embers
    return hit, boom0, boom1


def fog_edges():
    """Soft edges of the unexplored area, drawn in black over a seen tile
    next to unseen ones: one per side (N E S W), then one per corner (NE SE
    SW NW), in the order of the direction bits. Nonzero pixels mark where
    the black goes (the game draws them black)."""
    n = blank(16, 16)
    for x in range(16):
        d = 3 + round(math.sin(x * 0.8) * 0.8 + math.sin(x * 2.1 + 1.3) * 0.6)
        for y in range(16):
            if y < d or (y == d and (x + y) % 2 == 0) or \
                    (y == d + 1 and (x * 3 + y) % 4 == 0):
                n[y][x] = INK
    nw = blank(16, 16)
    for y in range(16):
        for x in range(16):
            r = math.hypot(x + 0.5, y + 0.5)
            if r < 3.2 or (r < 4.6 and (x + y) % 2 == 0):
                nw[y][x] = INK

    def rot(img):                           # a quarter turn clockwise
        return [[img[15 - x][y] for x in range(16)] for y in range(16)]
    e = rot(n)
    s = rot(e)
    w = rot(s)
    ne = rot(nw)
    se = rot(ne)
    sw = rot(se)
    return [n, e, s, w, ne, se, sw, nw]


def outlined(bitmap, color, w=16, h=16):
    """A shape from '#' rows in color, centered on the hotspot (7, 8),
    with an ink outline around it."""
    img = blank(w, h)
    bh, bw = len(bitmap), len(bitmap[0])
    x0, y0 = 7 - bw // 2, 8 - bh // 2
    for y, row in enumerate(bitmap):
        for x, ch in enumerate(row):
            if ch == '#':
                img[y0 + y][x0 + x] = color
            elif ch == 'h':
                img[y0 + y][x0 + x] = LIGHT
    out = copy(img)
    for y in range(h):
        for x in range(w):
            if img[y][x] == CLEAR and any(
                    0 <= x + dx < w and 0 <= y + dy < h and img[y + dy][x + dx]
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                out[y][x] = INK
    return out


DOLLAR = ['...#...',
          '.#####.',
          '##.#.##',
          '##.#...',
          '.####..',
          '...###.',
          '...#.##',
          '##.#.##',
          '.#####.',
          '...#...']
def wrench():
    """A light wrench, jaw at the top right, with an ink outline."""
    img = blank(16, 16)
    jx, jy = 10.5, 4.5                     # middle of the jaw
    for y in range(16):
        for x in range(16):
            px, py = x + 0.5, y + 0.5
            d = math.hypot(px - jx, py - jy)
            notch = (px - jx) - (jy - py) > -1.2 and (px - jx) + (jy - py) > 0.6 and d < 3.0
            jaw = d < 3.6 and not notch
            # handle: from the jaw down to the bottom left, 3 pixels thick
            t = ((px - 3.0) * (jx - 3.0) + (py - 13.0) * (jy - 13.0)) / \
                ((jx - 3.0) ** 2 + (jy - 13.0) ** 2)
            hx, hy = 3.0 + t * (jx - 3.0), 13.0 + t * (jy - 13.0)
            handle = 0 <= t <= 1 and math.hypot(px - hx, py - hy) < 1.5
            if jaw or handle:
                img[y][x] = STEEL if (px - hx) - (py - hy) > 0.6 and handle else LIGHT
    out = copy(img)
    for y in range(16):
        for x in range(16):
            if img[y][x] == CLEAR and any(
                    0 <= x + dx < 16 and 0 <= y + dy < 16 and img[y + dy][x + dx]
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                out[y][x] = INK
    return out


def no_sign():
    """Red circle with a slash: nothing to do here."""
    img = blank(16, 16)
    for y in range(16):
        for x in range(16):
            dx, dy = x - 7, y - 8
            d = math.hypot(dx, dy)
            if 4.2 <= d < 6.0 or (d < 5.0 and abs(dx + dy) <= 1):
                img[y][x] = RED
    out = copy(img)
    for y in range(16):
        for x in range(16):
            if img[y][x] == CLEAR and any(
                    0 <= x + dx < 16 and 0 <= y + dy < 16 and img[y + dy][x + dx]
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                out[y][x] = INK
    return out


FOG_NAMES = ['fog_n', 'fog_e', 'fog_s', 'fog_w', 'fog_ne', 'fog_se', 'fog_sw',
             'fog_nw']
# neighbor directions in the order of the bits (as dirofs in main.s)
FOG_DIRS = [(0, -1), (1, 0), (0, 1), (-1, 0), (1, -1), (1, 1), (-1, 1), (-1, -1)]
BUILDING_SIGHT = 4              # buildings see this many tiles; units one
MIN_SIGHT = 3                   # more than their weapons reach, at least 3
MAX_SIGHT = 7


def sight_radius(flags, rng):
    return BUILDING_SIGHT if flags & F_BUILDING else max(rng + 1, MIN_SIGHT)


def sight_widths(r):
    """Half widths of the circle of radius r, row by row (dy = -r..r)."""
    return [int(math.sqrt(r * r + r - dy * dy)) for dy in range(-r, r + 1)]


def seen_tiles(units):
    """Tiles our units and buildings see at the start."""
    seen = set()
    for spr, tile, flags, speed, hp, rng, *_ in units:
        if not flags & F_PLAYER:
            continue
        r = sight_radius(flags, rng)
        c0, r0 = tile % MAP_COLS, tile // MAP_COLS
        for dy, w in zip(range(-r, r + 1), sight_widths(r)):
            row = r0 + dy
            if 0 <= row < MAP_ROWS:
                for col in range(max(0, c0 - w), min(MAP_COLS - 1, c0 + w) + 1):
                    seen.add(row * MAP_COLS + col)
    return seen


def fog_bits(seen, t):
    """Which neighbors of seen tile t are on the map and unseen."""
    c, r = t % MAP_COLS, t // MAP_COLS
    bits = 0
    for i, (dx, dy) in enumerate(FOG_DIRS):
        if 0 <= c + dx < MAP_COLS and 0 <= r + dy < MAP_ROWS and \
                (r + dy) * MAP_COLS + c + dx not in seen:
            bits |= 1 << i
    return bits


def corner_kill(sides):
    """Corners next to any of these sides (N E S W bits): not drawn."""
    kill = 0
    for bit, (a, b) in ((4, (0, 1)), (5, (2, 1)), (6, (2, 3)), (7, (0, 3))):
        if sides >> a & 1 or sides >> b & 1:
            kill |= 1 << bit
    return kill


def drawn_edges(bits):
    """The edge sprites drawn: all sides, and corners only where neither
    side next to them has an edge."""
    return bits & ~corner_kill(bits & 15)


UNIT_TYPES = ['tank_p', 'tank_e', 'harv_p', 'sold_p', 'sold_e', 'turret_e',
              'turret_p', 'buggy_p', 'buggy_e', 'rock_p', 'rock_e', 'tower_p', 'tower_e',
              'harv_e']
# buildings: size in tiles (the rest are 2x2); those drawn in pieces
BSIZE = {'hq_p': 3, 'bar_e': 3}
BUILDING_PIECES = ['hq_p', 'bar_e', 'pp_p', 'bar_p', 'fact_p', 'ref_p', 'radar_p',
                   'fact_e', 'ref_e', 'pp_e']
SPRITE_ORDER = ([n for u in UNIT_TYPES for n in (u, u + '_l', u + '_u', u + '_d')] +
                ['%s%d' % (b, i) for b in BUILDING_PIECES for i in range(BSIZE.get(b, 2) ** 2)] +
                ['select', 'cur_arrow', 'cur_move', 'cur_attack',
                 'hit', 'boom0', 'boom1'] + FOG_NAMES +
                ['cur_sell', 'cur_repair', 'cur_no'])


# unit flags, shared with src/main.s through gfxequ.s
F_PLAYER, F_SEL, F_LEFT, F_VERT = 1, 2, 4, 8     # (F_VERT: up; with F_LEFT down)
F_DEAD, F_CHASE, F_STATIC, F_HARV = 0x10, 0x20, 0x40, 0x80
F_BUILDING, F_AI, F_AMOVE, F_DIRTY = 0x100, 0x200, 0x400, 0x8000

# The maps: name, terrain, the starting buildings ((name, top-left column,
# row): the command center and the enemy's barracks on 3x3 pads of
# concrete, the rest 2x2 on open ground; they become units after the
# others; we start with the command center only), the units (name, column, row), where harvesters unload (next
# to the command center), where our new units appear when no building
# makes them, the first view's top-left tile, and whether the enemy is in
# the west (then the units start facing each other that way).
MAPS = [
    {'name': 'GREEN VALLEY', 'rows': green_valley(),
     'buildings': [('hq_p', 2, 18), ('bar_e', 26, 3),
                   ('fact_e', 29, 3), ('ref_e', 24, 1), ('pp_e', 29, 7)],
     'units': [('tank_p', 6, 18), ('tank_p', 6, 20), ('harv_p', 8, 16),
               ('sold_p', 5, 21), ('sold_p', 6, 21),
               ('tank_e', 24, 7), ('tank_e', 26, 8),
               ('sold_e', 23, 6), ('sold_e', 24, 6), ('sold_e', 23, 7),
               ('turret_e', 24, 4), ('tower_e', 22, 6), ('tower_e', 27, 9),
               ('harv_e', 22, 5)],
     'dock': (5, 19), 'exit': (5, 20), 'camera': (0, 12),
     'enemy_west': False},
    {'name': 'RIVER CROSSING', 'rows': river_crossing(),
     'buildings': [('hq_p', 26, 17), ('bar_e', 3, 3),
                   ('fact_e', 6, 1), ('ref_e', 1, 6), ('pp_e', 1, 3)],
     'units': [('tank_p', 24, 17), ('tank_p', 24, 19), ('harv_p', 21, 17),
               ('sold_p', 26, 20), ('sold_p', 25, 20),
               ('tank_e', 7, 7), ('tank_e', 6, 8),
               ('sold_e', 8, 5), ('sold_e', 7, 5), ('sold_e', 8, 4),
               ('turret_e', 7, 3), ('tower_e', 10, 4), ('tower_e', 8, 9),
               ('harv_e', 3, 7)],
     'dock': (25, 18), 'exit': (25, 19), 'camera': (16, 12),
     'enemy_west': True},
    {'name': 'TWIN LAKES', 'rows': twin_lakes(),
     'buildings': [('hq_p', 2, 3), ('bar_e', 26, 18),
                   ('fact_e', 29, 18), ('ref_e', 23, 14), ('pp_e', 28, 15)],
     'units': [('tank_p', 6, 4), ('tank_p', 6, 6), ('harv_p', 8, 8),
               ('sold_p', 4, 7), ('sold_p', 5, 7),
               ('tank_e', 23, 20), ('tank_e', 24, 21),
               ('sold_e', 22, 19), ('sold_e', 23, 19), ('sold_e', 22, 21),
               ('turret_e', 25, 19), ('tower_e', 21, 17), ('tower_e', 27, 13),
               ('harv_e', 24, 17)],
     'dock': (5, 4), 'exit': (5, 5), 'camera': (0, 0),
     'enemy_west': False},
    {'name': 'STONE PASS', 'rows': stone_pass(),
     'buildings': [('hq_p', 2, 10), ('bar_e', 27, 10),
                   ('fact_e', 24, 8), ('ref_e', 24, 13), ('pp_e', 29, 6)],
     'units': [('tank_p', 6, 11), ('tank_p', 6, 13), ('harv_p', 8, 14),
               ('sold_p', 4, 14), ('sold_p', 5, 14),
               ('tank_e', 23, 12), ('tank_e', 22, 13),
               ('sold_e', 23, 10), ('sold_e', 21, 12), ('sold_e', 22, 10),
               ('turret_e', 22, 11), ('tower_e', 20, 6), ('tower_e', 21, 18),
               ('harv_e', 25, 16)],
     'dock': (5, 11), 'exit': (5, 12), 'camera': (0, 5),
     'enemy_west': False},
]



def use_map(i):
    """Make map i the one the map functions work on."""
    global MAP, BUILDINGS, UNITS, DOCK, EXIT, CAMERA0, ENEMY_WEST
    m = MAPS[i]
    MAP, BUILDINGS, UNITS = m['rows'], m['buildings'], m['units']
    DOCK, EXIT, CAMERA0 = m['dock'], m['exit'], m['camera']
    ENEMY_WEST = m['enemy_west']


use_map(0)

# hit points, range in tiles, damage per shot, frames between shots,
# speed (moves on frames where frame & speed == 0), cost, build seconds
STATS = {
    'tank': (120, 3, 15, 40, 1, 800, 8),
    'harv': (400, 0, 0, 0, 3, 1000, 10),
    'sold': (40, 2, 6, 30, 3, 100, 3),
    'turret': (150, 4, 20, 50, 0, 0, 0),
    'buggy': (90, 2, 5, 12, 0, 300, 5),
    'rock': (30, 4, 15, 50, 3, 300, 5),
    'tower': (150, 3, 6, 12, 0, 400, 5),
}

# structures: hit points, range, damage, rate, cost, build seconds, size
# in tiles, power (+ makes, - uses; the enemy's: none). The player can
# build those with a cost; the rest stand at the start.
HQ_POWER = 100
STRUCTS = {
    'pp_p': (200, 0, 0, 0, 300, 6, 2, 100),
    'bar_p': (300, 0, 0, 0, 500, 8, 2, -30),
    'ref_p': (300, 0, 0, 0, 1500, 10, 2, -30),
    'fact_p': (400, 0, 0, 0, 1000, 10, 2, -30),
    'radar_p': (250, 0, 0, 0, 800, 8, 2, -40),
    'turret_p': (200, 4, 20, 50, 600, 8, 1, -40),
    'tower_p': (150, 3, 6, 12, 400, 5, 1, -10),
    'hq_p': (400, 0, 0, 0, 0, 0, 3, HQ_POWER),
    'bar_e': (300, 0, 0, 0, 500, 20, 3, 0),     # (the enemy's: what it
    'fact_e': (400, 0, 0, 0, 1000, 25, 2, 0),   #   pays and how long it
    'ref_e': (300, 0, 0, 0, 1500, 25, 2, 0),    #   takes to rebuild one)
    'pp_e': (200, 0, 0, 0, 300, 15, 2, 0),
}
# the ones that are buildings (drawn with the map, in pieces); turrets and
# guard towers are drawn like units
BUILDING_NAMES = {n for n in STRUCTS if not n.startswith(('turret', 'tower'))}
STARTING = ['hq_p', 'bar_e', 'fact_e', 'ref_e', 'pp_e']    # (not built)

# armor and weapon classes: damage = base damage * DAMAGE[weapon][armor] / 8
INFANTRY, VEHICLE, BUILDING = 0, 1, 2
GUN, MGUN, ROCKETS = 0, 1, 2
ARMOR = {'tank': VEHICLE, 'harv': VEHICLE, 'buggy': VEHICLE, 'sold': INFANTRY,
         'rock': INFANTRY, 'turret': BUILDING, 'hq': BUILDING, 'bar': BUILDING,
         'pp': BUILDING, 'fact': BUILDING, 'ref': BUILDING, 'radar': BUILDING,
         'tower': BUILDING}
WEAPON = {'buggy': MGUN, 'rock': ROCKETS, 'tower': MGUN}   # the rest: GUN
DAMAGE = {GUN: (8, 8, 8),               # cannons and rifles: the same to all
          MGUN: (16, 4, 2),             # machine gun: good against infantry
          ROCKETS: (3, 16, 12)}         # rockets: good against armor


def unit_class(name):
    """Armor class in bits 0-1, weapon class in bits 2-3."""
    kind = name.split('_')[0]
    return ARMOR[kind] | WEAPON.get(kind, GUN) << 2

CREDITS0 = 2500                 # starting money
ORE_PER_TILE = 600              # credits in each ore tile
CAPACITY = 500                  # harvester load
SCOOP = 25                      # credits per scoop of ore
# ore grows back: every GROW_FRAMES frames each ore tile below full gets
# GROW_SCOOPS more (the game sweeps them, one a frame); at most ORE_TILES
# ore tiles on a map
GROW_FRAMES, GROW_SCOOPS, ORE_TILES = 2048, 3, 64
HARV_WAIT = 240                 # frames a harvester with no work waits
                                # before it looks again
AI_HARV_SECS = 30               # the enemy's refinery makes a new
                                # harvester (free) when it has none
# the enemy at each difficulty: starting money, its share (credits it
# gets for each SCOOP its harvester unloads), seconds before its first
# attack wave and at least between waves, units in the first wave and at
# most (one more each time), units it built alive at once at most.
DIFFICULTIES = [('EASY', 400, 4, 180, 80, 2, 4, 5),
                ('NORMAL', 700, 6, 120, 60, 3, 5, 6),
                ('HARD', 1000, 9, 90, 45, 3, 6, 8)]
DIFF0 = 1                       # chosen at first: NORMAL
AI_BUILDS = ['sold_e', 'rock_e', 'tank_e', 'sold_e', 'buggy_e', 'rock_e']  # repeated
H_IDLE, H_SEEK, H_GOTO, H_MINE, H_HOME, H_UNLOAD, H_WAIT = range(7)

# sidebar build icons, three across, top to bottom. Structures and units
# build in two separate queues; soldiers need a barracks, tanks and
# buggies a war factory (and come out of it), and a war factory needs a
# barracks; so do the enemy's. Harvesters need nothing: they come from
# the command center. The enemy's come out of its refinery.
ICON_UNITS = ['pp_p', 'bar_p', 'ref_p', 'fact_p', 'radar_p', 'turret_p', 'tower_p',
              'harv_p', 'tank_p', 'buggy_p', 'sold_p', 'rock_p']
NEEDS = {'fact_p': 'bar_p',
         'sold_p': 'bar_p', 'rock_p': 'bar_p', 'tank_p': 'fact_p',
         'buggy_p': 'fact_p', 'sold_e': 'bar_e', 'rock_e': 'bar_e', 'tank_e': 'fact_e',
         'buggy_e': 'fact_e', 'harv_e': 'ref_e'}
BARSEGS = 8                     # a progress bar's segments (2 pixels each)
ICONWB = 10                     # an icon's width in bytes

PLACE_RANGE = 4                 # structures go within this many tiles of
                                # one of your buildings
# selling gives back half the price; repairing adds REPAIR_HP hit points
# every REPAIR_STEP frames for REPAIR_COST credits
REPAIR_STEP, REPAIR_HP, REPAIR_COST = 8, 4, 3
MODE_SELL, MODE_REPAIR = 1, 2
# the SELL and REPAIR buttons in the sidebar: x0, x1 (y is the same)
BUTTONS = ((5, 29, "SELL"), (32, 58, "REPAIR"))
BUTTON_Y0, BUTTON_Y1 = 177, 189
# a button that is on: its colors changed by this map (others stay): gold
# with white letters
BUTTON_ON = {STEEL: GOLD, LIGHT: SAND, GOLD: LIGHT}


def icon_box(i):
    """Sidebar-relative box of build icon i: x0, y0, x1, y1 (three across,
    each 20 x 24 with a 16 x 16 picture)."""
    x0, y0 = 2 + (i % 3) * 20, 59 + (i // 3) * 25
    return x0, y0, x0 + 19, y0 + 23


def icon_bar(i):
    """Sidebar-relative top left of icon i's progress bar (16 x 2)."""
    x0, y0, _, _ = icon_box(i)
    return x0 + 2, y0 + 19

# terrain units cannot enter: water, trees, rocks, building pads
BLOCKED = 'wtrc'

CURSOR_START = (128, 100)       # screen pixel, arrow hotspot


def bsize(name):
    return STRUCTS[name][6]


def door(name, c0, r0):
    """A building's door (column, row): below its bottom-left tile. Units
    come out there, and harvesters unload at a refinery's."""
    return c0, r0 + bsize(name)


def building_overlays(sprites):
    """(tile, sprite) for the pieces of the starting buildings drawn over
    the map (empty pieces left out)."""
    out = []
    for name, c0, r0 in BUILDINGS:
        n = bsize(name)
        for i in range(n * n):
            piece = '%s%d' % (name, i)
            if any(any(row) for row in sprites[piece]):
                out.append(((r0 + i // n) * MAP_COLS + c0 + i % n,
                            SPRITE_ORDER.index(piece)))
    return out


def template_offset(name):
    return [n for n, _ in templates()].index(name) * TMPLSZ


def unit_records():
    """(base sprite, tile, flags, speed, hp, range, damage, rate, power,
    footprint top-left tile, footprint size, class) of the units, then the
    starting buildings. The sprite drawn is base + 0-3: facing right, left
    (F_LEFT), up (F_VERT) or down (both). tile = row*32 + col.
    Buildings: sprite = their template (offset in templates.bin); tile =
    the middle of a 3x3 one, the top left of a 2x2 one (as when placed).
    """
    recs = []
    for name, col, row in UNITS:
        assert MAP[row][col] not in BLOCKED, name
        hp, rng, dmg, rate, speed, _, _ = STATS[name.split('_')[0]]
        flags = unit_flags(name)
        if ENEMY_WEST:                          # facing the other side
            flags ^= F_LEFT
        recs.append((SPRITE_ORDER.index(name), row * MAP_COLS + col, flags, speed, hp,
                     rng, dmg, rate, 0, 0, 0, unit_class(name)))
    for name, col, row in BUILDINGS:
        hp, rng, dmg, rate, _, _, size, power = STRUCTS[name]
        mid = size // 2 if size == 3 else 0
        recs.append((template_offset(name), (row + mid) * MAP_COLS + col + mid,
                     unit_flags(name), 0, hp, 0, 0, 0,
                     (power if name.endswith('_p') else 0) & 0xFFFF,
                     row * MAP_COLS + col, size, unit_class(name)))
    return recs


def unit_flags(name):
    flags = F_PLAYER if name.endswith('_p') else F_LEFT
    if name.startswith(('turret', 'tower')):
        flags |= F_STATIC
    if name.startswith('harv'):
        flags |= F_HARV
    if name in BUILDING_NAMES:
        flags |= F_BUILDING | F_STATIC
    return flags


TMPLSZ, ICONSZ = 30, 22


def templates():
    """Everything that can be built, then the buildings that stand at the
    start: (name, record) with the record as in templates.bin: sprite,
    flags, speed, hp, range, damage, rate, cost, frames per progress-bar
    segment (BARSEGS of them), kind (0 = unit that rolls out, 1 =
    structure to place), size in tiles, power, class, name tag, the
    template of the building it needs (NONE: none). For buildings, sprite
    is the first of their pieces."""
    out = []
    for name in ICON_UNITS + AI_BUILDS + ['harv_e'] + STARTING:
        if name in [n for n, _ in out]:
            continue
        if name in STRUCTS:
            hp, rng, dmg, rate, cost, secs, size, power = STRUCTS[name]
            spr = SPRITE_ORDER.index(name + '0' if size > 1 else name)
            rec = [spr, unit_flags(name), 0, hp, rng, dmg, rate, cost,
                   secs * 60 // BARSEGS, 1, size, power & 0xFFFF, unit_class(name)]
        else:
            hp, rng, dmg, rate, speed, cost, secs = STATS[name.split('_')[0]]
            rec = [SPRITE_ORDER.index(name), unit_flags(name), speed, hp, rng,
                   dmg, rate, cost, secs * 60 // BARSEGS, 0, 1, 0, unit_class(name)]
        rec.append(LABEL_NAMES.index(name) if name in LABEL_NAMES else 0xFFFF)
        out.append((name, rec))
    names = [n for n, _ in out]
    for name, rec in out:
        rec.append(names.index(NEEDS[name]) * TMPLSZ if name in NEEDS else 0xFFFF)
    return [(n, tuple(r)) for n, r in out]


QUEUES = ['structures', 'infantry', 'vehicles', 'harvesters']


def icon_queue(name):
    """Its build queue: structures, infantry (barracks), vehicles (war
    factory) or harvesters (command center), each building one at a time,
    all at once."""
    kind = name.split('_')[0]
    if name in STRUCTS:
        return 0
    return {'sold': 1, 'rock': 1, 'tank': 2, 'buggy': 2, 'harv': 3}[kind]


def icon_dim(img, i):
    """Grey out icon i (sidebar image), byte-aligned like the game does:
    every other pixel of the inner area turns dark."""
    x0, y0, x1, y1 = icon_box(i)
    for y in range(y0 + 2, y1 - 1):
        for bx in range((SIDE_X + x0 + 2) // 2, (SIDE_X + x1 - 2) // 2 + 1):
            x = bx * 2 - SIDE_X + (y & 1)
            img[y][x] = INK


def icon_ready_pos(i):
    """Sidebar top left of the READY label on icon i (across all of it)."""
    x0, y0, _, _ = icon_box(i)
    return x0, y0 + 10



def ready_label():
    r = blank(20, 7, INK)
    text(r, 1, 1, "READY", LIGHT, shadow=None)
    return r


def power_bar(img, used, made):
    """The sidebar power bar (img = sidebar image), as the game draws it:
    2-pixel steps, green up to made/16 steps (red when over), a light
    mark at used/16."""
    n = min(POWBAR_STEPS, made // 16)
    color = RED if used > made else ORE
    for y in range(POWBAR_Y, POWBAR_Y + 5):
        for k in range(POWBAR_STEPS):
            c = color if k < n else INK
            if used and k == min(POWBAR_STEPS - 1, used // 16):
                c = LIGHT
            img[y][POWBAR_X + 2 * k:POWBAR_X + 2 * k + 2] = [c, c]


POWBAR_X, POWBAR_Y, POWBAR_STEPS = 8, 168, 24   # sidebar pixels


def ring_offsets(radius=4):
    """Tile offsets around a goal, nearest first: spreads out group moves."""
    offs = [(dx, dy) for dy in range(-radius, radius + 1)
            for dx in range(-radius, radius + 1)]
    offs.sort(key=lambda o: (max(abs(o[0]), abs(o[1])), o[0] ** 2 + o[1] ** 2))
    return offs


# ------------------------------------------------------------------ font

FONT = {  # 3x5 glyphs
    'A': ["###", "#.#", "###", "#.#", "#.#"],
    'B': ["##.", "#.#", "##.", "#.#", "##."],
    'C': ["###", "#..", "#..", "#..", "###"],
    'D': ["##.", "#.#", "#.#", "#.#", "##."],
    'E': ["###", "#..", "##.", "#..", "###"],
    'I': ["###", ".#.", ".#.", ".#.", "###"],
    'L': ["#..", "#..", "#..", "#..", "###"],
    'N': ["##.", "#.#", "#.#", "#.#", "#.#"],
    'O': ["###", "#.#", "#.#", "#.#", "###"],
    'P': ["###", "#.#", "###", "#..", "#.."],
    'R': ["##.", "#.#", "##.", "#.#", "#.#"],
    'S': ["###", "#..", "###", "..#", "###"],
    'T': ["###", ".#.", ".#.", ".#.", ".#."],
    'U': ["#.#", "#.#", "#.#", "#.#", "###"],
    'W': ["#.#", "#.#", "#.#", "###", "#.#"],
    'F': ["###", "#..", "##.", "#..", "#.."],
    'G': ["###", "#..", "#.#", "#.#", "###"],
    'H': ["#.#", "#.#", "###", "#.#", "#.#"],
    'K': ["#.#", "#.#", "##.", "#.#", "#.#"],
    'M': ["#.#", "###", "###", "#.#", "#.#"],
    'Y': ["#.#", "#.#", ".#.", ".#.", ".#."],
    'V': ["#.#", "#.#", "#.#", "#.#", ".#."],
    'X': ["#.#", "#.#", ".#.", "#.#", "#.#"],
    'Z': ["###", "..#", ".#.", "#..", "###"],
    'J': ["..#", "..#", "..#", "#.#", "###"],
    'Q': ["###", "#.#", "#.#", "###", "..#"],
    '-': ["...", "...", "###", "...", "..."],
    '.': ["...", "...", "...", "...", ".#."],
    '\u00a9': [".#####.", "#.###.#", "#.#...#", "#.###.#", ".#####."],  # (a C in a ring)
    '0': ["###", "#.#", "#.#", "#.#", "###"],
    '1': [".#.", "##.", ".#.", ".#.", "###"],
    '2': ["###", "..#", "###", "#..", "###"],
    '3': ["###", "..#", "###", "..#", "###"],
    '4': ["#.#", "#.#", "###", "..#", "..#"],
    '5': ["###", "#..", "###", "..#", "###"],
    '6': ["###", "#..", "###", "#.#", "###"],
    '7': ["###", "..#", "..#", "..#", "..#"],
    '8': ["###", "#.#", "###", "#.#", "###"],
    '9': ["###", "#.#", "###", "..#", "###"],
    ':': ["...", ".#.", "...", ".#.", "..."],
    '/': ["..#", "..#", ".#.", "#..", "#.."],
    ' ': ["...", "...", "...", "...", "..."],
}


def text(img, x, y, s, c, shadow=INK):
    """3x5 text (a glyph's width plus one apart) with a one-pixel drop
    shadow."""
    for pass_, (ox, oy, col) in enumerate(((1, 1, shadow), (0, 0, c))):
        if col is None:
            continue
        cx = x
        for ch in s:
            for gy, row in enumerate(FONT[ch]):
                for gx, p in enumerate(row):
                    if p == '#':
                        img[y + gy + oy][cx + gx + ox] = col
            cx += len(FONT[ch][0]) + 1


def text2x(img, x, y, s, c, shadow=INK):
    """Double-size 3x5 text (6x10 glyphs) with a drop shadow."""
    for ox, oy, col in ((1, 1, shadow), (0, 0, c)):
        if col is None:
            continue
        cx = x
        for ch in s:
            for gy, row in enumerate(FONT[ch]):
                for gx, p in enumerate(row):
                    if p == '#':
                        rect(img, cx + gx * 2 + ox, y + gy * 2 + oy,
                             cx + gx * 2 + 1 + ox, y + gy * 2 + 1 + oy, col)
            cx += 8


BANNER_W, BANNER_H = 176, 32
BANNER_X = (SIDE_X - BANNER_W) // 2
BANNER_Y = TOP_H + (VIEW_ROWS * 16 - BANNER_H) // 2


# the end-of-game panel: as wide, taller (whole cell rows), with the
# game's numbers (the game writes them at STAT_X, one line each)
END_H = 96
END_Y = TOP_H + (VIEW_ROWS * 16 - END_H) // 2
END_STATS = ["UNITS BUILT", "UNITS LOST", "ENEMIES DESTROYED", "ORE MINED", "MISSION TIME"]
STAT_Y0, STAT_DY = 26, 10               # panel rows of the stats' text
STAT_X, TIME_X = 144, 140               # panel columns: numbers, the time


def banner(title, color):
    """End-of-game panel shown in the middle of the map."""
    b = blank(BANNER_W, END_H, STEEL_D)
    frame(b, 0, 0, BANNER_W - 1, END_H - 1, INK)
    bevel(b, 1, 1, BANNER_W - 2, END_H - 2, STEEL, INK)
    text2x(b, (BANNER_W - (len(title) * 8 - 2)) // 2, 6, title, color)
    rect(b, 10, 21, BANNER_W - 11, 21, INK)
    for i, s in enumerate(END_STATS):
        text(b, 12, STAT_Y0 + i * STAT_DY, s, LIGHT)
    rect(b, 10, 79, BANNER_W - 11, 79, INK)
    sub = "CLICK TO PLAY AGAIN"
    text(b, (BANNER_W - text_width(sub)) // 2, 84, sub, LIGHT)
    return b


def text_width(s):
    return sum(len(FONT[ch][0]) + 1 for ch in s) - 1


# -------------------------------------------------------------------- UI


CREDX = 20                      # byte column of the credits number


POWX = 106                      # byte column of the power numbers
GLYPHS = '0123456789 /:'


QUEUE_MAX = 5                   # units of one kind queued at most


def digit_glyphs():
    """GLYPHS as 4x8 top-bar pieces, same as text() draws them, in gold
    (credits), green (power) and red (low power); then light on black,
    the number on a build icon with more of its kind queued."""
    out = []
    for color in (GOLD, ORE, RED):
        for ch in GLYPHS:
            g = blank(4, TOP_H, STEEL_D)
            rect(g, 0, 0, 3, 0, STEEL)
            rect(g, 0, 7, 3, 7, INK)
            text(g, 0, 1, ch, color)
            out.append(g)
    for ch in GLYPHS:
        g = blank(4, TOP_H, INK)
        text(g, 0, 1, ch, LIGHT, shadow=None)
        out.append(g)
    for ch in GLYPHS:                       # (the end-of-game panel's)
        g = blank(4, TOP_H, STEEL_D)
        text(g, 0, 1, ch, GOLD)
        out.append(g)
    return out


def make_topbar():
    t = blank(SCREEN_W, TOP_H, STEEL_D)
    rect(t, 0, 0, SCREEN_W - 1, 0, STEEL)
    rect(t, 0, 7, SCREEN_W - 1, 7, INK)
    text(t, 4, 1, "CREDITS:", GOLD)
    text(t, CREDX * 2, 1, '%5d' % CREDITS0, GOLD)
    text(t, POWX * 2 - 4 - text_width("POWER:"), 1, "POWER:", ORE)
    return t


def topbar_numbers(t, credits, used, made):
    """The parts of the top bar the game redraws."""
    text(t, CREDX * 2, 1, '%5d' % credits, GOLD)
    text(t, POWX * 2, 1, '%3d/%3d' % (used, made), RED if used > made else ORE)


RADAR_X, RADAR_Y, RADAR_W, RADAR_H = 8, 12, 48, 36   # in the sidebar


def radar_terrain(tiles, cells):
    """The radar picture of a map: each tile's commonest color, 1.5
    pixels per tile."""
    main = [max(range(16), key=lambda k: sum(r.count(k) for r in t)) for t in tiles]
    return [[main[cells[(py * 2 // 3) * MAP_COLS + px * 2 // 3]] for px in range(RADAR_W)]
            for py in range(RADAR_H)]


def radar_dynamic(side, units, cam, seen):
    """What the game draws on the radar: black where nothing has been
    seen, a dot per unit (2x2 for buildings; gold ours, red theirs where
    seen) and a light frame around the view."""
    for py in range(RADAR_H):
        for px in range(RADAR_W):
            if (py * 2 // 3) * MAP_COLS + px * 2 // 3 not in seen:
                side[RADAR_Y + py][RADAR_X + px] = CLEAR
    for spr, tile, flags, *_ in units:
        if not flags & F_PLAYER and tile not in seen:
            continue
        x = RADAR_X + (tile % MAP_COLS) * 3 // 2
        y = RADAR_Y + (tile // MAP_COLS) * 3 // 2
        c = GOLD if flags & F_PLAYER else RED
        n = 1 if flags & F_BUILDING else 0
        rect(side, x, y, x + n, y + n, c)
    x0, y0 = RADAR_X + cam[0] * 3 // 2, RADAR_Y + cam[1] * 3 // 2
    frame(side, x0, y0, x0 + VIEW_COLS * 3 // 2 - 1, y0 + VIEW_ROWS * 3 // 2 - 1, LIGHT)


def make_sidebar(tiles, cells=None):
    s = blank(SIDE_W, SCREEN_H - TOP_H, STEEL_D)
    rect(s, 0, 0, 0, len(s) - 1, INK)
    rect(s, 1, 0, 1, len(s) - 1, STEEL)

    def label(y, txt):
        text(s, 2 + (SIDE_W - 2 - text_width(txt)) // 2, y, txt, LIGHT)

    def panel(x0, y0, x1, y1, fill):
        frame(s, x0, y0, x1, y1, INK)
        bevel(s, x0 + 1, y0 + 1, x1 - 1, y1 - 1, STEEL_D, STEEL)
        rect(s, x0 + 2, y0 + 2, x1 - 2, y1 - 2, fill)

    # radar: the world's terrain, 1.5 pixels per tile (the game adds units
    # and the view frame)
    label(3, "RADAR")
    panel(5, 10, 58, 49, INK)
    if cells:                               # (the game puts the map's in)
        paste_all(s, radar_terrain(tiles, cells), RADAR_X, RADAR_Y)

    # build menu: 3 x 4 icons on dark blue
    label(52, "BUILD")
    pictures = {'turret_p': turret('player'), 'tower_p': guard_tower('player'),
                'tank_p': unit(TANK, 'player'), 'harv_p': unit(HARVESTER, 'player'),
                'sold_p': unit(SOLDIER, 'player'), 'buggy_p': unit(BUGGY, 'player'),
                'rock_p': unit(ROCKET, 'player')}
    for i, name in enumerate(ICON_UNITS):
        icon = pictures.get(name) or mini_building(name.split('_')[0])
        x0, y0, x1, y1 = icon_box(i)
        panel(x0, y0, x1, y1, WATER_D)
        assert len(icon) == 16 and len(icon[0]) == 16
        paste(s, icon, x0 + 2, y0 + 2)

    # power bar
    label(160, "POWER")
    panel(5, 166, 58, 174, INK)            # the game draws the bar

    # buttons
    for x0, x1, txt in BUTTONS:
        frame(s, x0, BUTTON_Y0, x1, BUTTON_Y1, INK)
        rect(s, x0 + 1, BUTTON_Y0 + 1, x1 - 1, BUTTON_Y1 - 1, STEEL)
        bevel(s, x0 + 1, BUTTON_Y0 + 1, x1 - 1, BUTTON_Y1 - 1, LIGHT, STEEL_D)
        text(s, x0 + (x1 - x0 + 1 - text_width(txt)) // 2, BUTTON_Y0 + 4, txt, GOLD)
    return s


def button_bytes(i):
    """Screen byte box of button i: offset of its top-left byte, bytes
    across (the bytes cover a pixel more on each side where the button
    starts or ends mid-byte; BUTTON_ON keeps their color), first cell
    column."""
    x0, x1, _ = BUTTONS[i]
    sx0, sx1 = SIDE_X + x0, SIDE_X + x1
    b0, b1 = sx0 // 2, sx1 // 2
    return (TOP_H + BUTTON_Y0) * 160 + b0, b1 - b0 + 1, sx0 // 16


def press_button(img, i, ox=0, oy=0):
    """Draw button i pressed (img: sidebar-relative unless offsets)."""
    x0, x1, _ = BUTTONS[i]
    for y in range(BUTTON_Y0, BUTTON_Y1 + 1):
        for x in range(x0, x1 + 1):
            img[oy + y][ox + x] = BUTTON_ON.get(img[oy + y][ox + x], img[oy + y][ox + x])


# ------------------------------------------------------------- the maps
# Each map goes into CONQUER.DATA packed (rle) as one block that the game
# unpacks into the same place at the start of a game; its parts in order:
MAP_BLOCK = [('DOCK', 2), ('EXIT', 2), ('CAMX', 2), ('CAMY', 2),
             ('MAP', MAP_COLS * MAP_ROWS), ('PASS', MAP_COLS * MAP_ROWS),
             ('ORE', MAP_COLS * MAP_ROWS), ('RADAR', RADAR_W * RADAR_H // 2),
             ('PREVIEW', RADAR_W * RADAR_H // 2), ('OVER', 160), ('UNITS', 20 * 24 + 4)]


def preview_terrain(tiles, cells):
    """The map's picture for the options screen: the radar's, but with the
    enemy's base pad drawn as grass - where they are, you find out."""
    grass = cells[next(k for k, ch in enumerate(''.join(MAP)) if ch == 'g')]
    hidden = list(cells)
    for name, c, r in BUILDINGS:
        if not name.endswith('_p') and bsize(name) == 3:
            for y in range(r, r + 3):
                for x in range(c, c + 3):
                    hidden[y * MAP_COLS + x] = grass
    return radar_terrain(tiles, hidden)


def map_block(tiles, cells, sprites):
    """The map in use (use_map) as its block: where harvesters unload, our
    units and the enemy's appear (tiles), the first view, the tiles, which
    are blocked, scoops of ore in each, the radar picture, the options
    screen's picture of it (without the enemy's base), the starting
    buildings' pieces (word tile, word sprite; NONE ends them) and the
    starting units (see unit_records; tile NONE ends them)."""
    def tile(p):
        return p[1] * MAP_COLS + p[0]
    parts = {'DOCK': struct.pack('<H', tile(DOCK)), 'EXIT': struct.pack('<H', tile(EXIT)),

             'CAMX': struct.pack('<H', CAMERA0[0]), 'CAMY': struct.pack('<H', CAMERA0[1]),             'MAP': bytes(cells),
             'PASS': bytes(1 if ch in BLOCKED else 0 for row in MAP for ch in row),
             'ORE': bytes(ORE_PER_TILE // SCOOP if ch == 'o' else 0
                          for row in MAP for ch in row),
             'RADAR': pack(radar_terrain(tiles, cells)),
             'PREVIEW': pack(preview_terrain(tiles, cells))}
    over = bytearray()
    for t, spr in building_overlays(sprites):
        over += struct.pack('<HH', t, spr)
    parts['OVER'] = bytes(over) + struct.pack('<H', 0xFFFF)
    units = unit_records()
    assert len(units) <= 20
    parts['UNITS'] = b''.join(struct.pack('<12H', *r) for r in units) + struct.pack('<2H', 0xFFFF, 0xFFFF)
    out = bytearray()
    for name, size in MAP_BLOCK:
        assert len(parts[name]) <= size, name
        out += parts[name] + bytes(size - len(parts[name]))
    return bytes(out)


def map_checks():
    """The map in use: walls all around; nothing standing on a blocked
    tile; our units' exit and the dock open."""
    assert len(MAP) == MAP_ROWS and all(len(r) == MAP_COLS for r in MAP)
    for x in range(MAP_COLS):
        assert MAP[0][x] in BLOCKED and MAP[-1][x] in BLOCKED
    for y in range(MAP_ROWS):
        assert MAP[y][0] in BLOCKED and MAP[y][-1] in BLOCKED
    foot = set()
    for name, c, r in BUILDINGS:
        n = bsize(name)
        tiles = [(x, y) for y in range(r, r + n) for x in range(c, c + n)]
        if n == 3:                              # on its concrete pad
            assert all(MAP[y][x] == 'c' for x, y in tiles), name
        else:                                   # on open ground
            assert all(MAP[y][x] not in BLOCKED + 'o' for x, y in tiles), name
        assert not foot & set(tiles), name
        foot |= set(tiles)
    doors = [door(name, c, r) for name, c, r in BUILDINGS     # (where units
             if name.split('_')[0] in ('bar', 'fact', 'ref')]   # come out)

    for x, y in [DOCK, EXIT] + doors:
        assert MAP[y][x] not in BLOCKED + 'o' and (x, y) not in foot, (x, y)
    for name, c, r in UNITS:
        assert (c, r) not in foot and (c, r) not in doors, name
    # every door, the dock and the exit reach our dock (units step only
    # straight, not past the corners of walls, so straight steps it is)
    walls = foot | {(c, r) for name, c, r in UNITS if name.startswith(('turret', 'tower'))}
    def open_(x, y):
        return MAP[y][x] not in BLOCKED and (x, y) not in walls
    reach, todo = {DOCK}, [DOCK]
    while todo:
        x, y = todo.pop()
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            n = (x + dx, y + dy)
            if n not in reach and open_(*n):
                reach.add(n)
                todo.append(n)
    for p in doors + [EXIT]:
        assert p in reach, ('shut in', p)
    # an enemy harvester; not too many ore tiles for the game's list
    assert any(n == 'harv_e' for n, _, _ in UNITS)
    assert sum(row.count('o') for row in MAP) <= ORE_TILES


# -------------------------------------------------------------- options
# Before each game: the difficulty, the map and the music, then START.
# The game unpacks this screen, presses the chosen buttons (their colors
# through BUTTON_ON, like SELL and REPAIR) and draws the map previews from
# the maps' preview pictures (the radar's without the enemy's base), twice
# the size, with a gold dot on ours.

OPT_DIFF_Y = 35                 # difficulty buttons' top
OPT_PREV_Y = 72                 # map previews' top (inside their frames)
OPT_PREV_X = 112                # the map preview's left (one map at a time)
OPT_NAME_Y = 152                # its name's top
OPT_ARROWS = ((60, 89), (230, 259))   # previous and next map buttons (x)
OPT_ARROW_Y = (98, 118)
OPT_START = (124, 172, 195, 192)
OPT_BTN_H = 13
# a chosen button lights up green: its colors through OPT_ON (the game's
# optbtn table)
OPT_ON = {STEEL_D: GRASS_D, STEEL: ORE, GRASS_L: ORE}


def opt_button(img, x0, y0, x1, y1, txt):
    """A gunmetal button, its label in dim green."""
    frame(img, x0, y0, x1, y1, INK)
    rect(img, x0 + 1, y0 + 1, x1 - 1, y1 - 1, STEEL_D)
    bevel(img, x0 + 1, y0 + 1, x1 - 1, y1 - 1, STEEL, INK)
    text(img, x0 + (x1 - x0 + 1 - text_width(txt)) // 2, y0 + (y1 - y0 - 3) // 2, txt,
         GRASS_L)


def press_rect(img, x0, y0, x1, y1, on=None):
    """A button pressed, as the game does it: both pixels of each byte
    through the mapping (OPT_ON)."""
    on = on or OPT_ON
    for y in range(y0, y1 + 1):
        for x in range(x0 & ~1, x1 + 1 | 1):
            img[y][x] = on.get(img[y][x], img[y][x])


def metal_panel(img, x0, y0, x1, y1, title=None):
    """A dark panel in a riveted gunmetal frame, its title in green."""
    frame(img, x0, y0, x1, y1, INK)
    bevel(img, x0 + 1, y0 + 1, x1 - 1, y1 - 1, STEEL, STEEL_D)
    bevel(img, x0 + 2, y0 + 2, x1 - 2, y1 - 2, STEEL_D, STEEL)
    rect(img, x0 + 3, y0 + 3, x1 - 3, y1 - 3, INK)
    for x, y in ((x0 + 1, y0 + 1), (x1 - 2, y0 + 1), (x0 + 1, y1 - 2), (x1 - 2, y1 - 2)):
        img[y][x] = LIGHT                       # rivets
        img[y + 1][x + 1] = CLEAR
    if title:
        text(img, x0 + 7, y0 + 5, title, ORE, shadow=None)


def hud_corners(img, x0, y0, x1, y1, c, arm):
    """Corner brackets around a box."""
    for x, y, dx, dy in ((x0, y0, 1, 1), (x1, y0, -1, 1), (x0, y1, 1, -1), (x1, y1, -1, -1)):
        for k in range(arm):
            img[y][x + dx * k] = c
            img[y + dy * k][x] = c


def logo(img, y):
    """CONQUER GS, three times the font's size: gold shading down each
    letter (GS in red), an ink outline, a dark shadow."""
    word = "CONQUER GS"
    w = sum(len(FONT[ch][0]) * 3 + 3 for ch in word) - 3
    x0 = (SCREEN_W - w) // 2
    layer = blank(SCREEN_W, 21)
    x = x0
    for i, ch in enumerate(word):
        ramp = (SAND, GOLD, GOLD, DIRT, DIRT) if i < 7 else (LIGHT, RED, RED, RED, DIRT_D)
        for gy, row in enumerate(FONT[ch]):
            for gx, p in enumerate(row):
                if p == '#':
                    rect(layer, x + gx * 3, 2 + gy * 3, x + gx * 3 + 2, 2 + gy * 3 + 2, ramp[gy])
        x += len(FONT[ch][0]) * 3 + 3
    out = copy(layer)
    for yy in range(21):
        for xx in range(SCREEN_W):
            if not layer[yy][xx]:
                near = any(0 <= yy + dy < 21 and 0 <= xx + dx < SCREEN_W and layer[yy + dy][xx + dx]
                           for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)))
                if near:
                    out[yy][xx] = INK
                elif yy >= 2 and xx >= 2 and layer[yy - 2][xx - 2]:
                    out[yy][xx] = DIRT_D        # shadow
    paste(img, out, 0, y)
    return x0, x0 + w - 1


def options_screen():
    """The screen and its click areas: (x0, y0, x1, y1, action, pressable)
    with action 0-2 a difficulty, 16 + i map i, 32 START, 48 music on, 49
    music off, 64 HOW TO PLAY."""
    img = blank(SCREEN_W, SCREEN_H, CLEAR)
    for y in range(0, SCREEN_H, 2):             # scanlines
        rect(img, 0, y, SCREEN_W - 1, y, INK)
    hud_corners(img, 2, 2, SCREEN_W - 3, SCREEN_H - 3, GRASS, 12)
    lx0, lx1 = logo(img, 2)
    rect(img, lx0, 23, lx1, 23, RED)             # a red rule under it
    sub = "MISSION SETUP"
    sx = (SCREEN_W - text_width(sub)) // 2
    text(img, sx, 25, sub, ORE, shadow=None)
    for x0, x1 in ((24, sx - 6), (sx + text_width(sub) + 5, SCREEN_W - 25)):
        rect(img, x0, 27, x1, 27, GRASS_D)
    areas = []
    # difficulty: a panel with the three buttons
    metal_panel(img, 16, 31, 303, 51)
    text(img, 24, OPT_DIFF_Y + 4, "DIFFICULTY", ORE, shadow=None)
    for i, (name, *_) in enumerate(DIFFICULTIES):
        x0 = 100 + i * 66
        opt_button(img, x0, OPT_DIFF_Y, x0 + 59, OPT_DIFF_Y + OPT_BTN_H - 1, name)
        areas.append((x0, OPT_DIFF_Y, x0 + 59, OPT_DIFF_Y + OPT_BTN_H - 1, i, 1))
    # the battlefield: one map at a time in a frame, its name below (the
    # game draws both), arrows on either side to pick another
    metal_panel(img, 16, 54, 303, 168, "BATTLEFIELD")
    x0, y0 = OPT_PREV_X, OPT_PREV_Y
    frame(img, x0 - 3, y0 - 3, x0 + 98, y0 + 74, INK)
    bevel(img, x0 - 2, y0 - 2, x0 + 97, y0 + 73, STEEL, STEEL_D)
    frame(img, x0 - 1, y0 - 1, x0 + 96, y0 + 72, INK)
    rect(img, x0, y0, x0 + 95, y0 + 71, CLEAR)
    hud_corners(img, x0 - 6, y0 - 6, x0 + 101, y0 + 77, ORE, 5)
    areas.append((x0, y0, x0 + 95, y0 + 71, 17, 0))          # (next)
    opt_button(img, x0, OPT_NAME_Y, x0 + 95, OPT_NAME_Y + OPT_BTN_H - 1, "")
    areas.append((x0, OPT_NAME_Y, x0 + 95, OPT_NAME_Y + OPT_BTN_H - 1, 17, 0))
    ay0, ay1 = OPT_ARROW_Y
    for k, (ax0, ax1) in enumerate(OPT_ARROWS):
        opt_button(img, ax0, ay0, ax1, ay1, "")
        cx, cy = (ax0 + ax1) // 2, (ay0 + ay1) // 2
        for d in range(6):                      # a triangle pointing out
            x = cx - 3 + d if k == 0 else cx + 3 - d
            rect(img, x, cy - d, x, cy + d, GRASS_L)
        areas.append((ax0, ay0, ax1, ay1, 16 + k, 0))
    text(img, (SCREEN_W - text_width("%d MAPS" % len(MAPS))) // 2, 59,
         "%d MAPS" % len(MAPS), STEEL, shadow=None)
    # the bottom: music on or off, START, the copyright
    by0 = 176
    text(img, 20, by0 + 4, "MUSIC", ORE, shadow=None)
    for k, (x0, x1, txt) in enumerate(((44, 69, "ON"), (72, 101, "OFF"))):
        opt_button(img, x0, by0, x1, by0 + OPT_BTN_H - 1, txt)
        areas.append((x0, by0, x1, by0 + OPT_BTN_H - 1, 48 + k, 1))
    x0, y0, x1, y1 = OPT_START                  # a big red launch button
    frame(img, x0, y0, x1, y1, INK)
    rect(img, x0 + 1, y0 + 1, x1 - 1, y1 - 1, RED)
    bevel(img, x0 + 1, y0 + 1, x1 - 1, y1 - 1, SAND, DIRT_D)
    bevel(img, x0 + 2, y0 + 2, x1 - 2, y1 - 2, RED, DIRT_D)
    text2x(img, x0 + (x1 - x0 + 1 - (5 * 8 - 2)) // 2, y0 + 6, "START", LIGHT)
    hud_corners(img, x0 - 3, y0 - 3, x1 + 3, y1 + 3, GOLD, 4)
    areas.append((x0, y0, x1, y1, 32, 0))
    x0, x1 = HELP_BTN                           # the instructions
    opt_button(img, x0, by0, x1, by0 + OPT_BTN_H - 1, "HOW TO PLAY")
    areas.append((x0, by0, x1, by0 + OPT_BTN_H - 1, 64, 0))
    for x0, y0, x1, y1, act, press in areas:
        assert x0 % 2 == 0 and x1 % 2 == 1
    return img, areas


HELP_BTN = (218, 299)                   # HOW TO PLAY (x; at the bottom)
NOTE = "© 2026 WALTER TENGLER"

# the instructions: pages behind HOW TO PLAY, each a screen like the
# mission setup's. Lines: (gold heading or key, light text) - a key and
# its text side by side, or a heading alone, or text alone.
def help_texts():
    t, b, so, ro, h = (STATS[k] for k in ('tank', 'buggy', 'sold', 'rock', 'harv'))
    return [
        ("THE MISSION", [
            ("GOAL", ""),
            ("", "DESTROY EVERY ENEMY UNIT AND BUILDING TO WIN."),
            ("", "IF YOUR COMMAND CENTER FALLS THE MISSION IS LOST."),
            ("BUILDING UP", ""),
            ("", "A POWER PLANT - A BARRACKS FOR SOLDIERS - THEN A WAR"),
            ("", "FACTORY FOR TANKS AND BUGGIES. HARVESTERS COME FROM"),
            ("", "THE COMMAND CENTER."),
            ("MONEY", ""),
            ("", "ORE: %d CREDITS A SCOOP - %d A LOAD. MINED-OUT ORE GROWS" % (SCOOP, CAPACITY)),
            ("", "BACK. A REFINERY NEAR THE ORE SHORTENS THE TRIPS."),
            ("POWER", ""),
            ("", "%d FROM THE COMMAND CENTER - 100 PER POWER PLANT. TOO" % HQ_POWER),
            ("", "LITTLE: EVERYTHING BUILDS AT HALF SPEED - NO RADAR."),
            ("", "THE RADAR NEEDS A RADAR CENTER. THE FOG HIDES THE ENEMY."),
        ]),
        ("CONTROLS", [
            ("CLICK", "SELECT A UNIT"),
            ("DRAG", "SELECT SEVERAL WITH A BOX"),
            ("CLICK GROUND", "MOVE THERE"),
            ("CLICK ENEMY", "ATTACK IT"),
            ("SPACE", "UNSELECT - STOP PLACING"),
            ("ARROWS", "SCROLL - OR HOLD THE MOUSE AT AN EDGE"),
            ("RADAR", "CLICK IT TO JUMP THERE"),
            ("ICON", "BUILD - WHEN READY CLICK AGAIN TO PLACE"),
            ("ICON AGAIN", "QUEUE UP TO %d UNITS OF A KIND" % QUEUE_MAX),
            ("OPTION-CLICK", "CANCEL A BUILD - MONEY BACK"),
            ("BARRACKS", "THEN GROUND: ITS RALLY POINT"),
            ("SELL / REPAIR", "THEN ONE OF YOUR STRUCTURES"),
            ("REST THE MOUSE", "SEE WHAT IT IS AND WHAT IT COSTS"),
            ("M  /  ESC", "MUSIC  /  PAUSE"),
        ]),
        ("UNITS AND THE ENEMY", [
            ("UNIT", "COST  ARMOR  RANGE  GOOD AGAINST"),
            ("TANK", "%4d   %4d     %d     EVERYTHING" % (t[5], t[0], t[1])),
            ("BUGGY", "%4d   %4d     %d     SOLDIERS - FAST" % (b[5], b[0], b[1])),
            ("SOLDIER", "%4d   %4d     %d     CHEAP" % (so[5], so[0], so[1])),
            ("ROCKET SOLDIER", "%4d   %4d     %d     TANKS AND BUILDINGS" % (ro[5], ro[0], ro[1])),
            ("HARVESTER", "%4d   %4d     -     MINES ORE" % (h[5], h[0])),
            ("THE ENEMY", ""),
            ("", "MINES WITH ITS OWN HARVESTER: DESTROY IT TO STOP ITS"),
            ("", "MONEY. IT REBUILDS WHAT YOU DESTROY ONCE IT CAN PAY"),
            ("", "AND ATTACKS IN WAVES THAT GROW BIGGER."),
            ("TIPS", ""),
            ("", "TWO TURRETS BY THE COMMAND CENTER HOLD THE EARLY WAVES."),
            ("", "HUNT ITS HARVESTER. MATCH YOUR WEAPONS TO THE TARGETS."),
        ]),
    ]


HELP_KEY_X, HELP_TEXT_X = 26, 96
HELP_ADDR = 0xA000
HELP_BTN_Y = 180                        # the pages' bottom row (buttons)
HELP_Y0, HELP_DY = 46, 9


def help_pages():
    """The instruction pages (screens)."""
    texts = help_texts()
    out = []
    for n, (title, lines) in enumerate(texts):
        img = blank(SCREEN_W, SCREEN_H, CLEAR)
        for y in range(0, SCREEN_H, 2):         # scanlines
            rect(img, 0, y, SCREEN_W - 1, y, INK)
        hud_corners(img, 2, 2, SCREEN_W - 3, SCREEN_H - 3, GRASS, 12)
        head = "HOW TO PLAY"                    # (no logo: room on the disk)
        hx = (SCREEN_W - (len(head) * 8 - 2)) // 2
        text2x(img, hx, 8, head, GOLD)
        rect(img, hx - 4, 22, hx + len(head) * 8 + 1, 22, RED)
        metal_panel(img, 16, 31, 303, 172, "%d/%d  %s" % (n + 1, len(texts), title))
        y = HELP_Y0
        for key, what in lines:
            if key and not what:                # a heading
                text(img, HELP_KEY_X, y, key, GOLD, shadow=None)
            elif not key:                       # text on its own
                assert HELP_KEY_X + 8 + text_width(what) < 296, what
                text(img, HELP_KEY_X + 8, y, what, LIGHT, shadow=None)
            else:
                assert HELP_KEY_X + text_width(key) < HELP_TEXT_X - 4, key
                assert HELP_TEXT_X + text_width(what) < 296, what
                text(img, HELP_KEY_X, y, key, GOLD, shadow=None)
                text(img, HELP_TEXT_X, y, what, LIGHT, shadow=None)
            y += HELP_DY
        assert y <= 172
        by0 = HELP_BTN_Y                        # BACK, NEXT or DONE
        opt_button(img, 16, by0, 89, by0 + OPT_BTN_H - 1, "BACK" if n else "SETUP")
        last = n == len(texts) - 1
        opt_button(img, 230, by0, 303, by0 + OPT_BTN_H - 1, "DONE" if last else "NEXT")
        hint = "ESC: BACK TO THE SETUP"
        text(img, (SCREEN_W - text_width(hint)) // 2, by0 + 4, hint, STEEL, shadow=None)
        out.append(img)
    return out


def opt_markers():
    """Per map, a 4x4 gold dot on our base in its preview: (screen byte
    offset of its top left, color byte). (No dot for the enemy's.)"""
    out = []
    for i in range(len(MAPS)):
        use_map(i)
        dots = []
        for name, c, r in BUILDINGS:                # (its 3x3 pad: the middle)
            if name == 'hq_p':
                x = OPT_PREV_X + (c + 1) * 3 & ~1
                y = OPT_PREV_Y + (r + 1) * 3
                dots.append((y * 160 + x // 2, GOLD * 17, x, y, GOLD))
        assert len(dots) == 1
        out.append(dots)
    use_map(0)
    return out


def map_name_image(name):
    """The chosen map's name as the game draws it below the preview: a lit
    button."""
    img = blank(98, OPT_BTN_H)                  # (press_rect reaches a pixel
    opt_button(img, 0, 0, 95, OPT_BTN_H - 1, name)   # past the right edge)
    press_rect(img, 0, 0, 95, OPT_BTN_H - 1)
    return [row[:96] for row in img]



def options_expected(img, maps_radar, markers, diff, mapno, musicoff=0):
    """The options screen as the game shows it (no cursor)."""
    out = copy(img)
    radar = maps_radar[mapno]
    for y in range(RADAR_H * 2):
        for x in range(RADAR_W * 2):
            out[OPT_PREV_Y + y][OPT_PREV_X + x] = radar[y // 2][x // 2]
    for off, cb, x, y, col in markers[mapno]:
        rect(out, x, y, x + 3, y + 3, col)
    paste_all(out, map_name_image(MAPS[mapno]['name']), OPT_PREV_X, OPT_NAME_Y)
    _, areas = options_screen()
    for x0, y0, x1, y1, act, press in areas:
        if press and act in (diff, 48 + musicoff):
            press_rect(out, x0, y0, x1, y1)
    return out


# the pause panel (Esc): as wide as the end-of-game one, taller (whole
# cell rows), with the controls - the game's instructions; its buttons
# (panel-relative x0, x1; y0, y1)
PAUSE_H = 128
PAUSE_Y = TOP_H + (VIEW_ROWS * 16 - PAUSE_H) // 2
PAUSE_BTNS = ((12, 79, "RESUME"), (94, 163, "QUIT MISSION"))
PAUSE_BTN_Y = (108, 119)
CONTROLS = [("CLICK", "SELECT / MOVE / ATTACK"),
            ("DRAG", "SELECT SEVERAL"),
            ("SPACE", "UNSELECT / STOP PLACING"),
            ("ARROWS", "SCROLL - OR THE EDGES"),
            ("ICON", "BUILD - AGAIN: QUEUE"),
            ("OPTION-CLICK", "CANCEL A BUILD"),
            ("BARRACKS", "THEN GROUND: RALLY POINT"),
            ("M  /  ESC", "MUSIC  /  PAUSE")]
CONTROLS_X, CONTROLS_Y, CONTROLS_DY = (12, 66), 26, 9


def pause_panel():
    b = blank(BANNER_W, PAUSE_H, STEEL_D)
    frame(b, 0, 0, BANNER_W - 1, PAUSE_H - 1, INK)
    bevel(b, 1, 1, BANNER_W - 2, PAUSE_H - 2, STEEL, INK)
    text2x(b, (BANNER_W - (6 * 8 - 2)) // 2, 5, "PAUSED", GOLD)
    rect(b, 10, 21, BANNER_W - 11, 21, INK)
    for i, (key, what) in enumerate(CONTROLS):
        y = CONTROLS_Y + i * CONTROLS_DY
        assert CONTROLS_X[0] + text_width(key) < CONTROLS_X[1] - 3
        assert CONTROLS_X[1] + text_width(what) < BANNER_W - 8, what
        text(b, CONTROLS_X[0], y, key, GOLD)
        text(b, CONTROLS_X[1], y, what, LIGHT)
    rect(b, 10, 101, BANNER_W - 11, 101, INK)
    for x0, x1, txt in PAUSE_BTNS:
        opt_button(b, x0, PAUSE_BTN_Y[0], x1, PAUSE_BTN_Y[1], txt)
    return b


# --------------------------------------------------------------- labels
# A name tag shows when the mouse rests on a unit, a building or a build
# icon: ours in gold, theirs in red; icons with their price.

LABEL_H = 9
NAMES = {'tank': 'TANK', 'harv': 'HARVESTER', 'buggy': 'BUGGY', 'sold': 'SOLDIER',
         'rock': 'ROCKET SOLDIER', 'turret': 'TURRET', 'hq': 'COMMAND CENTER',
         'bar': 'BARRACKS', 'pp': 'POWER PLANT', 'fact': 'WAR FACTORY',
         'ref': 'REFINERY', 'radar': 'RADAR CENTER', 'tower': 'GUARD TOWER'}
LABEL_NAMES = ['tank_p', 'tank_e', 'harv_p', 'buggy_p', 'buggy_e', 'sold_p', 'sold_e',
               'rock_p', 'rock_e', 'turret_p', 'turret_e', 'tower_p', 'tower_e',
               'hq_p', 'bar_p', 'bar_e', 'pp_p', 'pp_e', 'fact_p', 'fact_e', 'ref_p',
               'ref_e', 'radar_p', 'harv_e']


def label_image(parts):
    """A dark tag with a frame around the text parts ((text, color), ...)."""
    s = ' '.join(t for t, _ in parts)
    w = text_width(s) + 6
    w += -w % 4                         # (whole words: the game copies words)
    img = blank(w, LABEL_H, INK)
    frame(img, 0, 0, w - 1, LABEL_H - 1, STEEL_D)
    x = 3
    for t, c in parts:
        text(img, x, 2, t, c, shadow=None)
        x += (len(t) + 1) * 4
    return img


def labels():
    """(name, image) for every tag: the units', then the icons'."""
    out = []
    for u in LABEL_NAMES:
        kind, side = u.split('_')
        out.append((u, label_image([(NAMES[kind], GOLD if side == 'p' else RED)])))
    for i, u in enumerate(ICON_UNITS):
        cost = STRUCTS[u][4] if u in STRUCTS else STATS[u.split('_')[0]][5]
        out.append(('icon%d' % i, label_image([(NAMES[u.split('_')[0]], LIGHT),
                                               (str(cost), GOLD)])))
    return out


def radar_offline():
    """What the radar shows without a working radar center: dark, a little
    static, and the words RADAR OFFLINE."""
    img = blank(RADAR_W, RADAR_H, INK)
    rng = random.Random(7)
    for _ in range(70):
        img[rng.randrange(RADAR_H)][rng.randrange(RADAR_W)] = STEEL_D
    for y, s in ((11, "RADAR"), (19, "OFFLINE")):
        x = (RADAR_W - text_width(s)) // 2
        rect(img, x - 1, y - 1, x + text_width(s), y + 5, INK)
        text(img, x, y, s, STEEL, shadow=None)
    return img



# ---------------------------------------------------------------- output

def pack(img):
    """Pack rows of 4-bit pixels, left pixel in the high nibble."""
    out = bytearray()
    for row in img:
        assert len(row) % 2 == 0
        for i in range(0, len(row), 2):
            out.append((row[i] << 4) | row[i + 1])
    return bytes(out)


def rle(data):
    """Run-length code: control byte 1-127 = that many literal bytes
    follow; 129-255 = repeat the next byte (control - 127) times; 0 ends."""
    out, lit, i = bytearray(), bytearray(), 0

    def flush():
        while lit:
            chunk = lit[:127]
            out.append(len(chunk))
            out.extend(chunk)
            del lit[:127]

    while i < len(data):
        j = i
        while j < len(data) and j - i < 128 and data[j] == data[i]:
            j += 1
        if j - i >= 3:
            flush()
            out += bytes((127 + j - i, data[i]))
            i = j
        else:
            lit.append(data[i])
            i += 1
    flush()
    return bytes(out + b'\0')


def unrle(code):
    """Inverse of rle(), to check it."""
    out, i = bytearray(), 0
    while code[i]:
        c = code[i]
        if c < 128:
            out += code[i + 1:i + 1 + c]
            i += 1 + c
        else:
            out += bytes([code[i + 1]]) * (c - 127)
            i += 2
    return bytes(out)


def paste_all(dst, src, x0, y0):
    """Copy every pixel, color 0 included."""
    for y, row in enumerate(src):
        dst[y0 + y][x0:x0 + len(row)] = row


def mask_of(img):
    return [[0 if p else 15 for p in row] for row in img]


def write_png(path, img, scale=2):
    """Minimal PNG writer, pixels doubled horizontally and vertically."""
    rgb = [(r * 17, g * 17, b * 17) for r, g, b in PALETTE]
    raw = bytearray()
    for row in img:
        line = bytearray([0])
        for p in row:
            line += bytes(rgb[p]) * scale
        raw += bytes(line) * scale
    w, h = len(img[0]) * scale, len(img) * scale

    def chunk(kind, data):
        c = struct.pack('>I', len(data)) + kind + data
        return c + struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff)

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n')
        f.write(chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b'IDAT', zlib.compress(bytes(raw), 9)))
        f.write(chunk(b'IEND', b''))


TITLE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'title.shr')
PROMPT = "CLICK TO START"
PROMPT_UP = 2                   # rows above the bottom palette band


def title_prompt(outdir):
    """The CLICK TO START line (and the copyright under it) drawn on the
    title picture (assets/title.shr,
    a Super Hi-Res screen image): centered near the bottom, PROMPT_UP rows
    above the bottom palette band's top, in each row's palette's brightest
    color with a dark outline: packed pixels with 0 for see-through, and
    where it goes. Also writes title_expected.bin (the screen as the game
    should show it)."""
    pic = bytearray(open(TITLE_FILE, 'rb').read())
    assert len(pic) == 32768
    scb = pic[0x7D00:0x7DC8]

    def colors(y):                  # brightest and darkest (not 0) of row y
        pal = [struct.unpack_from('<H', pic, 0x7E00 + (scb[y] & 15) * 32 + i * 2)[0]
               for i in range(16)]

        def lum(i):
            c = pal[i]
            return 0.3 * (c >> 8 & 15) + 0.59 * (c >> 4 & 15) + 0.11 * (c & 15)
        order = sorted(range(1, 16), key=lum)       # (0: see-through here)
        return order[-1], order[0]
    y0 = 199                                        # the bottom band's top
    while y0 > 0 and scb[y0 - 1] == scb[199]:
        y0 -= 1
    w = text_width(PROMPT) * 2 + 2                  # (and a dark outline
    w += w & 1                                      #  all around, to stand
    h = 12 + 10                                     #  out on any ground;
    y = y0 - PROMPT_UP - 10                         #  the copyright under it)
    assert y + h <= 200 and text_width(NOTE) + 2 <= w
    letters = blank(w, h)
    text2x(letters, 1, 1, PROMPT, 1, shadow=None)
    text(letters, (w - text_width(NOTE)) // 2, 13, NOTE, 1, shadow=None)
    img = blank(w, h)
    for yy in range(h):
        bright, dark = colors(y + yy)
        for xx in range(w):
            if letters[yy][xx]:
                img[yy][xx] = bright
            elif any(0 <= yy + dy < h and 0 <= xx + dx < w and letters[yy + dy][xx + dx]
                     for dy in (-1, 0, 1) for dx in (-1, 0, 1)):
                img[yy][xx] = dark
    x = (SCREEN_W - w) // 2 & ~1
    packed = pack(img)
    # the game's result: see-through pixels keep the picture's
    for ry in range(h):
        for bx in range(w // 2):
            b = packed[ry * (w // 2) + bx]
            a = (y + ry) * 160 + x // 2 + bx
            m = (0xF0 if b & 0xF0 == 0 else 0) | (0x0F if b & 0x0F == 0 else 0)
            pic[a] = (pic[a] & m) | b
    with open(os.path.join(outdir, 'title_expected.bin'), 'wb') as f:
        f.write(pic)
    return bytes(packed), {'PROMPTOFF': y * 160 + x // 2, 'PROMPTW': w // 2, 'PROMPTH': h}


def first_view(path, tiles, cells, sprites, top, side):
    """A picture of what the IIgs should show at the start of the map in
    use: the first view, the top bar and the sidebar (its radar off: there
    is no radar center yet)."""
    units = unit_records()
    seen = seen_tiles(units)

    screen = blank(SCREEN_W, SCREEN_H)
    for y in range(TOP_H):
        screen[y] = top[y][:]
    for y in range(len(side)):
        screen[TOP_H + y][SIDE_X:] = side[y]
    cx, cy = CAMERA0
    over = dict(building_overlays(sprites))
    for vy in range(VIEW_ROWS):
        for vx in range(VIEW_COLS):
            t = (cy + vy) * MAP_COLS + cx + vx
            if t not in seen:
                for y in range(16):
                    screen[TOP_H + vy * 16 + y][vx * 16:vx * 16 + 16] = [CLEAR] * 16
                continue
            for y in range(16):
                screen[TOP_H + vy * 16 + y][vx * 16:vx * 16 + 16] = tiles[cells[t]][y]
            if t in over:
                paste(screen, sprites[SPRITE_ORDER[over[t]]], vx * 16, TOP_H + vy * 16)
            bits = drawn_edges(fog_bits(seen, t))
            for i, name in enumerate(FOG_NAMES):
                if bits >> i & 1:
                    for y, row in enumerate(sprites[name]):
                        for x, p in enumerate(row):
                            if p:
                                screen[TOP_H + vy * 16 + y][vx * 16 + x] = CLEAR
    for spr, tile, flags, *_ in units:
        if flags & F_BUILDING or (not flags & F_PLAYER and tile not in seen):
            continue
        x = (tile % MAP_COLS - cx) * 16
        y = (tile // MAP_COLS - cy) * 16
        if 0 <= x < SIDE_X and 0 <= y < VIEW_ROWS * 16:
            paste(screen, sprites[SPRITE_ORDER[spr + (flags & (F_LEFT | F_VERT)) // F_LEFT]],
                  x, TOP_H + y)
    paste(screen, sprites['cur_arrow'], *CURSOR_START)
    write_png(path, screen)


def main(outdir):
    os.makedirs(outdir, exist_ok=True)

    def put(name, data):
        with open(os.path.join(outdir, name), 'wb') as f:
            f.write(data)

    packed = {}

    def put_rle(name, raw):
        code = rle(raw)
        assert unrle(code) == raw
        put(name, code)
        packed[name] = code

    put('palette.bin', b''.join(
        struct.pack('<H', (r << 8) | (g << 4) | b) for r, g, b in PALETTE))

    tiles, maps = make_tileset()
    assert len(tiles) <= 256
    for i in range(len(MAPS)):
        use_map(i)
        map_checks()
    use_map(0)
    # per tile graphic: 1 = ore (drawn mined-out when its ore is gone)
    ore_tiles = set()
    for i, cells in enumerate(maps):
        ore_tiles |= {cells[k] for k, ch in enumerate(''.join(MAPS[i]['rows'])) if ch == 'o'}
    put('tileflags.bin', bytes(1 if t in ore_tiles else 0 for t in range(len(tiles))))

    sprites = make_sprites()
    # sprite pixels (color 0 = transparent; the game derives the masks),
    # then the map tiles; unpacked into a spare bank at start
    put_rle('sprites.rle', b''.join(pack(sprites[k]) for k in SPRITE_ORDER) +
            b''.join(pack(t) for t in tiles))

    # the maps, each a packed block
    for i, cells in enumerate(maps):
        use_map(i)
        put_rle('map%d.rle' % i, map_block(tiles, cells, sprites))
    use_map(0)
    cells = maps[0]
    units = unit_records()

    # the options screen
    opts, areas = options_screen()
    put_rle('options.rle', pack(opts))
    # CONQUER.HELP: the instruction pages, packed, loaded at start into
    # bank HELPBANK at HELPADDR (above the lose banner's layer)
    helpdata, helpoffs = bytearray(), []
    for page in help_pages():
        helpoffs.append(HELP_ADDR + len(helpdata))
        helpdata += rle(pack(page))
    assert HELP_ADDR + len(helpdata) <= 0x10000
    put('conquer.help', bytes(helpdata))
    put('helptab.bin', b''.join(struct.pack('<H', a) for a in helpoffs))
    tab = bytearray()
    for x0, y0, x1, y1, act, press in areas:
        tab += struct.pack('<8H', x0, y0, x1, y1, act, y0 * 160 + x0 // 2,
                           (x1 - x0 + 1) // 2 if press else 0, y1 - y0 + 1)
    tab += struct.pack('<H', 0xFFFF)
    put('opttab.bin', bytes(tab))
    put('optbtn.bin', bytes(OPT_ON.get(c, c) for c in range(16)))
    markers = opt_markers()
    put('optmark.bin', b''.join(struct.pack('<2H', off, cb) for dots in markers
                                for off, cb, *_ in dots))
    radars = []
    for i, c in enumerate(maps):
        use_map(i)
        radars.append(preview_terrain(tiles, c))
    use_map(0)
    # as the game should show it: at first, with HARD and the second map
    # chosen, and then the music off too (for tools/optionstest.lua)
    hard = len(DIFFICULTIES) - 1
    for name, diff, mapno, off in (('options_expected.bin', DIFF0, 0, 0),
                                   ('options_expected2.bin', hard, 1, 0),
                                   ('options_expected3.bin', hard, 1, 1)):
        expect = options_expected(opts, radars, markers, diff, mapno, off)
        if mapno == 0:
            write_png(os.path.join(outdir, 'options_preview.png'), expect)
        shr = bytearray(pack(expect)) + bytes(0x7E00 - 32000)
        shr += b''.join(struct.pack('<H', (r << 8) | (g << 4) | b) for r, g, b in PALETTE)
        shr += bytes(32768 - len(shr))
        put(name, bytes(shr))
    # what the test scripts need to know about it
    with open(os.path.join(outdir, 'options.lua'), 'w') as f:
        f.write('-- generated by tools/makegfx.py: the options screen\n')
        f.write('return {\n  areas = {\n')
        for x0, y0, x1, y1, act, press in areas:
            f.write('    {x0 = %d, y0 = %d, x1 = %d, y1 = %d, act = %d, press = %d},\n'
                    % (x0, y0, x1, y1, act, press))
        f.write('  },\n}\n')

    # the difficulties: the enemy's numbers (frames, not seconds)
    put('difftab.bin', b''.join(struct.pack("<7H", cr, share, first * 60, gap * 60, w0, wmax, mx)
                                for _, cr, share, first, gap, w0, wmax, mx in DIFFICULTIES))

    # the name tags: images one after the other, their offsets and widths
    # (bytes), and the tag of each unit sprite
    tags = labels()
    tagdata, tagtab = bytearray(), bytearray()
    for name, img in tags:
        tagtab += struct.pack('<2H', len(tagdata), len(img[0]) // 2)
        tagdata += pack(img)
    radoff = len(tagdata)                       # (then the radar offline,
    tagdata += pack(radar_offline())            #   and the maps' names)
    mapnames = len(tagdata)
    for m in MAPS:
        tagdata += pack(map_name_image(m['name']))
    put_rle('labels.rle', bytes(tagdata))
    put('labtab.bin', bytes(tagtab))
    tagno = {name: i for i, (name, _) in enumerate(tags)}
    put('sprlabel.bin', bytes(tagno.get(n, 255) for n in SPRITE_ORDER))
    labeladdr = (len(SPRITE_ORDER) + len(tiles)) * 128
    assert labeladdr + len(tagdata) <= 0x10000
    with open(os.path.join(outdir, 'labels.lua'), 'w') as f:
        f.write('-- generated by tools/makegfx.py: the name tags: number, offset\n')
        f.write('-- from LABELADDR in the sprite bank, bytes across\nreturn {\n')
        for i, (name, img) in enumerate(tags):
            f.write('  %s = {n = %d, off = %d, w = %d},\n' % (
                name, i, struct.unpack_from('<H', tagtab, i * 4)[0], len(img[0]) // 2))
        f.write('}\n')
    write_png(os.path.join(outdir, 'labels.png'),
              [row for _, img in tags for row in [r + [INK] * (80 - len(r)) for r in img]], scale=3)

    put('glyphs.bin', b''.join(pack(g) for g in digit_glyphs()))

    tmpl = templates()
    put('templates.bin', b''.join(struct.pack('<15H', *rec) for _, rec in tmpl))
    assert all(len(rec) * 2 == TMPLSZ for _, rec in tmpl)
    names = [n for n, _ in tmpl]
    icons = bytearray()
    for i, name in enumerate(ICON_UNITS):
        x0, y0, x1, y1 = icon_box(i)
        bx, by = icon_bar(i)
        rx, ry = icon_ready_pos(i)
        assert bx % 2 == 0 and rx % 2 == 0 and x0 % 2 == 0 and (x1 - x0 + 1) // 2 == ICONWB
        sx, sy = SIDE_X + bx, TOP_H + by
        icons += struct.pack('<11H', SIDE_X + x0, TOP_H + y0, SIDE_X + x1, TOP_H + y1,
                             names.index(name) * TMPLSZ,
                             sy * 160 + sx // 2,
                             names.index(NEEDS[name]) * TMPLSZ if name in NEEDS else 0xFFFF,
                             sx, sy, icon_queue(name) * 2,
                             (TOP_H + ry) * 160 + (SIDE_X + rx) // 2)
    icons += struct.pack('<H', 0xFFFF)
    assert len(icons) == len(ICON_UNITS) * ICONSZ + 2
    put('icons.bin', bytes(icons))
    # icon middles on screen, for the test scripts
    with open(os.path.join(outdir, 'icons.lua'), 'w') as f:
        f.write('-- generated by tools/makegfx.py: screen x, y of each build icon, its number\n')
        f.write('return {\n')
        for i, name in enumerate(ICON_UNITS):
            x0, y0, x1, y1 = icon_box(i)
            f.write('  %s = {%d, %d, n = %d},\n' % (name, SIDE_X + (x0 + x1) // 2,
                                                     TOP_H + (y0 + y1) // 2, i))
        f.write('}\n')
    put('aiorder.bin', b''.join(struct.pack('<H', names.index(n) * TMPLSZ) for n in AI_BUILDS))
    dmg = bytearray(16)
    for w, row in DAMAGE.items():
        for a, f in enumerate(row):
            dmg[w * 4 + a] = f
    put('dmgtab.bin', bytes(dmg))
    put('ready.bin', pack(ready_label()))
    assert BANNER_X % 2 == 0 and (END_Y - TOP_H) % 16 == 0 and END_H % 16 == 0
    for name, title, color in (('win.rle', "MISSION ACCOMPLISHED", GOLD),
                               ('lose.rle', "MISSION FAILED", RED)):
        layer = blank(SCREEN_W, SCREEN_H)
        paste_all(layer, banner(title, color), BANNER_X, END_Y)
        put_rle(name, pack(layer))
    # the pause panel: a layer like those, only its own rows (the game
    # unpacks it into the win banner's bank at $A000)
    assert (PAUSE_Y - TOP_H) % 16 == 0 and PAUSE_H % 16 == 0
    assert PAUSE_Y <= END_Y and PAUSE_Y + PAUSE_H >= END_Y + END_H
    layer = blank(SCREEN_W, PAUSE_H)
    paste_all(layer, pause_panel(), BANNER_X, 0)
    assert 0xA000 + len(layer) * 160 <= 0x10000
    put_rle('pause.rle', pack(layer))

    ring = bytearray()
    for dx, dy in ring_offsets():
        ring += struct.pack('<hh', dx, dy)
    ring += struct.pack('<H', 0x8000)
    put('ringtab.bin', bytes(ring))

    # sight circles: for radius r (0-7), half widths of its rows at
    # r * 16 + dy + r
    sight = bytearray(16 * (MAX_SIGHT + 1))
    for r in range(MAX_SIGHT + 1):
        for i, w in enumerate(sight_widths(r)):
            sight[r * 16 + i] = w
    put('sight.bin', bytes(sight))
    assert all(sight_radius(f, rng) <= MAX_SIGHT
               for _, (_, f, _, _, rng, *_) in templates())
    # the game keeps one code entry per sprite and tile (SPCODE, 256), and
    # compiles the sprites into bank 6 below the screen copier at $F000 and
    # the map tiles into bank 9: per word
    # of 4 pixels LDA/STA (6 bytes) when solid or a tile, LDA/AND/ORA/STA
    # (12) when partly see-through, nothing when empty; RTL at the end
    assert len(SPRITE_ORDER) + len(tiles) <= 256

    def code(img, tile=False):
        n = 1
        for row in img:
            for k in range(0, 16, 4):
                px = row[k:k + 4]
                n += 6 if tile or all(px) else 12 if any(px) else 0
        return n
    compiled = sum(code(sprites[k]) for k in SPRITE_ORDER)       # (bank 6)
    tilecode = sum(code(t, True) for t in tiles)                    # (bank 9)
    assert compiled <= 0xF000 and tilecode <= 0x10000, (compiled, tilecode)
    put('btnmap.bin', bytes(BUTTON_ON.get(c, c) for c in range(16)))
    # the bytes a pressed button changes must not reach past its edges
    for i in range(2):
        x0, x1, _ = BUTTONS[i]
        off, nb, _ = button_bytes(i)
        for sx in ((off % 160) * 2, (off % 160 + nb) * 2 - 1):
            if not SIDE_X + x0 <= sx <= SIDE_X + x1:
                assert BUTTON_ON.get(STEEL_D, STEEL_D) == STEEL_D

    equ = {'NSPRITES': len(SPRITE_ORDER),
           'SPR_SELECT': SPRITE_ORDER.index('select'),
           'SPR_ARROW': SPRITE_ORDER.index('cur_arrow'),
           'SPR_MOVE': SPRITE_ORDER.index('cur_move'),
           'SPR_ATTACK': SPRITE_ORDER.index('cur_attack'),
           'SPR_HIT': SPRITE_ORDER.index('hit'),
           'SPR_BOOM0': SPRITE_ORDER.index('boom0'),
           'SPR_BOOM1': SPRITE_ORDER.index('boom1'),
           'F_PLAYER': F_PLAYER, 'F_SEL': F_SEL, 'F_LEFT': F_LEFT, 'F_VERT': F_VERT,
           'F_DEAD': F_DEAD, 'F_CHASE': F_CHASE, 'F_STATIC': F_STATIC,
           'F_HARV': F_HARV, 'F_DIRTY': F_DIRTY,
           'CREDITS0': CREDITS0, 'CREDX': CREDX, 'CAPACITY': CAPACITY,
           'TILE_EMPTY': len(tiles) - 2, 'TILE_SHROUD': len(tiles) - 1,
           'SPR_FOG': SPRITE_ORDER.index('fog_n'), 'TMPLSZ': TMPLSZ, 'ICONSZ': ICONSZ,
           **{'TMPL_' + n.upper().replace('_', ''): names.index(n) * TMPLSZ
              for n in ('hq_p', 'bar_p', 'bar_e', 'fact_p', 'fact_e', 'ref_p', 'ref_e',
                        'radar_p', 'pp_e', 'pp_p', 'harv_p', 'harv_e')},
           'BARSEGS': BARSEGS, 'ICONWB': ICONWB,
           'RADOFFADDR': labeladdr + radoff,
           'MAPNAMES': labeladdr + mapnames, 'MAPNAMEW': 48, 'MAPNAMEH': OPT_BTN_H,
           'MAPNAMESZ': 48 * OPT_BTN_H,
           'NAMEOFF': OPT_NAME_Y * 160 + OPT_PREV_X // 2,
           'PAUSEROWS': BANNER_Y + BANNER_H,
           **{k: v for i, (x0, x1, _) in enumerate(PAUSE_BTNS)
              for k, v in ((('PRESX0', 'PQUITX0')[i], BANNER_X + x0),
                           (('PRESX1', 'PQUITX1')[i], BANNER_X + x1))},
           'PBTNY0': PAUSE_Y + PAUSE_BTN_Y[0], 'PBTNY1': PAUSE_Y + PAUSE_BTN_Y[1],
           'PAUSEY0': PAUSE_Y, 'PAUSEY1': PAUSE_Y + PAUSE_H, 'PAUSEBANDS': PAUSE_H // 16,
           'PAUSEOFF': (0x8000 - PAUSE_Y * 160) & 0xFFFF,
           'NGLYPHS': len(GLYPHS), 'NTILES': len(tiles), 'SCOOP': SCOOP,
           'MAPW': MAP_COLS, 'MAPH': MAP_ROWS,
           'RADX': SIDE_X + RADAR_X, 'RADY': TOP_H + RADAR_Y,
           'RADW': RADAR_W, 'RADH': RADAR_H,
           'POWX': POWX, 'HQ_POWER': HQ_POWER, 'PLACERANGE': PLACE_RANGE,
           'POWBAROFF': (TOP_H + POWBAR_Y) * 160 + (SIDE_X + POWBAR_X) // 2,
           'POWBARN': POWBAR_STEPS, 'POWBARX': SIDE_X + POWBAR_X,
           'POWBARY': TOP_H + POWBAR_Y,
           'H_IDLE': H_IDLE, 'H_SEEK': H_SEEK, 'H_GOTO': H_GOTO,
           'H_MINE': H_MINE, 'H_HOME': H_HOME, 'H_UNLOAD': H_UNLOAD,
           'H_WAIT': H_WAIT, 'HARVWAIT': HARV_WAIT, 'AIHARVT': AI_HARV_SECS * 60,
           'ORESCOOPS': ORE_PER_TILE // SCOOP, 'GROWMASK': GROW_FRAMES - 1,
           'GROWSCOOPS': GROW_SCOOPS, 'ORELMAX': ORE_TILES,
           'F_BUILDING': F_BUILDING, 'F_AI': F_AI, 'F_AMOVE': F_AMOVE,
           'NDIFF': len(DIFFICULTIES), 'DIFF0': DIFF0, 'NMAPS': len(MAPS),
           **{'MB_' + name: sum(n for _, n in MAP_BLOCK[:k]) for k, (name, _) in enumerate(MAP_BLOCK)},
           'MB_SIZE': sum(n for _, n in MAP_BLOCK),
           'LABELADDR': labeladdr, 'NLABELS': len(tags), 'LABELH': LABEL_H,
           'LBL_ICON0': tagno['icon0'],
           'PREVOFF': OPT_PREV_Y * 160 + OPT_PREV_X // 2,
           'PREVW': RADAR_W, 'PREVH': RADAR_H * 2,
           'NAIORDER': len(AI_BUILDS), 'NICONS': len(ICON_UNITS), 'NQUEUES': len(QUEUES),
           'QMAX': QUEUE_MAX, 'BADGE0': 3 * len(GLYPHS),
           **{'SPR_' + u.upper(): SPRITE_ORDER.index(u) for u in UNIT_TYPES},
           'WPN_ROCKETS': ROCKETS,
           'BANNEROFF': BANNER_Y * 160 + BANNER_X // 2,
           'BANNERW': BANNER_W // 2, 'BANNERH': BANNER_H,
           'BANNERX0': BANNER_X, 'BANNERX1': BANNER_X + BANNER_W,
           'ENDY0': END_Y, 'ENDY1': END_Y + END_H, 'ENDBANDS': END_H // 16,
           'STATADDR': (END_Y + STAT_Y0 - 1) * 160 + (BANNER_X + STAT_X) // 2,
           'STATSTEP': STAT_DY * 160,
           'TIMEADDR': (END_Y + STAT_Y0 - 1 + 4 * STAT_DY) * 160 + (BANNER_X + TIME_X) // 2,
           'STATGLYPHS': 4 * len(GLYPHS),
           'BANNERY0': BANNER_Y, 'BANNERY1': BANNER_Y + BANNER_H,
           'CURX0': CURSOR_START[0], 'CURY0': CURSOR_START[1],
           'SPR_SELL': SPRITE_ORDER.index('cur_sell'),
           'SPR_REPAIR': SPRITE_ORDER.index('cur_repair'),
           'SPR_NO': SPRITE_ORDER.index('cur_no'),
           'MODE_SELL': MODE_SELL, 'MODE_REPAIR': MODE_REPAIR,
           'REPAIRSTEP': REPAIR_STEP, 'REPAIRHP': REPAIR_HP,
           'REPAIRCOST': REPAIR_COST,
           'BTNY0': TOP_H + BUTTON_Y0, 'BTNY1': TOP_H + BUTTON_Y1,
           'BTNH': BUTTON_Y1 - BUTTON_Y0 + 1, 'BTNROW': (TOP_H + BUTTON_Y0 + 8) // 16,
           'SELLX0': SIDE_X + BUTTONS[0][0], 'SELLX1': SIDE_X + BUTTONS[0][1],
           'REPX0': SIDE_X + BUTTONS[1][0], 'REPX1': SIDE_X + BUTTONS[1][1],
           'SELLOFF': button_bytes(0)[0], 'SELLW': button_bytes(0)[1],
           'SELLCOL': button_bytes(0)[2],
           'REPOFF': button_bytes(1)[0], 'REPW': button_bytes(1)[1],
           'REPCOL': button_bytes(1)[2]}
    with open(os.path.join(outdir, 'gfxequ.s'), 'w') as f:
        f.write('* generated by tools/makegfx.py\n')
        for k, v in equ.items():
            f.write('%-10s equ   %d\n' % (k, v))

    top = make_topbar()
    side = make_sidebar(tiles)
    ui = blank(SCREEN_W, SCREEN_H)
    paste_all(ui, top, 0, 0)
    paste_all(ui, side, SIDE_X, TOP_H)
    put_rle('ui.rle', pack(ui))

    # CONQUER.DATA: the packed screens and sprites, loaded by the game at start
    # into a bank of its own (DATABANK, see main.s), and the
    # CLICK TO START line it draws on the title picture
    prompt, pinfo = title_prompt(outdir)
    data, offsets = bytearray(), {}
    for name, key in (('ui.rle', 'DATA_UI'), ('win.rle', 'DATA_WIN'),
                      ('lose.rle', 'DATA_LOSE'), ('pause.rle', 'DATA_PAUSE'),
                      ('sprites.rle', 'DATA_SPR'),
                      ('options.rle', 'DATA_OPTS'), ('labels.rle', 'DATA_LABELS'),
                      *(('map%d.rle' % i, 'DATA_MAP%d' % i) for i in range(len(MAPS)))):
        offsets[key] = len(data)
        data += packed[name]
    offsets['DATA_PROMPT'] = len(data)
    data += prompt
    offsets.update(pinfo)
    offsets['NHELP'] = len(help_texts())
    offsets['HELPADDR'] = HELP_ADDR
    offsets['HELPBTNY'] = HELP_BTN_Y
    offsets['HELPSIZE'] = os.path.getsize(os.path.join(outdir, 'conquer.help'))
    assert len(data) <= 0x10000                 # (a bank of its own, see main.s)
    assert (len(SPRITE_ORDER) + len(tiles)) * 128 <= 0x8000   # (the sprite bank)
    put('conquer.data', bytes(data))
    put('maptab.bin', b''.join(struct.pack('<H', offsets['DATA_MAP%d' % i])
                               for i in range(len(MAPS))))

    with open(os.path.join(outdir, 'gfxequ.s'), 'a') as f:
        for k, v in offsets.items():
            f.write('%-10s equ   %d\n' % (k, v))
        f.write('%-10s equ   %d\n' % ('DATASIZE', len(data)))

    # what the game draws over that at the start: numbers, power bar, the
    # soldier icons greyed out (no barracks yet), the radar off (no radar
    # center)
    use_map(0)
    have = {name for name, _, _ in BUILDINGS if name.endswith('_p')}
    made = sum(STRUCTS[n][7] for n in have if STRUCTS[n][7] > 0)
    used = -sum(STRUCTS[n][7] for n in have if STRUCTS[n][7] < 0)
    topbar_numbers(top, CREDITS0, used, made)
    power_bar(side, used, made)
    for i, name in enumerate(ICON_UNITS):
        if name in NEEDS and NEEDS[name] not in have:
            icon_dim(side, i)
    paste_all(side, radar_offline(), RADAR_X, RADAR_Y)

    for i, cells in enumerate(maps):
        use_map(i)
        first_view(os.path.join(outdir, 'preview.png' if i == 0 else 'preview%d.png' % (i + 1)),
                   tiles, cells, sprites, top, side)
    use_map(0)

    # the sidebar's lower part with each button pressed and the new
    # cursors, enlarged (for looking at, not used by the game)
    look = blank(SIDE_W * 2 + 4 + 64, 40, STEEL_D)
    for i in range(2):
        part = [row[:] for row in side[150:190]]
        press_button(part, i, 0, -150)
        for y in range(40):
            look[y][i * (SIDE_W + 4):i * (SIDE_W + 4) + SIDE_W] = part[y]
    for k, name in enumerate(['cur_sell', 'cur_repair', 'cur_no']):
        paste(look, sprites[name], SIDE_W * 2 + 8 + k * 18, 12)
    write_png(os.path.join(outdir, 'buttons.png'), look, scale=4)
    print('%d tiles, %d sprites (%d bytes of code), %d maps, %d name tags; CONQUER.DATA '
          '%d bytes' % (len(tiles), len(SPRITE_ORDER), compiled, len(MAPS), len(tags), len(data)))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'build/gfx')
