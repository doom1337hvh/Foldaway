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
# Put together and signed in a temporary folder, then copied into ./build: iCloud Drive (a
# synced Documents folder, say) tags files with extended attributes that codesign refuses to
# sign over, and can add them again faster than they can be cleared. Tags added afterwards
# don't affect the signature.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
STAGED="$STAGE/$APP_NAME.app"
mkdir -p "$STAGED/Contents/MacOS" "$STAGED/Contents/Resources"
cp "$BIN" "$STAGED/Contents/MacOS/$APP_NAME"
# Local symbols only bloat the binary; crash reports keep the global ones.
strip -x "$STAGED/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$STAGED/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$STAGED/Contents/Resources/"
cp "$ROOT/LICENSE" "$STAGED/Contents/Resources/LICENSE.txt"
xattr -cr "$STAGED"

step "Signing"
SIGN_HASH="$(security find-identity -p codesigning 2>/dev/null \
  | awk -v name="\"$SIGN_IDENTITY\"" 'index($0, name) {print $2; exit}')"
if [ -n "$SIGN_HASH" ]; then
  codesign --force --sign "$SIGN_HASH" "$STAGED"
  echo "Signed with \"$SIGN_IDENTITY\""
else
  codesign --force --sign - "$STAGED"
  echo "Signed ad hoc: no \"$SIGN_IDENTITY\" certificate, so macOS permissions reset on every rebuild"
fi
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
ditto --noextattr "$STAGED" "$APP"

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
