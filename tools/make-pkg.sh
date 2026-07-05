#!/usr/bin/env bash
# Build a notarized Developer ID .pkg installer for Anomalous.
#
# REQUIRES a "Developer ID Installer" certificate — this is SEPARATE from the
# "Developer ID Application" cert that signs the app/DMG. Create one (free) at
# Apple Developer → Certificates, Identifiers & Profiles → Certificates → +
# → "Developer ID Installer", download + double-click to add to the keychain.
#
# Usage:
#   source ~/.config/anomalous/signing.env
#   ./tools/make-pkg.sh [path/to/Anomalous.app] [outdir]
set -euo pipefail

: "${APPLE_ID:?source ~/.config/anomalous/signing.env first}"
: "${APPLE_PASSWORD:?missing APPLE_PASSWORD}"
: "${APPLE_TEAM_ID:?missing APPLE_TEAM_ID}"

TEAM_ID="${APPLE_TEAM_ID}"
INSTALLER_ID="Developer ID Installer: Michael Sitarzewski (${TEAM_ID})"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Anomalous-*/Build/Products/Release/Anomalous.app | head -1)}"
[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }
OUTDIR="${2:-$HERE/dist}"; mkdir -p "$OUTDIR"

# The app must already be Developer ID-signed + notarized + stapled.
codesign --verify --strict "$APP"
security find-identity -v 2>/dev/null | grep -q "Developer ID Installer" \
  || { echo "✗ No 'Developer ID Installer' certificate in the keychain."; \
       echo "  Create one at developer.apple.com → Certificates → + → Developer ID Installer."; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
PKG="$OUTDIR/Anomalous-$VERSION-macOS-arm64.pkg"

echo "▸ building + signing component pkg (installs to /Applications)"
pkgbuild \
  --component "$APP" \
  --install-location /Applications \
  --identifier bot.anomalous.sensor.pkg \
  --version "$VERSION" \
  --sign "$INSTALLER_ID" \
  "$PKG"

echo "▸ notarizing pkg (waits for Apple)"
xcrun notarytool submit "$PKG" \
  --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID" --wait

echo "▸ stapling pkg"
xcrun stapler staple "$PKG"
xcrun stapler validate "$PKG"

echo "✓ pkg ready: $PKG"
spctl -a -vv --type install "$PKG" 2>&1 | head -3 || true
echo "  Add it to the release:  gh release upload v$VERSION -R msitarzewski/anomalous-mac \"$PKG\""
