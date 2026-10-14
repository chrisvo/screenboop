#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c release
APP="$ROOT/build/Screenboop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Screenboop" "$APP/Contents/MacOS/Screenboop"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun swift "$ROOT/tools/GenerateIcon.swift" "$ROOT/.build/Screenboop.iconset"
iconutil -c icns "$ROOT/.build/Screenboop.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier dev.screenboop.mac "$APP"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
