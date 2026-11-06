#!/usr/bin/env python3
"""Builds Resources/Drums from CC0 sample libraries (Virtuosity Drums and VCSL by Versilian Studios
and Karoryfer Samples, Swirly Drums djembe). Usage: make-drums.py <samples dir>
Each output is <drum>_v<layer>_r<roundrobin>.wav, 44.1 kHz stereo 16-bit: close, overhead and room mics blended."""
import os, sys, subprocess, wave, numpy as np

SRC = sys.argv[1]
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Drums")
VD, PC = f"{SRC}/vd/Samples/mid", f"{SRC}/vd/Samples/perc/close"
VC = f"{SRC}/vcsl/Idiophones/Struck Idiophones"

def rr(fmt, layers, rrs): return [[fmt.format(v=v, r=r) for r in rrs] for v in layers]

M = f"{SRC}/vd/Samples"
def kit(folder, name, mics, layers, rrs=None, maxs=1.0):
    """Kit piece recorded on several mics at once: {mic: gain}. rrs=None means single takes named vl{v}."""
    def files(v, r):
        tail = f"vl{v}_rr{r}" if rrs else f"vl{v}"
        return [(f"{M}/{mic}/{folder}/{mic}_{name}_{tail}.flac", g) for mic, g in mics.items()]
    if rrs:
        return ([[files(v, r) for r in rrs] for v in layers], maxs)
    return ([[files(v, None) for v in grp] for grp in layers], maxs)

def perc(folder, stem, layers, rrs, maxs, room=0.35):
    """Hand percussion: close mic plus the far (room) pair."""
    return ([[[(f"{PC}/{folder}/{stem.format(v=v)}_rr{r}_Close.wav", 1.0),
               (f"{M}/perc/room/{folder}/{stem.format(v=v)}_rr{r}_Far.wav", room)] for r in rrs] for v in layers], maxs)

KICK = {"kickmic": 1.0, "oh": 0.12, "room": 0.06}
SNARE = {"snaremic": 1.0, "oh": 0.55, "room": 0.4}
CYM = {"oh": 1.0, "room": 0.35}
TOM = {"mid": 0.9, "oh": 0.6, "room": 0.4}
KIT = {
  "kick":     kit("kick", "kick_snoff", KICK, [1, 2, 3, 4], [1, 2, 3], 0.9),
  "snare":    kit("snare", "snare_center", SNARE, [(a, a + 1) for a in (5, 11, 17, 23, 29, 35)], None, 1.0),
  "rimshot":  kit("snare", "snare_rimshot", SNARE, [(a, a + 1) for a in (5, 8, 11)], None, 1.1),
  "xstick":   kit("snare", "snare_crossstick", SNARE, [(a, a + 1) for a in (3, 7, 11, 15)], None, 0.5),
  "hat":      kit("hh", "hh_closed", CYM, [1, 2, 3, 4], [1, 2, 3], 0.4),
  "halfhat":  kit("hh", "hh_half", CYM, [1, 2, 3, 4], [1, 2], 0.7),
  "openhat":  kit("hh", "hh_open", CYM, [2, 3, 4], [1, 2], 1.4),
  "pedalhat": kit("hh", "hh_pedal", CYM, [1, 2, 3], [1, 2], 0.4),
  "ride":     kit("ride", "ride_ride", CYM, [1, 2, 3], [1, 2, 3], 2.2),
  "ridebell": kit("ride", "ride_bell", CYM, [1, 2, 3], [1, 2], 2.0),
  "crash":    kit("crash", "crash_crash", CYM, [2, 3], [1, 2], 2.8),
  "tomhi":    kit("htom", "htom_center", TOM, [(a, a + 1) for a in (3, 7, 11, 15)], None, 1.3),
  "tomlo":    kit("ltom", "ltom_center", TOM, [(a, a + 1) for a in (3, 7, 11, 15)], None, 1.5),
  "conga":    perc("conga", "Conga_22_HitN_{v}", ["1_50", "51_100", "101_127"], [1, 2, 3, 4], 0.9),
  "congamute":perc("conga", "Conga_17_HitHM1_{v}", ["1_70", "71_127"], [1, 2, 3, 4], 0.45),
  "tumba":    perc("tumba", "Tumba_24_HitN_{v}", ["1_40", "41_70", "71_100", "101_127"], [1, 2, 3], 1.0),
  "bongohi":  perc("bongoh", "BongoH_Hit1_v{v}", [1, 2, 3], [1, 2, 3], 0.55),
  "bongolo":  perc("bongol", "BongoL_Hit1_v{v}", [1, 2, 3], [1, 2, 3], 0.65),
  "agogohi":  perc("agogo", "Agogo_High_v{v}", [1, 2, 3], [1, 2, 3], 0.8),
  "agogolo":  perc("agogo", "Agogo_Low_v{v}", [1, 2], [1, 2, 3], 0.8),
  "claves":   perc("claves", "Claves1_Hit_v{v}", [1, 2, 3], [1, 2], 0.4),
  "cabasa":   perc("cabasa", "Cabasa1_Rub_v{v}", [1, 2], [1, 2, 3, 4], 0.5),
  "shakerdn": perc("shaker", "LShaker_Shake1D", [""], [1, 2, 3, 4, 5], 0.4, room=0.25),
  "shakerup": perc("shaker", "LShaker_Shake1U", [""], [1, 2, 3, 4, 5], 0.4, room=0.25),
  "tamb":     perc("tambourine", "Tamb1_Shake", [""], [1, 2, 3, 4, 5], 0.7, room=0.3),
  "clap":     ([[[(f"{VC}/Claps/Clap_rr{r}.wav", 1.0)] for r in (1, 2, 3, 4)]], 0.6),
  "djembe":   ([[[(f"{SRC}/swirly/Samples/djembe/djembe_vl{v}_rr{r}.wav", 1.0)] for r in (1, 2)] for v in (3, 6, 9, 12)], 0.8),
}

