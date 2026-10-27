#!/usr/bin/env python3
"""The title music of Conquer GS: an original 8-bar loop in E minor for
the Ensoniq DOC, and the data the game's player needs.

Five voices: bass, lead and an arpeggio (each a single 256-byte waveform
cycle the DOC loops, "free-run" mode, its pitch set by the frequency
register and its loudness shaped every frame through the volume register),
then kick/snare and hi-hat (short one-shot samples).

The score is a step sequence: 16 steps a bar, FPS video frames a step
(7: about 128 beats a minute), 8 bars. Each voice has one byte a step:
0 nothing new, 255 note off (the volume fades out), else a note (an index
into the frequency table, from 1) or for the drum voices a drum (1 kick,
2 snare, 3 hat).

Writes into the output folder:
  music.bin    the 5 voices' steps (STEPS bytes each)
  musfreq.bin  the frequency table (a word per note, index 1 first)
  musequ.s     equates: MUSFPS, MUSSTEPS, envelopes, drum volumes
  music_preview.wav  two loops as the chip plays them (rendered here)

makesound.py puts the instruments (instruments()) into the sound image.
"""
import math
import os
import struct
import sys
import wave

import makesound

SCAN = makesound.SCAN           # DOC scan rate with 32 oscillators (Hz)
RATE = makesound.RATE           # the drums' sample rate (half of it)
FPS = 7                         # video frames a step
BARS = 8
STEPS = BARS * 16

# ------------------------------------------------------------------ score

CHORDS = ['Em', 'Em', 'C', 'D', 'Em', 'Em', 'C', 'B']
CHORD_TONES = {'Em': ['E4', 'G4', 'B4', 'E5'], 'C': ['C4', 'E4', 'G4', 'C5'],
               'D': ['D4', 'F#4', 'A4', 'D5'], 'B': ['B3', 'D#4', 'F#4', 'B4']}
BASS = {'Em': 'E2 E2 E3 E2 G2 E2 D3 B2', 'C': 'C2 C2 C3 C2 E2 C2 B2 G2',
        'D': 'D2 D2 D3 D2 F#2 D2 C3 A2', 'B': 'B1 B1 B2 B1 D#2 B1 A2 F#2'}
LEAD = ['E5:6 D5:2 E5:4 G5:4', 'F#5:8 E5:4 D5:4', 'E5:6 C5:2 G4:8', 'A4:4 B4:4 C5:4 D5:4',
        'E5:6 D5:2 E5:4 G5:4', 'B5:8 A5:4 G5:4', 'G5:6 E5:2 C5:4 E5:4', 'D#5:12 -:4']
# drums per bar: (kick steps, snare steps); the hat plays every 8th
DRUMS = {'normal': ([0, 8, 10], [4, 12]), 'turn': ([0, 6, 8], [4, 12, 14]),
         'fill': ([0, 8], [4, 12, 13, 14, 15])}
DRUM_BARS = ['normal', 'normal', 'normal', 'turn', 'normal', 'normal', 'normal', 'fill']

# envelopes of the tone voices, per video frame: a note starts at peak,
# falls by decay to sustain; a note off falls by release to 0
ENVELOPES = {'bass': (230, 12, 150, 50), 'lead': (200, 4, 140, 20), 'arp': (110, 14, 0, 30)}
DRUM_VOLUMES = {'kick': 230, 'snare': 190, 'hat': 80}
VOICES = ['bass', 'lead', 'arp', 'drums', 'hat']

NOTE_NAMES = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


def note_hz(name):
    """'F#4' -> Hz (A4 = 440)."""
    n = NOTE_NAMES[name[0]]
    i = 1
    if name[i] in '#b':
        n += 1 if name[i] == '#' else -1
        i += 1
    octave = int(name[i:])
    return 440.0 * 2 ** ((n + 12 * (octave + 1) - 69) / 12)


def doc_freq(hz):
    """The DOC frequency register for a 256-byte wave at resolution 0:
    it steps freq / 512 bytes a scan, so a cycle takes 131072 / freq."""
    return round(hz * 131072 / SCAN)


