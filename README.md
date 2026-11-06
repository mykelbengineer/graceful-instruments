# Graceful Instruments

A Mac app for a church band's laptop: plays loops, backing tracks and grooves with a click and spoken cues in the in-ears, and the music in the house.

Built for a 2015 MacBook Pro on macOS 11 Big Sur. It runs on anything newer too.

## What it does

- **Playback**: tracks, loops, stem packs and services (setlists). Change tempo and key, loop by bars, save portions, fade out.
- **In-ears split**: click, count-in and cues on the left channel, music on the right.
- **Grooves**: real recorded drums and percussion with a human feel. Styles include worship, highlife, makossa, afrobeat, reggae and soukous.
- **Key Finder**: hears the leader sing and names the key in a few seconds.
- **Pads**: ambient pads in any key that keep playing under songs.
- **Chords and lyrics**: chord charts worked out from the recording, and lyrics found to match the track. Export lyrics as a PDF.
- **Remote control**: a phone remote over Wi-Fi (scan a QR code), plus Yamaha MOXF8 (or any MIDI) button control.
- **Downloads and stems**: download from YouTube, and split songs into stems on the Mac.

## Build

Needs Xcode (Swift 5.9) and `ffmpeg` (`brew install ffmpeg`, used once to make the spoken cues).

```sh
scripts/build.sh          # builds build/Graceful Instruments.app (Intel + Apple Silicon)
scripts/deploy.sh         # installs it on the church MacBook over SSH and runs the self-test
```

Run the checks with `.build/release/GracefulInstruments --selftest`. Other command-line modes are listed at the top of `Sources/GracefulInstruments/DevTools.swift`.

## Layout

| Path | What's in it |
| --- | --- |
| `Sources/GracefulInstruments/` | the app (SwiftUI + AVAudioEngine) |
| `Resources/Drums/` | drum samples, all CC0 (see `CREDITS.txt`) |
| `Resources/StemMaker/` | the stem splitter's installer and script (Demucs) |
| `scripts/` | build, deploy, and the scripts that make the cues, drums and icon |

The library lives in `~/Music/Graceful Instruments`.
