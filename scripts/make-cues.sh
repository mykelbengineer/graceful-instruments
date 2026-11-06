#!/bin/bash
# Generates the spoken cue clips (mono 44.1kHz WAV, silence trimmed) with macOS `say`.
set -euo pipefail
cd "$(dirname "$0")/../Resources/Cues"
VOICE="${VOICE:-Samantha}"
words=( "1:One" "2:Two" "3:Three" "4:Four" "5:Five" "6:Six" "7:Seven" "8:Eight"
  "intro:Intro" "verse:Verse" "verse1:Verse one" "verse2:Verse two" "prechorus:Pre chorus" "chorus:Chorus"
  "bridge:Bridge" "instrumental:Instrumental" "tag:Tag" "outro:Outro" "ending:Ending" "turnaround:Turnaround"
  "build:Build" "down:Bring it down" "break:Break" "allin:All in" "hits:Hits" "acapella:A cappella"
  "again:Again" "lasttime:Last time" "keychange:Key change" "worship:Worship" "hold:Hold" "vamp:Vamp"
  "drumsonly:Drums only" "slowdown:Slow down" "speedup:Speed up" )
for w in "${words[@]}"; do
  key="${w%%:*}"; text="${w#*:}"
  rate=210; [[ "$key" =~ ^[0-9]$ ]] && rate=240
  say -v "$VOICE" -r $rate -o "/tmp/gi_cue_$key.aiff" "$text"
  ffmpeg -loglevel error -y -i "/tmp/gi_cue_$key.aiff" -ac 1 -ar 44100 \
    -af "silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse,loudnorm=I=-14:TP=-1" \
    -ar 44100 -c:a pcm_s16le "$key.wav"
  rm -f "/tmp/gi_cue_$key.aiff"
done
ls | wc -l