def score():
    """(per voice: list of STEPS events as note names, drum names, 'off' or
    None)."""
    v = {name: [None] * STEPS for name in VOICES}
    for bar, chord in enumerate(CHORDS):
        base = bar * 16
        for k, note in enumerate(BASS[chord].split()):      # staccato 8ths
            v['bass'][base + 2 * k] = note
            v['bass'][base + 2 * k + 1] = 'off'
        tones = CHORD_TONES[chord]
        for s in range(16):                                 # 16th arpeggio
            v['arp'][base + s] = tones[[0, 1, 2, 3, 2, 1][s % 6]]
        at = base
        for item in LEAD[bar].split():
            note, length = item.split(':')
            v['lead'][at] = 'off' if note == '-' else note
            at += int(length)
        kicks, snares = DRUMS[DRUM_BARS[bar]]
        for s in kicks:
            v['drums'][base + s] = 'kick'
        for s in snares:
            v['drums'][base + s] = 'snare'
        for s in range(0, 16, 2):
            v['hat'][base + s] = 'hat'
    return v


def encode():
    """(the steps as bytes, voice after voice; the frequency table)."""
    v = score()
    notes = sorted({e for name in ('bass', 'lead', 'arp') for e in v[name]
                    if e not in (None, 'off')}, key=note_hz)
    index = {n: i + 1 for i, n in enumerate(notes)}
    drums = {'kick': 1, 'snare': 2, 'hat': 3}
    out = bytearray()
    for name in VOICES:
        for e in v[name]:
            out.append(0 if e is None else 255 if e == 'off'
                       else drums[e] if name in ('drums', 'hat') else index[e])
    return bytes(out), [doc_freq(note_hz(n)) for n in notes], notes

# ------------------------------------------------------------- instruments


def cycle(harmonics):
    """One 256-sample cycle from harmonic amplitudes, 1-255 (no 0: the DOC
    would stop there)."""
    xs = [sum(a * math.sin(2 * math.pi * (k + 1) * i / 256) for k, a in enumerate(harmonics))
          for i in range(256)]
    peak = max(abs(x) for x in xs)
    return bytes(max(1, min(255, round(128 + 120 * x / peak))) for x in xs)


def kick():
    phase, out = 0.0, []
    nz = makesound.Noise(51)
    for i in range(int(0.15 * RATE)):
        t = i / RATE
        phase += 2 * math.pi * (45 + 110 * math.exp(-t / 0.03)) / RATE
        out.append(math.sin(phase) * math.exp(-t / 0.07) + 0.4 * nz.lp(3000) * math.exp(-t / 0.003))
    return out


def snare():
    nz = makesound.Band(52, 1800, 0.7)
    return [nz() * math.exp(-i / RATE / 0.05)
            + 0.6 * math.sin(2 * math.pi * 190 * i / RATE) * math.exp(-i / RATE / 0.04)
            for i in range(int(0.15 * RATE))]


def hat():
    nz = makesound.Band(53, 5000, 0.8)
    return [nz() * math.exp(-i / RATE / 0.015) for i in range(int(0.05 * RATE))]


def instruments():
    """(name, bytes, one-shot?) for the sound image: the three waves (256
    bytes, looped) and the three drums (ending with a 0)."""
    return [('m_bass', cycle([1 / n for n in range(1, 9)]), False),
            ('m_lead', cycle([1.0, 0.7, 0.5, 0.4, 0.3, 0.2, 0.12, 0.08]), False),
            ('m_arp', cycle([1, 0, 1 / 3, 0, 1 / 5, 0, 1 / 7]), False),
            ('m_kick', makesound.to8(kick()), True),
            ('m_snare', makesound.to8(snare()), True),
            ('m_hat', makesound.to8(hat()), True)]

# ----------------------------------------------------------------- render


