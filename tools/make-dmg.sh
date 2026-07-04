#!/usr/bin/env bash
# Build a notarized, drag-to-install DMG for Anomalous.
#
# The app inside MUST already be Developer ID-signed + notarized + stapled
# (run tools/sign.sh then tools/notarize.sh first). This wraps it in a DMG
# with an /Applications drop target, then signs + notarizes + staples the DMG
# itself so the download is Gatekeeper-clean offline.
#
# Usage:
#   source ~/.config/anomalous/signing.env
#   ./tools/make-dmg.sh [path/to/Anomalous.app] [outdir]
#
# Defaults: latest Release build → ./dist/Anomalous-<version>.dmg
set -euo pipefail

: "${APPLE_ID:?source ~/.config/anomalous/signing.env first}"
: "${APPLE_PASSWORD:?missing APPLE_PASSWORD}"
: "${APPLE_TEAM_ID:?missing APPLE_TEAM_ID}"

TEAM_ID="${APPLE_TEAM_ID}"
DEV_ID="Developer ID Application: Michael Sitarzewski (${TEAM_ID})"
HERE="$(cd "$(dirname "$0")/.." && pwd)"

APP="${1:-$(ls -td "$HOME"/Library/Developer/Xcode/DerivedData/Anomalous-*/Build/Products/Release/Anomalous.app | head -1)}"
[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }
OUTDIR="${2:-$HERE/dist}"
mkdir -p "$OUTDIR"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.1.0)"
VOL="Anomalous"
DMG="$OUTDIR/Anomalous-$VERSION.dmg"

# --- window/icon layout (tweak here) ---
WIN_W=430; WIN_H=260          # DMG window size
ICON_SIZE=80                  # icon size in the window
WIN_LEFT=200; WIN_TOP=150
APP_X=115;  APP_Y=120         # Anomalous.app icon position
APPS_X=315; APPS_Y=120        # /Applications drop-target position

echo "▸ verifying the app is signed + notarized (its ticket rides inside the DMG)"
codesign --verify --strict "$APP"
spctl -a -vv --type exec "$APP" 2>&1 | grep -q "accepted" \
  || { echo "✗ app is not Gatekeeper-accepted — run sign.sh + notarize.sh first"; exit 1; }

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/Anomalous.app"
ln -s /Applications "$STAGING/Applications"

echo "▸ building read-write DMG to style the window"
TMPDMG="$(mktemp -u).dmg"
SIZE_MB=$(( $(du -sm "$STAGING" | awk '{print $1}') + 20 ))
hdiutil create -volname "$VOL" -srcfolder "$STAGING" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$TMPDMG" >/dev/null
rm -rf "$STAGING"

DEV="$(hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG" | grep '/Volumes/' | awk '{print $1}')"
sleep 1
# Strip hidden cruft so it isn't visible to users who browse with hidden files
# shown (and so the window holds exactly two items: the app + Applications).
rm -rf "/Volumes/$VOL/.fseventsd" "/Volumes/$VOL/.Trashes" 2>/dev/null || true
echo "▸ applying Finder layout (${ICON_SIZE}px icons, ${WIN_W}×${WIN_H} window)"
osascript <<EOF
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {$WIN_LEFT, $WIN_TOP, $((WIN_LEFT+WIN_W)), $((WIN_TOP+WIN_H))}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to $ICON_SIZE
    set position of item "Anomalous.app" of container window to {$APP_X, $APP_Y}
    set position of item "Applications" of container window to {$APPS_X, $APPS_Y}
    -- re-assert bounds AFTER icon changes (Finder can nudge them) + settle
    set the bounds of container window to {$WIN_LEFT, $WIN_TOP, $((WIN_LEFT+WIN_W)), $((WIN_TOP+WIN_H))}
    update without registering applications
    delay 3
    close
  end tell
  delay 1
  tell disk "$VOL"
    open
    delay 1
    close
  end tell
end tell
EOF
sync; sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1 || diskutil eject "$DEV" >/dev/null 2>&1 || true

echo "▸ compressing → $DMG"
rm -f "$DMG"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMPDMG"

echo "▸ signing DMG"
codesign --force --sign "$DEV_ID" --timestamp "$DMG"

echo "▸ notarizing DMG (waits for Apple)"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$TEAM_ID" --wait

echo "▸ stapling DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "✓ DMG ready: $DMG"
spctl -a -vv --type open --context context:primary-signature "$DMG" 2>&1 | head -3 || true
