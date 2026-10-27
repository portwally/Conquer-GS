#!/usr/bin/env python3
"""Synthesize the sound effects of Conquer GS and lay them out for the
Ensoniq DOC (the IIgs sound chip).

Writes into the output folder:
  conquer.sound  the DOC sound RAM image from address 0 (the game streams
                 it into the DOC at start)
  sndtab.bin     per sound: wavetable page, size/resolution, frequency,
                 volume, first oscillator, voices (the game sets up its
                 oscillators from it: two per voice, left and right, after
                 the music's ten)
  sndequ.s       equates: SND_<NAME> bits, NSOUNDS, SOUNDSIZE, and for
                 the title music's instruments (makemusic.py) their page
                 and size/resolution: PG_<NAME>, SR_<NAME>
  sounds/*.wav   each sound as a WAV file, to listen to

A sound with a recording in assets/sounds/<name>.wav (8-bit, 13,160 Hz,
mono, already prepared: see assets/sounds/CREDITS.txt) uses it; the others
are made here from sine waves and noise. Samples are 8-bit unsigned around
128; the DOC treats a 0 byte as the end of a one-shot sample, so they use
1-255 and end with a 0.
"""
import math
import os
import random
import struct
import sys
import wave

SCAN = 894886 / 34          # DOC scan rate with 32 oscillators (Hz)
RATE = SCAN / 2             # samples play at half of it: frequency 256
FREQ = 256                  #   with resolution = table size (shift 9)


def env_exp(t, tau):
    return math.exp(-t / tau)


class Noise:
    """White noise with a one-pole low-pass filter (cutoff can move)."""

    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.y = 0.0

    def lp(self, cutoff):
        a = 1 - math.exp(-2 * math.pi * cutoff / RATE)
        self.y += a * (self.rng.uniform(-1, 1) - self.y)
        return self.y


def make(seconds, fn):
    n = int(seconds * RATE)
    return [fn(i / RATE, i) for i in range(n)]


class Band:
    """Band-pass filtered white noise (an RBJ biquad): noise with a pitch
    to it, rather than hiss."""

    def __init__(self, seed, f, q):
        self.rng = random.Random(seed)
        w = 2 * math.pi * f / RATE
        alpha = math.sin(w) / (2 * q)
        a0 = 1 + alpha
        self.b = (alpha / a0, 0.0, -alpha / a0)
        self.a = (-2 * math.cos(w) / a0, (1 - alpha) / a0)
        self.x1 = self.x2 = self.y1 = self.y2 = 0.0

    def __call__(self):
        x = self.rng.uniform(-1, 1)
        y = self.b[0] * x + self.b[2] * self.x2 - self.a[0] * self.y1 - self.a[1] * self.y2
        self.x2, self.x1, self.y2, self.y1 = self.x1, x, self.y1, y
        return y * 3          # (about unit loudness)


class Body:
    """A falling tone, driven into a soft clip so its harmonics carry it
    on small speakers: f0 + df * exp(-t / fall) Hz."""

    def __init__(self, f0, df, fall, drive):
        self.f0, self.df, self.fall, self.drive = f0, df, fall, drive
        self.phase = 0.0

    def __call__(self, t):
        self.phase += 2 * math.pi * (self.f0 + self.df * env_exp(t, self.fall)) / RATE
        return math.tanh(self.drive * math.sin(self.phase)) / math.tanh(self.drive)


def attack(t, ms):
    return min(1.0, t * 1000 / ms)


def cannon():
    """Tank and turret cannon: a deep boom (a falling, saturated tone) with
    a blast and a short crack on top."""
    body = Body(55, 110, 0.035, 2.5)
    blast = Band(11, 400, 0.8)
    crack = Band(12, 2000, 1.2)
    out = []
    for i in range(int(0.30 * RATE)):
        t = i / RATE
        v = (0.9 * body(t) * attack(t, 4) * env_exp(t, 0.10)
             + 0.6 * blast() * env_exp(t, 0.05)
             + 1.0 * crack() * env_exp(t, 0.008))
        out.append(math.tanh(1.3 * v))
    return out


