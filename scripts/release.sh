#!/bin/bash
# Builds Foldaway and packages it for a GitHub release:
#
#   dist/Foldaway-<version>.zip
#   dist/Foldaway-<version>.dmg
#   dist/SHA256SUMS.txt
#
# The version comes from Resources/Info.plist (CFBundleShortVersionString); bump it, and
# CFBundleVersion, before each release.
#
# Releases must be signed with the same "Foldaway Local Signing" certificate every time
# (scripts/create-signing-cert.sh). macOS ties the permission people grant Foldaway (Screen
# Recording) to that signature, so a release signed any other way makes everyone grant it
# again. Keep a backup of the certificate (see docs/RELEASING.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Foldaway.app"
DIST="$ROOT/dist"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
NAME="Foldaway-$VERSION"

step() { printf '\n==> %s\n' "$1"; }

"$ROOT/scripts/build.sh"

step "Checking the signature"
# iCloud Drive may have tagged the app again since it was signed; the tags aren't part of it.
xattr -cr "$APP"
codesign --verify --deep --strict "$APP"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
AUTHORITY="$(awk -F= '/^Authority=/ {print $2; exit}' <<<"$DETAILS")"
if [ "$AUTHORITY" != "Foldaway Local Signing" ] && [ "${ALLOW_ADHOC:-}" != "1" ]; then
  echo "The app isn't signed with \"Foldaway Local Signing\" (got: ${AUTHORITY:-ad hoc})."
  echo "Everyone would have to allow Screen Recording for Foldaway again after updating."
  echo "Restore the certificate (docs/RELEASING.md), or set ALLOW_ADHOC=1 to release anyway."
  exit 1
fi
echo "Signed by $AUTHORITY"

step "Packaging $NAME"
rm -rf "$DIST"
mkdir -p "$DIST"
# ditto keeps the framework's symlinks and the signature intact. The local file attributes
# macOS adds (provenance and the like) are left out; the signature doesn't cover them.
CLEAN=(--norsrc --noextattr --noqtn --noacl)
ditto -c -k "${CLEAN[@]}" --keepParent "$APP" "$DIST/$NAME.zip"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "${CLEAN[@]}" "$APP" "$STAGING/Foldaway.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "Foldaway $VERSION" -srcfolder "$STAGING" -fs HFS+ \
  -format UDZO -ov "$DIST/$NAME.dmg"

(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)

step "Done"
ls -lh "$DIST"
cat "$DIST/SHA256SUMS.txt"
cat <<NEXT

Next:
  git tag v$VERSION && git push origin v$VERSION
  Then create a release for v$VERSION on GitHub and attach the three files in dist/.
NEXT
