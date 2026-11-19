#!/usr/bin/env python3
"""The game's Finder icon: the Iron Guard's badge (a steel gauntlet
gripping lightning on blue enamel in a gold rim), the same as Conquer GS 2's.

- CONQUER.ICONS, a GS/OS Finder icon file ($CA; File Type Note $CA): one
  record for CONQUER.SYSTEM (type $FF), a normal and a small icon. The
  Finder looks for it in the disk's ICONS folder. An icon pixel is 4 bits,
  drawn in the Finder's 640 mode as two screen pixels: one black, red,
  green or white (bits 3-2), the other black, blue, yellow or white (bits
  1-0) - so its 16 colors are those mixes. The big icon is hand-pixeled.

    python3 tools/makeicons.py build/gfx
"""
import math
import os
import struct
import sys
import zlib

# the Finder's colors, as their two pixels (for previews)
HIGH = [(0, 0, 0), (221, 0, 0), (0, 238, 0), (255, 255, 255)]
LOW = [(0, 0, 0), (0, 0, 255), (255, 255, 0), (255, 255, 255)]
KEY = {'k': 0x0, 'n': 0x1, 'l': 0xD, 'g': 0x2, 'y': 0xE, 'G': 0xC, 'w': 0xF}
# black, dark blue (black+blue), light blue (white+blue), dark gold
# (black+yellow), pale yellow (white+yellow), grey (white+black), white

FIST = [  # 20 x 17, on the badge: bolts above and below, the fist, its arm
    "...........y........",
    "..........yy....y...",
    "....y.....y....yy...",
    ".....y....yy..yy....",
    "......yy...yyyy.....",
    "........kkkkkk......",
    ".......kwwwwwwk.....",
    "......kwGGGGGGGk....",
    "......kwkkkkkkGk....",
    ".....kkwGGkGkGGk....",
    "....kwGkGGkGkGGk....",
    "...kwGGkkGGGGGk.....",
    "..kwGGGk.kkkkk......",
    ".kwGGGk...yy........",
    "kwGGGk...yy.y.......",
    "kGGGk.....yy........",
    "kkkk.......y........",
]
SMALL = [  # 10 x 8
    "..kkkkkk..",
    ".kgnnyngk.",
    "kgnnyyGnnk",
    "kgnGGGGngk",
    "kgkGGGknngk"[:10],
    "kgnnyknngk",
    ".kgnynngk.",
    "..kkkkkk..",
]


def badge(W, H):
    """The rim and the enamel, as Finder colors (None: not part of it)."""
    cx, cy, rx, ry = (W - 1) / 2, (H - 1) / 2, W / 2, H / 2
    out = [[None] * W for _ in range(H)]
    for y in range(H):
        for x in range(W):
            d = math.hypot((x - cx) / rx, (y - cy) / ry)
            lit = (x - cx) / rx + (y - cy) / ry < 0
            if d > 1.0:
                continue
            c = 'k' if d > 0.93 else 'g' if d > 0.80 else 'k' if d > 0.74 \
                else 'l' if d > 0.66 and lit else 'n'
            out[y][x] = KEY[c]
    return out


def big_icon():
    ic = badge(28, 23)
    for y, row in enumerate(FIST):
        for x, ch in enumerate(row):
            if ch != '.':
                ic[3 + y][4 + x] = KEY[ch]
    return ic


def small_icon():
    return [[None if ch == '.' else KEY[ch] for ch in row] for row in SMALL]


def icon_record(ic, color=True):
    """QuickDraw II icon: type, size, height, width, image, mask (4 bits a
    pixel, the left one in the high nibble)."""
    H, W = len(ic), len(ic[0])
    bpr = (W + 1) // 2
    img, mask = bytearray(), bytearray()
    for row in ic:
        row = row + [None] * (bpr * 2 - W)
        for i in range(0, bpr * 2, 2):
            a, b = row[i], row[i + 1]
            img.append(((0xF if a is None else a) << 4) | (0xF if b is None else b))
            mask.append((0 if a is None else 0xF0) | (0 if b is None else 0x0F))
    return struct.pack('<4H', 0x8000 if color else 0, len(img), H, W) + bytes(img) + bytes(mask)


def pstr(s, n):
    b = bytes([len(s)]) + s.encode('ascii')
    assert len(b) <= n
    return b + bytes(n - len(b))


def icon_file():
    big, small = icon_record(big_icon()), icon_record(small_icon())
    out = struct.pack('<IHI', 0, 1, 0) + pstr('CONQUER.ICONS', 16)
    for name in ('CONQUER.SYSTEM',):
        rec = pstr('', 64) + pstr(name, 16) + struct.pack('<HH', 0x00FF, 0) + big + small
        out += struct.pack('<H', len(rec) + 2) + rec
    return out + struct.pack('<H', 0)


def png(path, rows):
    """rows: lists of (r, g, b)."""
    H, W = len(rows), len(rows[0])
    raw = b''.join(b'\0' + bytes(c for px in row for c in px) for row in rows)
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d))
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))
                           + ch(b'IDAT', zlib.compress(raw, 9)) + ch(b'IEND', b''))


def finder_preview(ic, scale=12, bg=(200, 200, 200)):
    """How the Finder shows it (the two pixels of each mixed), rows a bit
    taller (the IIgs' pixels)."""
    sy = int(scale * 1.2)
    rows = []
    for row in ic:
        line = []
        for c in row:
            col = bg if c is None else tuple((HIGH[c >> 2][k] + LOW[c & 3][k]) // 2 for k in range(3))
            line += [col] * scale
        rows += [line] * sy
    return rows


def main(outdir):
    open(os.path.join(outdir, 'conquer.icons'), 'wb').write(icon_file())
    png(os.path.join(outdir, 'finder_icon.png'), finder_preview(big_icon()))
    png(os.path.join(outdir, 'finder_small.png'), finder_preview(small_icon()))


if __name__ == '__main__':
    main(sys.argv[1])