def rifle():
    """Soldier's rifle: a crack, then a short falling bang, and an echo."""
    body = Body(140, 160, 0.015, 2.0)
    crack = Band(21, 2500, 1.5)
    mid = Band(22, 900, 1.0)
    dry = []
    for i in range(int(0.14 * RATE)):
        t = i / RATE
        dry.append(1.4 * crack() * env_exp(t, 0.006)
                   + 0.9 * body(t) * attack(t, 3) * env_exp(t, 0.035)
                   + 0.4 * mid() * env_exp(t, 0.015))
    lag = int(0.038 * RATE)                         # (one echo off a wall)
    return [math.tanh(1.2 * (v + (0.3 * dry[i - lag] if i >= lag else 0.0)))
            for i, v in enumerate(dry)]


def mgun():
    """Buggy's machine gun: a burst of three quick pops (it fires every 0.2 s,
    so this runs together into automatic fire)."""
    out = [0.0] * int(0.155 * RATE)
    for k, (at, loud) in enumerate(((0.0, 1.0), (0.05, 0.85), (0.10, 0.9))):
        body = Body(170, 120, 0.01, 2.0)
        click = Band(31 + k, 1800, 1.5)
        mid = Band(41 + k, 600, 1.0)
        start = int(at * RATE)
        for i in range(start, len(out)):
            u = (i - start) / RATE
            out[i] += loud * (1.1 * click() * env_exp(u, 0.004)
                              + 0.9 * body(u) * attack(u, 2) * env_exp(u, 0.02)
                              + 0.3 * mid() * env_exp(u, 0.01))
    return [math.tanh(1.2 * v) for v in out]


def rocket():
    """Rocket soldier: a whoosh rising then fading."""
    nz = Noise(4)
    out = []
    for i in range(int(0.31 * RATE)):
        t = i / RATE
        a = min(1.0, t / 0.03) * env_exp(max(0.0, t - 0.03), 0.1)
        cut = 600 + 2400 * min(1.0, t / 0.08) * env_exp(t, 0.25)
        out.append(nz.lp(cut) * 2.8 * a)
    return out


def boom():
    """Explosion: a crack, then a long low roar with a rumble under it."""
    nz = Noise(5)
    phase = 0.0
    out = []
    for i in range(int(0.62 * RATE)):
        t = i / RATE
        roar = nz.lp(200 + 1800 * env_exp(t, 0.12)) * 2.6 * env_exp(t, 0.2)
        phase += 2 * math.pi * (38 + 30 * env_exp(t, 0.15)) / RATE
        rumble = math.sin(phase) * 0.55 * env_exp(t, 0.25)
        crack = nz.rng.uniform(-1, 1) * 0.6 * env_exp(t, 0.01)
        out.append(roar + rumble + crack)
    return out


def ready():
    """Production done: two soft rising tones."""
    def tone(t, f, start, length):
        if not start <= t < start + length:
            return 0.0
        u = t - start
        a = min(1.0, u / 0.006) * env_exp(u, length / 2.5)
        w = 2 * math.pi * f * u
        return a * (math.sin(w) + 0.25 * math.sin(3 * w))
    return make(0.31, lambda t, i: 0.7 * (tone(t, 784, 0.0, 0.13) + tone(t, 1175, 0.14, 0.17)))


def place():
    """Structure placed: a heavy thud with a metal clank."""
    nz = Noise(6)
    phase = 0.0
    out = []
    for i in range(int(0.2 * RATE)):
        t = i / RATE
        phase += 2 * math.pi * (55 + 40 * env_exp(t, 0.03)) / RATE
        thud = math.sin(phase) * env_exp(t, 0.05)
        clank = 0.3 * math.sin(2 * math.pi * 410 * t) * env_exp(t, 0.03)
        click = nz.lp(2500) * 1.5 * env_exp(t, 0.006)
        out.append(0.9 * thud + clank + click)
    return out


# name, how loud on the DOC (0-255), maker, voices (two: a second shot
# right after the first doesn't cut it off); the bit numbers follow this
# order
SOUNDS = [('cannon', 210, cannon, 2), ('rifle', 170, rifle, 2), ('mgun', 160, mgun, 2),
          ('rocket', 180, rocket, 2), ('boom', 255, boom, 1), ('ready', 150, ready, 1),
          ('place', 190, place, 1)]
MUSIC_OSCS = 10                 # oscillators 0-9 play the music; each voice
                                # of a sound takes the next two (left, right)


