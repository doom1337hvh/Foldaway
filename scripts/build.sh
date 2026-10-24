#!/bin/bash
# Builds Foldaway.app into ./build. Needs only the Xcode Command Line Tools.
#
#   scripts/build.sh            build ./build/Foldaway.app
#   scripts/build.sh --install  also copy it to ~/Applications and launch it
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Foldaway"
APP="$ROOT/build/$APP_NAME.app"

# Signing with a stable certificate (made once by scripts/create-signing-cert.sh) keeps the
# Accessibility and Screen Recording permissions across rebuilds. Without it, builds are signed
# ad hoc and macOS treats every rebuild as a new app.
SIGN_IDENTITY="${SIGN_IDENTITY:-Foldaway Local Signing}"

step() { printf '\n==> %s\n' "$1"; }

step "Building $APP_NAME"
swift build --package-path "$ROOT" -c release --arch arm64
BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/$APP_NAME"

step "Assembling $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# Local symbols only bloat the binary; crash reports keep the global ones.
strip -x "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

step "Signing"
# Finder and iCloud Drive tag files with extended attributes that codesign refuses to sign over.
xattr -cr "$APP"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGN_IDENTITY\"" 'index($0, name) {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
  codesign --force --sign "$SIGN_HASH" "$APP"
  echo "Signed with \"$SIGN_IDENTITY\""
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc: no \"$SIGN_IDENTITY\" certificate, so macOS permissions reset on every rebuild"
fi

echo
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  step "Installing to ~/Applications"
  DEST="$HOME/Applications/$APP_NAME.app"
  pkill -x "$APP_NAME" 2>/dev/null && sleep 0.5 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
