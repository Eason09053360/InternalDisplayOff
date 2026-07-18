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
  -framework ApplicationServices \
  -framework CoreGraphics \
  -framework IOKit

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$EXECUTABLE"

# Prefer a stable code-signing identity so the Accessibility (TCC) grant
# survives rebuilds. Ad-hoc signatures change their cdhash on every build,
# which silently invalidates the granted permission even though the toggle in
# System Settings still looks ON. Set SIGN_IDENTITY to a code-signing identity
# name (see: security find-identity -v -p codesigning) to use it; otherwise we
# fall back to ad-hoc.
SIGN_IDENTITY="${SIGN_IDENTITY:-InternalDisplayOff Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "Signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  echo "No stable identity ('$SIGN_IDENTITY') found; signing ad-hoc."
  echo "  (Accessibility permission will need re-granting after each rebuild.)"
  codesign --force --deep --sign - "$APP"
fi

echo "Built: $APP"
