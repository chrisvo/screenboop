#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$ROOT" -c release
APP="$ROOT/build/screenboop.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/screenboop" "$APP/Contents/MacOS/screenboop"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
xcrun swift "$ROOT/tools/GenerateIcon.swift" "$ROOT/.build/screenboop.iconset"
iconutil -c icns "$ROOT/.build/screenboop.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --identifier dev.screenboop.mac "$APP"
printf '\nBuilt %s\nLaunch: open "%s"\n' "$APP" "$APP"
