#!/usr/bin/env python3
"""Check a MAME recording of the title music (tools/musictest.lua, run with
-wavwrite) against tools/makemusic.py's own rendering of the score: the
same loudness over time, a loop every STEPS * FPS / 60 seconds, each bar's
bass on its chord's root, both channels, silence once the game runs, and
then a sound effect that still plays.

usage: musiccheck.py recording.wav musictest.log"""
import math
import os
import re
import struct
import sys
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import makemusic

wav, log = sys.argv[1], sys.argv[2]
times = {}
for line in open(log):
    for key, pat in (('start', r'music playing at ([\d.]+)'), ('click', r'click at ([\d.]+)'),
                     ('game', r'game running at ([\d.]+)'), ('play', r'play place at ([\d.]+)'),
                     ('end', r'end at ([\d.]+)')):
        m = re.search(pat, line)
        if m:
            times[key] = float(m.group(1))

w = wave.open(wav)
ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
raw = struct.unpack('<%dh' % (n * ch), w.readframes(n))
peaks = sorted(range(ch), key=lambda c: -max(abs(v) for v in raw[c::ch]))
left, right = raw[peaks[0]::ch], raw[peaks[1]::ch]


def envelope(x, srate, ms=1000 * makemusic.FPS / 120, hop=10):
    """RMS loudness over windows of half a step (shorter ones would follow
    the bass waves' phase, which the chip and the render don't share),
    every hop ms."""
    sq = [0]
    for v in x:
        sq.append(sq[-1] + v * v)
    win, step = int(srate * ms / 1000), srate * hop / 1000
    out, i = [], 0.0
    while int(i) + win < len(x):
        a = int(i)
        out.append(math.sqrt((sq[a + win] - sq[a]) / win))
        i += step
    return out


def corr(a, b):
    m = min(len(a), len(b))
    a, b = a[:m], b[:m]
    ma, mb = sum(a) / m, sum(b) / m
    num = sum((p - ma) * (q - mb) for p, q in zip(a, b))
    den = math.sqrt(sum((p - ma) ** 2 for p in a) * sum((q - mb) ** 2 for q in b))
    return num / den if den else 0.0


loop = makemusic.STEPS * makemusic.FPS / 60
bad = 0
ref = makemusic.render(loops=2)
renv = envelope(ref, makemusic.SCAN)
# the music began a step or two before the log's mark: find where
first = int((times['start'] - 0.5) * rate)
rec = envelope(left[first:first + int((2 * loop + 1) * rate)], rate)
c, lag = max((corr(rec[k:k + len(renv)], renv), k) for k in range(0, 80))
begin = first + lag * rate // 100
print('loudness over time like the score rendered by makemusic.py: %.3f (music from %.2f s)' % (
    c, begin / rate))
bad += c < 0.9
# a loop later it is the same again
e = envelope(left[begin:begin + int(2 * loop * rate)], rate)
p, best = max((corr(e[:int(loop * 100) - 50], e[k:k + int(loop * 100) - 50]), k)
              for k in range(int(loop * 100) - 60, int(loop * 100) + 60))
print('it repeats every %.2f s (the score: %.2f s), match %.3f' % (best / 100, loop, p))
bad += abs(best / 100 - loop) > 0.05 or p < 0.9
# each bar's bass: the strongest pitch from 40 to 140 Hz in its first half
# is its chord's root (low-passed before taking every 8th sample, so the
# higher voices can't fold down into that range)
NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
roots = {'Em': 'E', 'C': 'C', 'D': 'D', 'B': 'B'}
bar = loop / 8
sr = rate / 8
wrong, heard = [], []
for b, chord in enumerate(makemusic.CHORDS):
    x = left[begin + int(b * bar * rate):begin + int((b + 0.5) * bar * rate)]
    seg = [sum(x[i:i + 8]) for i in range(0, len(x) - 8, 8)]

    def strength(f):
        k = 2 * math.cos(2 * math.pi * f / sr)
        s1 = s2 = 0.0
        for v in seg:
            s1, s2 = v + k * s1 - s2, s1
        return s1 * s1 + s2 * s2 - k * s1 * s2
    f = max((40 + 0.5 * i for i in range(201)), key=strength)
    name = NAMES[round(12 * math.log2(f / 440) + 69) % 12]
    heard.append('%s %.0f Hz' % (name, f))
    if name != roots[chord]:
        wrong.append('bar %d: %s (%.1f Hz), not %s' % (b + 1, name, f, chord))
print('bass roots bar by bar: ' + ('all right (%s)' % ', '.join(heard) if not wrong
                                   else ', '.join(wrong)))
bad += len(wrong) > 0
# (MAME puts the right channel a sample or two after the left, as in
# tools/soundcheck.py)
lr = max(corr(left[begin:begin + rate], right[begin + k:begin + k + rate]) for k in range(-3, 4))
print('left = right: %.3f' % lr)
bad += lr < 0.99
# silent in the game, until it asks for a sound effect: that one plays
g0, g1 = int((times['game'] + 0.2) * rate), int(times['play'] * rate)
music_rms = math.sqrt(sum(v * v for v in left[begin:begin + rate * 5]) / (rate * 5))
game_rms = math.sqrt(sum(v * v for v in left[g0:g1]) / max(1, g1 - g0))
print('once the game runs: %.1f%% of the music\'s loudness' % (100 * game_rms / music_rms))
bad += game_rms > 0.02 * music_rms
p0 = int(times['play'] * rate)
fx_peak = max(abs(v) for v in left[p0:p0 + rate // 5])
print('then a sound effect: %s (peak %d)' % ('heard' if fx_peak > 1000 else 'NOT heard', fx_peak))
bad += fx_peak <= 1000
print('problems: %d' % bad)
sys.exit(1 if bad else 0)
