#!/usr/bin/env python3
"""Render a 32K Super Hi-Res memory dump ($E1/2000-$9FFF) to PNG (320 mode).
A screen with every line on palette 0 (the game's) comes out exactly as
makegfx.py writes its previews; one using several palettes (the title
picture) in full color, line by line."""
import struct, sys, zlib
sys.path.insert(0, __import__('os').path.dirname(__file__))
import makegfx

data = open(sys.argv[1], 'rb').read()
scb = data[0x7D00:0x7DC8]


def palette(p):
    out = []
    for i in range(16):
        w = struct.unpack_from('<H', data, 0x7E00 + p * 32 + i * 2)[0]
        out.append(((w >> 8) & 15, (w >> 4) & 15, w & 15))
    return out


img = [[0] * 320 for _ in range(200)]
for y in range(200):
    for x in range(160):
        b = data[y * 160 + x]
        img[y][2 * x], img[y][2 * x + 1] = b >> 4, b & 15
if not any(s & 15 for s in scb):
    pal = palette(0)
    print('palette 0:', ' '.join('%X%X%X' % c for c in pal))
    makegfx.PALETTE[:] = pal
    makegfx.write_png(sys.argv[2], img)
else:
    pals = [palette(p) for p in range(16)]
    print('palettes per line:', len(set(s & 15 for s in scb)))
    raw = bytearray()
    for y in range(200):
        pal = pals[scb[y] & 15]
        row = bytearray()
        for n in img[y]:
            r, g, b = pal[n]
            row += bytes((r * 17, g * 17, b * 17)) * 2
        for _ in range(2):
            raw += b'\0' + row

    def chunk(kind, body):
        c = kind + body
        return struct.pack('>I', len(body)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)
    with open(sys.argv[2], 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 640, 400, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(bytes(raw), 9)) + chunk(b'IEND', b''))
