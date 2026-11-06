#!/bin/bash
# Installs the Stem Maker engine (Python 3.11 + PyTorch 2.2 CPU + Demucs) into
# ~/Music/Graceful Instruments/stemmaker. Safe to run again; prints "STEP:" lines for the app.
set -euo pipefail
ROOT="$HOME/Music/Graceful Instruments/stemmaker"
PY="$ROOT/python/bin/python3"
mkdir -p "$ROOT"
cd "$ROOT"

if [ ! -x "$PY" ]; then
  echo "STEP: Downloading Python"
  ARCH=$(uname -m); [ "$ARCH" = "arm64" ] && TRIPLE=aarch64-apple-darwin || TRIPLE=x86_64-apple-darwin
  URL=$(curl -fsSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest \
    | /usr/bin/grep -oE "https://[^\"]*cpython-3\.11\.[0-9]+(\+|%2B)[0-9]+-${TRIPLE}-install_only\.tar\.gz" | sed -n 1p)
  [ -n "$URL" ] || { echo "ERROR: could not find a Python download"; exit 1; }
  curl -fsSL "$URL" -o python.tar.gz
  rm -rf python && tar -xzf python.tar.gz && rm python.tar.gz
fi

echo "STEP: Installing PyTorch (large download, several minutes)"
"$PY" -m pip install --disable-pip-version-check -q --upgrade pip
# 2.2.2 is the last PyTorch release built for Intel Macs.
"$PY" -m pip install --disable-pip-version-check -q "torch==2.2.2" "torchaudio==2.2.2" "numpy<2"

echo "STEP: Installing Demucs"
"$PY" -m pip install --disable-pip-version-check -q soundfile einops julius openunmix pyyaml tqdm dora-search
# --no-deps skips lameenc (MP3 export), which has no Intel wheel; we write FLAC instead.
"$PY" -m pip install --disable-pip-version-check -q --no-deps "demucs==4.0.1"

echo "STEP: Downloading the separation models"
"$PY" - <<'PY'
from demucs.pretrained import get_model
for name in ("htdemucs", "htdemucs_6s", "htdemucs_ft"):
    get_model(name)
print("models ready")
PY
echo "$(date)" > "$ROOT/installed"
echo "STEP: Ready"
