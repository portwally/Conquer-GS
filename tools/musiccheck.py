#!/usr/bin/env python3
"""Check a MAME recording of the music (tools/musictest.lua, run with
-wavwrite) against tools/makemusic.py's own rendering of the tunes: the
title tune at the title and the battle tune in the game, each with each
bar as loud as in the render, the same again a loop later and each bar's
bass on its chord's root, on both channels; in the game, the battle
tune's notes (frequencies) and volumes as the game told the chip, frame
by frame, the same as the score; the battle tune quieter than the title's; then silence after
the M key, a sound effect that still plays, and the music back after M
again.

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
                     ('game', r'game running at ([\d.]+)'), ('off', r'M pressed at ([\d.]+)'),
                     ('play', r'play place at ([\d.]+)'), ('on', r'M again at ([\d.]+)'),
                     ('end', r'end at ([\d.]+)')):
        m = re.search(pat, line)
        if m:
            times[key] = float(m.group(1))

w = wave.open(wav)
ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
raw = struct.unpack('<%dh' % (n * ch), w.readframes(n))
peaks = sorted(range(ch), key=lambda c: -max(abs(v) for v in raw[c::ch]))
left, right_ch = raw[peaks[0]::ch], raw[peaks[1]::ch]


def envelope(x, srate, ms, hop=10):
    """RMS loudness over windows of ms (half a step: shorter ones would
    follow the bass waves' phase, which the chip and the render don't
    share), every hop ms."""
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


def rms(a, b):
    a, b = int(a * rate), int(b * rate)
    return math.sqrt(sum(v * v for v in left[a:b]) / max(1, b - a))


NAMES = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']


def pitch_name(hz):
    return NAMES[round(12 * math.log2(hz / 440) + 69) % 12]


def goertzel(x, f, sr):
    """Strength of frequency f in the samples x."""
    k = 2 * math.cos(2 * math.pi * f / sr)
    s1 = s2 = 0.0
    for v in x:
        s1, s2 = v + k * s1 - s2, s1
    return s1 * s1 + s2 * s2 - k * s1 * s2


def tune_checks(tune, t0, seconds):
    """The tune recorded from about t0 for `seconds`: (problems, where it
    starts in samples)."""
    problems = 0
    loop = tune.seconds()
    ms = 1000 * tune.fps / 120
    ref = makemusic.render(loops=1, tune=tune)
    renv = envelope(ref, makemusic.SCAN, ms)
    first = int((t0 - 0.5) * rate)
    rec = envelope(left[first:first + int((loop + 2) * rate)], rate, ms)
    c, lag = max((corr(rec[k:k + len(renv)], renv), k) for k in range(0, 150))
    begin = first + lag * rate // 100
    # (a driving tune is about as loud all along, so this is mostly for
    # finding where it starts; what it plays is checked below)
    print('%s tune: from %.2f s, loudness over time like the render: %.3f' % (
        tune.name, begin / rate, c))
    problems += c < 0.75
    bar = loop / tune.bars
    # each bar as loud as in the render (scaled to the recording), and the
    # same again a loop later (as many bars as were recorded)
    rbar = [math.sqrt(sum(v * v for v in ref[int(b * bar * makemusic.SCAN):
                                              int((b + 1) * bar * makemusic.SCAN)])
                      / (bar * makemusic.SCAN)) for b in range(tune.bars)]
    mbar = [rms(begin / rate + b * bar, begin / rate + (b + 1) * bar) for b in range(tune.bars)]
    k = sum(mbar) / sum(rbar)
    off = max(abs(m / (k * r) - 1) for m, r in zip(mbar, rbar))
    again = [rms(begin / rate + loop + b * bar, begin / rate + loop + (b + 1) * bar)
             for b in range(tune.bars) if (b + 1) * bar < seconds - loop - 0.5]
    off2 = max(abs(a / m - 1) for a, m in zip(again, mbar))
    print('  each bar as loud as in the render: within %.0f%%; a loop later (%d bars): '
          'within %.0f%%' % (100 * off, len(again), 100 * off2))
    problems += off > 0.15 or off2 > 0.10
    # each bar's bass: the strongest pitch from 40 to 140 Hz in its first
    # half is its chord's root (low-passed before taking every 8th sample)
    sr = rate / 8
    wrong, heard = [], []
    for b, chord in enumerate(tune.chords):
        x = left[begin + int(b * bar * rate):begin + int((b + 0.5) * bar * rate)]
        seg = [sum(x[i:i + 8]) for i in range(0, len(x) - 8, 8)]
        f = max((40 + 0.5 * i for i in range(201)), key=lambda f: goertzel(seg, f, sr))
        name = pitch_name(f)
        root = pitch_name(makemusic.note_hz(tune.tones[chord][0]))
        heard.append(name)
        if name != root:
            wrong.append('bar %d: %s (%.1f Hz), not %s' % (b + 1, name, f, root))
    print('  bass roots bar by bar: ' + ('all right (%s)' % ' '.join(heard) if not wrong
                                         else ', '.join(wrong)))
    problems += len(wrong) > 0
    # both channels (MAME puts the right one a sample or two after the left)
    lr = max(corr(left[begin:begin + rate], right_ch[begin + k:begin + k + rate])
             for k in range(-3, 4))
    print('  left = right: %.3f' % lr)
    problems += lr < 0.99
    return problems, begin


def player_check(tune, path):
    """What the game told the music's oscillators in the game (musictest's
    log: frame, register, value) against the score: every note's frequency
    on both of its oscillators on its step's frame, and every frame's volume
    as the render has it. Returns problems."""
    steps, starts, freqs, _ = makemusic.encode()
    t0 = starts[makemusic.TUNES.index(tune)]
    regs, frames = {}, {}
    for line in open(path):
        fr, reg, val = map(int, line.split())
        frames.setdefault(fr, []).append((reg, val))
    # the frames where a tone voice got a new frequency (low byte, both sides)
    got = []                                    # (frame, voice, frequency)
    state = {}
    for fr in sorted(frames):
        for reg, val in frames[fr]:
            state[reg] = val
            if reg < 0x26 and (reg & 0x1F) < 6 and reg >= 0x20 and reg & 1:
                v = (reg & 0x1F) // 2           # (the right side's high byte:
                f = state[0x20 + 2 * v] << 8 | state.get(2 * v, 0)  # the last
                if f == state[0x20 + 2 * v + 1] << 8 | state.get(2 * v + 1, 0):
                    got.append((fr, v, f))      # of a note's four writes)
    want = []
    for k in range(tune.steps * 2):
        for v in range(3):
            e = steps[t0 + v * tune.steps + k % tune.steps]
            if e and e != 255:
                want.append((k * tune.fps, v, freqs[e - 1]))
    first = got[0][0] - want[0][0]              # (the tune's first frame)
    last = max(g[0] for g in got) - first
    want = [w for w in want if w[0] <= last]
    have = {(fr - first, v, f) for fr, v, f in got}
    right = sum(w in have for w in want)
    print('  the game told the chip %d of the score\'s %d notes (%.1f loops) on their '
          'frames' % (right, len(want), last / (tune.steps * tune.fps)))
    problems = right < len(want) or len(got) != len(want)
    # the volumes, frame by frame (the last value written holds)
    vol = {v: 0 for v in range(3)}
    env = [tune.envelopes[n] for n in ('bass', 'lead', 'arp')]
    sim = [0, 0, 0]
    mode = [0, 0, 0]
    wrong = 0
    for k in range(last + 1):
        if k % tune.fps == 0:                   # the render's step
            for v in range(3):
                e = steps[t0 + v * tune.steps + (k // tune.fps) % tune.steps]
                if e == 255:
                    mode[v] = 2
                elif e:
                    sim[v], mode[v] = env[v][0], 1
        for v in range(3):
            peak, decay, sustain, release = env[v]
            if mode[v] == 1:
                sim[v] = max(sustain, sim[v] - decay)
            elif mode[v] == 2:
                sim[v] = max(0, sim[v] - release)
                if sim[v] == 0:
                    mode[v] = 0
        for reg, val in frames.get(k + first, []):
            if 0x40 <= reg < 0x46:
                vol[(reg & 0x1F) // 2] = val
        wrong += any(vol[v] != sim[v] for v in range(3))
    print('  its volumes as in the render: %d of %d frames' % (last + 1 - wrong, last + 1))
    return problems + (wrong > 0)


bad = 0
p, tbegin = tune_checks(makemusic.TITLE, times['start'], times['click'] - times['start'])
bad += p
p, bbegin = tune_checks(makemusic.BATTLE, times['game'], times['off'] - times['game'])
bad += p
bad += player_check(makemusic.BATTLE, os.path.join(os.path.dirname(wav), 'musicwrites.txt'))
title_rms = rms(tbegin / rate, tbegin / rate + 10)
battle_rms = rms(bbegin / rate, bbegin / rate + 30)
print('the battle tune is %.0f%% as loud as the title tune' % (100 * battle_rms / title_rms))
bad += battle_rms > 0.9 * title_rms
quiet = rms(times['off'] + 0.3, times['play'] - 0.05)
print('after M: %.1f%% of the battle tune\'s loudness' % (100 * quiet / battle_rms))
bad += quiet > 0.02 * battle_rms
p0 = int(times['play'] * rate)
fx_peak = max(abs(v) for v in left[p0:p0 + rate // 5])
print('then a sound effect: %s (peak %d)' % ('heard' if fx_peak > 1000 else 'NOT heard', fx_peak))
bad += fx_peak <= 1000
back = rms(times['on'] + 0.5, times['end'] - 0.2)
print('after M again: %.0f%% of its loudness' % (100 * back / battle_rms))
bad += back < 0.3 * battle_rms
print('problems: %d' % bad)
sys.exit(1 if bad else 0)