def render(loops=2):
    """The loop as the DOC and the game's player make it: per scan, each
    voice's accumulator steps by its frequency and the byte at (acc >> 9)
    is played times its volume (no smoothing); volumes change once a video
    frame, steps every FPS frames - as in sounds.s's music player."""
    steps, freqs, _ = encode()
    inst = {n: d for n, d, _ in instruments()}
    waves = [inst['m_bass'], inst['m_lead'], inst['m_arp']]
    drum = {1: inst['m_kick'], 2: inst['m_snare'], 3: inst['m_hat']}
    dvol = {1: DRUM_VOLUMES['kick'], 2: DRUM_VOLUMES['snare'], 3: DRUM_VOLUMES['hat']}
    env = [ENVELOPES[n] for n in ('bass', 'lead', 'arp')]
    acc = [0, 0, 0]
    freq = [0, 0, 0]
    vol = [0, 0, 0]
    mode = [0, 0, 0]                          # 0 off, 1 decaying, 2 releasing
    dsample = [None, None]
    dacc = [0, 0]
    dv = [0, 0]
    out = []
    per_frame = SCAN / 60
    frames = loops * STEPS * FPS
    tick, step = FPS - 1, 0
    for frame in range(frames):
        tick += 1
        if tick == FPS:                       # a new step
            tick = 0
            for v in range(3):
                e = steps[v * STEPS + step]
                if e == 255:
                    mode[v] = 2
                elif e:
                    freq[v] = freqs[e - 1]
                    vol[v] = env[v][0]
                    mode[v] = 1
            for d in range(2):
                e = steps[(3 + d) * STEPS + step]
                if e:
                    dsample[d], dacc[d], dv[d] = drum[e], 0, dvol[e]
            step = (step + 1) % STEPS
        for v in range(3):                    # the envelopes
            peak, decay, sustain, release = env[v]
            if mode[v] == 1:
                vol[v] = max(sustain, vol[v] - decay)
            elif mode[v] == 2:
                vol[v] = max(0, vol[v] - release)
                if vol[v] == 0:
                    mode[v] = 0
        for _ in range(round((frame + 1) * per_frame) - round(frame * per_frame)):
            s = 0
            for v in range(3):
                acc[v] = (acc[v] + freq[v]) & 0xFFFFFF
                s += (waves[v][(acc[v] >> 9) & 255] - 128) * vol[v]
            for d in range(2):
                if dsample[d] is not None:
                    b = dsample[d][dacc[d] >> 9]
                    if b == 0:
                        dsample[d] = None
                    else:
                        s += (b - 128) * dv[d]
                        dacc[d] += 256
            out.append(s)
    return out


def main(outdir):
    steps, freqs, notes = encode()
    with open(os.path.join(outdir, 'music.bin'), 'wb') as f:
        f.write(steps)
    with open(os.path.join(outdir, 'musfreq.bin'), 'wb') as f:
        f.write(b''.join(struct.pack('<H', q) for q in freqs))
    with open(os.path.join(outdir, 'musequ.s'), 'w') as f:
        f.write('* generated by tools/makemusic.py\n')
        eq = {'MUSFPS': FPS, 'MUSSTEPS': STEPS}
        for name, (peak, decay, sustain, release) in ENVELOPES.items():
            key = name.upper()[:4]
            eq.update({'PK_' + key: peak, 'DC_' + key: decay, 'SU_' + key: sustain,
                       'RL_' + key: release})
        for name, v in DRUM_VOLUMES.items():
            eq['VOL_' + name.upper()] = v
        for k, v in eq.items():
            f.write('%-10s equ   %d\n' % (k, v))
    pcm = render()
    peak = max(1, max(abs(s) for s in pcm))
    with wave.open(os.path.join(outdir, 'music_preview.wav'), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(round(SCAN))
        w.writeframes(b''.join(struct.pack('<h', int(30000 * s / peak)) for s in pcm))
    print('music: %d bars, %d steps of %d frames (%.1f s a loop), %d notes (%s to %s)' % (
        BARS, STEPS, FPS, STEPS * FPS / 60, len(notes), notes[0], notes[-1]))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'build/gfx')
