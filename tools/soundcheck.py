#!/usr/bin/env python3
"""Check a MAME recording made with tools/soundtest.lua against the sounds
tools/makesound.py made: each must start right after the game was asked
for it and be the same waveform (so the chip plays the sample at the
right rate, whole), the chime at the same pitches. Both stereo channels
must carry it.

usage: soundcheck.py recording.wav soundtest.log [build/gfx]"""
import math
import os
import re
import struct
import sys
import wave

wav, log = sys.argv[1], sys.argv[2]
gfx = sys.argv[3] if len(sys.argv) > 3 else 'build/gfx'

w = wave.open(wav)
ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
raw = struct.unpack('<%dh' % (n * ch), w.readframes(n))
# the DOC's two outputs: the recorded channels that carry the most
peaks = sorted(range(ch), key=lambda c: -max(abs(v) for v in raw[c::ch]))
left, right = raw[peaks[0]::ch], raw[peaks[1]::ch]


def load(name):
    s = wave.open(os.path.join(gfx, 'sounds', name + '.wav'))
    data = s.readframes(s.getnframes())
    return [b - 128 for b in data], s.getframerate()


def envelope(x, srate, ms=5):
    step = max(1, int(srate * ms / 1000))
    return [math.sqrt(sum(v * v for v in x[i:i + step]) / step) for i in range(0, len(x) - step, step)]


def corr(a, b):
    m = min(len(a), len(b))
    a, b = a[:m], b[:m]
    ma, mb = sum(a) / m, sum(b) / m
    num = sum((p - ma) * (q - mb) for p, q in zip(a, b))
    den = math.sqrt(sum((p - ma) ** 2 for p in a) * sum((q - mb) ** 2 for q in b))
    return num / den if den else 0.0


def tone(x, srate, f):
    """Strength of frequency f in x (Goertzel)."""
    k = 2 * math.cos(2 * math.pi * f / srate)
    s1 = s2 = 0.0
    for v in x:
        s1, s2 = v + k * s1 - s2, s1
    return math.sqrt(max(0.0, s1 * s1 + s2 * s2 - k * s1 * s2)) / len(x)


bad = 0
for line in open(log):
    m = re.match(r'play (\w+) at ([\d.]+) s', line)
    if not m:
        continue
    name, t = m.group(1), float(m.group(2))
    ref, rrate = load(name)
    start = int(t * rate)
    # the recording at the sample's own rate, from the request on; the
    # sample must be in it (waveform, not just loudness) within 60 ms
    step = rate / rrate
    def at(pos):                              # (between two recorded samples)
        k = int(pos)
        return left[k] + (left[k + 1] - left[k]) * (pos - k)
    rec = [at(start + i * step) for i in range(len(ref) + int(0.08 * rrate))]
    c, lag = max((corr(rec[k:k + len(ref)], ref), k) for k in range(0, int(0.06 * rrate)))
    on = start + int(lag * step)
    delay = lag / rrate * 1000
    seg_l = left[on:on + int(len(ref) / rrate * rate) + rate // 20]
    seg_r = right[on:on + len(seg_l)]
    # how long it is heard: up to its last loud moment (bursts have gaps)
    noise = max(abs(v) for v in left[start - rate // 10:start]) if start > rate // 10 else 0
    thresh = max(150, noise * 2)
    loud = [i for i, v in enumerate(seg_l) if abs(v) > thresh]
    got = (loud[-1] if loud else 0) / rate
    want = len(ref) / rrate
    # (the two channels are started one after the other: one may begin a
    # DOC sample, 1/26320 s, later)
    lr = max(corr(seg_l[:2000], seg_r[k:k + 2000]) for k in range(0, 4))
    lr = max(lr, max(corr(seg_l[k:k + 2000], seg_r[:2000]) for k in range(1, 4)))
    ok = c > 0.95 and lr > 0.99 and delay < 40
    extra = ''
    if name == 'ready':                       # the two tones of the chime
        a = seg_l[int(0.02 * rate):int(0.11 * rate)]
        b = seg_l[int(0.16 * rate):int(0.25 * rate)]
        pa = max((tone(a, rate, f), f) for f in range(600, 1500, 10))[1]
        pb = max((tone(b, rate, f), f) for f in range(600, 1500, 10))[1]
        extra = ', tones %d and %d Hz (made 784 and 1175)' % (pa, pb)
        ok = ok and abs(pa - 784) < 30 and abs(pb - 1175) < 40
    print('%-7s %s: starts %2.0f ms after the request, heard for %.2f s (made %.2f s), '
          'waveform like the original: %.3f, left = right: %.2f%s' % (
              name, 'ok' if ok else 'WRONG', delay, got, want, c, lr, extra))
    bad += not ok
print('problems: %d' % bad)
sys.exit(1 if bad else 0)