def load(path):
    """Stereo float array (n, 2) at 44.1 kHz; mono files go to both sides."""
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-ac", "2", "-ar", "44100", "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()

def mixmics(parts, maxs):
    """All mics of one hit, cut from the same instant (found on the first, closest mic) so they stay in phase."""
    sig = [(load(f), g) for f, g in parts if os.path.exists(f)]
    first = sig[0][0]
    mono = np.abs(first).max(axis=1)
    peak = mono.max() or 1
    on = int(np.argmax(mono > peak * 0.05))
    start = max(0, on - int(0.002 * 44100))
    n = int(maxs * 44100)
    out = np.zeros((n, 2), dtype=np.float32)
    for x, g in sig:
        seg = x[start:start + n]
        out[:len(seg)] += seg * g
    env = np.abs(out).max(axis=1)
    above = np.where(env > env.max() * 0.001)[0]
    end = (above[-1] + 1) if len(above) else n
    out = out[:end]
    fade = min(len(out), int(0.03 * 44100))
    out[-fade:] *= (np.linspace(1, 0, fade) ** 2)[:, None]
    return out

def kickify(x):
    """The library kick is a small jazz drum: high (~81 Hz), ringing, no beater attack. Make it a live
    gospel kick: keep its real attack, damp the ring, add a deep short body (~55 Hz) and a beater click."""
    sr = 44100
    n = max(len(x), int(0.45 * sr))
    t = np.arange(n) / sr
    out = np.zeros((n, 2), dtype=np.float32)
    peak = np.abs(x).max() or 1
    # 1. The real drum, its boom damped after the first 40 ms (like a pillow inside the drum).
    damp = np.where(t < 0.04, 1.0, np.exp(-(t - 0.04) / 0.05))
    out[:len(x)] += x * damp[:len(x), None] * 0.85
    # 2. Body: a fast drop from 110 to 55 Hz, then a short "tum".
    f = 55 + 55 * np.exp(-t / 0.012)
    body = np.sin(2 * np.pi * np.cumsum(f) / sr) * np.exp(-t / 0.11) * np.minimum(1, t / 0.0015)
    out += (body * peak * 0.75)[:, None]
    # 3. Beater click: a very short bright tick.
    rng = np.random.default_rng(len(x))
    noise = rng.standard_normal(n) * np.exp(-t / 0.0025)
    from scipy.signal import butter, lfilter
    b, a = butter(2, [2000 / (sr / 2), 7000 / (sr / 2)], btype="band")
    click = lfilter(b, a, noise)
    out += (click / (np.abs(click).max() or 1) * peak * 0.35)[:, None]
    # Gentle high-pass so it stays clean under the bass guitar.
    b, a = butter(2, 35 / (sr / 2), btype="high")
    out = lfilter(b, a, out, axis=0).astype(np.float32)
    end = int(0.42 * sr)
    out = out[:end]
    fade = int(0.04 * sr)
    out[-fade:] *= (np.linspace(1, 0, fade) ** 2)[:, None]
    return out

def save(path, x):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())

os.makedirs(OUT, exist_ok=True)
for f in os.listdir(OUT):
    if f.endswith(".wav"): os.remove(os.path.join(OUT, f))
total = 0
for name, (layers, maxs) in KIT.items():
    clips = [[mixmics(parts, maxs) for parts in takes] for takes in layers]
    if name == "kick":
        clips = [[kickify(c) for c in l] for l in clips]
    peak = max(np.max(np.abs(c)) for l in clips for c in l)
    for vi, l in enumerate(clips):
        for ri, c in enumerate(l):
            p = os.path.join(OUT, f"{name}_v{vi + 1}_r{ri + 1}.wav")
            save(p, c * (0.89 / peak))
            total += os.path.getsize(p)
    print(f"{name:10s} {len(clips)} layers x {len(clips[0])}")
print(f"total {total / 1e6:.1f} MB")
