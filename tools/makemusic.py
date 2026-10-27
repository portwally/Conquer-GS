#!/usr/bin/env python3
"""The music of Conquer GS for the Ensoniq DOC, and the data the game's
player needs: two original loops, the title tune (8 bars in E minor) and
a driving one for the battles, quieter (16 bars in A minor).

Each has five voices: bass, lead and an arpeggio (each a single 256-byte
waveform cycle the DOC loops, "free-run" mode, its pitch set by the
frequency register and its loudness shaped every frame through the volume
register), then kick/snare and hi-hat (short one-shot samples).

A score is a step sequence: 16 steps a bar, FPS video frames a step. Each
voice has one byte a step: 0 nothing new, 255 note off (the volume fades
out), else a note (an index into the frequency table, from 1, shared by
both tunes) or for the drum voices a drum (1 kick, 2 snare, 3 hat).

Writes into the output folder:
  music.bin     the tunes' steps: per tune, its five voices one after the
                other (STEPS bytes each)
  musfreq.bin   the frequency table (a word per note, index 1 first)
  mustracks.bin per tune (MTRSZ bytes): frames a step, steps, where each
                voice's steps start in music.bin, the tone voices'
                envelopes (peak, decay, sustain, release), the drums'
                volumes and the tone voices' waves (0 bass, 1 lead, 2
                arpeggio, 3 pad: the game knows their pages)
  musequ.s      equates: NTRACKS, MTRSZ, the tune numbers
  music_preview.wav, battle_preview.wav  two loops of each as the chip
                plays them (rendered here)

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
VOICES = ['bass', 'lead', 'arp', 'drums', 'hat']
NOTE_NAMES = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}


def note_hz(name):
    """'F#4', 'Bb2' -> Hz (A4 = 440)."""
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


def notes_of(line):
    """'E5:6 D5:2 -:4' -> [('E5', 6), ('D5', 2), ('-', 4)]"""
    return [(n, int(k)) for n, k in (item.split(':') for item in line.split())]

# ------------------------------------------------------------------ tunes


class Tune:
    """A tune: chords per bar, the bass per chord (8 notes: staccato eighths;
    16 tokens: sixteenths, a note, '.' nothing new or '-' off), the lead line,
    the arpeggio's chord tones and pattern, drum patterns per bar, the tone
    voices' envelopes (per frame: a note starts at peak, falls by decay to
    sustain; a note off falls by release to 0), the drums' volumes and the
    tone voices' waves; level scales all the volumes (the battle tune plays
    under the sound effects)."""

    def __init__(self, name, fps, chords, bass, lead, tones, arp, arp_every,
                 drums, drum_bars, envelopes, drum_volumes, waves, level=1.0,
                 hat_every=2):
        self.name, self.fps, self.chords = name, fps, chords
        self.bars = len(chords)
        self.steps = self.bars * 16
        self.bass, self.lead, self.tones = bass, lead, tones
        self.arp, self.arp_every = arp, arp_every
        self.drums, self.drum_bars, self.hat_every = drums, drum_bars, hat_every
        self.waves, self.level = waves, level
        self.envelopes = {k: tuple(max(1 if v else 0, round(v * level)) for v in e)
                          for k, e in envelopes.items()}
        self.drum_volumes = {k: round(v * level) for k, v in drum_volumes.items()}

    def score(self):
        """Per voice: STEPS events (note names, drum names, 'off' or None)."""
        v = {name: [None] * self.steps for name in VOICES}
        for bar, chord in enumerate(self.chords):
            base = bar * 16
            line = self.bass[chord].split()
            if len(line) == 8:                                  # staccato 8ths
                for k, note in enumerate(line):
                    v['bass'][base + 2 * k] = note
                    v['bass'][base + 2 * k + 1] = 'off'
            else:                                               # 16ths
                assert len(line) == 16, chord
                for k, note in enumerate(line):
                    v['bass'][base + k] = None if note == '.' else 'off' if note == '-' else note
            tones = self.tones[chord]
            for s in range(0, 16, self.arp_every):
                v['arp'][base + s] = tones[self.arp[(s // self.arp_every) % len(self.arp)]]
            kicks, snares = self.drums[self.drum_bars[bar % len(self.drum_bars)]]
            for s in kicks:
                v['drums'][base + s] = 'kick'
            for s in snares:
                v['drums'][base + s] = 'snare'
            for s in range(0, 16, self.hat_every):
                v['hat'][base + s] = 'hat'
        at = 0
        for note, length in notes_of(self.lead):
            v['lead'][at] = 'off' if note == '-' else note
            at += length
        assert at == self.steps, (self.name, at)
        return v

    def seconds(self):
        return self.steps * self.fps / 60


TITLE = Tune(
    'title', 7,                 # (about 128 beats a minute)
    chords=['Em', 'Em', 'C', 'D', 'Em', 'Em', 'C', 'B'],
    bass={'Em': 'E2 E2 E3 E2 G2 E2 D3 B2', 'C': 'C2 C2 C3 C2 E2 C2 B2 G2',
          'D': 'D2 D2 D3 D2 F#2 D2 C3 A2', 'B': 'B1 B1 B2 B1 D#2 B1 A2 F#2'},
    lead=' '.join(['E5:6 D5:2 E5:4 G5:4', 'F#5:8 E5:4 D5:4', 'E5:6 C5:2 G4:8',
                   'A4:4 B4:4 C5:4 D5:4', 'E5:6 D5:2 E5:4 G5:4', 'B5:8 A5:4 G5:4',
                   'G5:6 E5:2 C5:4 E5:4', 'D#5:12 -:4']),
    tones={'Em': ['E4', 'G4', 'B4', 'E5'], 'C': ['C4', 'E4', 'G4', 'C5'],
           'D': ['D4', 'F#4', 'A4', 'D5'], 'B': ['B3', 'D#4', 'F#4', 'B4']},
    arp=[0, 1, 2, 3, 2, 1], arp_every=1,                     # 16th arpeggio
    drums={'normal': ([0, 8, 10], [4, 12]), 'turn': ([0, 6, 8], [4, 12, 14]),
           'fill': ([0, 8], [4, 12, 13, 14, 15])},
    drum_bars=['normal', 'normal', 'normal', 'turn', 'normal', 'normal', 'normal', 'fill'],
    envelopes={'bass': (230, 12, 150, 50), 'lead': (200, 4, 140, 20), 'arp': (110, 14, 0, 30)},
    drum_volumes={'kick': 230, 'snare': 190, 'hat': 80},
    waves=('m_bass', 'm_lead', 'm_arp'))

GALLOP = 'R . R R R . R R R . R R O . R R'      # (R root, O an octave up)


def gallop(root, octave):
    """The battle bass for a chord: a galloping sixteenth-note drive."""
    up = root[:-1] + str(int(root[-1]) + 1)
    return ' '.join(root if t == 'R' else up if t == 'O' else t for t in GALLOP.split())


BATTLE = Tune(
    'battle', 6,                # (150 beats a minute), driving, under the battle
    chords=['Am', 'Am', 'F', 'G', 'Am', 'Am', 'F', 'E',
            'Dm', 'Dm', 'Am', 'Am', 'F', 'G', 'E', 'E'],
    bass={c: gallop(r, 2) for c, r in (('Am', 'A2'), ('F', 'F2'), ('G', 'G2'),
                                       ('E', 'E2'), ('Dm', 'D2'))},
    lead=' '.join(['E5:2 E5:2 A5:4 G5:2 E5:2 C5:4', 'D5:2 E5:2 C5:2 A4:6 -:4',
                   'A4:2 C5:2 F5:4 E5:2 C5:2 A4:4', 'B4:2 D5:2 G5:4 F5:2 D5:2 B4:4',
                   'E5:2 E5:2 A5:4 B5:2 C6:2 B5:4', 'A5:2 G5:2 E5:4 D5:2 C5:2 E5:4',
                   'F5:4 E5:2 D5:2 C5:4 A4:4', 'B4:4 G#4:4 E4:4 -:4',
                   'D5:2 F5:2 A5:4 G5:2 F5:2 D5:4', 'C5:2 D5:2 F5:2 E5:6 -:4',
                   'E5:2 A5:2 C6:4 B5:2 A5:2 E5:4', 'G5:4 F5:2 E5:2 D5:4 C5:4',
                   'C5:2 F5:2 A5:4 G5:2 F5:2 C5:4', 'D5:2 G5:2 B5:4 A5:2 G5:2 D5:4',
                   'E5:4 G#5:4 B5:4 D6:4', 'E6:8 -:4 B5:2 G#5:2']),
    tones={'Am': ['A3', 'C4', 'E4', 'A4'], 'F': ['F3', 'A3', 'C4', 'F4'],
           'G': ['G3', 'B3', 'D4', 'G4'], 'E': ['E3', 'G#3', 'B3', 'E4'],
           'Dm': ['D3', 'F3', 'A3', 'D4']},
    arp=[0, 1, 2, 3, 2, 1], arp_every=1,                     # 16th arpeggio
    drums={'drive': ([0, 6, 8, 10], [4, 12]), 'push': ([0, 3, 6, 8, 10], [4, 12, 14]),
           'fill': ([0, 8], [4, 10, 12, 13, 14, 15])},
    drum_bars=['drive', 'drive', 'drive', 'push', 'drive', 'drive', 'drive', 'fill'],
    envelopes={'bass': (220, 20, 120, 60), 'lead': (200, 6, 130, 30), 'arp': (90, 15, 0, 30)},
    drum_volumes={'kick': 220, 'snare': 170, 'hat': 70},
    waves=('m_bass', 'm_lead', 'm_arp'), level=0.28, hat_every=1)

TUNES = [TITLE, BATTLE]

# the title tune, under the names tools/musiccheck.py uses
CHORDS, FPS, STEPS, BARS = TITLE.chords, TITLE.fps, TITLE.steps, TITLE.bars


def encode():
    """(the tunes' steps as bytes, tune after tune and voice after voice;
    where each tune starts; the frequency table; the notes)."""
    scores = [t.score() for t in TUNES]
    notes = sorted({e for v in scores for name in ('bass', 'lead', 'arp') for e in v[name]
                    if e not in (None, 'off')}, key=note_hz)
    index = {n: i + 1 for i, n in enumerate(notes)}
    drums = {'kick': 1, 'snare': 2, 'hat': 3}
    out, starts = bytearray(), []
    for v in scores:
        starts.append(len(out))
        for name in VOICES:
            for e in v[name]:
                out.append(0 if e is None else 255 if e == 'off'
                           else drums[e] if name in ('drums', 'hat') else index[e])
    assert len(notes) < 255
    return bytes(out), starts, [doc_freq(note_hz(n)) for n in notes], notes

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
    """(name, bytes, one-shot?) for the sound image: the waves (256
    bytes, looped) and the three drums (ending with a 0)."""
    return [('m_bass', cycle([1 / n for n in range(1, 9)]), False),
            ('m_lead', cycle([1.0, 0.7, 0.5, 0.4, 0.3, 0.2, 0.12, 0.08]), False),
            ('m_arp', cycle([1, 0, 1 / 3, 0, 1 / 5, 0, 1 / 7]), False),
            ('m_pad', cycle([1.0, 0.3, 0.12, 0.05]), False),      # soft, round
            ('m_kick', makesound.to8(kick()), True),
            ('m_snare', makesound.to8(snare()), True),
            ('m_hat', makesound.to8(hat()), True)]

# ----------------------------------------------------------------- render


def render(loops=2, tune=TITLE):
    """A tune as the DOC and the game's player make it: per scan, each
    voice's accumulator steps by its frequency and the byte at (acc >> 9)
    is played times its volume (no smoothing); volumes change once a video
    frame, steps every FPS frames - as in main.s's music player."""
    allsteps, starts, freqs, _ = encode()
    t0 = starts[TUNES.index(tune)]
    steps = allsteps[t0:t0 + 5 * tune.steps]
    inst = {n: d for n, d, _ in instruments()}
    waves = [inst[w] for w in tune.waves]
    drum = {1: inst['m_kick'], 2: inst['m_snare'], 3: inst['m_hat']}
    dvol = {1: tune.drum_volumes['kick'], 2: tune.drum_volumes['snare'],
            3: tune.drum_volumes['hat']}
    env = [tune.envelopes[n] for n in ('bass', 'lead', 'arp')]
    acc, freq, vol, mode = [0, 0, 0], [0, 0, 0], [0, 0, 0], [0, 0, 0]  # mode: 0 off,
    dsample, dacc, dv = [None, None], [0, 0], [0, 0]                 # 1 decaying, 2 releasing
    out = []
    per_frame = SCAN / 60
    tick, step = tune.fps - 1, 0
    for frame in range(loops * tune.steps * tune.fps):
        tick += 1
        if tick == tune.fps:                  # a new step
            tick = 0
            for v in range(3):
                e = steps[v * tune.steps + step]
                if e == 255:
                    mode[v] = 2
                elif e:
                    freq[v] = freqs[e - 1]
                    vol[v] = env[v][0]
                    mode[v] = 1
            for d in range(2):
                e = steps[(3 + d) * tune.steps + step]
                if e:
                    dsample[d], dacc[d], dv[d] = drum[e], 0, dvol[e]
            step = (step + 1) % tune.steps
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


