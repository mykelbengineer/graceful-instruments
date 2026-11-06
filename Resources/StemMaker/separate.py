"""Stem Maker: splits a WAV into stems with Demucs.

usage: python separate.py input.wav output_dir [htdemucs|htdemucs_ft|htdemucs_6s] [shifts]
Prints "PROGRESS <0-100>" lines and writes <stem>.flac files.
"""
import os
import sys

import numpy as np
import soundfile as sf
import torch
from demucs.apply import apply_model
from demucs.pretrained import get_model


def main():
    src, out_dir = sys.argv[1], sys.argv[2]
    name = sys.argv[3] if len(sys.argv) > 3 else "htdemucs"
    shifts = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    torch.set_num_threads(max(1, os.cpu_count() or 2))
    os.makedirs(out_dir, exist_ok=True)

    print("STATUS loading model", flush=True)
    model = get_model(name)
    model.eval()

    audio, sr = sf.read(src, dtype="float32", always_2d=True)
    if sr != model.samplerate:
        raise SystemExit(f"expected {model.samplerate} Hz audio, got {sr}")
    wav = torch.from_numpy(audio.T.copy())
    if wav.shape[0] == 1:
        wav = wav.repeat(2, 1)
    wav = wav[:2]
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    mix = ((wav - mean) / std)[None]

    # Report progress by wrapping tqdm, which apply_model uses for its chunks.
    import demucs.apply as dapply

    # A "bag" model (htdemucs_ft) runs several sub-models, each with its own progress bar; with
    # shifts each runs several times. Spread them over 0-100%.
    passes = len(getattr(model, "models", [model])) * max(1, shifts)
    state = {"pass": 0}

    class Progress:
        def __init__(self, iterable, total=None, **_):
            self.items = list(iterable)
            self.total = total or len(self.items)
            self.index = state["pass"]
            state["pass"] += 1

        def __iter__(self):
            for i, x in enumerate(self.items):
                done = (min(self.index, passes - 1) + i / max(1, self.total)) / passes
                print(f"PROGRESS {int(100 * done)}", flush=True)
                yield x

    dapply.tqdm.tqdm = Progress
    print("STATUS separating", flush=True)
    with torch.no_grad():
        sources = apply_model(model, mix, shifts=shifts, split=True, overlap=0.25, progress=True, device="cpu")[0]
    sources = sources * std + mean

    # Make the stems add back up to the original exactly: "other" becomes everything the named stems
    # didn't take. Muting the vocals then gives the original minus vocals, with the instruments untouched.
    names = list(model.sources)
    if "other" in names:
        k = names.index("other")
        rest = sum(sources[i] for i in range(len(names)) if i != k)
        sources[k] = wav - rest

    # A single stem can peak above the full mix; leave headroom instead of clipping, and tell the app
    # how much to turn them back up so they still add up to the original.
    peak = float(sources.abs().max())
    scale = 0.98 / peak if peak > 0.98 else 1.0
    for stem, data in zip(model.sources, sources):
        sf.write(os.path.join(out_dir, f"{stem}.flac"), (data * scale).numpy().T, sr, subtype="PCM_24")
    print(f"GAIN {1.0 / scale:.6f}", flush=True)
    print("PROGRESS 100", flush=True)
    print("DONE " + ",".join(model.sources), flush=True)


if __name__ == "__main__":
    main()
