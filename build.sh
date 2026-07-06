#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/Internal Display Off.app"
EXECUTABLE="$APP/Contents/MacOS/InternalDisplayOff"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang "$ROOT/Sources/InternalDisplayOff/main.m" \
  -o "$EXECUTABLE" \
  -fobjc-arc \
  -framework Cocoa \
  -framework CoreGraphics \
  -framework IOKit

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$EXECUTABLE"

codesign --force --deep --sign - "$APP"

echo "Built: $APP"
