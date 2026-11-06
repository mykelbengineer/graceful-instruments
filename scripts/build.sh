#!/bin/bash
# Builds "Graceful Instruments.app" (Intel + Apple Silicon, macOS 11+) into build/.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-1.0.$(date +%Y%m%d%H%M)}"
swift build -c release --arch x86_64 >/dev/null
swift build -c release --arch arm64 >/dev/null
APP="build/Graceful Instruments.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  "$(swift build -c release --arch x86_64 --show-bin-path)/GracefulInstruments" \
  "$(swift build -c release --arch arm64 --show-bin-path)/GracefulInstruments" \
  -output "$APP/Contents/MacOS/GracefulInstruments"
# macOS 11 has no Swift concurrency runtime; ship Xcode's back-deployment copy.
mkdir -p "$APP/Contents/Frameworks"
BACKDEPLOY="$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.5/macosx/libswift_Concurrency.dylib"
cp "$BACKDEPLOY" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/GracefulInstruments"
codesign --force -s - "$APP/Contents/Frameworks/libswift_Concurrency.dylib" >/dev/null 2>&1
# The spoken cues are made on this Mac with its built-in voice (not stored in the repo).
ls Resources/Cues/*.wav >/dev/null 2>&1 || { mkdir -p Resources/Cues; scripts/make-cues.sh >/dev/null; }
cp -R Resources/Cues "$APP/Contents/Resources/Cues"
cp -R Resources/StemMaker "$APP/Contents/Resources/StemMaker"
cp -R Resources/Drums "$APP/Contents/Resources/Drums"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Graceful Instruments</string>
  <key>CFBundleDisplayName</key><string>Graceful Instruments</string>
  <key>CFBundleIdentifier</key><string>com.mykelstudios.gracefulinstruments</string>
  <key>CFBundleExecutable</key><string>GracefulInstruments</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>The Key Finder listens to the singer to work out the key.</string>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1
echo "built $APP ($VERSION)"
