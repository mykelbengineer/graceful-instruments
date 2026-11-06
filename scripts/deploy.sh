#!/bin/bash
# Builds and installs the app on the church MacBook (ssh alias msmbp), then runs the self-test there.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/build.sh
HOST="${HOST:-msmbp}"
ssh "$HOST" 'osascript -e "quit app \"Graceful Instruments\"" >/dev/null 2>&1 || true'
# tar over ssh: the MacBook's old rsync splits paths with spaces.
tar -C build -czf - "Graceful Instruments.app" | ssh "$HOST" 'rm -rf "/Applications/Graceful Instruments.app" && tar -C /Applications -xzf -' 
ssh "$HOST" '"/Applications/Graceful Instruments.app/Contents/MacOS/GracefulInstruments" --selftest'
