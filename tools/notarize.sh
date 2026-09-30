#!/usr/bin/env bash
# Notarize + staple a signed Anomalous.app.
# Usage:  source ~/.config/anomalous/signing.env && ./tools/notarize.sh [app]
set -euo pipefail

: "${APPLE_ID:?source ~/.config/anomalous/signing.env first}"
: "${APPLE_PASSWORD:?missing APPLE_PASSWORD}"
: "${APPLE_TEAM_ID:?missing APPLE_TEAM_ID}"

APP="${1:?Pass the explicit Release/Anomalous.app path}"
[[ "$APP" == */Release/Anomalous.app ]] || { echo "✗ expected an explicit Release/Anomalous.app artifact"; exit 1; }
[ -d "$APP" ] || { echo "✗ app not found: $APP"; exit 1; }

ZIP="$(dirname "$APP")/Anomalous-notarize.zip"
echo "▸ zipping $APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "▸ submitting to Apple (waits)"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait

echo "▸ stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
echo "✓ notarized + stapled: $APP"
spctl -a -vv --type execute "$APP"