def to8(samples):
    """Floats about -1..1 to 8-bit 1-255 around 128, then the end mark 0."""
    peak = max(1e-9, max(abs(s) for s in samples))
    gain = min(1.0, 0.98 / peak)
    out = bytearray(max(1, min(255, int(round(128 + 127 * s * gain)))) for s in samples)
    return bytes(out) + b'\0'


def write_wav(path, data):
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(int(RATE))
        w.writeframes(data[:-1])


RECORDINGS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'sounds')


def recording(name):
    """The prepared recording for this sound, or None."""
    path = os.path.join(RECORDINGS, name + '.wav')
    if not os.path.exists(path):
        return None
    with wave.open(path) as w:
        assert (w.getnchannels(), w.getsampwidth(), w.getframerate()) == (1, 1, int(RATE)), path
        data = w.readframes(w.getnframes())
    return bytes(max(1, b) for b in data) + b'\0'


def main(outdir):
    os.makedirs(os.path.join(outdir, 'sounds'), exist_ok=True)
    made = []
    for bit, (name, vol, fn, voices) in enumerate(SOUNDS):
        data = recording(name) or to8(fn())
        size = 0                                   # table size: 256 << size
        while (256 << size) < len(data):
            size += 1
        assert size <= 7
        made.append((name, vol, data, size, bit))
        write_wav(os.path.join(outdir, 'sounds', name + '.wav'), data)
    # the title music's instruments: waves of 256 bytes the chip loops
    # (table size 0, resolution 0) and one-shot drums like the sounds
    import makemusic
    extra = []
    for name, data, oneshot in makemusic.instruments():
        size = 0
        while (256 << size) < len(data):
            size += 1
        extra.append((name, 0, data, size, None))
    # biggest tables first, each at the lowest multiple of its table size
    # where its bytes fit between the others' (a table only has to start
    # there: the chip stops at the sample's 0 byte, so the rest of a big
    # table can hold smaller sounds)
    used = []                                       # (start, end) taken
    place_at = {}
    for name, vol, data, size, bit in sorted(made + extra, key=lambda m: (-m[3], -len(m[2]))):
        table = 256 << size
        at = 0
        while any(at < e and s < at + len(data) for s, e in used):
            at += table
        assert at + len(data) <= 65536, name
        used.append((at, at + len(data)))
        place_at[name] = at
    image = bytearray(max(e for s, e in used))
    for name, vol, data, size, bit in made + extra:
        image[place_at[name]:place_at[name] + len(data)] = data
    with open(os.path.join(outdir, 'conquer.sound'), 'wb') as f:
        f.write(image)
    tab = bytearray()
    osc = MUSIC_OSCS
    first = {}
    for name, vol, data, size, bit in made:
        voices = SOUNDS[bit][3]
        first[name] = osc
        tab += struct.pack('<BBHBBBB', place_at[name] >> 8, size << 3 | size, FREQ, vol,
                           osc, voices, 0)
        osc += 2 * voices
    assert osc <= 32
    with open(os.path.join(outdir, 'sndtab.bin'), 'wb') as f:
        f.write(tab)
    with open(os.path.join(outdir, 'sndequ.s'), 'w') as f:
        f.write('* generated by tools/makesound.py\n')
        for name, vol, data, size, bit in made:
            f.write('%-10s equ   %d\n' % ('SND_' + name.upper(), 1 << bit))
            f.write('%-10s equ   %d\n' % ('SOSC_' + name.upper(), first[name]))
            f.write('%-10s equ   %d\n' % ('SVOX_' + name.upper(), SOUNDS[bit][3]))
        f.write('%-10s equ   %d\n' % ('NSOUNDS', len(made)))
        for name, vol, data, size, bit in extra:
            key = name[2:].upper()
            loops = len(data) == 256 and data[-1] != 0
            f.write('%-10s equ   %d\n' % ('PG_' + key, place_at[name] >> 8))
            f.write('%-10s equ   %d\n' % ('SR_' + key, 0 if loops else size << 3 | size))
        f.write('%-10s equ   %d\n' % ('SOUNDSIZE', len(image)))
    print('%d sounds and %d music instruments, %d bytes of sound RAM: %s' % (
        len(made), len(extra), len(image), ', '.join(
        '%s %.2f s%s' % (m[0], (len(m[2]) - 1) / RATE, ' (recorded)' if recording(m[0]) else '')
        for m in made)))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'build/gfx')