MTRSZ = 50                      # bytes per tune in mustracks.bin


def main(outdir):
    steps, starts, freqs, notes = encode()
    with open(os.path.join(outdir, 'music.bin'), 'wb') as f:
        f.write(steps)
    with open(os.path.join(outdir, 'musfreq.bin'), 'wb') as f:
        f.write(b''.join(struct.pack('<H', q) for q in freqs))
    waves = [n for n, _, oneshot in instruments() if not oneshot]
    tracks = bytearray()
    for tune, start in zip(TUNES, starts):
        env = [tune.envelopes[n] for n in ('bass', 'lead', 'arp')]
        rec = [tune.fps, tune.steps] + [start + v * tune.steps for v in range(5)]
        for k in range(4):                    # peaks, decays, sustains, releases
            rec += [e[k] for e in env]
        rec += [tune.drum_volumes[d] for d in ('kick', 'snare', 'hat')]
        rec += [waves.index(w) for w in tune.waves]
        tracks += struct.pack('<%dH' % len(rec), *rec)
    assert len(tracks) == MTRSZ * len(TUNES)
    with open(os.path.join(outdir, 'mustracks.bin'), 'wb') as f:
        f.write(tracks)
    with open(os.path.join(outdir, 'musequ.s'), 'w') as f:
        f.write('* generated by tools/makemusic.py\n')
        for k, v in {'NTRACKS': len(TUNES), 'MTRSZ': MTRSZ,
                     **{'TUNE_' + t.name.upper(): i for i, t in enumerate(TUNES)}}.items():
            f.write('%-10s equ   %d\n' % (k, v))
    for tune, name in ((TITLE, 'music_preview.wav'), (BATTLE, 'battle_preview.wav')):
        pcm = render(tune=tune)
        peak = max(1, max(abs(s) for s in pcm))
        with wave.open(os.path.join(outdir, name), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(round(SCAN))
            w.writeframes(b''.join(struct.pack('<h', int(30000 * s / peak)) for s in pcm))
    print('music: %s, %d notes (%s to %s)' % (', '.join(
        '%s %d bars of %d frames a step (%.1f s)' % (t.name, t.bars, t.fps, t.seconds())
        for t in TUNES), len(notes), notes[0], notes[-1]))


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'build/gfx')
